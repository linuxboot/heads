# Heads TPM Usage

This document covers how Heads uses the TPM for measured boot, secret sealing,
rollback protection, and PCR extension.

See also: [architecture.md](architecture.md), [boot-process.md](boot-process.md), [security-model.md](security-model.md).

---

## tpmr — unified TPM abstraction

`initrd/bin/tpmr` is a shell script wrapper that presents a single interface
over both TPM 1.2 (`tpm` / `trousers`) and TPM 2.0 (`tpm2-tools`). All Heads
scripts call `tpmr` rather than invoking `tpm` or `tpm2` directly.

### PCR sizes

| TPM version | Hash algorithm | PCR size |
| --- | --- | --- |
| TPM 1.2 | SHA-1 | 20 bytes |
| TPM 2.0 | SHA-256 | 32 bytes |

### Subcommand surface

| Subcommand | Description |
| --- | --- |
| `pcrread` | Read a PCR value |
| `pcrsize` | Print PCR byte size (20 or 32) |
| `calcfuturepcr` | Replay PCR extension to compute a future value |
| `extend` | Extend a PCR with a hash or file |
| `seal` | Seal a file to TPM NVRAM with a PCR policy |
| `unseal` | Unseal from TPM NVRAM |
| `startsession` | Start an authorization session (TPM2 only) |
| `counter_read` | Read a monotonic counter |
| `counter_increment` | Increment a monotonic counter |
| `counter_create` | Create a new monotonic counter |
| `destroy` | Destroy an NVRAM index |
| `reset` | Reset the TPM |
| `kexec_finalize` | Finalize PCR state before kexec (TPM2 only) |
| `shutdown` | Orderly shutdown (TPM2 only) |

---

## PCR assignments

### Who extends what

`config/coreboot-*.config` defines slot assignments via `CONFIG_PCR_*` for
optional coreboot measured-boot features. Coreboot supports several modes:

| coreboot mode | PCRs used | Status in Heads |
| --- | --- | --- |
| SRTM (Static Root of Trust for Measurement) | PCR 2 (`CONFIG_PCR_SRTM=2`) | **Active on all boards with TPM hardware and `CONFIG_TPM_MEASURED_BOOT=y`** |
| Boot mode measurement | PCR 1 (`CONFIG_PCR_BOOT_MODE=1`) | Not enabled |
| Hardware ID measurement | PCR 1 (`CONFIG_PCR_HWID=1`) | Not enabled |
| Runtime data | PCR 3 (`CONFIG_PCR_RUNTIME_DATA=3`) | Not enabled — coreboot's default slot for runtime data, but the feature is not activated in Heads; PCR 3 remains zero |
| Firmware version | PCR 10 (`CONFIG_PCR_FW_VER=10`) | Not enabled |

### Root of Trust and SRTM chain

Coreboot's measured boot establishes a **Core Root of Trust for Measurement
(CRTM)**. When the CRTM executes only once per power cycle — as it does on all
Heads boards — this is a **Static CRTM (S-CRTM)**, creating an SRTM chain.

The **bootblock** (IBB — Initial Boot Block) is the S-CRTM: the first code
executed by the CPU after reset, directly from SPI flash. Its integrity is
guaranteed by hardware write-protection of the flash, not by a prior measurement.
Measured boot is independent of vboot and does not require vboot to be enabled.

CBFS stages are measured as raw data before decompression; CBFS headers are
excluded from measurements.

#### Standard path (boards with CONFIG_TPM_MEASURED_BOOT=y + CONFIG_TPM_INIT_RAMSTAGE=y)

On the majority of Heads boards, the TPM chip is not initialized until ramstage
— the bootblock and romstage run before any TPM recording takes place. Once
ramstage initializes the TPM, coreboot's measured boot (`CONFIG_TPM_MEASURED_BOOT=y`)
reads each prior stage back from CBFS and extends PCR 2 (`CONFIG_PCR_SRTM=2`)
retroactively. The full chain recorded into PCR 2 is:

```text
bootblock → romstage → ramstage → Heads Linux kernel + initrd (payload)
```

