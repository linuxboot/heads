# SPI Flash Write Protection with flashprog

This document covers how to inspect and configure SPI flash write protection on
heads-supported hardware using the `flashprog wp` subcommands.

## Background

Write protection prevents firmware regions from being overwritten, forming the
hardware basis of a Static Root of Trust (SRTM).  On Intel PCH platforms
(Skylake and later), write protection is enforced by **Protected Range Registers
(PRRs)** in the PCH SPI BAR rather than by the flash chip's own STATUS register.
This matters because:

- On PCH100+ (Meteor Lake etc.) the flash is accessed via hardware sequencing
  (hwseq); the chip's STATUS register is not directly addressable with standard
  SPI opcodes.
- Protection is only meaningful when the SPI configuration is locked
  (`FLOCKDN`).  coreboot pre-programs PRR0 with `WP=1` as preparation for the
  kexec lockdown, but that bit is cleared by flashprog on every init when
  `FLOCKDN=0`.  Until `lock_chip` is called (just before kexec), write
  protection is **not enforced** regardless of what the PRR registers show.

The patched heads flashprog correctly accounts for this: `wp status` reports
`disabled` when `FLOCKDN=0` and `hardware` only when `FLOCKDN=1` and at least
one PRR has `WP=1` with a non-empty range.

## Programmer Options

All heads boards use `--programmer internal`.  The `wp` subcommands do **not**
accept layout flags (`--ifd`, `--image`, `-i`); those must be omitted.

If `CONFIG_FLASH_OPTIONS` is set in the environment, the `wp-test` and
`wp-debug` scripts strip layout flags automatically.

## Commands

### Check current protection status

```sh
flashprog wp status --programmer internal
```

**Before `lock_chip`** (FLOCKDN=0 — heads runtime, pre-kexec):

```text
Protection range: start=0x00000000 length=0x00000000 (none)
Protection mode: disabled
```

coreboot has already written `WP=1` to PRR0, but `ichspi_lock` (FLOCKDN) is
not yet set.  flashprog clears the WP bit during init, so the PRR is not
enforced and `wp status` correctly reports `disabled`.

**After `lock_chip`** (FLOCKDN=1 — SPI configuration locked, kexec imminent):

```text
Protection range: start=0x00000000 length=0x02000000 (all)
Protection mode: hardware
```

FLOCKDN is set; `ich9_set_pr` cannot clear WP bits.  PRR0 covers the full
32 MB chip (base=0x00000, limit=0x01fff in 4 KB units → 0x00000000–0x01ffffff).
flashprog also emits a warning at init time:

```text
SPI Configuration is locked down.
PR0: Warning: 0x00000000-0x01ffffff is read-only.
At least some flash regions are write protected. For write operations,
you should use a flash layout and include only writable regions. See
manpage for more details.
```

Add `--verbose` to see individual PRR register values, FLOCKDN state, DLOCK,
and all FREG entries:

```sh
flashprog wp status --programmer internal --verbose
```

Before `lock_chip` the verbose output includes:

```text
HSFS: FDONE=0, FCERR=0, AEL=0, SCIP=0, PRR34_LOCKDN=0, WRSDIS=0, FDOPSS=1, FDV=1, FLOCKDN=0
DLOCK: BMWAG_LOCKDN=0, BMRAG_LOCKDN=0, SBMWAG_LOCKDN=0, SBMRAG_LOCKDN=0,
       PR0_LOCKDN=0, PR1_LOCKDN=0, PR2_LOCKDN=0, PR3_LOCKDN=0, PR4_LOCKDN=0,
       SSEQ_LOCKDN=0
ich_hwseq_wp_read_cfg: FLOCKDN not set, PRR protection not enforced
```

After `lock_chip`:

