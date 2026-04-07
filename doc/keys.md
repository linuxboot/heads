# Keys and Secrets in Heads

Heads uses several distinct secrets and keys, each protecting a different layer
of the system.  Understanding what each one does helps in choosing appropriate
passphrases and in recovery scenarios.

## TPM Owner Passphrase

The TPM is "owned" by the user.  Setting the owner passphrase clears all
existing NVRAM and spaces.  An attacker who controls this passphrase can reseal
the TPMTOTP shared secret but cannot decrypt the disk without the Disk Recovery
Key passphrase.

**Recommended length:** 2 Diceware words (1-32 characters, TPM hardware limit).

## TPMTOTP / HOTP Shared Secret

A random 20-byte value generated during OEM Factory Reset / Re-Ownership.

- **TOTP (smartphone):** sealed into TPM NVRAM against PCR values; on each
  boot Heads unseals it if PCRs match and displays the current TOTP code for
  comparison against a phone app.  Requires correct UTC time in Heads.
- **HOTP (USB Security dongle):** same secret sealed to dongle; dongle
  verifies automatically and shows a green/red LED.  No accurate time needed.

A new secret must be generated after each firmware update.

## TPM Counter Key

Increment-only counters prevent rollback attacks.  An attacker controlling
this key can only cause a denial-of-service by incrementing the counter.

## GPG Admin PIN

Protects management operations on the OpenPGP smartcard inside the USB
Security dongle.  Required to seal HOTP measurements under Heads.

- Locks after **3 consecutive wrong attempts** — do not forget it.
- Can be used to unblock a locked GPG User PIN via `gpg --change-pin`.
- **Recommended length:** 2 Diceware words (6-25 characters in Heads).

## GPG User PIN

Used to sign and encrypt content and for all user interactions with the USB
Security dongle.  Heads prompts for this when signing `/boot` hashes.

- Locks after **3 consecutive wrong attempts**.
- **Recommended length:** 2 Diceware words (6-25 characters in Heads).

## Disk Recovery Key Passphrase

The primary LUKS passphrase set at OS installation.  Processed through PBKDF2
(LUKS1) or Argon2 (LUKS2) to derive the actual disk encryption key.

- Required to access encrypted data from any computer (without TPM).
- Required to set up or recover a TPM Disk Unlock Key.
- Required when "unsafe booting" — the OS prompts for it directly.
- **Recommended length:** 6 Diceware words.

## TPM Disk Unlock Key Passphrase

An additional LUKS key sealed in TPM NVRAM with PCR values for firmware,
kernel modules, and LUKS headers.  Released only when Heads boots unmodified
from the expected firmware.

- Ties the disk to one machine.
- In recovery mode PCRs will not match; use the Disk Recovery Key instead.
- After 3 failed unlock attempts Heads falls back to the Disk Recovery Key.
- **Recommended length:** 3 Diceware words.

## Owner's GPG Key

Generated during OEM Factory Reset / Re-Ownership.  Private key lives on the
USB Security dongle's OpenPGP smartcard.  Public key is fused into the Heads
firmware image and used to verify `/boot` signatures on every boot.

## TPM PCR Map

| PCR | Content |
|-----|---------|
| 0 | (reserved; populated by binary blobs where applicable for SRTM) |
| 1 | (reserved) |
| 2 | coreboot bootblock, ROM stage, RAM stage, Heads Linux kernel + initrd |
| 3 | (reserved) |
| 4 | Boot mode (0 during `/init`, then `recovery` or `normal-boot`) |
| 5 | Heads Linux kernel modules |
| 6 | Drive LUKS headers |
| 7 | Heads user-specific CBFS files (config.user, GPG keyring, etc.) |
| 16 | Used for TPM future-calc of LUKS header during DUK setup |

Secrets sealed against PCRs 2, 4, 5, 6, 7.  If any of these change
(firmware update, kernel module change, LUKS header change, config change)
unseal operations fail until secrets are re-sealed.

## TPM Unseal Errors

`Error Authentication failed (Incorrect Password) from TPM_Unseal`
— PCRs match but the passphrase is wrong (expected; just re-enter it).

Any other TPM_Unseal error means the PCR measurements differ from when
secrets were sealed — potential tampering or an unsigned firmware update.

Review the PCR2 TCPA event log from Recovery Shell:

```
cbmem -L
```

## LUKS Key Derivation

Both the Disk Recovery Key passphrase and the TPM Disk Unlock Key passphrase
are processed through the LUKS key derivation function (PBKDF2 for LUKS1,
Argon2 for LUKS2) before being compared against the stored key slot.  The
actual disk encryption key lives only in the LUKS header; passphrases never
directly encrypt disk data.
