# Flash write protection and chipset locking

Heads uses two complementary mechanisms to protect the SPI flash ROM
from modification after boot:
1. **PR0 chipset locking** (supported Intel board configurations) — the primary mechanism
2. **WP# pin** (subset of boards) — optional hardware reinforcement

## PR0 chipset locking

### Overview

PR0 (Protected Range 0) is an Intel chipset SPI controller feature.
When locked via `FLOCKDN`, the PR0 register becomes immutable and its
protected range (the full ROM when `BOOTMEDIA_LOCK_WHOLE_RO=y`) is
rejected for writes at the chipset level — before they reach the flash
chip.  The lock persists until the next system reset.

Heads applies the lock just before kexec, ensuring the OS cannot modify
the firmware in-place.

### Coreboot build-time requirements

The coreboot config must prepare the SPI controller for SMM-initiated
lockdown.  **`CONFIG_INTEL_CHIPSET_LOCKDOWN` must be disabled** — Heads
performs the lockdown itself, not coreboot at boot-time.

| Config | Pre-Skylake | >= Skylake |
|--------|:-----------:|:----------:|
| `CONFIG_BOOTMEDIA_LOCK_CONTROLLER=y` | Required | Required |
| `CONFIG_BOOTMEDIA_LOCK_WHOLE_RO=y`   | Required | Required |
| `# CONFIG_INTEL_CHIPSET_LOCKDOWN is not set` | Required | Required |
| `CONFIG_SOC_INTEL_COMMON_SPI_LOCKDOWN_SMM=y` | N/A | Required |
| `CONFIG_SPI_FLASH_SMM=y`  | N/A | Required |

**Coreboot patch** (required for Skylake+):
`patches/coreboot-25.09/0003-soc-intel-lockdown-Allow-locking-down-SPI-and-LPC-in.patch`

For kano (MrChromebox coreboot fork), the same patch is carried at:
`patches/coreboot-mrchromebox-26.03/0002-soc-intel-lockdown-Allow-locking-down-SPI-and-LPC-in.patch`
(rebased for the fork's context; the fork's `CONFIG_SOC_INTEL_COMMON_SPI_LOCKDOWN_SMM=y` is set in `config/coreboot-kano.config`).

This is a copy of [review.coreboot.org/+/85278](https://review.coreboot.org/c/coreboot/+/85278).
It adds the `SOC_INTEL_COMMON_SPI_LOCKDOWN_SMM` Kconfig and refactors
SPI+LPC locking from boot-time ramstage into an SMM handler.  Without
this patch, coreboot issues `APM_CNT_FINALIZE` unconditionally during
ramstage, leaving Heads no control over the lock timing.

For pre-Skylake boards (Sandy Bridge through Broadwell), the upstream
coreboot already supports SPI lockdown via SMI without this patch.

### Heads build-time requirements

In `boards/<board>/<board>.config`:

```bash
CONFIG_IO386=y                           # builds io386 (I/O port utility)
export CONFIG_FINALIZE_PLATFORM_LOCKING=y  # enables runtime lock_chip.sh
```

`modules/io386` fetches a static binary from
`hardenedlinux/io386` (commit `fc73fcf8e5`).

### Runtime chain

Just before kexec hands control to the OS, `kexec-boot.sh` calls
`lock_chip.sh`:

```text
kexec-boot.sh:221-223
  if [ -x /bin/io386 -a "$CONFIG_FINALIZE_PLATFORM_LOCKING" = "y" ]
    └─ lock_chip.sh
         └─ io386 -o b -b x 0xb2 0xcb
             │         │    │    └─ APM_CNT_FINALIZE (0xcb)
             │         │    └────── SMI trigger port (0xb2)
             │         └─────────── IO port access
             └───────────────────── byte output
```

The `io386` write triggers an SMI.  In SMM, coreboot's handler calls:

```
fast_spi_lockdown_bios()
  → fast_spi_pr_dlock()       — sets FLOCKDN, locks PR0
  → fast_spi_set_lock_enable() — locks FAST_SPIBAR
  → BIOS Interface Lock
  → BIOS Lock (BLE)
  → EXT BIOS Lock (SMM_BWP)
  → (optional) EISS + WP# pins if CONFIG_BOOTMEDIA_SMM_BWP=y
```

Once `FLOCKDN` is set, the SPI controller rejects writes to the
PR0-protected range.  Only a system reset clears the lock.

### Board coverage

PR0 applicability is configuration-driven rather than represented by a fixed
Intel-board count.  Until the HCL is deployed, this section is non-exhaustive.
The authoritative inputs are each board's `boards/<board>/<board>.config`
values, especially `CONFIG_FINALIZE_PLATFORM_LOCKING`, together with the
selected coreboot configuration's SPI-lockdown options.  When this narrative
and those configurations differ, the board and selected coreboot configs
describe the target's compiled behavior.

Skylake-and-newer supported configurations require the SMM lockdown patch and
options listed above.  Pre-Skylake configurations use the upstream SMI path.
AMD, emulated, POWER9/Talos, and explicitly disabled configurations are not
Intel PR0-locking targets.  Do not derive a repository-wide count from this
narrative; count only board configs that satisfy the documented requirements.

### User-facing toggle

In the Heads configuration GUI (`config-gui.sh`), option 't':
"Deactivate Platform Locking to permit OS write access to firmware"
sets `CONFIG_FINALIZE_PLATFORM_LOCKING=n` in `/etc/config.user` for
the current boot session.  The toggle takes effect immediately (the
running config is reloaded), but reverts on reboot unless the user
also saves via option 's' ("Save the current configuration to the
running BIOS").  Save calls `replace_rom_file` to update
`heads/initrd/etc/config.user` in the ROM's CBFS using `cbfs.sh`,
then `flashrom` reflashes the SPI ROM.  After saving and rebooting, the lock
remains disabled until toggled back on and saved again, or the ROM
is reflashed with the default `CONFIG_FINALIZE_PLATFORM_LOCKING=y`.

## WP# pin protection

The WP# pin on SPI flash chips provides a second, electrical level
of write protection independent of the chipset's PR0 mechanism.
Setting WP# via `flashprog` requires per-chip support.

Status: WP# is technically available on some chips but not widely
used in practice.  Issues tracked at:
- https://github.com/flashrom/flashrom/issues/185
- https://github.com/linuxboot/heads/issues/985
- https://github.com/linuxboot/heads/issues/1741
- https://github.com/linuxboot/heads/issues/1546

QDPI conflicts with WP# on some chips (same IO2 pin), which may
prevent WP# enablement when QDPI is active for chipset/ME reads.

## References

- Upstream coreboot patch for SMM lockdown: [CB:85278](https://review.coreboot.org/c/coreboot/+/85278)
- PR merged for <= Haswell PR0 locking: [heads#1373](https://github.com/linuxboot/heads/pull/1373)
- flashrom → flashprog migration: [heads#1769](https://github.com/linuxboot/heads/pull/1769)
- Dasharo KGPE-D16 SPI WP docs: https://docs.dasharo.com/variants/asus_kgpe_d16/spi-wp/

## Issue tracking

Remaining open items for those wanting to move WP forward:

- WP# pin enablement on more chips
- QDPI/WP# pin conflict resolution
- Broader per-board WP# testing
- Upstreaming CB:85278 into mainline coreboot
