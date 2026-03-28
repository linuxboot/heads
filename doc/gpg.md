# GPG Key Management

Heads uses a GPG key stored on the USB Security dongle's OpenPGP smartcard to
sign `/boot` contents and verify firmware integrity.

## Key Generation

Key generation happens automatically during `OEM Factory Reset / Re-Ownership`.
See [configuring-keys.md](configuring-keys.md) for the full provisioning flow.

Two generation paths are available:

**On-card (default):** keys are generated directly on the smartcard.
No off-card backup exists — losing the dongle means losing the key.

**In-memory with backup:** master key and subkeys are generated in RAM,
backed up to an encrypted LUKS container on a USB thumb drive, then subkeys
are optionally copied to the dongle.  Recommended for production environments.

## Changing PINs

### From Recovery Shell

```bash
gpg --change-pin
```

Menu options:
- `1` — Change User PIN (requires current User PIN)
- `2` — Unblock User PIN (requires Admin PIN)
- `3` — Change Admin PIN (requires current Admin PIN)

### PIN Retry Counters

OpenPGP cards have separate retry counters for User PIN, Reset Code, and
Admin PIN.  The factory state counter reads `3 0 3`:

- `3` — User PIN attempts remaining
- `0` — Reset Code not configured (factory state; not exhausted)
- `3` — Admin PIN attempts remaining

When a counter reaches 0 the corresponding PIN is blocked.  A blocked User
PIN can be unblocked with the Admin PIN.  A blocked Admin PIN **cannot be
recovered** — the card must be fully reset (destroying all keys).

## Full Card Reset (last resort)

If the Admin PIN is blocked or the card is in an unrecoverable state:

```bash
gpg-connect-agent << 'EOF'
/hex
scd serialno
scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40
scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40
scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40
scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40
scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40
scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40
scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40
scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40
scd apdu 00 e6 00 00
scd apdu 00 44 00 00
EOF
```

This sends deliberate wrong PINs to exhaust both the User and Admin PIN
counters, then issues the APDU sequence to fully reset the OpenPGP applet.
**All keys on the card are destroyed.**  Run `OEM Factory Reset / Re-Ownership`
afterwards.

## Adding an Existing Public Key

If the dongle is already provisioned and you need to inject the matching
public key into the Heads firmware:

1. Copy the public key (`.asc`) to a USB drive.
2. Insert the dongle and the USB drive.
3. From Heads: `Options -> GPG Management -> Add a GPG key to the running BIOS + reflash`.
4. Reboot.  Generate a new TOTP/HOTP secret when prompted.

## Nitrokey 3 Specifics

- Supports NIST P-256 ECC keys in addition to RSA — significantly faster key
  generation and signing.
- Secrets app (HOTP) PIN is separate from the OpenPGP card Admin PIN.
- Physical touch confirmation is required for some operations (initialize,
  key generation).
- Secrets app PIN reset is available via `Options -> OEM Factory Reset /
  Re-Ownership` without a full card reset.

## TODO

- Populate the GPG key's preferred keyserver field and the card `url` field
  after uploading the public key to `keys.openpgp.org`.  Requires network
  access in the initrd.  See `set_card_identity()` in `initrd/bin/oem-factory-reset`.
