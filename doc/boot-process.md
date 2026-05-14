# Heads Boot Process

This document describes the complete boot flow from power-on to OS handoff.

See also: [architecture.md](architecture.md) for component overview,
[tpm.md](tpm.md) for TPM PCR details, [security-model.md](security-model.md)
for the trust model.

---

## Overview

```text
Power-on
  │
  ▼
coreboot (SPI flash)
  │  hardware init, SRTM measurement into PCR 2
  ▼
Linux kernel (coreboot payload, no initramfs)
  │
  ▼
/init  ← first userspace process
  │  mount filesystems, load config, combine user overrides
  ▼
/bin/gui-init  ← main interactive boot loop
  │  TPM preflight, GPG key check, TOTP/HOTP attestation
  ▼
kexec-select-boot
  │  verify /boot hashes + GPG signature, rollback counter
  ▼
kexec  ← hands off to OS kernel
```

---

## Stage 1: /init

`/init` is the first userspace process. It:

1. Mounts virtual filesystems (`/dev`, `/proc`, `/sys`).
2. Loads board defaults from `/etc/config` and the functions library.
3. Runs `cbfs-init` to extract user configuration from CBFS into `/etc/config.user`.
4. Calls `combine_configs()` to merge all `/etc/config*` files into `/tmp/config`,
   then sources `/tmp/config` so all subsequent scripts see the merged settings.
5. If `CONFIG_BOOT_RECOVERY_SERIAL` is set, starts a background `pause_recovery`
  path on that serial TTY (`/dev/ttyS*`) that waits for Enter and then launches
  the recovery shell there.
6. Checks for a quick `r` keypress (100 ms timeout) to drop to a recovery shell
   before any GUI starts.
7. Starts `cttyhack $CONFIG_BOOTSCRIPT` (default: `/bin/gui-init`) under a PID 1
  respawn loop, so the boot script is relaunched if it exits unexpectedly while
  init stays alive.

### Config file merge

```text
/etc/config          (ROM, board defaults)
/etc/config.user     (CBFS, user overrides)
        │
        └─► combine_configs() ─► /tmp/config  (runtime, sourced by all scripts)
```

User settings appear last in the concatenation and therefore override board
defaults. Changes are persisted by reflashing CBFS.

---

## Stage 2: /bin/gui-init

`gui-init` is the main interactive boot agent. It runs as an infinite loop and
handles all user interaction until the OS is handed off via kexec.

### Initialization

On startup, `gui-init` detects the controlling TTY (set by `cttyhack` in `/init`)
and exports it as `HEADS_TTY` and `GPG_TTY`. This ensures that all interactive
prompts and GPG operations reach the correct terminal regardless of stdout/stderr
redirections.

### TPM rollback preflight

Before showing any menu, `gui-init` verifies that the TPM rollback counter is
consistent with `/boot/kexec_rollback.txt`. An inconsistency indicates either a
TPM reset (expected: user must re-seal secrets) or an unexpected state (possible
tampering). On failure, the main menu background is set to error color and the
user is offered recovery options.

### GPG key check (`check_gpg_key`)

`gui-init` counts the keys in the GPG keyring. An empty keyring means no `/boot`
signature can be verified. The user must add a key or perform OEM Factory Reset
before booting.

### TOTP generation (`update_totp`)

`unseal-totp` retrieves the TOTP secret from TPM NVRAM and generates the current
30-second code. If the unseal fails (PCR mismatch, TPM reset, tampered firmware),
`INTEGRITY_GATE_REQUIRED` is set to `y`, which blocks all subsequent TPM secret
sealing until an integrity check passes. See [security-model.md](security-model.md).

### HOTP / hardware token check (`update_hotp`)