The gap between first CPU execution (bootblock) and first TPM recording (ramstage)
is covered by hardware write-protection of the SPI flash — the contents of those
stages cannot change without physical flash access. The bootblock is still the
S-CRTM; the TPM just begins recording later.

After this chain is recorded, the TPM state reflects the complete firmware
stack. Any modification to any of these stages produces a different PCR 2
value, causing unseal operations to fail.

Under the active Heads configuration, only PCR 2 is extended by coreboot.
PCRs 0, 1, and 3 remain at zero and are anchored as zero in sealing policies.

#### Boards with different or absent coreboot measured boot

`CONFIG_TPM_MEASURED_BOOT` is the config key used in current coreboot versions.
Older coreboot releases (notably 4.11, used by KGPE-D16 and some Librem server
boards) used `CONFIG_TPM_INIT=y` before this key existed. The absence of
`CONFIG_TPM_MEASURED_BOOT` in an older-coreboot config does not automatically
mean measured boot is absent — it may use the older naming.

Notable exceptions from the standard SRTM path:

| Board family | coreboot fork/version | TPM situation | Notes |
| --- | --- | --- | --- |
| KGPE-D16 server/workstation variants | 4.11 (unmaintained) | `CONFIG_TPM_INIT=y` (old key); no `CONFIG_TPM_MEASURED_BOOT` | Pre-dates the current measured boot config naming |
| ThinkPad T520 | 4.22.01 (unmaintained) | `CONFIG_TPM_INIT_RAMSTAGE=y` but `CONFIG_TPM_MEASURED_BOOT` explicitly not set | TPM initialized but SRTM measurements disabled |
| Librem l1um (original) | purism fork (unmaintained) | `CONFIG_TPM_INIT=y` (old key); no `CONFIG_TPM_MEASURED_BOOT` | Purism fork; pre-dates current measured boot naming |
| Librem Mini, Librem Mini v2, Librem 11 | purism fork (maintained) | `CONFIG_NO_TPM=y` | No TPM hardware; falls back to ROM-hash HOTP mode (see below) |

On boards where coreboot SRTM measurements are absent or uncertain, PCR 2
remains at zero from coreboot's perspective. Heads still seals secrets to the
TPM (where a TPM exists), but the PCR 2 component of the seal offers no
firmware tamper detection. Boot integrity on these platforms relies on
write-protection of the flash and GPG-signed `/boot`.

