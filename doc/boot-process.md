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

Merges board defaults, user overrides, and CBFS config into `/tmp/config`.
See [architecture.md#configuration-system](architecture.md#configuration-system).

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

## Stage 2b: USB boot (`kexec-iso-init.sh`)

When booting from an ISO file on USB media, `kexec-iso-init.sh` handles the ISO
boot flow. Invoked from Options → Boot Options → "USB boot".

### Flow (execution order)

The ISO boot flow consists of 7 steps, with branching after step 3:

```
  Step 1: Signature verification ──FAIL→ abort
  Step 2: Mount ISO
  Step 3: loopback.cfg?
    ├── FOUND → Step 4: Fast-path gate
    │    ├── Verify ISO compatibility → Step 5 → Step 6 → Step 7 (menu)
    │    └── Boot ISO now           → Step 6 → Step 7 (menu)
    └── NOT FOUND → Step 4: Probing gate
         ├── Verify ISO compatibility → Step 5 → Step 6 → Step 7 (menu)
         ├── Boot ISO now           → Step 6 → Step 7 (menu)
         └── Cancel → back to ISO selection
```

1. **Signature verification**: Check for `.sig` or `.asc` detached signature.
   Unsigned ISOs prompt the user before proceeding.

2. **Mount ISO**: Mount the ISO file as a loopback device at `/boot`.

3. **loopback.cfg**: Read `boot/grub/loopback.cfg` or `boot/grub2/loopback.cfg`
   — a ~2 KB file check vs. unpacking the entire initramfs (200+ MB).
   Three outcomes:

    - **Found + GRUB vars present** (`${iso_path}` or `${isofile}` in
      `loopback.cfg`): Variables are stripped — unresolved references
      would be passed literally to the kernel (security risk).  Universal
      ADD params provide absolute ISO paths.  Fast-path gate offers
      "Verify ISO compatibility" or "Boot ISO now."  Only Ubuntu 26.04
      uses GRUB vars in its loopback.cfg.

    - **Found + no GRUB vars** (most ISOs — Debian, Fedora, Tails,
      Kicksecure, NixOS, openSUSE KDE Live): Fast-path gate with two
      options:
      - **Verify ISO compatibility** (recommended) — run step 5
        (initramfs + kernel scan, ~30-60s), then boot menu with markers.
      - **Boot ISO now** — skip step 5, go directly to boot menu.
        Entries appear without compatibility markers (unverified).
       Universal fallback ADD params handle ISO-finding kernel parameters.

    - **Not found**: Skip to the probing gate below.  No `loopback.cfg`
      could be detected on this ISO.

4. **Probing gate** (only when step 3 found nothing):
   When the ISO has no `loopback.cfg`, a three-option whiptail dialog asks
   how to proceed before the expensive step 5 scan:

    - **Verify ISO compatibility** — run step 5 (unpack + kernel scan, ~30-60s).
    - **Boot ISO now** — skip step 5, boot menu with no markers.
    - **Cancel** — return to ISO file browser.

5. **Initramfs compatibility check** (`check_initramfs_compat`, runs when user
    chose "Verify ISO compatibility" at either gate):
   Verify the ISO's initramfs contains kernel modules for the USB partition's
    filesystem (ext4/vfat/exfat).  If the initramfs cannot read the USB filesystem,
    the kernel won't find the ISO after kexec.  Display driver detection runs
    against the decompressed kernel — checks for built-in vesafb, vesadrm,
    or simpledrm symbols via _check_kernel_probe_driver().
    - Parsing boot configs for initramfs paths (instead of searching the whole ISO)
    - Unpacking each initramfs and checking for required `.ko` files and
      `modules.builtin`
    - Each initramfs gets its own independent `[OK]` / `[!]` / (blank) fs-compat
      marker and `[OK]:graphics (<driver>)` / `[~]:drm` / `[!]` display marker.
    - **Per-pair kernel check**: Each (kernel, initramfs) pair is checked
      independently.  A kernel with built-in vesafb/vesadrm/simpledrm has its
      display marker upgraded from `[~]:drm` to `[OK]:graphics (<driver>)`.  This
      correctly handles ISOs where one kernel variant has a display driver and
      another doesn't.
    - Read-only filesystems (iso9660/squashfs/udf) and unmapped fstypes skip.
    - All initramfs archives are checked (no early break) so the compat file is complete.
   - A filesystem warning is shown if no initramfs has the USB fs module.
   - A display warning is shown if no kernel has a display driver.

6. **Boot param injection**: All common ISO boot methods are unconditionally
        injected as kernel ADD params — the kernel passes all of them to
    userspace via /proc/cmdline.  The ISO's initramfs scripts (casper,
    live-boot, dracut) recognize only the parameters they need and ignore
    the rest.  When loopback.cfg contains GRUB variable references, those
    are stripped (removed via `_strip_grub_vars()`) — the universal
    combined with the universal fallback.
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

