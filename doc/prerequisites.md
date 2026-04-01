# Prerequisites

## USB Security Dongles

All USB Security dongles used with Heads must support the **OpenPGP card
applet**.  FIDO2 and U2F are not used by Heads.

HOTP verification requires a dongle with HOTP support and a compatible firmware
version.  Without HOTP, Heads falls back to TPMTOTP (smartphone-based).

| Dongle | OpenPGP | HOTP | Notes |
|--------|---------|------|-------|
| Nitrokey Pro 2 | Yes | Yes | Full support |
| Nitrokey Storage 2 | Yes | Yes | Full support |
| Nitrokey 3 | Yes | Yes | Full support; p256 ECC available |
| Purism Librem Key | Yes | Yes | Full support; rebranded NK Pro |
| YubiKey 5 Series | Yes | No | OpenPGP signing only; no HOTP |
| Nitrokey Pro (v1, fw < 0.8) | Yes | Limited | Older firmware may report no HOTP support; test before use |

Heads detects dongle branding at runtime via USB VID:PID:

| VID:PID | Dongle |
|---------|--------|
| `20a0:42b2` | Nitrokey 3 |
| `20a0:4108` | Nitrokey Pro |
| `20a0:4109` | Nitrokey Storage |
| `316d:4c4b` | Purism Librem Key |

## HOTP vs. TPMTOTP

**HOTP (recommended when available):**
- Heads generates HOTP codes and the dongle verifies them automatically.
- Pass = green LED, fail = red LED and boot halt.
- Does not require accurate time.

**TPMTOTP (smartphone fallback):**
- Heads generates a TOTP code on screen; the user compares it against a phone
  app (Google Authenticator, FreeOTP+, etc.).
- Requires correct UTC time set in `Options -> Time`.
- Less automated — relies on the user noticing a mismatch.

## OS Requirements

- A dedicated `/boot` partition (not `/boot` inside an LVM or btrfs subvolume
  unless the board config supports it).
- LUKS-encrypted root (for TPM Disk Unlock Key functionality).

## Supported Flashing Methods

See board-specific configs under `boards/`.  Most x86 boards support:

- External SPI flashing (initial install) via `flashprog`.
- Internal flashing (upgrades) via `Options -> Flash/Update BIOS` for firmware
  built after November 2023.

Run from Recovery Shell to verify internal flash is unlocked:

```
flashprog -p internal
```
