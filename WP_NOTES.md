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
  - WP still unused

Alternative, as suggested by @i-c-o-n is Chipset Platform Locking (PR0) which is enforced at platform's chipset level for a boot
- This is implemented and enforced on <= Haswell from this PR merged : https://github.com/linuxboot/heads/pull/1373
- Non-upstreamed work has been made from @root-hardenedvault work in vaultboot downstream fork of Heads at https://github.com/hardenedvault/vaultboot/blob/master/patches/coreboot/0001-x11.patch
- Discussion point under flashrom-> flashprog PR under https://github.com/linuxboot/heads/pull/1769/files/f8eb0a27c3dcb17a8c6fcb85dd7f03e8513798ae#r1752395865 tagging @i-c-o-n


Not sure what is the way forward here, but lets keep this file in tree to track improvements over time.
