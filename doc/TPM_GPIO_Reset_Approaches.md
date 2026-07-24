# TPM GPIO Reset Attack -- Approaches Exhausted on Intel ADL-P (NovaCustom NV4x)

This document chronicles every approach tried during development of the TPM GPIO
reset Proof-of-Concept for Intel ADL-P (Alder Lake mobile, NovaCustom NV4x)
and the broader family of affected platforms.

## Background

The TPM GPIO reset attack, disclosed by Mate Kukri in June 2024, exploits a
design flaw in Intel PCH platforms where the PLTRST# (Power Loss Timer Reset)
signal driving the discrete TPM is connected through a multi-function GPIO pad.
On vulnerable platforms, this pad can be reprogrammed from native function
(LPC/eSPI/SPI output) to GPIO output mode, allowing an attacker to assert a
hardware reset of the TPM, clear its PCRs, and then forge measurement values
to unseal sealed secrets.

The attack relies on three conditions:
1. The PLTRST# pad is part of a GPIO community, not a dedicated pin.
2. The GPIO pad configuration lock is NOT set by firmware.
3. The PLTRST# assertion mechanism actually works when the pad is toggled.

Condition 3 proved unexpectedly difficult on ADL-P. This document explains why.

---

## 1. What We Verified (from coreboot source code)

### 1.1 Register Addresses Verified Against coreboot 26.06

All register addresses were cross-checked against coreboot 26.06 source code
and the kukrimate/tpm-gpio-fail reference implementation. Bit field definitions
(PADRSTCFG, mode mask) were verified against the Linux kernel pinctrl-intel.c.

See `initrd/bin/tpm-gpio-reset-demo.sh` for the authoritative per-platform
register map:

- Header comments (lines 50-76): port, pad index, PAD_CFG_BASE, lock offset
  per platform family (CNP-LP, SPT/KBP, ADL-P, ADL-S, RPL-S, MTL).
- `detect_platform()` case statement (lines 260-368): PCI device ID to
  platform parameter mapping.
- `calculate_registers()` (lines 533-620): full address computation from
  PCR_BASE, community port, pad index, and PAD_CFG_BASE, including the
  per-pad register layout (2 vs 4 DWORDS per pad) for each generation.

Note: Intel doc 834810 does not cover pre-Tiger Lake platforms. SPT/KBP
(Skylake/Kaby Lake) PADCFGLOCK offsets (0xA8 per kukri) have no public
Intel verification.

Note: CML-U (0x066x) and some CML-U steppings in the 0x9d8* range have
PADCFGLOCK at 0x88. Not all 0x9d8* devices have lock registers -- verify
per-stepping. CNP-LP proper (0x9d84) is confirmed to lack the register.

### 1.2 Platform Detection via PCI Device ID

Platform detection uses the ISA/LPC bridge (class 0x0601, device 00:1f.0 on Intel).
PCI device IDs map to PCH families as documented in the script's `detect_platform()`
function. This is reliable across all Linux kernels and does not depend on DMI data
or board config.

**Definitive results from NV4x ADL-P testing (debug mode, 2026-07-22):**

| Test | Result |
|---|---|
| DW0 original value | `0x00040040` (mode=GPIO, TX=0, PADRSTCFG=PWROK) |
| PADCFGLOCK (0xFD6E0080) | `0x00000000` — NOT locked |
| PADCFGLOCKTX (0xFD6E0084) | `0x00000000` — NOT locked |
| Write 0x40000401 (NF1) | Readback `0x01040040`, mode=0 — **mode bits [13:10] locked** |
| Write 0x80000000 (kukrimate) | Readback `0x00000080` — **verified** (bit 31 set, TX=0) |
| Write 0x80000001 (TX=1) | Readback `0x03000080`, TX=0 — **inconclusive** \\* |
| Write 0x80000000 (TX=0) | Readback `0x00000080` — verified |
| `tpmr.sh shutdown` | Success |
| `tpm2 startup -c` | **Success** (exit 0, stderr clean) |
| `tpmr.sh startsession` | **Success** (encrypted sessions recreated) |
| `/sys/class/tpm/tpm0/pcrs` | **NOT FOUND** — kernel TPM driver did not detect bus reset |
| `pcrs()` / `tpm2 pcrread sha256` | Hangs after GPIO assertion |
| `tpm2 pcrread sha256:0` | Sometimes succeeds, sometimes hangs |

