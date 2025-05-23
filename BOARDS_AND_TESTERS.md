General information
==

- Intel CPU generations: https://en.wikipedia.org/wiki/List_of_Intel_processors
- AMD CPU Generations:https://en.wikipedia.org/wiki/AMD_processors
- Transient CPU vulnerabilities: https://en.wikipedia.org/wiki/Transient_execution_CPU_vulnerability

--> **AS OF 2025-05-21 : ALL INTEL OLDER THAN 8TH GENERATION (AS OLD TO NEHALEM 1ST GEN) CPU WILL STAY VULNERABLE TO SPECTRE V2 VULN SINCE EOL**

Live list of community supported platform testers per last coreboot/linux version bump
==

Heads is a community project, where boards under boards/* need to be tested by board owners when coreboot/linux version bumps happen prior of a Pull Request (PR) merge.
This list will be maintained per coreboot/linux version bumps PRs.

Please see boards/BOARD_NAME/BOARD_NAME.config for HCL details.

----

As per https://github.com/linuxboot/heads/issues/692, currently built CircleCI boards ROMs are:

Laptops
==

xx20 (Sandy Bridge: Intel 2nd Gen CPU)
===
- [ ] t420 (xx20): @notgivenby @alexmaloteaux @akfhasodh @doob85
- [ ] x220 (xx20): @srgrint @Thrilleratplay

xx30 (Ivy Bridge: Intel 3rd Gen CPU)
===
- [ ] t430 (xx30): @notgivenby @nestire @Thrilleratplay @alexmaloteaux @lsafd @bwachter(iGPU maximized) @shamen123 @eganonoa(iGPU) @nitrosimon @jans23 @icequbes1 (iGPU) @weyounsix (t430-dgpu)
- [ ] w530 (xx30): @eganonoa @zifxify @weyounsix (dGPU: w530-k2000m) @jnscmns (dGPU K1000M) @computer-user123 (w530 / w530 k2000: prefers iGPU) @tlaurio
- [ ] x230 (xx30): @nestire @tlaurion @merge @jan23 @MrChromebox @shamen123 @eganonoa @bwachter @Thrilleratplay @jnscmns
- [ ] x230-fhd/edp variant: @n4ru @computer-user123 (nitro caster board) @Tonux599 @househead @pcm720 (eDP 4.0 board and 1440p display) @doob85 https://matrix.to/#/@rsabdpy:matrix.org (agan mod board)
- [ ] x230t: @fhvyhjriur
- [ ] t530 (xx30): @fhvyhjriur @3hhh (See: https://github.com/linuxboot/heads/issues/1682)

xx4x (Haswell: Intel 4th Gen CPU)
===
- [ ] t440p: @fhvyhjriur @ThePlexus @srgrint @akunterkontrolle @rbreslow
- [ ] w541 (similar of t440p): @ResendeGHF @gaspar-ilom (Late tested; at risk of deprecation)

xx8x (Kaby Lake Refresh / Coffee Lake: Intel 8th Gen Mobile)
===
- [ ] t480: @gaspar-ilom @doritos4mlady @MattClifton76 @notgivenby @akunterkontrolle

Librem
===
- [ ] Librem 13v2 (Sky Lake: Intel 6th Gen CPU): @JonathonHall-Purism
- [ ] Librem 15v3 (Sky Lake: Intel 6th Gen CPU): @JonathonHall-Purism
- [ ] Librem 15v4 (Kaby Lake: Intel 7th Gen CPU): @JonathonHall-Purism
- [ ] Librem 13v4 (Kaby Lake: Intel 7th Gen CPU): @JonathonHall-Purism
- [ ] Librem 14 (Comet Lake: Intel 10th Gen CPU): @JonathonHall-Purism
- [ ] Librem 11 (Jasper Lake: Intel 11th Gen Atom CPU): @JonathonHall-Purism

Clevo
===
- [ ] Nitropad NS50 (Alder Lake: Intel 12th Gen CPU): @daringer
- [ ] Novacustom NV4x (Alder Lake: Intel 12th Gen CPU): @tlaurion @daringer
- [ ] Novacustom v540tu (Meteor Lake: Intel Core Ultra 7 155H, Core Ultra Series 1 – 14th Gen Mobile): @tlaurion @daringer @mkopec
- [ ] Novacustom v560tu (Meteor Lake: Intel Core Ultra 7 155H, Core Ultra Series 1 – 14th Gen Mobile): @tlaurion @daringer @mkopec


Desktops / Servers
==
- [ ] Optiplex 7010/9010 SFF/DT (Ivy Bridge: Intel 3rd Gen CPU): @tlaurion(owns DT variant)
- [ ] HP Z220 CMT (Ivy Bridge: Intel 3rd Gen CPU): @d-wid
- [ ] KGPE-D16 (Bulldozer: AMD Family 15h CPU) – dropped in coreboot 4.12: @arhabd @Tonux599 @zifxify https://matrix.to/#/@rsabdpy:matrix.org
- [ ] Librem L1UM v1 (Broadwell: Intel 5th Gen CPU): @JonathonHall-Purism
- [ ] Librem L1UM v2 (Coffee Lake: Intel 8th Gen CPU): @JonathonHall-Purism
- [ ] Librem mini v1 (Whiskey Lake: Intel 8th Gen CPU): @JonathonHall-Purism
- [ ] Librem mini v2 (Comet Lake: Intel 10th Gen CPU): @JonathonHall-Purism
- [ ] Talos II (Power9, PPC64LE): @tlaurion (became untested, low community interest despite large investment)
