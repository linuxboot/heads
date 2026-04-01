# Configuring Keys: OEM Factory Reset / Re-Ownership

This is the primary provisioning step after installing an OS or receiving a
new Heads-equipped device.  It configures all security components in one pass.

## Before You Start

**Use a safe environment.**  Passphrases are echoed to the screen during setup.

**Prepare Diceware passphrases in advance.**  Heads displays a QR code linking
to `osresearch.net/Configuring-Keys` when you enter the questionnaire — that
page lists recommended word counts per secret and links to EFF Diceware.
Using physical dice against a wordlist produces passphrases that are both
strong and memorable.
See [Keys](keys.md) for recommended lengths per secret.

**You need:**
- A USB Security dongle with OpenPGP support (Nitrokey Pro 2, Nitrokey Storage 2,
  Nitrokey 3, or Purism Librem Key for full HOTP support; YubiKey 5 for
  OpenPGP-only).
- An OS installed on a dedicated `/boot` partition.
- Optionally: a USB thumb drive to back up GPG key material (recommended).

## Entering OEM Factory Reset / Re-Ownership

From the Heads main menu: `Options -> OEM Factory Reset / Re-Ownership`.

The wizard first shows a warning describing what will be erased.  Confirm to
continue.

## Default vs. Custom Configuration

`Would you like to use default configuration options? [Y/n]`

**Answer N.**  Accepting defaults leaves all security components at factory
PINs and passphrases (12345678 / 123456) which are publicly known.  Custom
configuration only happens once per ownership; take the time to do it properly.

When you answer N, Heads displays a **QR code for osresearch.net/Configuring-Keys**
— scan it with a phone for per-secret word-count guidance and EFF Diceware links.

## Questionnaire

### LUKS Disk Recovery Key Passphrase

`Would you like to change the current LUKS Disk Recovery Key passphrase?`

Answer **Y** if you did not install the OS yourself.  The passphrase set at
OS install is unknown to you and may be known to the installer.

### LUKS Re-encryption

`Would you like to re-encrypt the LUKS container and generate a new LUKS Disk Recovery Key?`

Answer **Y** if you did not install the OS yourself.  Changing the passphrase
alone does not change the underlying encryption key — anyone with a LUKS header
backup from before could still decrypt with the old passphrase.  Re-encryption
generates a new key and renders old header backups useless.

### GPG Key Storage

`Would you like to format an encrypted USB Thumb drive to store GPG key material?`

- **Y** — Generates the GPG master key and subkeys in memory, backs them up
  to an encrypted LUKS container on a USB thumb drive, then optionally copies
  subkeys to the dongle.  Recommended for production environments.
- **N** — Generates keys directly on the dongle's OpenPGP smartcard with no
  off-card backup.  Simpler but irreversible if the dongle is lost.

If you answered Y:

`Would you like in-memory generated subkeys to be copied to the USB Security dongle's OpenPGP smartcard?`

Answer **Y** (recommended).  Answering N leaves keys only on the backup drive;
clone it to a second drive for redundancy.

### Passphrase Strategy

`Would you like to set a single custom passphrase to all security components?`

Not recommended — using one passphrase for everything means compromising one
secret compromises all.  Useful only for OEM provisioning workflows.

`Would you like to set distinct PINs/passphrases for each security component?`

Answer **Y**.  You will be prompted for:

- **TPM Owner Passphrase** (min 8 chars) — protects TPM NVRAM ownership
- **GPG Admin PIN** (6-25 chars) — protects smartcard management operations
- **GPG User PIN** (6-25 chars) — protects signing and encryption operations

### Custom GPG Key Identity

`Would you like to set custom user information for the GnuPG key?`

Answer **Y** if you plan to use the dongle for personal signing/encryption or
want the public key to be searchable on keyservers.

- **Real Name** — your name; becomes the cardholder name on the smartcard
- **Email** — your email; becomes the login field on the smartcard and the
  key UID email
- **Comment** — distinguishes this key (e.g. "USB Security dongle"); 1-60 chars

## Key Generation

After the questionnaire, Heads performs the following steps in order:

1. Applies any requested LUKS passphrase or re-encryption changes
2. Resets the TPM with your chosen passphrase
3. Factory-resets the OpenPGP smartcard
4. Enables forced-signature PIN on the smartcard (good security practice)
5. Generates the GPG key (on-card or in-memory per your choice)
6. Backs up key material to the USB thumb drive (in-memory path only)
7. Copies subkeys to the dongle (in-memory path, if you chose to copy)
8. Sets the smartcard cardholder name and login fields from your identity info
9. Changes GPG Admin and User PINs to your chosen values
10. Adds the new public key to the firmware and reflashes the BIOS
11. Generates `/boot` hashes and signs them with the new key
12. Displays all provisioned secrets for confirmation

After completing, Heads shows a **reboot prompt**.  TOTP/HOTP secret
generation happens on the **first normal boot** after OEM reset — Heads detects
the TPM was cleared and guides you through the reseal process.

RSA key generation on older dongles (Nitrokey Pro, Librem Key) may take
10 minutes or more — be patient.

## Provisioned Secrets Summary

At the end, Heads displays all provisioned secrets on screen and encodes them
in a QR code.  **This is the last time these values are shown.**  Write them
down or scan the QR code to a secure location before continuing.

## After Provisioning

### TOTP (smartphone)

Scan the QR code into Google Authenticator, FreeOTP+, or a compatible app.
On subsequent boots Heads displays the current TOTP; compare it against
your phone.  Requires correct UTC time set in `Options -> Time`.

### HOTP (USB Security dongle)

Heads seals the secret to the dongle automatically.  On subsequent boots the
dongle verifies the HOTP code and shows a green LED (pass) or red LED (fail).

### TPM Disk Unlock Key (optional)

Go to `Options -> Boot Options`, select a default boot option, and answer
the prompts to seal a disk unlock key in the TPM.  This requires your Disk
Recovery Key passphrase and GPG User PIN.  On subsequent boots the TPM
releases the key automatically when PCRs match.

## Adding an Existing GPG Key

If you already have a provisioned USB Security dongle:

1. Insert the dongle and the USB drive containing your public key.
2. Go to `Options -> GPG Management -> Add a GPG key to the running BIOS + reflash`.
3. Follow the steps.  After reflashing, reboot.
4. Generate a new TOTP/HOTP secret when prompted.

## Forgotten GPG User PIN

From Recovery Shell with the dongle inserted:

```
gpg --change-pin
```

Enter the Admin PIN when prompted, then set a new User PIN.

**Warning:** 3 consecutive wrong Admin PIN attempts permanently locks the
card.  There is no recovery from an exhausted Admin PIN counter short of a
full factory reset of the OpenPGP applet (which destroys all keys on the card).