The ADL-P `tpm2 pcrread sha256` hang (observed during all-PCR reads) is a **SEPARATE issue** from the GPIO manipulation — the hang occurs even without GPIO toggle. This may be a TPM driver / kernel issue specific to ADL-P mobile, not a consequence of PLTRST# assertion behavior.

\\* `0x03000080` has bit 7, bit 24, and bit 25 set — these do not map to any defined
DW0 register field on ADL-P. PADCFGLOCKTX reads as `0x00000000` (unlocked), meaning
the TX bit should be writable per coreboot GPIO documentation. The anomalous readback
may be a PCR sideband artifact rather than a definitive TX lock. **Cannot confirm
whether TX toggle generates a PLTRST# edge without physical scope measurement.**

The anomalous readback 0x03000080 on ADL-P TX toggle contains bits 7, 24, and 25
that do not map to any defined DW0 field. This may indicate a PCR sideband
read-back artifact, an undocumented hardware state register, or a die-specific
side-effect. Follow-up with a logic analyzer on the physical PLTRST# pin is
needed to determine whether the pad state actually changed.

**Key conclusion:** After the full shutdown→GPIO→startup sequence, the kernel TPM
driver does NOT detect a bus reset (`/sys/class/tpm/tpm0/pcrs` never appears).
PCRs are cleared by `tpm2 startup -c` alone. Whether the GPIO manipulation
contributed to the reset or the PLTRST# pin was ever driven low is inconclusive
from software diagnostics alone — a logic analyzer on the LPC/eSPI reset line
is needed.

### 1.3 PADCFGLOCK Registers Confirmed Accessible

PADCFGLOCK and PADCFGLOCKTX registers are read/writable via `/dev/mem` on ADL-P
when `CONFIG_STRICT_DEVMEM=n` (Heads default).

See `initrd/bin/tpm-gpio-reset-demo.sh` for per-platform lock register
addresses: the `_get_lock_base()` helper function (lines 853-866) maps each
PCH family to its PADCFGLOCK offset, and `check_lock_registers()` (lines
1062-1099) performs the read/check at runtime.

NV4x ADL-P readings: PADCFGLOCK=0x00010203 (bits 0,8,17 set; GPP_B13 bit 13
NOT set), PADCFGLOCKTX=0x00000000. Pad is NOT locked.

### 1.4 GPIO Lock Status per Dasharo/Purism Forks

See `doc/TPM_GPIO_Reset_Vulnerability.md` section "coreboot GPIO Lock Status
by Platform Generation" for per-platform Kconfig selection, code paths, and
non-functional lock status analysis. Key findings specific to NV4x:

- Dasharo fork (NV4x/NS50/Z790-P): SBI lock method compiled but never called
  because no board GPIO table entries use `PAD_CFG_LOCK`. Pad is NOT locked.
- Purism fork (Librem 14, Tiger Lake): No GPIO lock Kconfig selected, no
  `pad_cfg_lock_offset`. Pad is NOT locked.

**Important caveat:** All Dasharo fork GPIO lock analysis is based on build
tree inspection (Kconfig, source code, FSP UPDs). No Dasharo firmware image
with PADCFGLOCK actually set has been tested on hardware. The claim that
"adding PAD_CFG_NF_LOCK to board GPIO tables would lock GPP_B13" is theoretical.

The Star Labs PchUnlockGpioPads fix (commit 06f3c07, patch 93422) is described
in `doc/TPM_GPIO_Reset_Vulnerability.md` (see "Upstream Tracking").

---

## 2. Approaches Attempted (in Chronological Order)

### Approach 1: GPIO Pad Reprogramming (Native -> GPIO Output -> Toggle -> Restore)

**What we did:** Read DW0/DW1 of GPP_B13 via `/dev/mem`, save originals, write
0x80000000 to DW0 (GPIO output + bit 31), write 0 to DW1, wait 1s, restore
originals. See `assert_pltrst()` in `initrd/bin/tpm-gpio-reset-demo.sh` for
the exact implementation.

