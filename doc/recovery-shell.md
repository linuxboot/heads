# Recovery Shell

The Recovery Shell is a full bash environment within the Heads initrd.  It
gives direct access to block devices, GPG, TPM tools, and flash utilities.

## Entering the Recovery Shell

- At power-on: press `r` repeatedly during the Heads splash screen.
- From the Heads GUI: `Options -> Recovery Shell`.

## Limitations

The Recovery Shell boots with PCR 4 set to `recovery` instead of
`normal-boot`.  This means:

- **TPM-sealed secrets will not unseal** — PCRs no longer match.
- TOTP/HOTP sealing and TPM Disk Unlock Key creation/unsealing do not work.
- To perform seal/unseal operations return to the normal GUI boot.

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
