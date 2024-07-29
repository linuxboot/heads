Live list of community supported platform testers per last coreboot/linux version bump
==

Heads is a community project, where boards under boards/* need to be tested by board owners when coreboot/linux version bumps happen prior of a Pull Request (PR) merge.
This list will be maintained per coreboot/linux version bumps PRs.

Please see boards/BOARD_NAME/BOARD_NAME.config for HCL details.

----

As per https://github.com/linuxboot/heads/issues/692, currently built CircleCI boards ROMs are:

Laptops
==

xx20 (Sandy):
===
- [ ] t420 (xx20): @alexmaloteaux @natterangell (iGPU) @akfhasodh @doob85
- [ ] x220 (xx20): @Thrilleratplay @BlackMaria @srgrint

xx30 (Ivy):
===
- [ ] t430 (xx30): @nestire(t430-legacy, t430-maximized) @Thrilleratplay @alexmaloteaux @lsafd @bwachter(iGPU maximized) @shamen123 @eganonoa(iGPU) @nitrosimon @jans23 @icequbes1 (iGPU) @weyounsix (t430-dgpu)
- [ ] w530 (xx30): @eganonoa @zifxify @weyounsix (dGPU: w530-k2000m) @jnscmns (dGPU K1000M) @computer-user123 (w530 / & w530 k2000 : prefers iGPU)
- [ ] x230 (xx30): @nestire(x230-legacy, x230-maximized) @tlaurion(maximized) @osresearch @merge @jan23 @MrChromebox @shamen123 @eganonoa @bwachter @Thrilleratplay @jnscmns @doob85 @natterangell (x230i variant: irrelevant individual board)
- [ ] x230-fhd/edp variant: @n4ru @computer-user123 (nitro caster board) @Tonux599 @househead @pcm720 (eDP 4.0 board and 1440p display)
- [ ] t530 (xx30): @fhvyhjriur @3hhh (Opportunity to mainstream and close https://github.com/linuxboot/heads/issues/1682)

xx4x(Haswell):
===
- [ ] t440p: @ThePlexus @srgrint @akunterkontrolle @rbreslow
- [ ] w541 (similar to t440p): @resende-gustavo @gaspar-ilom

Librems:
===
- [ ] Librem 11(JasperLake): @JonathonHall-Purism
- [ ] Librem 13v2 (Skylake): @JonathonHall-Purism
- [ ] Librem 13v4 (Kabylake): @JonathonHall-Purism
- [ ] Librem 14 (CometLake): @JonathonHall-Purism
- [ ] Librem 15v3 (Skylake): @JonathonHall-Purism
- [ ] Librem 15v4 (Kabylake): @JonathonHall-Purism

Clevo:
===
- [ ] Nitropad NS50 (AlderLake) : @daringer
- [ ] Nitropad NV41 (AlderLake) : @daringer, @tlaurion


Desktops/Servers
==
- [ ] kgpe-d16 (AMD fam15h) (dropped in coreboot 4.12): @tlaurion @Tonux599 @zifxify @arhabd
- [ ] Librem L1UM v1 (Broadwell): @JonathonHall-Purism
- [ ] Librem L1Um v2 (CoffeeLake): @JonathonHall-Purism
- [ ] Talos II (PPC64LE, Power9) : @tlaurion
- [ ] z220-cmt (HP Z220 CMT): @d-wid
