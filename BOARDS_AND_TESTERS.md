General information
==

- **Intel CPU Generations:** [List of Intel processors](https://en.wikipedia.org/wiki/List_of_Intel_processors)
  - **End of Servicing Updates (ESU Date)** [ESU table for Intel processors](https://www.intel.com/content/www/us/en/support/articles/000022396/processors.html)
- **AMD CPU Generations:** [List of AMD processors](https://en.wikipedia.org/wiki/AMD_processors)
- **Transient CPU Vulnerabilities:** [Transient execution CPU vulnerability](https://en.wikipedia.org/wiki/Transient_execution_CPU_vulnerability)

**Note (as of 2025-05-29):**
- Intel CPUs from the 1st to 7th generations (Nehalem through Kaby Lake) have reached End-of-Life (EOL) status and no longer receive microcode updates. Consequently, these processors remain vulnerable to Spectre Variant 2 (CVE-2017-5715) and related speculative execution vulnerabilities. 
- Some 8th generations (Kaby Lake Refresh) also reached EOL per Intel ESU.
- **Those boards names were renamed with EOL_ preceding their board names for users to be hinted by this at download/compilation/testing time**

While software-based mitigations like Retpoline can reduce exposure to certain speculative execution attacks, their effectiveness is limited without corresponding microcode updates.  Therefore, systems utilizing these older CPUs should be considered inherently vulnerable to Spectre Variant 2 and similar threats.

Only mitigation is to make sure no secret is present in memory (trusted workflow) in parallel of untrusted workflows.
- This implies a single trusted workflow per boot session, ideally without any secrets remaining in memory—for example, running Tails from a live CD without providing it with any disk decryption passphrase.
  - Poper OPSEC when running Tails: https://www.anarsec.guide/posts/tails
    - The moment a secret resides in memory (e.g., a passphrase or private document), minimize its exposure by limiting its duration—reboot before switching tasks.
    - Always prioritize security over convenience. When in doubt, reboot.
  - Proper OPSEC for Memory use on QubesOS: https://www.anarsec.guide/posts/qubes/#appendix-opsec-for-memory-use
    - Use disposable qubes as if you were running Tails: use distinct disposable qubes and for really short lived tasks: always consider disk decryption key in memory at risk!
**On systems affected by QSB-107 and lacking updated microcode, [any untrusted application running in a qube could potentially exfiltrate sensitive memory content at a rate of as fast as 5.6 KiB/s.](https://comsec.ethz.ch/research/microarch/branch-privilege-injection)**


Live list of community supported platform testers per last coreboot/linux version bump
==

Heads is a community project, where boards under boards/* need to be tested by board owners when coreboot/linux version bumps happen prior of a Pull Request (PR) merge.
This list will be maintained per coreboot/linux version bumps PRs.

Please see boards/BOARD_NAME/BOARD_NAME.config for HCL details.

----

As per tracking issue for board testers: https://github.com/linuxboot/heads/issues/692, currently built CircleCI boards ROMs are:

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
- [ ] t530 (xx30): @fhvyhjriur @3hhh (See: https://github.com/linuxboot/heads/issues/1682)

xx4x (Haswell: Intel 4th Gen CPU)
===
- [ ] t440p: @MattClifton76 @fhvyhjriur @ThePlexus @srgrint @akunterkontrolle @rbreslow
- [ ] w541 (similar of t440p): @gaspar-ilom @ResendeGHF

xx8x (Kaby Lake Refresh: Intel 8th Gen Mobile : ESU ended 12/31/2024)
===
- [ ] t480: @gaspar-ilom @doritos4mlady @MattClifton76 @notgivenby @akunterkontrolle
- [ ] t480s: @thickfont @kjkent @HarleyGodfrey @nestire

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
- [ ] Librem L1UM v2 (Coffee Lake: Intel 9th Gen CPU): @JonathonHall-Purism
- [ ] Librem mini v1 (Whiskey Lake: Intel 8th Gen CPU : ESU ends 03/31/2026): @JonathonHall-Purism
- [ ] Librem mini v2 (Comet Lake: Intel 10th Gen CPU): @JonathonHall-Purism
- [ ] Talos II (Power9, PPC64LE): @tlaurion (became untested, low community interest despite large investment)