On boards with no TPM hardware, Heads uses ROM-hash HOTP as the sole
attestation mechanism. See
[security-model.md — HOTP on boards without a TPM](security-model.md#hotp-on-boards-without-a-tpm-rom-hash-mode)
for the mechanism and its known limitations.

#### S-CRTM hardening (external hardware RoT)

The software S-CRTM (bootblock measuring itself) has a known limitation: the
IBB is self-referential — it asserts its own integrity. To address this,
processor vendors provide external RoT mechanisms that validate the IBB via
hardware before execution:

- **Intel BootGuard** — validates the bootblock against a signed manifest fused
  into the CPU/PCH before any code runs
- **AMD Hardware Validated Boot (HVB)** — equivalent AMD mechanism

These are hardware features of the platform, not coreboot configuration choices.
Where a board's CPU supports BootGuard or HVB, that hardware layer sits below
the coreboot SRTM chain and provides additional assurance for the S-CRTM
integrity.

#### Intel TXT path (OptiPlex 7019/9010 TXT only)

One board — the Dell OptiPlex configured with Intel Trusted Execution Technology
(`CONFIG_INTEL_TXT=y`, `CONFIG_TPM_MEASURED_BOOT_INIT_BOOTBLOCK=y`) — initializes
the TPM in the bootblock itself, closing the gap described above: the IBB measures
itself and then each subsequent stage, so measurements begin at the very first
stage. It also enables a **Dynamic Root of Trust for Measurement (DRTM)** path
via the Intel SINIT ACM, which allows a DRTM chain to be re-established within
a single power cycle with hardware-rooted trust. The PCR 2 SRTM chain is
unchanged; the TXT mechanism adds the DRTM capability on top of it.

| PCR | Extended by | Content |
| --- | --- | --- |
| 0 | unused | Zero; anchored in sealing policies |
| 1 | unused | Zero; anchored in sealing policies |
| 2 | coreboot SRTM | Boot block, ROM stage, RAM stage, Heads Linux kernel + initrd |
| 3 | unused | Zero; anchored in sealing policies |
| 4 | Heads (`usb-init`, `kexec-insert-key`, `functions`) | Boot mode tracking: `"usb"` during USB init, `"generic"` after DUK unsealed, `"recovery"` when recovery shell entered |
| 5 | Heads `insmod` wrapper | Each loaded kernel module: parameters + binary content (default `MODULE_PCR=5`) |
| 6 | Heads `qubes-measure-luks` | LUKS header dump for each encrypted drive |
| 7 | Heads `cbfs-init`, `uefi-init` | Each CBFS/UEFI file: filename then content (default `CONFIG_PCR=7`) — covers `config.user`, GPG keyring, user CBFS files |
| 16 | `tpmr calcfuturepcr` (scratch use only) | Resettable debug PCR used as scratch pad during pre-computation of future PCR values; not part of any sealing policy |

PCRs 0-3 are read at seal time and included in sealing policies. The zero
state of PCRs 0, 1, and 3 is intentional — any unexpected extension of those
PCRs (e.g. enabling an optional coreboot feature) would break the seal.

### Sealing policies

#### LUKS Disk Unlock Key (DUK) — kexec-seal-key

The DUK is a 128-character random key (128 bytes from `/dev/urandom`, providing
1024 bits of entropy). It is added to a dedicated LUKS key slot and sealed to
TPM NVRAM with the policy below.

| PCR | How obtained | Reason |
| --- | --- | --- |
| 0 | `pcrread` (current value) | Platform state at seal time |
| 1 | `pcrread` (current value) | Platform state at seal time |
| 2 | `pcrread` (current value) | coreboot SRTM measurement |
| 3 | `pcrread` (current value) | Platform state at seal time |
| 4 | `calcfuturepcr` | Pre-computed normal-boot path (before any USB init or recovery) |
| 5 | `pcrread` or `calcfuturepcr 5` | Actual if extra modules loaded; zeroed future value if no extra modules |
| 6 | `calcfuturepcr 6 /tmp/luksDump.txt` | Pre-computed LUKS header measurement |
| 7 | `pcrread` (current value) | User CBFS files |

PCR 5 is conditional: if the board loads extra kernel modules (USB HID,
libata, HOTP token), the actual post-load PCR 5 value is used. If no extra
modules are loaded, `calcfuturepcr 5` computes the zeroed (never-extended)
future value. This means the seal is valid only for the expected module set.

PCR 6 is pre-computed: `calcfuturepcr 6 /tmp/luksDump.txt` replays the
LUKS header extension to compute the expected post-measurement value. If
the LUKS header changes (key slot added/removed), the DUK unseal fails.

#### TOTP/HOTP secret — seal-totp

| PCR | Included | Reason |
| --- | --- | --- |
| 0 | Yes | Platform state |
| 1 | Yes | Platform state |
| 2 | Yes | coreboot SRTM measurement |
| 3 | Yes | Platform state |
| 4 | Yes | Pre-computed normal-boot value |
| 5 | **No** | Kernel modules are not firmware integrity attestation |
| 6 | **No** | LUKS header consistency is not firmware integrity attestation |
| 7 | Yes | User CBFS files |

The narrower policy means a LUKS header change or different kernel module
set does not prevent TOTP from unsealing. TOTP/HOTP attests firmware and
ROM configuration integrity, not disk state.

---

## PCR extension

`tpmr extend -ix <pcr_num> -ic <string>` extends a PCR with the hash of a
string. `-if <file>` extends with the hash of a file.

`calcfuturepcr` replays the expected extend sequence to compute what a PCR
will contain after the normal boot path, without actually extending it.
This is used to seal secrets against a known-future PCR state (e.g. PCR 4
after normal init, before any recovery shell entry).

### Recovery PCR extension

When a recovery shell is entered, `initrd/etc/functions` extends PCR 4 with
the string `"recovery"`. This permanently invalidates TOTP and LUKS DUK
unsealing for the rest of the boot session — the TPM will refuse to unseal
secrets that were sealed against the normal-boot PCR 4 value.

### TPM event log

Coreboot records each PCR extension into a TPM event log. Three log formats
are supported: coreboot-specific, TPM 1.2 spec, and TPM 2.0 spec. The log can
be inspected from an OS or recovery shell with:

```text
cbmem -L
```

This is the authoritative record of what was measured into each PCR during
firmware boot. Useful for diagnosing unexpected PCR values or verifying that
a new board's SRTM chain matches expectations.

---

## Rollback counter

Heads uses a TPM monotonic counter to detect rollback attacks. The counter
is incremented every time `/boot` is re-signed (i.e. every time `kexec-sign-config`
runs after an OS update).

The counter is created with a fixed label (`3135106223`, decimal) by
`check_tpm_counter` in `initrd/etc/functions`. The label is a stable
identifier used when creating the counter during OEM Factory Reset.

### Counter state file

`read_tpm_counter` in `initrd/etc/functions` reads the counter from the TPM
and writes the result to `/tmp/counter-<index>`. The format is
`<hex_index>: <hex_value>`.

`/boot/kexec_rollback.txt` stores the SHA-256 hash of that counter file.
At boot, `kexec-select-boot` reads the counter, hashes the file, and checks
it against the stored hash. Any discrepancy aborts the boot.

### Rollback preflight: boot-time validation

Before presenting TOTP/HOTP recovery prompts, `gui-init` calls
`preflight_rollback_counter_before_reseal` to confirm the rollback counter
is consistent. This catches TPM replacements, `/boot` disk swaps, and counter
corruption before any secrets are resealed.

Failure conditions and their diagnostic messages:

| Condition | Message shown to user |
| --- | --- |
| `/boot/kexec_rollback.txt` missing on initialized system | "TPM rollback metadata is missing or unreadable... System appears initialized but rollback state cannot be validated." |
| Counter index unreadable from TPM | "TPM rollback counter '`<id>`' cannot be read." |
| TPM2: counter has `ownerwrite` but not `authwrite` | "TPM rollback counter '`<id>`' uses ownerwrite-only policy." |
| TPM2: counter has neither `authwrite` nor `ownerwrite` | "TPM rollback counter '`<id>`' has no writable attribute." |
| TPM2: counter attributes empty or unreadable | "TPM rollback counter '`<id>`' attributes are empty / cannot be read." |

The exact diagnostic message from `fail_preflight` is shown directly in the
error dialog — **not** a vague paraphrase. This tells the user and any support
context exactly which condition was detected. The action guidance ("Reset TPM
from GUI...") is stripped from the dialog since the menu already offers those
options.

The user is offered four actions: show the integrity report, OEM Factory Reset,
Reset the TPM, or continue to the main menu. The dialog loops until the
counter passes preflight or the user chooses to continue.

### Pipeline safety

`tpmr counter_read` must be called with a direct redirect, not piped through
`tee`. Piping through `tee` hides `tpmr` failures because `||` checks the
exit status of `tee` (always 0), not `tpmr`. See
[ux-patterns.md](ux-patterns.md#tpm-counter-patterns) for the correct pattern.

---

## TPM secret sealing internals (TPM2)

TPM2 sealing uses NVRAM persistent objects with a combined PCR + optional
password policy:

1. A policy session is started (`tpm2 startauthsession --policy-session`).
2. PCR values are bound to the session (`tpm2 policypcr`).
3. If a password is set, `tpm2 policyauthvalue` adds it to the policy.
4. The secret is stored in a persistent NVRAM handle.
5. At unseal time, the same policy session is reconstructed and
   `tpm2 unseal` retrieves the plaintext.

The primary handle file must exist before unsealing. If it is missing (after
a TPM reset), `tpm2_unseal` exits with a clear warning rather than producing
a confusing low-level error.

---

## Configuration reference for developers

The following table maps each configurable aspect of the RoT and PCR policy to
the file that controls it. Use this when adding a board, changing a sealing
policy, or investigating why a seal/unseal operation fails.

| What you want to understand or change | Where to look | What to look for |
| --- | --- | --- |
| Which coreboot PCRs are active on a board | `config/coreboot-<board>.config` | `CONFIG_PCR_SRTM`, `CONFIG_TPM_INIT_RAMSTAGE`, `CONFIG_TPM_MEASURED_BOOT_INIT_BOOTBLOCK`, `CONFIG_INTEL_TXT` |
| Which coreboot version / fork a board uses | `modules/coreboot` + `boards/<board>/` | `CONFIG_COREBOOT_VERSION` in board config selects the coreboot source defined in `modules/coreboot` |
| LUKS DUK sealing policy (which PCRs) | `initrd/bin/kexec-seal-key` | `tpmr seal` call and surrounding `pcrread` / `calcfuturepcr` calls; DEBUG comments explain each PCR |
| TOTP/HOTP sealing policy (which PCRs) | `initrd/bin/seal-totp` | `tpmr seal` call; DEBUG messages explain why PCR 5 and PCR 6 are excluded |
| PCR 4 (boot mode) tracking | `initrd/bin/usb-init`, `initrd/bin/kexec-insert-key`, `initrd/etc/functions` | `tpmr extend` calls with `"usb"`, `"generic"`, `"recovery"` |
| PCR 5 (kernel modules) | `initrd/sbin/insmod` | `MODULE_PCR` variable; default `MODULE_PCR=5`; each `insmod` extends PCR 5 |
| PCR 6 (LUKS header) | `initrd/bin/qubes-measure-luks` | `tpmr extend` call against `/tmp/luksDump.txt` |
| PCR 7 (CBFS / ROM files) | `initrd/bin/cbfs-init`, `initrd/bin/uefi-init` | `CONFIG_PCR` variable; default `CONFIG_PCR=7`; each extracted file extends PCR 7 |
| Rollback counter logic | `initrd/etc/functions` | `check_tpm_counter`, `read_tpm_counter`, `counter_increment` |

### Adding a new board

To verify that a new board's coreboot config matches the expected RoT:

1. Check that `CONFIG_TPM_MEASURED_BOOT=y` and `CONFIG_PCR_SRTM=2` are set.
   For boards using coreboot 4.11 or older forks, the equivalent older key is
   `CONFIG_TPM_INIT=y`; confirm whether that version's measured boot is active.
2. Confirm `CONFIG_TPM_INIT_RAMSTAGE=y` (standard) or document why it differs.
   If the board has no TPM hardware, verify `CONFIG_NO_TPM=y` is intentional and
   note that TPM-based attestation (TOTP, LUKS DUK) will not be available.
3. Check that `CONFIG_PCR_BOOT_MODE`, `CONFIG_PCR_HWID`, `CONFIG_PCR_RUNTIME_DATA`
   are set to their slot numbers but **not** enabled (no corresponding `=y` feature
   flag). These are slot reservations; enabling them would extend PCRs 1 and 3,
   breaking all existing seals on that board.
4. If the board uses Intel TXT, verify `CONFIG_INTEL_TXT=y` and
   `CONFIG_TPM_MEASURED_BOOT_INIT_BOOTBLOCK=y` are intentional and document the
   DRTM capability in the board's README.

---

## TPM1 vs TPM2 differences

| Feature | TPM 1.2 | TPM 2.0 |
| --- | --- | --- |
| PCR hash | SHA-1 (20 bytes) | SHA-256 (32 bytes) |
| Sealing | `tpm sealfile2` | `tpm2 nvdefine` + policy session |
| Counter | `tpm nv*` | `tpm2 nvincrement` |
| Auth sessions | Not used | Required for policy-based unseal |
| `kexec_finalize` | No-op | Extends PCRs, then `tpm2 shutdown` |
| `startsession` | No-op | Creates encryption session |
