# Recovery Shell

The Recovery Shell is a full bash environment within the Heads initrd.  It
gives direct access to block devices, GPG, TPM tools, and flash utilities.

## Entering the Recovery Shell

- At power-on: press `r` repeatedly during the Heads splash screen.
- From the Heads GUI: `Options -> Recovery Shell`.
- If `CONFIG_BOOT_RECOVERY_SERIAL` is enabled by the board config, `/init`
  starts a serial `pause_recovery` path that waits for Enter, then launches
  recovery on that serial TTY.

## Limitations

The Recovery Shell boots with PCR 4 set to `recovery` instead of
`normal-boot`.  This means:

- **TPM-sealed secrets will not unseal** — PCRs no longer match.
- TOTP/HOTP sealing and TPM Disk Unlock Key creation/unsealing do not work.
- To perform seal/unseal operations return to the normal GUI boot.

## Authentication

`gpg_auth()` in `initrd/etc/functions.sh` guards the recovery shell and
external media boot entry.  On boards with `CONFIG_HAVE_GPG_KEY_BACKUP=y`,
recovery calls `gpg_auth()` before opening the bash prompt, and
`media-scan.sh` (called from `usb-init.sh`) also invokes `gpg_auth` before
scanning USB devices.  TPM operations, flash/update, GPG management, and
all other GUI menu functions are NOT gated by this check — they remain
accessible from the main menu.

After OEM Factory Reset / Re-Ownership or the reprovision flow,
`CONFIG_HAVE_GPG_KEY_BACKUP=y` is persisted in the user config stored in
CBFS, so that recovery shell and USB boot authentication is enforced
even on boards where the compile-time default differs.

To enable `gpg_auth` during OEM Factory Reset / Re-Ownership, answer Y to
"format an encrypted USB Thumb drive to store GPG key material? (Required
to enable GPG authentication)".  Choosing N skips the backup drive creation
and leaves `gpg_auth` disabled (recovery shell and USB boot remain
unauthenticated).

**What `gpg_auth` guards — and what it does not:**

`gpg_auth()` is called from exactly two places: the recovery shell entry
point (`recovery()` in `functions.sh`) and the USB/external media boot
scanner (`media-scan.sh`, called from `usb-init.sh`).  The normal GUI boot
flow (`gui-init.sh`) does NOT invoke `gpg_auth()` — it handles GPG key
presence through its own `check_gpg_key` mechanism, which is separate from
`gpg_auth`.

Many destructive operations are already available from the GUI without
`gpg_auth`: the user can reflash firmware (`Options -> Flash/Update`),
wipe GPG keys and config (`Options -> Clear GPG key(s) and reset all user
settings`), reset the TPM, re-sign boot hash manifests
(`Options -> Update checksums and sign all files in /boot`),
and generate new GPG keys.  All of these are tamper-evident — the TPM
PCR measurements and HOTP/TOTP codes will detect changes.

What `gpg_auth` prevents:

- **Recovery shell entry without authentication.**  The recovery shell
  gives unrestricted root access to raw block devices, SPI flash, TPM
  commands, and GPG key operations.  The GUI does not expose
  `flash.sh -r` (dump running firmware).  An attacker with recovery
  shell access could dump the full SPI flash for offline analysis, forge
  a malicious firmware image, and flash it back undetected.  `gpg_auth`
  blocks this path.  (Note: an attacker with physical access can still
  extract the SPI flash via an external programmer after disassembly —
  `gpg_auth` only protects the in-software path through the running
  system.)

- **USB/external media boot from an untrusted drive.**  `media-scan.sh`
  (called from `usb-init.sh`) invokes `gpg_auth` before scanning USB
  devices.  When `CONFIG_HAVE_GPG_KEY_BACKUP` is not set, `gpg_auth`
  is a no-op and USB boot proceeds without restriction.  When the flag
  is set (after OEM factory reset or reprovision), the user must
  authenticate with their GPG smartcard before external media boot is
  allowed.  (Note: the boot process locks the SPI flash controller,
  making Heads the only internal flasher.  An attacker booting from
  USB cannot reflash the firmware even with root access.  External
  SPI flashing via hardware programmer after disassembly is always
  possible regardless — see [wp-notes.md](wp-notes.md).)