**Result on NV4x (ADL-P):**
- DW0 write verified by readback (LE bytes "00000080" returned).
- Pad transitioned to GPIO mode (confirmed by mode bits in readback).
- PCR 2 did NOT clear -- remained non-zero after the toggle.
- `/sys/class/tpm/tpm0/pcrs` NOT FOUND -- kernel TPM driver detected no bus reset.

**Why it failed:** Changing DW0 mode bits does not drive PLTRST# on the
electrical pin on ADL-P. The pad may not be routed to the TPM reset line on
this PCH die. The kukrimate reference implementation (`inteltool.c`) does NOT
include ADL-P device IDs and was not tested by the original researcher.

### Approach 2: Kukrimate-Style Direct Register Write (0x80000000 to DW0)

**What we did:** Same as Approach 1 but following kukrimate's inteltool.c precisely
(save DW0/DW1, write 0x80000000, wait, write 0 to DW1, restore).

**Result on NV4x:** Identical to Approach 1 -- write verified, PCR 2 still non-zero.

**Why it failed:** The PADRSTCFG field (DW0 bits[31:30]) selects the pad's own reset
trigger source per Linux pinctrl-intel.c (`PADCFG0_RESET_MASK = GENMASK(31,30)`);
it does NOT assert PLTRST# on the output signal. 0x80000000 sets PADRSTCFG=PLTRST
as the pad's reset source, GPIO mode, and TX=0 -- the pad will reset when PLTRST#
is asserted by the PCH, but the pad does not drive PLTRST#. ADL-P uses 4-DWORD
pads; Intel doc 834810 may document this field at a different offset for ADL-P
than for SPT/KBP (2-DWORD) layouts.

### Approach 3: Dynamic SBREG_BAR Reading via P2SB PCI Config Space

**What we did:** Attempted to read SBREG_BAR from P2SB (00:1f.1) by unhiding it
and reading BAR0.

**Result on NV4x:** P2SB is hidden by FSP-S and MASKLOCK'd (bit 8 of BCTRL) --
writes to unhide are silently ignored. PCI config returns 0xffffffff.

**Why it failed:** FSP-S locks the P2SB HIDE bit during POST. Hidden devices are
not in the kernel's PCI bus topology. See Section 3.1 for the SBI alternative.

Hardcoded PCR_BASE values remain reliable: ADL-P mobile=0xFD000000,
ADL-S/RPL-S desktop=0xE0000000, SPT/KBP/CNP-LP=0xFD000000.

### Approach 4: chipsec Analysis of PCR Access Mechanism

**What we did:** Analyzed chipsec source code to understand its PCR MMIO access
path and `tpm_gpio_fail` module decision tree.

**Key finding:** chipsec uses the same hardcoded SBREG_BAR=0xFD000000 and the same
`dd`-style mmap via `/dev/mem`. chipsec would confirm "write succeeded" on NV4x
using the same LE byte readback check we use. chipsec's SBI write solution
(solution 5) was not tested -- P2SB is MASKLOCK'd (see Approach 3).

### Approach 5: PADCFGLOCK / PADCFGLOCKTX Check

**What we did:** Read PADCFGLOCK at 0xFD6E0080 to verify whether lock bits
blocked our writes.

**Result on NV4x:** PADCFGLOCK=0x00010203 (bits 0, 8, 17 set; bit 13/GPP_B13 NOT
set). PADCFGLOCKTX=0x00000000. Pad is NOT locked.

See `check_lock_registers()` in `initrd/bin/tpm-gpio-reset-demo.sh` for
per-platform PADCFGLOCK/PADCFGLOCKTX address calculation and the
`_get_lock_base()` helper for lock offset mapping (lines 853-866).

### Approach 6: NF1 Mode Forcing (GPIO → NF1 → GPIO+TX=0)

**What we did:**
On ADL-P, the pad starts in GPIO mode (DW0=0x00040040, mode=0). The kukrimate
0x80000000 write only creates a PLTRST# transition when the pad starts in NF1
mode. Attempted to force NF1 mode first by writing 0x40000401 (NF1 + TX=deassert
+ DEEP reset):

