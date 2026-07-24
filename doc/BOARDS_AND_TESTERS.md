General information
==

[Intel](https://en.wikipedia.org/wiki/List_of_Intel_processors) and
[AMD](https://en.wikipedia.org/wiki/List_of_AMD_processors) CPU generations;
[Transient execution CPU vulnerability](https://en.wikipedia.org/wiki/Transient_execution_CPU_vulnerability).

"ESU" means "End of Servicing Updates" -- the date after which Intel stops
releasing microcode for a CPU generation; newly discovered vulnerabilities on
past-ESU generations remain unpatched. The `EOL_` prefix in board directories
indicates ended microcode servicing. For future ESU dates refer to:
- **Intel:** [ESU policy](https://www.intel.com/content/www/us/en/support/topics/support-and-servicing-for-processors.html) | [microcode releases](https://github.com/intel/Intel-Linux-Processor-Microcode-Data-Files/releases)
- **AMD:** [linux-firmware microcode history](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/log/amd-ucode/)
- **IBM POWER9:** [End of Standard Service announcement](https://public.dhe.ibm.com/systems/support/planning/notices/September.12.2024.Announcement.Power9.pdf) (January 31, 2026)

## Per-board EOL/ESU status

The Last Microcode column links to the [Intel microcode releases page](https://github.com/intel/Intel-Linux-Processor-Microcode-Data-Files/releases).
Dates below are as of the document's last update and may be stale.

**EOL boards** (`EOL_` prefix present):

| Board | Gen | Code Name | ESU Date | Last Microcode |
|---|---|---|---|---|
| `EOL_t420` | 2nd | Sandy Bridge | No official ESU | 2019-05-14 |
| `EOL_x220` | 2nd | Sandy Bridge | No official ESU | 2019-05-14 |
| `EOL_t430` | 3rd | Ivy Bridge | No official ESU | 2019-05-14 |
| `EOL_w530` | 3rd | Ivy Bridge | No official ESU | 2019-05-14 |
| `EOL_x230` | 3rd | Ivy Bridge | No official ESU | 2019-05-14 |
| `EOL_t530` | 3rd | Ivy Bridge | No official ESU | 2019-05-14 |
| `EOL_optiplex-7010_9010` | 3rd | Ivy Bridge | No official ESU | 2019-05-14 |
| `EOL_z220-cmt` | 3rd | Ivy Bridge | No official ESU | 2019-05-14 |
| `EOL_t440p` | 4th | Haswell | Jun 30, 2021 | 2021-06 |
| `EOL_w541` | 4th | Haswell | Jun 30, 2021 | 2021-06 |
| `EOL_librem_l1um` | 5th | Broadwell | Jun 30, 2021 | 2020-06 |
| `EOL_librem_13v2` | 6th | Skylake | Sep 30, 2022 | 2022-11 |
| `EOL_librem_15v3` | 6th | Skylake | Sep 30, 2022 | 2022-11 |
| `EOL_m900_tower` | 6th | Skylake | Sep 30, 2022 | 2022-11 |
| `EOL_librem_13v4` | 7th | Kaby Lake | Mar 31, 2024 | 2024-03 |
| `EOL_librem_15v4` | 7th | Kaby Lake | Mar 31, 2024 | 2024-03 |
| `EOL_t480` | 8th | Kaby Lake-R | Mar 31, 2026 ¹ | 2024-03 |
| `EOL_t480s` | 8th | Kaby Lake-R | Mar 31, 2026 ¹ | 2024-03 |

¹ KBL-R falls under Whiskey Lake ESU (Mar 31, 2026); also classified under Coffee Lake ESU (Jun 30, 2025). Both dates have passed.

| `librem_l1um_v2` | 9th | Coffee Lake Refresh | Jun 30, 2026 | Not in Feb 2026+ |
| `librem_mini` | 8th | Whiskey Lake | Mar 31, 2026 | Not in Feb 2026+ |
| `UNTESTED_talos-2` | POWER9 | Talos II (IBM) | Jan 31, 2026 ² | Feb 2024 ² |

² IBM End of Standard Service for POWER9. Last Raptor firmware release: February 2024.

**Active boards** (ESU not yet reached; no `EOL_` prefix):

| Board | Gen | Code Name | ESU Date | Last Microcode |
|---|---|---|---|---|
| `librem_14` | 10th | Comet Lake | Jun 30, 2027 | 2025-05 ³ |
| `librem_mini_v2` | 10th | Comet Lake | Jun 30, 2027 | 2025-05 ³ |
| `librem_11` | Atom | Jasper Lake | TBD | TBD |
| `UNTESTED_nitropad-ns50` | 12th | Alder Lake | Active | 2026-02 |
| `novacustom-nv4x_adl` | 12th | Alder Lake | Active | 2026-02 |
| `UNTESTED_msi_z690a_ddr4` | 12th | Alder Lake | Active | 2026-02 |
| `UNTESTED_msi_z690a_ddr5` | 12th | Alder Lake | Active | 2026-02 |
| `msi_z790p_ddr5` | 13th | Raptor Lake | Active | 2026-05 |
| `UNTESTED_msi_z790p_ddr4` | 13th | Raptor Lake | Active | 2026-05 |
| `novacustom-v540tu` | Core Ultra S1 | Meteor Lake | Active | 2026-05 |
| `novacustom-v560tu` | Core Ultra S1 | Meteor Lake | Active | 2026-05 |

³ Comet Lake ESU runs through Jun 30, 2027. Check the
[Intel microcode releases page](https://github.com/intel/Intel-Linux-Processor-Microcode-Data-Files/releases)
for recent updates.

**Formerly supported** (`unmaintained_boards/*/`; reference only):

| Board | Gen | Code Name | ESU Date | Last Microcode |
|---|---|---|---|---|
| KGPE-D16 | AMD Family 15h | Bulldozer | No AMD ESU | 2018-05 (dropped in coreboot 4.12) |

KGPE-D16 is the last fully blob-free **x86** platform (Talos II is the last
fully blob-free platform overall, on POWER9). AMD ceased Family 15h microcode
in 2018; removed from upstream coreboot in 4.12 (2019). The Dasharo fork was
abandoned August 2025. An independent community port (15h.org, October 2025)
exists but is not part of upstream coreboot.

### Mitigation

Spectre Variant 2 (CVE-2017-5715) and related speculative execution
vulnerabilities are unpatched on any board past its ESU date. Retpoline and
similar software mitigations have limited effectiveness without microcode
updates. On EOL platforms, run a single trusted workflow per boot session
and reboot before switching tasks.

See the [Heads threat model](https://osresearch.net/Heads-threat-model/#mitigation-on-eol-platforms)
for detailed guidance including Tails OPSEC, QubesOS memory management, and
QSB-107 exposure rates.

## TPM GPIO Reset Vulnerability

*For a detailed analysis including per-platform feasibility, attack steps,
and upstream tracking, see [TPM_GPIO_Reset_Vulnerability.md](TPM_GPIO_Reset_Vulnerability.md).*

Heads relies on coreboot to lock PCH GPIO pad configuration before booting
the OS. On many Intel platforms, coreboot fails to set these lock bits.
If pads are unlocked, post-coreboot code can reprogram the PLTRST# pin to
GPIO mode and assert it, forcing a TPM Reset.

Attack chain:
1. Attacker asserts PLTRST# via GPIO, resetting the TPM to power-on state
   (PCRs cleared to zero; NVRAM preserved).
2. Attacker replays known PCR measurements (boot hashes are deterministic)
   to reconstruct the sealed PCR state.
3. Since PCRs match sealed values, `tpm2 unseal` succeeds, extracting the
   TOTP/HOTP shared secret.

The TPM Disk Unlock Key with passphrase is **not affected** -- the
passphrase is required regardless of PCR state. TPMTOTP/HOTP remote
attestation **is affected** -- the shared secret at NVRAM index 0x4d47
has no passphrase, enabling unseal with forged PCRs.

The fix must come from coreboot. Tracked at [coreboot ticket #576](https://ticket.coreboot.org/issues/576)
and [coreboot patch series](https://review.coreboot.org/q/topic:%22intel_gpio_lock%22).

## Board Testers

Boards under `boards/*` must be tested by listed owners for coreboot/linux
version bumps. This file is the primary board tester registry.
To be added or removed as a tester, comment on [issue #692](https://github.com/linuxboot/heads/issues/692).
For HCL details: `boards/BOARD_NAME/BOARD_NAME.config`.

Laptops
==

xx20 (Sandy Bridge, 2nd Gen -- EOL)
===
- [ ] t420 (xx20): @notgivenby @alexmaloteaux @akfhasodh @doob85
- [ ] x220 (xx20): @srgrint @Thrilleratplay

xx30 (Ivy Bridge, 3rd Gen -- EOL)
===
- [ ] t430 (xx30): @notgivenby @nestire @Thrilleratplay @alexmaloteaux @lsafd @bwachter(iGPU maximized) @shamen123 @eganonoa(iGPU) @nitrosimon @jans23 @icequbes1 (iGPU) @weyounsix (t430-dgpu)
- [ ] w530 (xx30): @eganonoa @zifxify @weyounsix (dGPU: w530-k2000m) @jnscmns (dGPU K1000M) @computer-user123 (w530 / w530 k2000: prefers iGPU) @tlaurion
- [ ] x230 (xx30): @nestire @tlaurion @merge @jan23 @MrChromebox @shamen123 @eganonoa @bwachter @Thrilleratplay @jnscmns
- [ ] x230-fhd/edp variant: @n4ru @computer-user123 (nitro caster board) @Tonux599 @househead @pcm720 (eDP 4.0 board and 1440p display) @doob85
- [ ] t530 (xx30): @fhvyhjriur @3hhh (See: https://github.com/linuxboot/heads/issues/1682)

ThinkCentre (Skylake, 6th Gen Desktop -- EOL)
===
- [ ] M900 Tower: @notgivenby

xx4x (Haswell, 4th Gen -- EOL)
===
- [ ] t440p: @MattClifton76 @fhvyhjriur @ThePlexus @srgrint @akunterkontrolle @rbreslow
- [ ] w541 (similar to t440p): @gaspar-ilom @ResendeGHF

xx8x (Kaby Lake Refresh, 8th Gen Mobile -- EOL)
===
- [ ] t480: @gaspar-ilom @doritos4mlady @MattClifton76 @notgivenby @akunterkontrolle @nestire (Nitrokey)
- [ ] t480s: @thickfont @kjkent @HarleyGodfrey @nestire (Nitrokey)

Librem
===
All EOL unless marked Active.
- [ ] Librem 13v2 (Skylake, 6th Gen): @JonathonHall-Purism
- [ ] Librem 15v3 (Skylake, 6th Gen): @JonathonHall-Purism
- [ ] Librem 15v4 (Kaby Lake, 7th Gen): @JonathonHall-Purism
- [ ] Librem 13v4 (Kaby Lake, 7th Gen): @JonathonHall-Purism
- [ ] Librem 14 (Comet Lake, 10th Gen -- Active): @JonathonHall-Purism
- [ ] Librem 11 (Jasper Lake, Atom -- Active): @JonathonHall-Purism

Clevo
===
All Active.
- [ ] Nitropad NS50 (Alder Lake, 12th Gen): @daringer
- [ ] Novacustom NV4x (Alder Lake, 12th Gen): @tlaurion @daringer
- [ ] Novacustom v540tu (Meteor Lake, Core Ultra S1): @tlaurion @daringer @mkopec
- [ ] Novacustom v560tu (Meteor Lake, Core Ultra S1): @tlaurion @daringer @mkopec

Desktops / Servers
==
All EOL unless marked Active.
- [ ] Optiplex 7010/9010 SFF/DT (Ivy Bridge, 3rd Gen): @tlaurion(owns DT variant)
- [ ] HP Z220 CMT (Ivy Bridge, 3rd Gen): @d-wid
- [ ] KGPE-D16 (AMD Family 15h): @arhabd @Tonux599 @zifxify
- [ ] Librem L1UM v1 (Broadwell, 5th Gen): @JonathonHall-Purism
- [ ] Librem L1UM v2 (Coffee Lake, 9th Gen): @JonathonHall-Purism
- [ ] Librem mini v1 (Whiskey Lake, 8th Gen): @JonathonHall-Purism
- [ ] Librem mini v2 (Comet Lake, 10th Gen -- Active): @JonathonHall-Purism
- [ ] Talos II (POWER9, PPC64LE): @tlaurion (became untested, low community interest despite large investment)

MSI (Alder/Raptor Lake — Active)
---
- [ ] MSI PRO Z690-A (WIFI) (DDR4): **None** - Board is untested. (Active, Alder Lake 12th Gen)
- [ ] MSI PRO Z690-A (WIFI) (DDR5): **None** - Board is untested. (Active, Alder Lake 12th Gen)
- [ ] MSI PRO Z790-P (WIFI) (DDR4): **None** - Board is untested. (Active, Raptor Lake 13th Gen)
- [ ] MSI PRO Z790-P (WIFI) (DDR5): @Tonux599 (Active, Raptor Lake 13th Gen)
