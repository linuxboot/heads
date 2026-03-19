Flashrom was passed to flashprog under https://github.com/linuxboot/heads/pull/1769

Those are notes for @i-c-o-n and others wanting to move WP forward but track issues and users

The problem with WP is that it is desired but even if partial write protection regions is present, WP is widely unused.

Some random notes since support is incomplete (depends on chips, really)
-QDPI is problematic for WP (same IO2 PIN)
  - Might be turned on by chipset for ME read https://matrix.to/#/!pAlHOfxQNPXOgFGTmo:matrix.org/$NCNidoPsw1ze6zv3m2jlPuGuNrdlDQmDcU81If-q55A?via=matrix.org&via=nitro.chat&via=tchncs.de
- WP wanted, WP done, WP unused
  - WP wanted https://github.com/flashrom/flashrom/issues/185 https://github.com/linuxboot/heads/issues/985
  - WP done: https://github.com/linuxboot/heads/issues/1741 https://github.com/linuxboot/heads/issues/1546
   - Documented https://docs.dasharo.com/variants/asus_kgpe_d16/spi-wp/
  - WP still unused for SPI STATUS register-based protection (older/non-opaque boards)

Alternative, as suggested by @i-c-o-n is Chipset Platform Locking (PR0) which is enforced at platform's chipset level for a boot
- This is implemented and enforced on <= Haswell from this PR merged : https://github.com/linuxboot/heads/pull/1373
- All Intel platforms have PR0 platform locking implemented prior to kexec call with this not yet upstreamed patch applied in all forks https://review.coreboot.org/c/coreboot/+/85278
- Discussion point under flashrom-> flashprog PR under https://github.com/linuxboot/heads/pull/1769/files/f8eb0a27c3dcb17a8c6fcb85dd7f03e8513798ae#r1752395865 tagging @i-c-o-n

## PCH100+ (Meteor Lake) — PRR-based WP now implemented

`flashprog wp` subcommands (status, list, disable, range, enable) are now
functional on PCH100+ chipsets where flash is accessed via hardware sequencing
(opaque/hwseq programmer).  Protection is read from and written to the PCH's
Protected Range Registers (PRRs) rather than the flash chip's STATUS register,
which is not directly accessible on these platforms.

Implementation based on WP infrastructure contributed by the Dasharo/3mdeb team
(SergiiDmytruk, Pokisiekk, macpijan, krystian-hebel and others) and upstreamed
to flashrom.  See <https://review.coreboot.org/c/flashrom/+/68179> and
<https://github.com/linuxboot/heads/issues/1741>.

Key behaviour:

- `wp status` reports `disabled` before `lock_chip` (FLOCKDN=0): coreboot
  pre-programs PRR0 with WP=1 as preparation for kexec lockdown, but
  ich9_set_pr() clears those bits when FLOCKDN=0, so protection is not enforced.
- `wp status` reports `hardware` after `lock_chip` (FLOCKDN=1): PRR registers
  are frozen by DLOCK; ich9_set_pr() cannot clear WP bits.
- Pre-flash WP check integrated into heads: flash operations are refused when
  `wp status` reports `hardware` mode overlapping the write target.

Tested on novacustom-v560tu (Intel Meteor Lake):
  Before lock_chip (FLOCKDN=0): PASS=8  FAIL=0  SKIP=0
  After  lock_chip (FLOCKDN=1): PASS=6  FAIL=0  SKIP=2  (write cmds skipped)

See doc/flashprog-wp.md for usage, commands, and hardware output examples.

Not sure what is the way forward here, but lets keep this file in tree to track improvements over time.
