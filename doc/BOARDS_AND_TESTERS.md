General information
==

- **Intel CPU Generations:** [List of Intel processors](https://en.wikipedia.org/wiki/List_of_Intel_processors)
  - **End of Servicing Updates (ESU Date)** [ESU table for Intel processors](https://www.intel.com/content/www/us/en/support/articles/000022396/processors.html)
- **AMD CPU Generations:** [List of AMD processors](https://en.wikipedia.org/wiki/AMD_processors)
- **Transient CPU Vulnerabilities:** [Transient execution CPU vulnerability](https://en.wikipedia.org/wiki/Transient_execution_CPU_vulnerability)

**Note (as of 2026-07-22):**
- Intel CPUs from the 1st to 7th generations (Nehalem through Kaby Lake) have reached End-of-Life (EOL) status and no longer receive microcode updates. Consequently, these processors remain vulnerable to Spectre Variant 2 (CVE-2017-5715) and related speculative execution vulnerabilities.
- Some 8th generations (Kaby Lake Refresh) also reached EOL per Intel ESU.

**Per-generation EOL/ESU dates** (sources: [eosl.date](https://eosl.date/eol/product/intel-processors/), [Intel microcode releases](https://github.com/intel/Intel-Linux-Processor-Microcode-Data-Files/releases)):

| Generation | Code Name | EOL/ESU Date | Microcode Status |
|---|---|---|---|
| 2nd Gen | Sandy Bridge | ~2017-2018 (estimated) | No updates since ~2018 |
| 3rd Gen | Ivy Bridge | Dec 31, 2019 | No updates since ~2019 |
| 4th Gen | Haswell | Jun 30, 2021 | No updates since ~2021 |
| 5th Gen | Broadwell | Jun 30, 2021 | No updates since ~2021 |
| 6th Gen | Skylake | Sep 30, 2022 | No updates since ~2022 |
| 7th Gen | Kaby Lake | Mar 31, 2024 | No updates since ~2024 |
| 8th Gen | Kaby Lake-R / Coffee Lake / Whiskey Lake | Jun 30, 2025 | Not in Feb 2026 release |
| 10th Gen | Comet Lake | Active (as of Feb 2026) | Last in Feb 2026; dropped from May 2026 |
| 11th Gen | Tiger Lake | Active | Last in Feb 2026; dropped from May 2026 |
| 12th Gen | Alder Lake | Active | Last in Feb 2026; dropped from May 2026 |

Intel does **not** offer an Extended Security Updates (ESU) program. "ESU" in Intel documentation refers to "End of Servicing Updates" — the date after which no further microcode releases are made. Once a generation reaches ESU, any newly discovered CPU vulnerabilities will remain unpatched indefinitely.

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

## TPM GPIO Reset Vulnerability (upstream coreboot bug)

Heads relies on coreboot for GPIO pad configuration. Many Intel platforms are
affected by a coreboot bug where the PCH GPIO lock bits are not set before
booting the OS, allowing an attacker with code execution to reset the discrete
TPM without a physical reboot and forge PCR measurements.
See [TPM GPIO fail (mkukri.xyz)](https://mkukri.xyz/2024/06/01/tpm-gpio-fail.html)
and [doc/TPM_GPIO_Reset_Vulnerability.md](TPM_GPIO_Reset_Vulnerability.md) for details.

Impact on Heads: TPM Disk Unlock Key with passphrase is **not affected**.
TPMTOTP/HOTP remote attestation **is affected** (PCRs can be forged).
The fix must come from coreboot. Tracked at [coreboot ticket #576](https://ticket.coreboot.org/issues/576)
and [coreboot patch series](https://review.coreboot.org/q/topic:%22intel_gpio_lock%22).

| Board group | SoC generation | Coreboot GPIO lock |
|---|---|---|
| xx20 (Sandy Bridge, 2nd Gen) | Dedicated PLTRST pin | Not vulnerable |
| xx30 (Ivy Bridge, 3rd Gen) | Dedicated PLTRST pin | Not vulnerable |
| xx4x / w541 (Haswell, 4th Gen) | Dedicated PLTRST pin | Not vulnerable |
| xx8x / t480 / t480s (Kaby Lake, 8th Gen) | Skylake SoC code (25.09) | Not functional: no pad lock offsets, no Kconfig lock method selected |
| Librem 13v2/15v3 (Skylake, 6th Gen) | Purism fork | Not functional: no lock Kconfig selected (Purism fork) |
| Librem 13v4/15v4 (Kaby Lake, 7th Gen) | Purism fork | Not functional: no lock Kconfig selected (Purism fork) |
| Librem 14 (Comet Lake, 10th Gen) | Purism fork | Not functional: no lock Kconfig selected (Purism fork) |
| Librem 11 (Jasper Lake, Atom) | Purism fork | Not functional: no lock Kconfig selected (Purism fork) |
| Librem L1UM v1 (Broadwell, 5th Gen) | Dedicated PLTRST pin | Not vulnerable |
| Librem L1UM v2 (Coffee Lake, 9th Gen) | Purism fork | Not functional: no lock Kconfig selected (Purism fork) |
| Librem mini v1 (Whiskey Lake, 8th Gen) | Purism fork | Not functional: no lock Kconfig selected (Purism fork) |
| Librem mini v2 (Comet Lake, 10th Gen) | Purism fork | Not functional: no lock Kconfig selected (Purism fork) |
| Optiplex 7010/9010 (Ivy Bridge, 3rd Gen) | Dedicated PLTRST pin | Not vulnerable |
| HP Z220 CMT (Ivy Bridge, 3rd Gen) | Dedicated PLTRST pin | Not vulnerable |
| Clevo NS50 / NV4x (Alder Lake, 12th Gen) | Dasharo fork | Not functional: lock Kconfig selected but SMM lock disabled, no board pad locks (Dasharo fork) |
| Clevo v540tu/v560tu (Meteor Lake) | Dasharo fork | Functional: GPIO lock enabled via PCR method (Dasharo fork) |
| MSI Z690-A/Z790-P (Alder/Raptor Lake) | Dasharo fork | Not functional: SMM lock disabled, no board pad locks (Dasharo fork) |
| KGPE-D16 (AMD) | Not Intel | Not affected |
| Talos II (Power9) | Not Intel | Not affected |

Note: Dasharo and Purism coreboot fork statuses reflect confirmed findings from
vendor build tree inspection. See doc/TPM_GPIO_Reset_Vulnerability.md for per-fork
details.

Laptops
==

xx20 (Sandy Bridge: Intel 2nd Gen CPU)
===
- [ ] t420 (xx20): @notgivenby @alexmaloteaux @akfhasodh @doob85
- [ ] x220 (xx20): @srgrint @Thrilleratplay

xx30 (Ivy Bridge: Intel 3rd Gen CPU)
===
- [ ] t430 (xx30): @notgivenby @nestire @Thrilleratplay @alexmaloteaux @lsafd @bwachter(iGPU maximized) @shamen123 @eganonoa(iGPU) @nitrosimon @jans23 @icequbes1 (iGPU) @weyounsix (t430-dgpu)
- [ ] w530 (xx30): @eganonoa @zifxify @weyounsix (dGPU: w530-k2000m) @jnscmns (dGPU K1000M) @computer-user123 (w530 / w530 k2000: prefers iGPU) @tlaurion
- [ ] x230 (xx30): @nestire @tlaurion @merge @jan23 @MrChromebox @shamen123 @eganonoa @bwachter @Thrilleratplay @jnscmns
- [ ] x230-fhd/edp variant: @n4ru @computer-user123 (nitro caster board) @Tonux599 @househead @pcm720 (eDP 4.0 board and 1440p display) @doob85
- [ ] t530 (xx30): @fhvyhjriur @3hhh (See: https://github.com/linuxboot/heads/issues/1682)

xx4x (Haswell: Intel 4th Gen CPU)
===
- [ ] t440p: @MattClifton76 @fhvyhjriur @ThePlexus @srgrint @akunterkontrolle @rbreslow
- [ ] w541 (similar of t440p): @gaspar-ilom @ResendeGHF

xx8x (Kaby Lake Refresh: Intel 8th Gen Mobile : ESU ended 12/31/2024)
===
- [ ] t480: @gaspar-ilom @doritos4mlady @MattClifton76 @notgivenby @akunterkontrolle @nestire (Nitrokey)
- [ ] t480s: @thickfont @kjkent @HarleyGodfrey @nestire (Nitrokey)

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
- [ ] KGPE-D16 (Bulldozer: AMD Family 15h CPU) – dropped in coreboot 4.12: @arhabd @Tonux599 @zifxify
- [ ] Librem L1UM v1 (Broadwell: Intel 5th Gen CPU): @JonathonHall-Purism
- [ ] Librem L1UM v2 (Coffee Lake: Intel 9th Gen CPU): @JonathonHall-Purism
- [ ] Librem mini v1 (Whiskey Lake: Intel 8th Gen CPU : ESU ends 03/31/2026): @JonathonHall-Purism
- [ ] Librem mini v2 (Comet Lake: Intel 10th Gen CPU): @JonathonHall-Purism
- [ ] Talos II (Power9, PPC64LE): @tlaurion (became untested, low community interest despite large investment)

MSI
---
- [ ] MSI PRO Z690-A (WIFI) (DDR4): **None** - Board is untested.
- [ ] MSI PRO Z690-A (WIFI) (DDR5): **None** - Board is untested.
- [ ] MSI PRO Z790-P (WIFI) (DDR4): **None** - Board is untested.
- [ ] MSI PRO Z790-P (WIFI) (DDR5): @Tonux599