If a hardware HOTP token is present (`/bin/hotp_verification`), `gui-init` obtains
the HOTP secret (unsealed from TPM on boards with a TPM; derived from a ROM hash on
boards without one) and asks the token to verify the current code. Result codes:
`0` = success, `4` = wrong code, `7` = not a valid HOTP value.
See [security-model.md](security-model.md#hotp-on-boards-without-a-tpm-rom-hash-mode)
for the no-TPM path.

### Auto-boot

If HOTP succeeded and `CONFIG_AUTO_BOOT_TIMEOUT` is set, a countdown starts and
the default boot entry is selected automatically if the user does not intervene.

### Main menu loop

`show_main_menu` displays the current date, TOTP code, and HOTP status in the
menu title bar. The background color reflects the current integrity state
(normal / warning / error). Options: default boot, refresh TOTP/HOTP, options
menu, system info, power off.

---

## Stage 2b: USB ISO Boot (`kexec-iso-init.sh`)

When booting from an ISO file on USB media, `kexec-iso-init.sh` handles the ISO
boot flow. It is invoked from the "USB ISO Boot" option in the main menu.

### Flow

1. **Signature verification**: Check for `.sig` or `.asc` detached signature
2. **Mount ISO**: Mount the ISO file as loopback device at `/boot`
 3. **Layer 1: initramfs fs compatibility check** (`check_initrd_compat`):
    Before presenting boot options, verify the ISO's initramfs contains kernel
    modules for the USB partition's filesystem (ext4/vfat/exfat).  If the initrd
    can't read the USB filesystem, the kernel won't find the ISO after kexec.
    Also checks for a framebuffer driver (efifb, bochs) needed for display after
    kexec.
    - Parsing boot configs for initrd paths (instead of searching the whole ISO)
    - Unpacking each initrd and checking for required `.ko` files and
      `modules.builtin`
    - Each initrd gets its own independent `[OK]` / `[!]` / (blank) marker in
      `/tmp/kexec_initrd_compat.txt` (the per-initrd flag `initrd_supports_fs` is tracked
      separately from the global `any_supported` flag, so no initrd is silently
      skipped)
    - `[OK]` = initrd has the needed module as `.ko`, has it in
      `modules.builtin`, or has no `.ko` files at all (minimal initrd with
      everything built into the kernel: nothing to check against).
    - `[!]`  = initrd has loadable kernel modules but none for the USB
      filesystem type.  No built-in assumption: we report what we find.
    - Read-only filesystems (iso9660/squashfs/udf) and unmapped fstypes skip
    - All initrds are checked (no early break) so the compat file is complete.
    - Framebuffer results are written to `/tmp/kexec_fb_compat.txt`.  A
      separate warning is shown if no initrd has a known fb driver.
4. **Layer 2: loopback.cfg fast path**: If the ISO has a `loopback.cfg`, parse
   it and resolve GRUB variables (`${iso_path}`, `${isofile}`) to extract the
   ISO kernel params from loopback entries.
5. **Boot param injection**: When Layer 2 resolves nothing (no GRUB vars found
   in loopback.cfg), all common ISO boot methods are injected unconditionally
   as kernel ADD params so the ISO initrd can pick whichever it supports:
   - `iso-scan/filename=/$ISO_PATH`: Ubuntu casper, Fedora dracut
   - `findiso=/$ISO_PATH`: Debian live-boot, NixOS stage-1
   - `img_dev=/dev/disk/by-uuid/$DEV_UUID`: block device containing the ISO
   - `img_loop=$ISO_PATH`: loopback file path (relative)
   - `iso=$DEV_UUID/$ISO_PATH`: UUID/path alternative
   - `live-media=/dev/disk/by-uuid/$DEV_UUID`: device filter (casper, live-boot)
   The kernel ignores parameters it doesn't understand.
   `fromiso=` is intentionally not injected because it conflicts with `findiso=`
   in Debian live-boot's `check_dev()`: `fromiso` mounts the ISO, then `findiso`
   looks for the ISO file inside the mounted ISO (not found), unmounts it,
   leaving orphaned loop devices that get re-scanned -> infinite loop.
   `findiso=` alone covers Debian and NixOS.
   `live-media-path=` is intentionally not injected because the default differs
   per distro (`/live` for Debian, `/casper` for Ubuntu/PureOS, `/LiveOS` for
   Fedora); leaving it unset lets each distro use its own default.
6. **Layer 3: kexec-select-boot**: Launch the standard boot menu with `-u`
   (unique entries, dedup sorted by name).

### Initrd compatibility markers in the boot menu

During Layer 1, `check_initrd_compat` writes per-initrd results to
`/tmp/kexec_initrd_compat.txt`.  `kexec-select-boot` reads this file and shows
`[OK]` or `[!]` at the start of each menu line (before the entry name):

| Marker | Meaning | Behavior |
|--------|---------|----------|
| `[OK]` | Initrd has the USB fs module (as .ko or modules.builtin) | Boot should work |
| `[!]`  | Initrd has loadable modules but none for the USB fs type | May fail after kexec |
| (blank) | Initrd has zero .ko files: can't verify either way | Assume OK (minimal initrd) |
| (none) | Entry has no initrd (memtest, etc.) | No filesystem dependency |

A `NOTE` (3-second sleep, cannot scroll past) is displayed before the menu
explaining the legend.  Markers follow `doc/logging.md` accessibility rules:
text-based, serial-safe, not color-dependent.

### Compatibility note for ext4 and vfat

Initrds with no `.ko` files at all get no marker at all (blank): we can't
verify either way, so nothing is displayed.

### Boot param injection

When Layer 2 (loopback.cfg) resolves no GRUB variables, the following
parameters are injected unconditionally so the ISO initrd can find the USB
partition and the ISO file after kexec, regardless of which distribution's
init system it uses:

| Parameter | Example | Used by |
|-----------|---------|---------|
| `iso-scan/filename=` | `/ISOs/foo.iso` | Ubuntu casper, Fedora dracut |
| `findiso=` | `/ISOs/foo.iso` | Debian live-boot, NixOS stage-1 |
| `img_dev=` | `/dev/disk/by-uuid/UUID` | Block device hint |
| `img_loop=` | `ISOs/foo.iso` | Loopback path |
| `iso=` | `UUID/ISOs/foo.iso` | Alternative path |
| `live-media=` | `/dev/disk/by-uuid/UUID` | Device filter (casper, live-boot) |

---

## Stage 3: kexec-select-boot

Called from the boot menu. Responsible for final verification and OS handoff.

### TPM2 primary key hash check

For TPM2 systems, verifies the SHA-256 hash of the TPM2 primary key handle
against `/boot/kexec_primhdl_hash.txt` (if the file exists). A mismatch means
the TPM2 primary key was regenerated without updating the stored hash.

### Boot hash verification (`verify_global_hashes`)

`verify_checksums` checks the SHA-256 of every `/boot` file against
`kexec_hashes.txt`, then verifies `kexec.sig` with `gpgv`. A hash mismatch or
invalid signature causes `die`: there is no "boot anyway" path.

Optionally, root partition hashes are also checked if `CONFIG_ROOT_CHECK_AT_BOOT=y`.

### Rollback counter verification (`verify_rollback_counter`)

The TPM monotonic counter index is read from `/boot/kexec_rollback.txt` and the
counter is read from the TPM. The SHA-256 of the counter file is then checked
against the hash stored in `kexec_rollback.txt`. Any discrepancy aborts the boot.

### OS boot execution (`do_boot`)

If a TPM-sealed LUKS Disk Unlock Key (DUK) is configured, `kexec-insert-key`
unseals the DUK and injects it into a minimal initrd prepended to the OS initrd.
The OS kernel then finds the key and unlocks LUKS without prompting the user.

`kexec-boot` performs the final `kexec` system call to hand off to the OS kernel.

---

## Recovery shell

The recovery shell is an authenticated environment. Entering it extends TPM
PCR 4 with `"recovery"`, permanently invalidating TOTP/HOTP/LUKS unseal for
the rest of the boot session. See [tpm.md](tpm.md).