```text
HSFS: FDONE=0, FCERR=0, AEL=0, SCIP=0, PRR34_LOCKDN=1, WRSDIS=1, FDOPSS=1, FDV=1, FLOCKDN=1
DLOCK: BMWAG_LOCKDN=0, BMRAG_LOCKDN=0, SBMWAG_LOCKDN=0, SBMRAG_LOCKDN=0,
       PR0_LOCKDN=1, PR1_LOCKDN=1, PR2_LOCKDN=1, PR3_LOCKDN=1, PR4_LOCKDN=1,
       SSEQ_LOCKDN=0
PRR0: 0x9fff0000 (WP=1 RP=0 base=0x00000 limit=0x01fff)
PRR1: 0x00000000 (WP=0 RP=0 base=0x00000 limit=0x00000)
PRR2: 0x00000000 (WP=0 RP=0 base=0x00000 limit=0x00000)
PRR3: 0x00000000 (WP=0 RP=0 base=0x00000 limit=0x00000)
PRR4: 0x00000000 (WP=0 RP=0 base=0x00000 limit=0x00000)
PRR5: 0x00000000 (WP=0 RP=0 base=0x00000 limit=0x00000)
```

`DLOCK.PR0_LOCKDN=1` through `PR4_LOCKDN=1` means the PRR registers themselves
are frozen; even writing 0 to them fails.

### List available protection ranges

```sh
flashprog wp list --programmer internal
```

Returns the no-protection entry, power-of-2 top-aligned fractions from 4 KB up
to half the chip, and full-chip protection.  On a 32 MB chip:

```text
Available protection ranges:
    start=0x00000000 length=0x00000000 (none)
    start=0x01fff000 length=0x00001000 (upper 1/8192)
    start=0x01ffe000 length=0x00002000 (upper 1/4096)
    start=0x01ffc000 length=0x00004000 (upper 1/2048)
    start=0x01ff8000 length=0x00008000 (upper 1/1024)
    start=0x01ff0000 length=0x00010000 (upper 1/512)
    start=0x01fe0000 length=0x00020000 (upper 1/256)
    start=0x01fc0000 length=0x00040000 (upper 1/128)
    start=0x01f80000 length=0x00080000 (upper 1/64)
    start=0x01f00000 length=0x00100000 (upper 1/32)
    start=0x01e00000 length=0x00200000 (upper 1/16)
    start=0x01c00000 length=0x00400000 (upper 1/8)
    start=0x01800000 length=0x00800000 (upper 1/4)
    start=0x01000000 length=0x01000000 (upper 1/2)
    start=0x00000000 length=0x02000000 (all)
```

`wp list` works in both locked and unlocked states.

### Disable write protection

```sh
flashprog wp disable --programmer internal
```

Clears the `WP` bit on all writable PRR registers.  Returns exit code 0 on
success:

```text
Disabled hardware protection
```

If `FLOCKDN=1`, the registers are frozen and the command fails:

```text
ich_hwseq_wp_write_cfg: SPI configuration is locked (FLOCKDN); cannot modify protected ranges
Failed to apply new WP settings: failed to write the new WP configuration
```

### Set a protection range and enable

Set the range first, then enable:

```sh
# Protect the top 4 MB of a 32 MB chip
flashprog wp range --programmer internal 0x1c00000,0x400000
flashprog wp enable --programmer internal
```

`wp range` encodes the address and length into PRR0.  `wp enable` sets the `WP`
bit.  Both commands require 4 KB-aligned start and length values.  On success:

```text
Configured protection range: start=0x01c00000 length=0x00400000 (upper 1/8)
```

```text
Enabled hardware protection
```

If `FLOCKDN=1`, both commands fail with the same locked-down error as `wp disable`.

**Persistence note:** When `FLOCKDN=0` (heads runtime before kexec), the PRR
write takes effect for the current flashprog session but is not persistent.  On
the next invocation, `ich9_set_pr` clears the WP bit again because FLOCKDN is
not set.  Persistent, hardware-enforced protection is only active after
`lock_chip` sets `FLOCKDN=1`.

## Pre-flash WP check in heads

Before writing firmware, heads checks whether the target region is protected.
If `wp status` reports `hardware` mode with a range that overlaps the write
target, the flash operation is refused.  This guards against accidentally
overwriting a PRR-protected area on a system where `lock_chip` has already run
(post-kexec or externally locked).

## Testing tools

Two shell scripts under `initrd/tests/wp/` are provided for hardware validation.

### wp-test

Runs a sequence of functional tests and prints `PASS`/`FAIL`/`SKIP` per test:

```sh
initrd/tests/wp/wp-test [flashprog-programmer-opts]
```

