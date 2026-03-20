# Heads Security Model

This document describes the security architecture of Heads: how trust is
established, how integrity is verified at each boot, and how secrets are
protected.

See also: [architecture.md](architecture.md), [tpm.md](tpm.md),
[boot-process.md](boot-process.md), [ux-patterns.md](ux-patterns.md).

---

## Trust hierarchy

The diagram below shows the standard TPM-based boot path. For boards without
TPM hardware, see [HOTP on boards without a TPM](#hotp-on-boards-without-a-tpm-rom-hash-mode).

```text
SPI flash ROM  (hardware root of trust)
  │
  │  coreboot SRTM measures boot block + payload into PCR 2; PCRs 0,1,3 unused
  ▼
TPM PCR values  (hardware-attested firmware state)
  │
  │  Heads unseals TOTP/HOTP secret only when PCRs match expected values
  ▼
TOTP/HOTP code  (proves firmware was not tampered since last seal)
  │
  │  User verifies TOTP/HOTP matches the value on their phone/token
  ▼
User-approved boot  (human-in-the-loop verification)
  │
  │  GPG signature on /boot/kexec.sig verified against ROM-fused public key
  ▼
/boot integrity  (OS bootloader, kernel, and initrd authenticated)
  │
  │  LUKS DUK unsealed from TPM (only when PCRs match + /boot is signed)
  ▼
Decrypted OS disk  (disk encryption key delivered without passphrase prompt)
```

---

## Hardware root of trust

The trust anchor is the SPI flash ROM containing coreboot. Heads treats this
as the immutable starting point:

- Coreboot measures firmware stages and the Linux payload into TPM PCR 2 (SRTM) before executing it.
- The Linux payload is embedded in the ROM (no network, no external media required).
- The ROM is physically write-protected on supported boards. See
  [wp-notes.md](wp-notes.md) for current status.

There is no certificate authority, no boot server, and no runtime network
access during the verified boot path.

---

## Measured boot

The **bootblock** (IBB — Initial Boot Block) is the Static Core Root of Trust
for Measurement (S-CRTM): the first code executed by the CPU, directly from
SPI flash, before anything else has run. All subsequent stages are measured
from it.

Coreboot's measured boot (`CONFIG_TPM_MEASURED_BOOT=y`) measures the full
firmware chain into **PCR 2** (`CONFIG_PCR_SRTM=2`):

```text
bootblock → romstage → ramstage → Heads Linux kernel + initrd (payload)
```

On boards with `CONFIG_TPM_MEASURED_BOOT=y` + `CONFIG_TPM_INIT_RAMSTAGE=y`
(the majority of maintained boards), ramstage initializes the TPM, reads each
prior stage from CBFS, and extends PCR 2. Older coreboot versions (4.11) used
`CONFIG_TPM_INIT=y` before this config key existed; some boards have no TPM
hardware. See [tpm.md](tpm.md) for the full breakdown.

PCRs 0, 1, and 3 are unused — the `CONFIG_PCR_*` entries for those registers
are slot assignments for optional coreboot features that are not enabled. They
remain at zero and are anchored as zero in sealing policies.

Heads extends additional PCRs during userspace boot:

- **PCR 4** — boot mode tracking; see below
- **PCR 5** — each kernel module loaded via the `insmod` wrapper (binary + parameters)
- **PCR 6** — LUKS header dump (by `qubes-measure-luks`) before disk unlock
- **PCR 7** — each CBFS/UEFI file extracted from ROM (by `cbfs-init`/`uefi-init`)

Heads extends PCR 4 further depending on execution path:

- **Normal boot**: `calcfuturepcr 4` pre-computes the expected value and secrets
  are sealed against it.
- **Recovery shell**: PCR 4 is extended with `"recovery"`, invalidating
  normal-boot unsealing for the rest of the session.

See [tpm.md](tpm.md) for the full PCR table and sealing policies.
For board-specific RoT configuration and the files that control each PCR,
see [tpm.md — Configuration reference for developers](tpm.md#configuration-reference-for-developers).

---

## Boot attestation: TOTP and HOTP

Both mechanisms seal a secret to TPM NVRAM with a PCR policy. The secret
can only be unsealed when the firmware PCR state matches what was recorded
at seal time. A firmware change causes a PCR mismatch and unseal failure,
which the user observes as a TOTP/HOTP mismatch.

### TOTP

A 20-byte random secret is generated at OEM Factory Reset and sealed to
TPM NVRAM. At each boot, `unseal-totp` retrieves it and generates the current
30-second code. The user compares this against their authenticator app.

If the PCRs differ (firmware changed or recovery shell was entered), the
unseal fails and no valid code is shown.

### HOTP

An HOTP secret is sealed to TPM and programmed onto a USB hardware token
(Librem Key, Nitrokey). At boot, the token's LED signals success or failure
— visible before the screen is fully initialized. Because the token is a
separate physical device, it provides a tamper signal independent of the display.

### HOTP on boards without a TPM (ROM-hash mode)

On boards where `CONFIG_NO_TPM=y` (currently the Librem Mini, Librem Mini v2,
and Librem 11), there is no TPM to seal secrets against PCR values. Heads falls
back to a different HOTP secret derivation implemented in `secret_from_rom_hash`
in `initrd/etc/functions`:

1. At seal time, `flash.sh` reads the full SPI ROM via flashrom/flashprog.
2. The SHA-256 of the ROM image is used directly as the HOTP secret.
3. The secret is programmed onto the USB security dongle.
4. At each boot, the ROM is read again, SHA-256 recomputed, and the HOTP code
   sent to the dongle for comparison. A changed ROM produces a different hash,
   a different code, and a dongle failure signal.

The HOTP counter is stored in `/boot/kexec_hotp_counter` as a plain file
(not in TPM NVRAM, which does not exist on these platforms).

**Known limitations of ROM-hash HOTP (publicly noted):**

- The secret is **deterministic and derived from public data** — anyone with
  physical access to read the ROM can derive the HOTP secret independently,
  without owning the dongle.
- **No hardware platform binding**: the secret is not tied to the specific
  hardware instance, only to ROM contents.
- ROM reading via flashrom/flashprog at every boot **expands attack surface**
  and is slower than a TPM unseal.
- The counter file on `/boot` is not TPM-protected and could in principle be
  manipulated to extend the HOTP window (the token accepts codes within a
  ±5-count lookahead window).
- There is **no equivalent of TOTP** on these boards; time-based attestation
  without a TPM is not implemented.
- LUKS disk encryption key sealing to TPM (DUK) is **not available**; disk
  unlock requires the user's passphrase at every boot.

The ROM-hash HOTP mode provides a weaker attestation model than the TPM-based
path. Its value is in detecting ROM modifications via the dongle's LED, but it
does not provide the same tamper-evident guarantees as TPM PCR sealing.

### Attestation failure handling

If TOTP or HOTP unseal fails, `INTEGRITY_GATE_REQUIRED` is set and all TPM
secret sealing operations are blocked until the integrity gate passes.
See [ux-patterns.md](ux-patterns.md#gate-before-sealing).

---

## /boot integrity: GPG signatures

All files in `/boot` are protected by a SHA-256 hash manifest and a GPG
detached signature (`kexec.sig`).

### Signing (kexec-sign-config)

When the user installs or updates the OS, `kexec-sign-config`:

1. Hashes all non-`kexec*` files in `/boot` into `kexec_hashes.txt` and
   generates a directory tree listing in `kexec_tree.txt`.
2. Signs the hash manifest with a GPG key, producing `kexec.sig`.
3. Increments the TPM rollback counter and stores the new counter hash in
   `kexec_rollback.txt`.

The signing key lives on a hardware security dongle (OpenPGP smartcard),
never in the ROM. Signing requires physical possession of the card and
knowledge of the card PIN.

### Verification (kexec-select-boot)

At each boot, `verify_global_hashes` in `kexec-select-boot` calls
`verify_checksums` and `check_config` to confirm that every `/boot` file
matches its stored hash and that `kexec.sig` is valid. A hash or signature
failure causes `die` — there is no "boot anyway" path.

The ROM contains only the **public key**. Verification uses `gpgv` with
the ROM keyring; no private key material is needed at boot.

---

## Disk encryption: LUKS DUK

The LUKS Disk Unlock Key (DUK) is a random binary key that:

1. Is generated from `/dev/urandom` by `kexec-seal-key`.
2. Is sealed to TPM NVRAM with PCR policy `0,1,2,3,4,5,6,7`.
3. Is added as a LUKS key slot alongside the user's Disk Recovery Key (DRK).
4. At boot, `kexec-insert-key` unseals it and injects it into a minimal
   initrd prepended to the OS initrd. The OS kernel unlocks LUKS without
   prompting the user.

If the TPM refuses to unseal (PCR mismatch, TPM reset), the OS falls back
to prompting for the DRK passphrase. The DRK is always a valid recovery path.

---

## Integrity gate before sealing

Before any operation that seals new TPM secrets, `gate_reseal_with_integrity_report`
in `gui-init` verifies:

1. TPM is not in a reset-required state.
2. No prior TOTP/HOTP failure is recorded (`INTEGRITY_GATE_REQUIRED` is unset).
3. `/boot` hash verification passes.
4. `kexec.sig` is valid and signed by a key in the current keyring.
5. If HOTP is enabled: the USB security token is present.
6. User explicitly confirms proceeding.

If any check fails, the sealing operation is aborted. This prevents new
secrets from being sealed against a potentially compromised `/boot`.

For the UNKNOWN_KEY scenario and correct error messaging, see
[ux-patterns.md](ux-patterns.md#security-ux--integrity-report-and-unknown-keys).

---

## OEM Factory Reset

`oem-factory-reset` re-establishes full ownership of the device in five phases:

1. **TPM reset** — clears the TPM owner hierarchy, removes all NVRAM indices,
   and invalidates all sealed secrets.
2. **GPG key initialization** — generates new keys (in-memory RSA or ECC, or
   on-smartcard) and configures the OpenPGP card PINs. The card PIN length
   is limited to 25 characters due to a firmware constraint on supported tokens
   (Librem Key / Nitrokey HOTP).
3. **TPM rollback counter creation** — creates a new monotonic counter and
   stores its initial hash in `/boot/kexec_rollback.txt`.
4. **`/boot` signing** — hashes and GPG-signs the initial `/boot` state.
5. **TOTP/HOTP and LUKS DUK sealing** — TOTP/HOTP secrets are sealed
   immediately; LUKS DUK sealing is performed by the user on the next boot
   via the GUI menu.

---

## Fail-closed design

All verification failures are fatal by default:

- GPG signature mismatch → `die` (recovery shell)
- Hash mismatch → `die` (recovery shell)
- TPM counter mismatch → `die` (recovery shell)
- TOTP unseal failure → error menu (no unattended boot)
- LUKS DUK unseal failure → OS prompts for DRK passphrase (no silent failure)

There is no "continue anyway" path for integrity failures.