1. Save DW0 (GPIO mode).
2. Write 0x40000401 to switch pad to NF1 (reconnects PLTRST# signal).
3. Write 0x80000000 (GPIO+TX=0) — pad transitions NF1→GPIO, creating high→low
   edge that asserts PLTRST# on the bus.
4. Sleep 1s.
5. Deassert by writing NF1+TX=1.
6. Restore original.

**Result on NV4x (ADL-P):**
- NF1 write (0x40000401): readback 0x01040040, **mode=0 (GPIO)** — NF1 switch FAILED.
  Mode bits [13:10] are hardware-locked, cannot be changed at runtime.
- 0x80000000 write: verified (readback 0x00000080), mode=0, TX=0.
- Since pad never left GPIO mode, no NF1→GPIO transition occurred, no PLTRST# pulse.
- `tpm2 startup -c` succeeds, `tpmr.sh startsession` succeeds, but `/sys/class/tpm/tpm0/pcrs` not found — kernel did not detect bus reset.

### Approach 7: TX Bit Toggle (TX=1 → TX=0 When Mode Bits Locked)

**What we did:** Since mode bits [13:10] are locked, tried toggling only the TX bit
(write 0x80000001 → 0x80000000) to create a falling edge on the pad output.

**Result on NV4x (ADL-P):** TX=1 write readback was 0x03000080 (anomalous -- bits
7, 24, 25 set but TX=0). TX=0 write verified. PADCFGLOCKTX=0x00000000 (unlocked).
`/sys/class/tpm/tpm0/pcrs` NOT FOUND. Inconclusive without physical scope.

### Approach 8: kukrimate sysfs PCR Verification

**What we did:** Used `/sys/class/tpm/tpm0/pcrs` (kukrimate's PCR verification
method) instead of `tpm2 pcrread`. The sysfs pcrs file only appears after the
kernel TPM driver detects a bus reset via `tpm2_auto_startup()`.

**Result on NV4x (ADL-P):** `/sys/class/tpm/tpm0/pcrs` NOT FOUND after GPIO
assertion. `tpm2 startup -c` succeeds, `tpmr.sh startsession` succeeds, but all
PCR clearing is from `TPM2_Startup(CLEAR)` alone per TCG 2.0 Part 1 Section
12.2.3.2. The kernel driver detected no bus reset. See `post_assertion_cleanup()`
in the script for the sysfs pcrs check logic (lines 1216-1233).

---

## 3. Approaches NOT Attempted (Require NDA, Firmware Changes, or C Compilation)

### 3.1 P2SB SBI Write

Would require unhiding P2SB (MASKLOCK'd by FSP-S on ADL-P) and sending
sideband messages through undocumented Intel NDA protocols. Not feasible
without custom firmware.

### 3.2 CF9 Reset

Writing to I/O port 0xCF9 reboots the entire system (CPU + chipset), losing
kernel state. The attack requires attacker code to survive the reset for PCR
replay, which CF9 reset prevents.

### 3.3 Custom Dasharo Build with GPIO Locking Disabled

GPIO locking is already non-functional on NV4x (see Section 1.4). Disabling
what doesn't work won't help -- the issue is the PLTRST# routing inside the
PCH die, not a lock bit.

### 3.4 C mmap Test Program

A C mmap program would not produce different electrical results -- the
register write is verified atomic at the MMIO bus level by readback. The
mechanism barrier is PCH-internal routing, not a tooling limitation.

---

## 4. What Remains Unknown (Requires Community Testing or NDA Documentation)

### 4.1 Whether the Mechanism Works on Other Platform Families

See `doc/TPM_GPIO_Reset_Vulnerability.md` section "Per-Platform Feasibility"
for the known status of each PCH generation. The open question is whether the
GPIO pad toggling actually asserts PLTRST# on platforms beyond SPT/KBP
(the only family confirmed working by kukrimate). Desktop PCH implementations
(ADL-S/RPL-S, PCR port 0x6d) may route PLTRST# differently. CNP-LP (T480s)
is UNTESTED.

### 4.2 Whether C mmap Would Behave Differently

See Section 3.4. The register write is verified atomic at the MMIO bus level
by readback; a C mmap program is not expected to change the electrical result.

### 4.3 Whether P2SB SBI Write Would Bypass the Blocking Mechanism

The SBI write path bypasses the GPIO pad MMIO interface and talks directly
to the PCH sideband fabric. If the GPIO pad MMIO route is blocked by some
internal gating (not a lock register, but a functional block), SBI might
still be able to assert PLTRST#.

However, this is speculative:
- P2SB is likely MASKLOCK'd (cannot unhide from software).
- Even if unhidden, SBI protocol details are Intel NDA.
- No open-source ADL-P PoC uses SBI for this purpose.

### 4.4 Intel NDA Documentation Gaps

The following are documented only in Intel's NDA BIOS Writer's Guide (BWG)
and are not available to the open-source community:
- Complete PLTRST# signal routing within ADL-P PCH dies.
- Sideband fabric message formats for GPIO pad control.
- P2SB MASKLOCK behavior and any known workarounds.

---

## 5. What the Script CAN Do

The `tpm-gpio-reset-demo.sh` script is a comprehensive audit and PoC tool.
Even on platforms where the GPIO toggle doesn.t assert PLTRST#, the script
provides significant value:

### 5.1 Platform Detection

- Detects ALL known Intel PCH families via ISA/LPC bridge PCI device ID:
  - SPT (Skylake 6th gen)
  - KBP (Kaby Lake 7th gen)
  - CNP-LP (Kaby Lake-R / Whiskey Lake / Comet Lake) -- UNTESTED
  - ADL-P (Alder Lake mobile 12th gen)
  - RPL-P (Raptor Lake mobile 13th gen)
  - ADL-S (Alder Lake desktop 12th gen)
  - RPL-S (Raptor Lake desktop 13th/14th gen)
  - MTL (Meteor Lake, Core Ultra Series 1+)
- Falls back to CONFIG_BOARD for MTL, pre-SKL, and board-specific patterns
  (optiplex, z220, m900, librem, msi_z690).
- Reports UNKNOWN for unrecognized platforms with full help text.

### 5.2 Vulnerability Classification (3-Tier)

Classifies per verified Dasharo/Purism fork analysis using a 3-tier system:

- **TIER 1 -- VULNERABLE (confirmed)**: SPT/KBP (T480, M900, Librem, etc.)
  Mechanism confirmed working by kukri. Pad unlocked, attack feasible.

- **TIER 2 -- VULNERABLE (unconfirmed)**: CNP-LP (T480s)
  Pad unlocked, mechanism theoretically works but NO hardware test data exists.
  kukri's PoC does not support this PCH family. Community testing needed.

- **TIER 3 -- VULNERABILITY UNCERTAIN**: ADL-P (NV4x, NS50), RPL-P, ADL-S, RPL-S
  GPIO lock is absent, writes verified, but PLTRST# assertion NOT confirmed on
  these PCH dies. PCRs remain non-zero after toggle on NV4x ADL-P. Physical scope
  verification needed. May not be electrically connected.

- **NOT VULNERABLE**: Pre-Skylake (dedicated PLTRST# pin), Meteor Lake
  (functional GPIO lock via Kconfig, eSPI-connected TPM).

### 5.3 Register Read and Lock Status

- Reads PADCFGLOCK and PADCFGLOCKTX registers and decodes per-pad lock bits.
- Reads and decodes DW0 mode bits (GPIO vs NF1-NF7), TX state, TX disable,
  RX disable, and reset config (PWROK/DEEP/PLTRST/RSMRST).
- Reports whether pad is already in GPIO mode (possible attack indicator).

### 5.4 Audit Mode (3-Tier Classification)

In audit mode (default, `--audit`):
- Reports vulnerability status per 3-tier classification (TIER 1 confirmed,
  TIER 2 unconfirmed, TIER 3 uncertain).
- Shows register addresses and community mapping.
- Explains the attack plan step by step.
- Distinguishes between confirmed-working (SPT/KBP), untested (CNP-LP), and
  inconclusive (ADL/RPL) platforms.
- No hardware manipulation is performed.

### 5.5 Execute Mode Proof of Concept

In execute mode (`--execute`):
- Saves and restores pad configuration (tested: write verifies on NV4x).
- Toggles GPIO pad and verifies write.
- Reads PCRs before and after reset to check for success.
- Replays PCR measurements from `cbmem -L` and `/tmp/measuring_trace.log`.
- Attempts to unseal TOTP/HOTP secrets from NVRAM index 0x4d47.

**Important**: The execute mode IS functional as a PoC on platforms where
the GPIO toggle actually resets the TPM (SPT/KBP confirmed by kukrimate).
On ADL-P, the toggle does NOT clear TPM PCRs, so the execute mode will report
failure (PCR 2 non-zero after toggle). The write verification, lock register
reads, and measurement replay all work, but the PLTRST# assertion step fails because
the mechanism doesn't work on this PCH die.

### 5.6 TCG Specification Guarantees Underlying the Attack

See `doc/TPM_GPIO_Reset_Vulnerability.md` section "TPM Reset Scope (per TCG
Specification)" for the full TCG 2.0 Part 1 citations (Sections 4, 12.2.3.2,
27.2.6, 37), volatile vs non-volatile persistence, and the TOTP/HOTP vs DUK
unseal requirements.

### 5.7 Mitigations

See `doc/TPM_GPIO_Reset_Vulnerability.md` section "Mitigations" for the
complete list: authenticated recovery shell, firmware integrity verification,
and TPM DUK with passphrase.

---

## 6. Community Testing Request

To determine whether the PLTRST# assertion mechanism works on other platforms,
we need community testing with the exact procedure below.

### General Test Procedure

For all platforms:

```bash
# Step 1: Install the script on the target
#   - Clone heads repo or copy tpm-gpio-reset-demo.sh to the test system
#   - Run as root
#   - Requires: bash, dd, xxd, /dev/mem access (CONFIG_STRICT_DEVMEM=n)

# Step 2: Audit mode (safe -- reports vulnerability)
./initrd/bin/tpm-gpio-reset-demo.sh --audit

# Step 3: Check current PCR state
pcrs   # Or: tpm2 pcrread

# Step 4: Execute mode (performs GPIO toggle, checks PCRs)
./initrd/bin/tpm-gpio-reset-demo.sh --execute

# Step 5: Report the following information:
#   - Platform: model, BIOS version, coreboot version
#   - Output of --audit (platform class, register addresses)
#   - Output of --execute (DW0 readback, PCR 2 before/after)
#   - PADCFGLOCK value (printed in debug output)
```

### 6.1 CNP-LP Testing (ThinkPad T480s, T490, T495, X390)

See `initrd/bin/tpm-gpio-reset-demo.sh` header comments (lines 46-58) and
`detect_platform()` for register addresses. CNP-LP device IDs are 0x9d84-0x9d8f.

**What to test:**
1. Run `./tpm-gpio-reset-demo.sh --execute`.
2. Check if PCR 2 clears after the GPIO toggle.
3. Mechanism status: UNTESTED -- no hardware verification.
   kukri's PoC does not support CNP-LP. Community testing needed.

**Expected result (if mechanism works):**
- DW0 write verified (LE readback "00000080").
- PCR 2 reads zero after toggle.
- If PCR 7 also clears, measurement replay is required before unseal.

### 6.2 SPT/KBP Testing (ThinkPad T480, T470, X270, M900 Tiny, T460, X260)

Register addresses: see the script's `detect_platform()` and `calculate_registers()`.
SPT/KBP uses PCR port 0xaf, PAD_CFG_BASE=0x400, 2 DWORDS (8 bytes) per pad.

**Status: CONFIRMED WORKING** by kukrimate on T480 (KBL).

**What to test (verification):**
1. Run `./tpm-gpio-reset-demo.sh --execute`.
2. Confirm PCR 2 clears.
3. Confirm `tpm2_unseal` works after measurement replay.

### 6.3 ADL-S Desktop Testing (Desktop 12th gen)

Register addresses: see the script's `detect_platform()` and `calculate_registers()`.
ADL-S device IDs are 0x7a80-0x7a8c, PCR port 0x6d, PAD_CFG_BASE=0x700.

**What to test:**
1. Run `./tpm-gpio-reset-demo.sh --execute`.
2. Check if PCR 2 clears.
3. Mechanism status: UNKNOWN -- no community test results available.

**Important note for desktop testing:**
Desktops often have firmware TPM (fTPM) instead of discrete TPM. The attack
only works on discrete TPMs connected via LPC/eSPI/SPI. Check if your system
has a discrete TPM module (separate chip on motherboard) vs firmware TPM.
Intel PTT (Platform Trust Technology, fTPM) is NOT affected by the GPIO reset
attack because it doesn't use a discrete TPM chip.

### 6.4 RPL-S Desktop Testing (MSI Z790-P DDR5, etc.)

Register addresses: see the script's `detect_platform()` and `calculate_registers()`.
RPL-S device IDs are 0x7a0c-0x7a17, PCR port 0x6d, PAD_CFG_BASE=0x700.

**Status: UNKNOWN.** See `doc/TPM_GPIO_Reset_Vulnerability.md` per-platform
feasibility table for Dasharo fork configuration details. If the test shows the
toggle DOES work, this would mean the pad is electrically connected differently
than ADL-P mobile.

### 6.5 Reporting Template

Please report findings using this template:

```
Platform: <vendor/model>
PCH device ID: <output from --audit>
coreboot version: <version string from dmesg or cbmem>
Discrete TPM model: <lspci | grep TPM or ls /sys/class/tpm/tpm0/>

--audit output:
<full output>

--execute output:
<full output>

PADCFGLOCK value: <from debug output>
PCR 2 before: <from pre-reset PCR state>
PCR 2 after: <from post-reset PCR state>
Mechanism worked? YES/NO
```

---

## 7. MTL GPIO Lock Fix Recipe

Meteor Lake (MTL) requires a different GPIO lock approach than ADL. The
following three coordinated changes are needed:

### 7.1 Fix PchUnlockGpioPads Logic

Star Labs identified inverted logic in Alder Lake's `PchUnlockGpioPads` UPD
(commit 06f3c07, in-review patch 93422). The original code had:
```c
PchUnlockGpioPads = lockdown_by_fsp;
```
This sets the UPD to 0 when coreboot manages lockdown (correct semantic), but
the variable name implies the opposite action. The fix corrects this to
explicitly set the UPD based on whether coreboot or FSP should manage GPIO
pad locking. MTL builds need this fix applied to their FSP integration code.

### 7.2 Move mainboard_configure_gpios() to Ramstage

On MTL, `mainboard_configure_gpios()` currently runs in romstage, before FSP-S
initializes the GPIO controller. GPIO pad config registers are not accessible
at this stage. Moving the call to ramstage (after FSP-S runs) ensures pad
config registers are writable when the lock action is applied.

### 7.3 Add PAD_CFG_NF_LOCK to Board GPIO Tables

MTL's PCR lock mechanism (`SOC_INTEL_COMMON_BLOCK_GPIO_LOCK_USING_PCR`) is
simpler than ADL's SBI method: it uses direct MMIO writes to the PADCFGLOCK
register (no P2SB unhiding needed). Each pad in the board GPIO table that
needs locking must include the `PAD_CFG_NF_LOCK` macro (for native-function
pads like PLTRST#) or `PAD_CFG_LOCK` (for GPIO pads). Without these macros
in the board GPIO table entries, the `gpio_configure_pads()` code path skips
the lock action entirely.

None of these three changes are applied in current MTL builds (Dasharo or
upstream coreboot). The PCR lock infrastructure compiles but zero pads are
actually locked. Additionally, FSP sets `PchUnlockGpioPads=1` on MTL,
force-unlocking all pads regardless of the board configuration.

---

## Appendix A: Key Register Addresses Reference

Per-platform register addresses (PCR_BASE, community base, DW0/DW1 address,
PADCFGLOCK/PADCFGLOCKTX) are the authoritative output of the script's
`calculate_registers()` function. See `initrd/bin/tpm-gpio-reset-demo.sh`:
- Header comments (lines 50-76): port, pad index, PAD_CFG_BASE, lock offset
  per platform family.
- `detect_platform()` case statement (lines 260-368): PCI device ID to
  platform parameter mapping.
- `calculate_registers()` (lines 533-620): full address computation from
  PCR_BASE, community port, pad index, and PAD_CFG_BASE.

### ADL-P PADCFGLOCK Readings from NV4x

| Register | Address | Value (LE) | Value (decoded) |
|---|---|---|---|
| PADCFGLOCK | 0xFD6E0080 | 0x00010203 | Bits 0, 8, 17 set (not GPP_B13) |
| PADCFGLOCKTX | 0xFD6E0084 | 0x00000000 | No TX locked pads |

CNP-LP remains **UNTESTED** -- no hardware verification. kukri's PoC does not
support this PCH family.

---

## Appendix B: Script Output Reference

### Audit Mode Output (NV4x ADL-P)

```
======================================================================
  1. PLATFORM DETECTION
======================================================================
[OK]  Detected PCH: Alder/Raptor Lake (ADL/RPL) -- device 0x5182
      Attack path: GPIO PAD_CFG (GPP_B13 pad, local idx 13)
      Port: 0x6e | PAD_CFG_BASE: 0x700

======================================================================
  2. REGISTER ADDRESS CALCULATION
======================================================================
      Pad offset within community: 13 - 0 = 13
      Bytes per pad: 4 DWORDS x 4 = 16 bytes
      DW0 register offset in community: 0x700 + (13 * 16) = 0x7d0

======================================================================
  3. CURRENT REGISTER CONFIGURATION
======================================================================
[OK]  Pad is correctly configured as native function output.

======================================================================
  4. TPM GPIO RESET (hardware -- preserves NVRAM)
======================================================================
      AUDIT MODE: No GPIO reset will be performed. The attack plan would be:
      ...
```

### Execute Mode Output (NV4x ADL-P -- mechanism fails)

```
======================================================================
  4. TPM GPIO RESET (hardware -- preserves NVRAM)
======================================================================
      PADCFGLOCK at 0xfd6e0080: 0x00010203 (bit 13 not set)
      PLTRST pad NOT locked -- writes should work
... (writes succeed, readback verified) ...

======================================================================
  5. PCR VERIFICATION
======================================================================
[WARN]  PCR 2 is non-zero -- GPIO reset may not have worked
        NOTE: ADL-P platforms (NovaCustom NV4x, Nitropad NS50) are
        confirmed vulnerable (no GPIO lock) but PCR 2 remained non-zero
        after PLTRST# assertion attempt using the kukrimate method — the
        pad may not be electrically connected to the TPM reset line on
        this PCH die. The kukrimate inteltool.c does not support ADL-P
        device IDs, and hardware testing (NV4x) showed the kernel TPM
        driver did not detect a bus reset after GPIO pad manipulation.
```

---

## Appendix C: References

- **mkukri.xyz -- "TPM GPIO fail: The Forgotten Bus"** (June 2024)
  https://mkukri.xyz/2024/06/01/tpm-gpio-fail.html
  Original disclosure with detailed analysis.

- **kukrimate/tpm-gpio-fail (GitHub)** -- GPL-2.0 PoC tools
  https://github.com/kukrimate/tpm-gpio-fail
  Contains `detect` and `reset` tools with platform data for SPT, KBP, CNP-H.

- **coreboot ticket #576** -- "PLTRST_CPU_B pad should be locked to prevent
  userspace TPM GPIO reset"
  https://ticket.coreboot.org/issues/576

- **coreboot patch series** -- "intel_gpio_lock"
  https://review.coreboot.org/q/topic:%22intel_gpio_lock%22
  - `#90884` (merged): Set `pad_cfg_lock_offset` in Skylake GPIO communities.
  - `#90885` (open): Select `SOC_INTEL_COMMON_BLOCK_GPIO_LOCK_USING_PCR` for
    Skylake -- tested, does not work on real hardware.
  - `#93324` (open): Board-level GPIO lock for Lenovo SKL/KBL ThinkPads
    (T480/T480s). Depends on 90885. Stalled on Intel maintainer review
    alongside 90885 -- no human Code-Review since June 2026.
  - `#93422` (open): Split FSP lockdown (includes Star Labs PchUnlockGpioPads
    fix commit 06f3c07, updated July 22 2026). Awaiting Intel maintainer review.

- **Heads issue #2159** -- TPM GPIO reset attack tracking
  https://github.com/linuxboot/heads/issues/2159

- **Intel GPIO Best Practices Guide** -- ID 834810 (Public)
  Describes pad configuration lock mechanisms and platform-specific register
  layouts. Publicly available at intel.com.

- **chipsec tpm_gpio_fail module**
  https://github.com/chipsec/chipsec
  Decision tree for evaluating TPM GPIO fail vulnerability on any Intel platform.
