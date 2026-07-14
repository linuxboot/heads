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

When `CONFIG_HAVE_GPG_KEY_BACKUP=y` (set during OEM Factory Reset / Re-Ownership
with the in-memory backup path, or by running the reprovision flow from the GPG
Management Menu), the recovery shell requires GPG smartcard authentication before
the bash prompt opens.

**Scope:** This guards recovery shell and external media/USB boot entry
(`media-scan.sh` also calls `gpg_auth` before scanning USB).  TPM operations,
flash/update, GPG management, and all other GUI menu functions are NOT gated
by this check — they remain accessible from the main menu.

**What it guards against:** Recovery shell access gives full bash within the
initrd, including direct block device read/write, SPI flash access, TPM
commands, and GPG key operations.  An unauthenticated physical attacker with
shell access could flash malicious firmware, delete `/boot` content, lock TPM
PIN counters permanently, sign unauthorized `/boot` content, or attempt
LUKS disk decryption.

**How it works:** `gpg_auth()` in `initrd/etc/functions.sh` generates a random
nonce, the user signs it with their GPG key (smartcard or backup USB drive)
within 3 attempts, and the signature is verified against the ROM-fused public
keyring.  On failure, `DIE` exits the session.  With `CONFIG_RESTRICTED_BOOT=y`,
the shell is blocked entirely and the system reboots after 5 seconds.

**Without authentication:** If `CONFIG_HAVE_GPG_KEY_BACKUP` is not set,
`gpg_auth()` is a no-op and the recovery shell opens without prompting.

## Resetting Configuration

`Options -> Change configuration settings -> 'r'` (`Clear GPG key(s) and reset
all user settings`) wipes the running system configuration:

- Clears `~/.gnupg` (GPG keyring, trustdb)
- Deletes `/boot/kexec*` (signatures, checksums, boot options)
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