7. **kexec-select-boot**: Launch the boot menu.  Entries show markers
    when step 5 ran, or no markers when step 5 was bypassed.

### Exit trap / cleanup

An `EXIT` trap is installed early in the script.  On any exit (success, error,
or user cancel) the ISO loopback mount is unmounted from `/boot` and temporary
compatibility files are cleaned up.  This prevents stale mounts if the user
returns to the ISO browser and selects a different ISO.

### Initramfs compatibility markers in the boot menu

During step 5 (initramfs compat), `check_initramfs_compat` writes per-initramfs
results to `/tmp/kexec_initrd_compat.txt` (filesystem module check) and
`/tmp/kexec_display_driver.txt` (kernel display driver check via symbol
detection — the kernel's built-in driver binds before initramfs runs).
`kexec-select-boot` combines these two signals into three-state menu
markers shown before each entry name:

| Marker | Meaning | User experience |
|--------|---------|-----------------|
| `[OK]` | USB filesystem module found and kernel display driver confirmed | Boots with continuous or quickly-restored display |
| `[~]` | Display driver not found in kernel (`[~]:drm`), or USB fs missing | Boots with caveat — brief blank or degraded |
| `[X]` | No display driver, initramfs module missing, or unknown marker | Screen stays blank until native driver loads |
| (blank) | Initramfs has no .ko files: can't verify | Assume OK (minimal initramfs) |

When the user chose "Boot ISO now" at either gate (fast-path or probing),
step 5 was bypassed and no compat files exist: all entries appear without
a marker prefix.  A STATUS line explains why.

A `STATUS` line is displayed before the menu.
When step 5 ran, it shows the `[OK]/[~]` legend describing the markers.
When step 5 was skipped, it shows
"Compatibility not checked -- entries may still work" instead.
Markers follow `doc/logging.md` accessibility rules: text-based,
serial-safe, not color-dependent.

### Compatibility note for ext4 and vfat

Initramfs archives with no `.ko` files at all get no marker at all (blank): we can't
verify either way, so nothing is displayed.

### Boot param injection

Universal ADD params are always injected via `_build_universal_add()`.
For the full parameter reference, `fromiso=` conflict rationale, and
per-distro requirements, see [iso_boot.md](iso_boot.md).

---

## Stage 3: kexec-select-boot

Called from the boot menu. Responsible for final verification and OS handoff.

### TPM2 primary key hash check

For TPM2 systems, verifies the SHA-256 hash of the TPM2 primary key handle
against `/boot/kexec_primhdl_hash.txt` (if the file exists). A mismatch means
the TPM2 primary key was regenerated without updating the stored hash.

### Boot hash verification (`verify_global_hashes`)

`verify_checksums` checks the SHA-256 of every `/boot` file against
`kexec_hashes.txt`, then verifies `kexec.sig` with `gpgv`.  On mismatch,
an interactive whiptail menu offers options: investigate discrepancies,
update checksums, or return to the main menu.

Optionally, root partition hashes are also checked if `CONFIG_ROOT_CHECK_AT_BOOT=y`.

### Rollback counter verification (`verify_rollback_counter`)

The TPM monotonic counter index is read from `/boot/kexec_rollback.txt` and the
counter is read from the TPM. The SHA-256 of the counter file is then checked
against the hash stored in `kexec_rollback.txt`. Any discrepancy aborts the boot.

### OS boot execution (`do_boot`)

If a TPM-sealed LUKS Disk Unlock Key (DUK) is configured, `kexec-insert-key`
unseals the DUK and injects it into a minimal initramfs prepended to the OS initramfs.
The OS kernel then finds the key and unlocks LUKS without prompting the user.

`kexec-boot` performs the final `kexec` system call to hand off to the OS kernel.
For details on how the kernel command line is assembled from boot entry params,
ADD params, and Board ADD, see [kexec_handoff.md](kexec_handoff.md#kernel-command-line-construction).
Just before kexec, if `CONFIG_FINALIZE_PLATFORM_LOCKING=y`, `lock_chip.sh` triggers
a chipset-level PR0 lockdown via SMI (`io386` writes to port `0xb2`), setting
`FLOCKDN` in the SPI controller.  Once locked, the protected flash region becomes
read-only until the next system reset — the OS cannot modify the firmware.  See
[wp-notes.md](wp-notes.md#pr0-chipset-locking).

---

## Recovery shell

The recovery shell is an authenticated environment. Entering it extends TPM
PCR 4 with `"recovery"`, permanently invalidating TOTP/HOTP/LUKS unseal for
the rest of the boot session. See [tpm.md](tpm.md).
