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
5. Checks for a quick `r` keypress (100 ms timeout) to drop to a recovery shell
   before any GUI starts.
6. Execs `cttyhack $CONFIG_BOOTSCRIPT` (default: `/bin/gui-init`), which sets up
   a controlling TTY and hands off to the boot script.

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

When booting from an ISO file on USB media, `kexec-iso-init.sh` handles:

1. **Signature verification**: Check for `.sig` or `.asc` detached signature
2. **Mount ISO**: Mount the ISO file as loopback device
3. **Detect USB filesystem**: Get filesystem type from USB stick (ext4/vfat/exfat)
4. **Validate initrd support**: Check ISO initrd supports:
   - USB storage drivers
   - Loopback device
   - Filesystem of USB stick
   - Boot quirk script to find ISO on USB (findiso/live-media/boot=casper)
5. **Warning dialog**: If ISO may not boot, show warning and allow cancel

### Known Compatible ISOs (tested 2026-04)

| Distribution | Boot Param | USB FS | Status |
|--------------|------------|--------|--------|
| Ubuntu Desktop | iso-scan/filename | ext4/vfat/exfat | works |
| Debian Live kde/xfce | findiso | ext4/vfat/exfat | works |
| Tails standard | live-media=removable | ext4/vfat | works |
| Tails exfat-support ISO | live-media=removable | exfat | works |
| Fedora Workstation | boot=casper / rd.live.image | ext4/vfat | works |
| Fedora Silverblue | inst.stage2= / inst.repo= | ext4/vfat | works |
| Qubes OS R4.3+ | inst.repo=hd:LABEL= | ext4/vfat | works |
| NixOS | findiso | ext4/vfat/exfat | works |
| PureOS | boot=casper | ext4/vfat/exfat | works |

### Known Incompatible ISOs

| Distribution | Reason | Workaround |
|--------------|--------|------------|
| Debian DVD | CD-only design, no USB boot | `dd` or use Debian netinst |

**Fedora Silverblue / Qubes OS**: These use Anaconda installer with `inst.stage2=` or `inst.repo=` parameters. The initrd includes Dracut's iso-scan module which can find ISO files on USB when the correct LABEL/UUID is provided. Works with ISO file boot when USB has matching label.

### References

- [GRUB2 loopback ISO boot](https://a1ive.github.io/grub2_loopback.html)
- [Arch Linux ISO Boot](https://wiki.archlinux.org/title/ISO_Spring_(%27Loop%27_device))
- [Debian USB creation](https://wiki.debian.org/DebianInstaller/CreateUSBMedia)

---

Called from the boot menu. Responsible for final verification and OS handoff.

### TPM2 primary key hash check

For TPM2 systems, verifies the SHA-256 hash of the TPM2 primary key handle
against `/boot/kexec_primhdl_hash.txt` (if the file exists). A mismatch means
the TPM2 primary key was regenerated without updating the stored hash.

### Boot hash verification (`verify_global_hashes`)

`verify_checksums` checks the SHA-256 of every `/boot` file against
`kexec_hashes.txt`, then verifies `kexec.sig` with `gpgv`. A hash mismatch or
invalid signature causes `die` — there is no "boot anyway" path.

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