**What `gpg_auth` does NOT prevent:**

- Reflashing firmware through the GUI
- Wiping GPG keys, config, or TPM state through the GUI
- Re-signing `/boot` through the GUI
- Any operation the user can perform from the main menu

**How it works:** `gpg_auth()` generates a random nonce, the user signs it
with their GPG key (smartcard or backup USB drive) within 3 attempts, and the
signature is verified against the ROM-fused public keyring.  On failure,
`DIE` exits the session.  With `CONFIG_RESTRICTED_BOOT=y`, the shell is
blocked entirely and the system reboots after 5 seconds.

**Without authentication:** If the board does not have
`CONFIG_HAVE_GPG_KEY_BACKUP` set, `gpg_auth()` is a no-op and the recovery
shell opens without prompting.

## Resetting Configuration

`Options -> Change configuration settings -> 'r'` (`Clear GPG key(s) and reset
all user settings`) wipes the running system configuration:

- Clears `~/.gnupg` (GPG keyring, trustdb)
- Deletes `/boot/kexec*.txt` and `/boot/kexec.sig` (boot hash manifests,
  checksums, rollback counter, signatures)
- Removes all `heads/` files from CBFS (keyring, trustdb, config.user)
- Reflashes the cleaned firmware
- Resets the TPM if present

**Attestation impact:** Removing `heads/` files from CBFS changes the SPI flash
contents measured into PCR 7 by `cbfs-init` at next boot.  Combined with the
TPM reset, TOTP/HOTP unseal will fail on the next boot — Heads shows the
standard red-menu TOTP error prompt.

**Recovery after wipe:** Run OEM Factory Reset / Re-Ownership (Options -> 'F')
to fully reprovision ([configuring-keys.md](configuring-keys.md)).  If you have a
GPG key backup USB drive from a previous in-memory OEM reset, use
`GPG Options -> 'k' Reprovision USB Security dongle from GPG key backup`
to restore subkeys from the backup ([configuring-keys.md#restoring-keys-from-backup](configuring-keys.md#restoring-keys-from-backup)),
then flash the public key to ROM, re-sign /boot, and generate new TOTP/HOTP
secrets.

## Common Operations

### Manual boot

```bash
kexec-boot -b /boot -e 'foo|elf|kernel /vmlinuz|initrd /initrd.img|append root=/dev/whatever'
```

### Sign /boot after manual changes

```bash
mount /dev/sdaX /boot
kexec-sign-config -p /boot
```

### Change GPG User PIN (locked out)

With the dongle inserted:

```bash
gpg --change-pin
```

Enter the Admin PIN when prompted, then set a new User PIN.

### Read the TCPA event log (debug PCR mismatches)

```bash
cbmem -L
```

Shows what was measured into each PCR during the current boot.  Useful for
diagnosing unexpected TPM unseal failures.

### Mount a USB drive

```bash
mount-usb
```

Mounts the first detected USB partition at `/media`.  For a specific device:

```bash
mount-usb --device /dev/sdb1 --mode rw
```

### Flash firmware manually

```bash
mount-usb
flashprog -p internal -w /media/heads-board-version.rom
```

Verify internal flash is unlocked first:

```bash
flashprog -p internal
```

### Sign a detached ISO (for verified OS install from Recovery Shell)

```bash
mount-usb --mode rw
cd /media
gpg --detach-sign <iso_name>
reboot
```

## After Recovery Shell Work

If you modified `/boot` or reflashed firmware, return to the GUI and:

1. Generate new TOTP/HOTP secret (`Options -> Generate new HOTP/TOTP secret`).
2. Update checksums and sign `/boot` (`Options -> Update checksums and sign all files in /boot`).
3. Optionally re-seal the TPM Disk Unlock Key by selecting a default boot option.

## PIN Caching

When exiting and re-entering the recovery shell, secrets are wiped and TTY is
re-detected on each iteration. This forces re-authentication (GPG PIN prompt)
on each entry, preventing cached credential reuse across shell sessions.