With no arguments the script uses `CONFIG_FLASH_OPTIONS` from the environment
(stripping layout flags), or falls back to `--programmer internal`.

Tests performed:

| # | Description |
| --- | --- |
| 1 | `wp status` exits with code 0 |
| 2 | `wp status` output contains a `Protection mode:` field |
| 3 | `wp list` exits with code 0 |
| 4 | `wp list` returns more than 2 ranges |
| 5 | `FLOCKDN` state detected via verbose output |
| 6 | `wp status` mode matches `FLOCKDN` state (disabled when unlocked) |
| 7 | `wp disable` exits code 0 — skipped if `FLOCKDN=1` |
| 8 | `wp range` + `wp enable` exit code 0 — skipped if `FLOCKDN=1` |

**Expected results before `lock_chip`** (novacustom-v560tu, Meteor Lake, FLOCKDN=0):

```text
Results: PASS=8  FAIL=0  SKIP=0
```

Tests 7 and 8 pass because PRR registers are writable when FLOCKDN=0.

**Expected results after `lock_chip`** (same hardware, FLOCKDN=1):

```text
Results: PASS=6  FAIL=0  SKIP=2
```

Tests 7 and 8 are skipped because FLOCKDN=1 freezes the PRR registers.  The
two skips are not failures: the hardware is operating correctly.

### wp-debug

Collects diagnostic output for analysis or bug reports:

```sh
initrd/tests/wp/wp-debug [flashprog-programmer-opts]
```

Runs `wp status`, `wp list`, `wp status --verbose`, reads the PCH SPI BAR base
via `setpci` (if available), dumps `/proc/mtd`, and filters relevant `dmesg`
lines.  Paste the output when filing a flash write protection issue.

## PCH100+ notes (Meteor Lake and newer)

On PCH100+ the SPI BAR layout changed:

- PRR registers start at offset `0x84` (`PCH100_REG_FPR0`).
- There are 6 registers (PRR0–PRR5); the last (`GPR0`/PRR5) is chipset-controlled
  and is not written by flashprog.
- After `lock_chip`, `DLOCK` bits `PR0_LOCKDN` through `PR4_LOCKDN` are all set,
  freezing the five OS-accessible PRRs.
- The chip is fully opaque (hardware sequencer only); there is no direct SPI
  STATUS register access via software sequencing.

The patched flashprog adds `read_register` / `write_register` hooks to the hwseq
opaque master so that STATUS register reads/writes go through hardware sequencer
cycle types 8 (RD_STATUS) and 7 (WR_STATUS).  The `wp_read_cfg`,
`wp_write_cfg`, and `wp_get_ranges` hooks implement PRR-based write protection.

## Credits

Write-protection infrastructure for opaque/hwseq programmers (patches 0100,
0300, 0400, and the STATUS register read/write functions in 0200) was developed
by the Dasharo/3mdeb team (SergiiDmytruk, Pokisiekk, macpijan, krystian-hebel
and others) and upstreamed to flashrom.  These patches backport that work to
flashprog 1.5, adapting for API differences between the two projects.

The PRR-based WP functions (`ich_hwseq_wp_read_cfg`, `ich_hwseq_wp_write_cfg`,
`ich_hwseq_wp_get_ranges`) and the FLOCKDN-aware enforcement logic are original
heads contributions.

- Dasharo WP work tracking: <https://github.com/linuxboot/heads/issues/1741>
- Upstream flashrom review: <https://review.coreboot.org/c/flashrom/+/68179>
- Dasharo flashrom fork: <https://github.com/Dasharo/flashrom>
- Upstream flashrom: <https://github.com/flashrom/flashrom>

## Reference

- `patches/flashprog-*/0100-opaque-master-wp-callbacks.patch` — opaque_master struct extension (backport)
- `patches/flashprog-*/0200-ichspi-hwseq-status-register-rw.patch` — hwseq STATUS r/w (backport) + PRR WP (original)
- `patches/flashprog-*/0300-writeprotect-bus-prog-dispatch.patch` — BUS_PROG WP dispatch (backport)
- `patches/flashprog-*/0400-libflashprog-opaque-wp-dispatch.patch` — opaque WP dispatch (backport)
- Intel PCH SPI Programming Guide, chapter "Protected Range Registers"
