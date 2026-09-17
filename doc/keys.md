# Keys and Secrets in Heads

See also: [About/Keys](https://osresearch.net/Keys/) for the narrative system-level key inventory.

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

A random 20-byte value generated when a new TOTP/HOTP secret is created,
normally on the first boot after OEM Factory Reset / Reownership.

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
- After 3 failed unlock attempts Heads offers to boot using the Disk Recovery Key.
- **Recommended length:** 3 Diceware words.

## Owner's GPG Key

Generated during OEM Factory Reset / Re-Ownership.  Private key lives on the
USB Security dongle's OpenPGP smartcard.  Public key is fused into the Heads
firmware image and used to verify `/boot` signatures on every boot.

## TPM PCR Map

Heads extends and seals only PCRs 0 through 7; the assignments are in [tpm.md](tpm.md#pcr-assignments) and the seal policies in [tpm.md](tpm.md#sealing-policies).

## TPM Unseal Errors

`Error Authentication failed (Incorrect Password) from TPM_Unseal`
— PCRs match but the passphrase is wrong (expected; just re-enter it).

A different TPM_Unseal error can have several causes, including a decryption
failure or TPM dictionary attack lockout. Check the event log (`cbmem -L`) and
the TPM state before assuming tampering.

See [tpm.md](tpm.md#tpm-event-log) for the event log and unseal errors.

## LUKS Key Derivation

Both the Disk Recovery Key passphrase and the TPM Disk Unlock Key passphrase
are processed through the LUKS key derivation function (PBKDF2 for LUKS1,
Argon2 for LUKS2) before being compared against the stored key slot.  The
actual disk encryption key lives only in the LUKS header; passphrases never
directly encrypt disk data.
