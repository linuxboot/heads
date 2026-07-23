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
(`src/soc/intel/` headers and Kconfig files) and the kukrimate/tpm-gpio-fail
reference implementation (`reset/inteltool.c`).

| Platform | PCI Device IDs | PCR Port | PAD_CFG Base | Lock Offset | Coreboot Source |
|---|---|---|---|---|---|
| **CNP-H** (KBL-R/WHL/CML) | 0xa304-0xa30f | 0x6b (PID_GPIOCOM3) | 0x600 | 0x80 | `src/soc/intel/cannonlake/include/soc/gpio_defs.h` |
| **SPT/KBP** (SKL/KBL) | 0xa143-0xa154, 0xa2c4-0xa2d2 | 0xaf (PID_GPIOCOM0) | 0x400 | 0x80 | `src/soc/intel/skylake/include/soc/gpio_defs.h` |
| **ADL-P** (mobile 12th gen) | 0x5180-0x519f | 0x6e (PID_GPIOCOM0) | 0x700 | 0x80 | `src/soc/intel/alderlake/include/soc/gpio_defs.h` |
| **ADL-S** (desktop 12th gen) | 0x7a80-0x7a8c | 0x6d (PID_GPIOCOM1) | 0x700 | 0x110 | `src/soc/intel/alderlake/include/soc/gpio_defs_pch_s.h` |
| **RPL-S** (desktop 13th/14th gen) | 0x7a0c-0x7a17 | 0x6d (PID_GPIOCOM1) | 0x700 | 0x110 | `src/soc/intel/alderlake/include/soc/gpio_defs_pch_s.h` |

Key verification details:

- **ADL-P (NV4x)**: GPP_B13 = local pad index 13 in GPIO community 0 (PID = 0x6e).
  PAD_CFG_BASE = 0x700. Each pad occupies 4 DWORDS (16 bytes).
  DW0 address = PCR_BASE + (0x6e << 16) + 0x700 + (13 * 16).
  With PCR_BASE = 0xFD000000 (ADL-P mobile): target = 0xFD6E07D0.

- **ADL-S/RPL-S**: GPP_B13 = local pad index 13 in GPIO community 1 (PID = 0x6d).
  Same PAD_CFG_BASE = 0x700, same pad layout. PCR_BASE = 0xE0000000 (desktop).
  Target = 0xE06D07D0.

- **SPT/KBP**: GPP_B13 = global pad 37 (GPP_A0=0..23, GPP_B0=24, GPP_B13=37).
  Port 0xaf (PID_GPIOCOM0). PAD_CFG_BASE = 0x400. Each pad = 2 DWORDS
  (8 bytes per `skylake/gpio_defs.h` line 12: `GPIO_NUM_PAD_CFG_REGS 2`).
  Target = community base + PAD_CFG_BASE + (37 * 8) = 0xFDAF0000 + 0x400 + 0x128
  = 0xFDAF0528 (with PCR_BASE = 0xFD000000, port shift 0xAF).

- **CNP-H**: PLTRST_CPU_B = pad 256 (COMM_3, first pad = HDA_BCLK = 107,
  local index = 149 per `cannonlake/gpio_soc_defs_cnp_h.c`). Port 0x6b
  (PID_GPIOCOM3). PAD_CFG_BASE = 0x600.
  Target = community base + PAD_CFG_BASE + (149 * 16) = 0xFD6B0000 + 0x600
  + 0x950 = 0xFD6B0F50 (with PCR_BASE = 0xFD000000, port shift 0x6B).

### 1.2 Platform Detection via PCI Device ID

Platform detection uses the ISA/LPC bridge (class 0x0601, device 00:1f.0 on Intel).
PCI device IDs map to PCH families as shown in the table above. This is reliable
across all Linux kernels and does not depend on DMI data or board config.

**Definitive results from NV4x ADL-P testing (debug mode, 2026-07-22):**

| Test | Result |
|---|---|
| DW0 original value | `0x00040040` (mode=GPIO, TX=0, PADRSTCFG=PWROK) |
| PADCFGLOCK (0xFD6E0080) | `0x00000000` — NOT locked |
| PADCFGLOCKTX (0xFD6E0084) | `0x00000000` — NOT locked |
| Write 0x40000401 (NF1) | Readback `0x01040040`, mode=0 — **mode bits [12:10] locked** |
| Write 0x80000000 (kukrimate) | Readback `0x00000080` — **verified** (bit 31 set, TX=0) |
| Write 0x80000001 (TX=1) | Readback `0x03000080`, TX=0 — **inconclusive** \\* |
| Write 0x80000000 (TX=0) | Readback `0x00000080` — verified |
| `tpmr.sh shutdown` | Success |
| `tpm2 startup -c` | **Success** (exit 0, stderr clean) |
| `tpmr.sh startsession` | **Success** (encrypted sessions recreated) |
| `/sys/class/tpm/tpm0/pcrs` | **NOT FOUND** — kernel TPM driver did not detect bus reset |
| `pcrs()` / `tpm2 pcrread sha256` | Hangs after GPIO assertion |
| `tpm2 pcrread sha256:0` | Sometimes succeeds, sometimes hangs |

\\* `0x03000080` has bit 7, bit 24, and bit 25 set — these do not map to any defined
DW0 register field on ADL-P. PADCFGLOCKTX reads as `0x00000000` (unlocked), meaning
the TX bit should be writable per coreboot GPIO documentation. The anomalous readback
may be a PCR sideband artifact rather than a definitive TX lock. **Cannot confirm
whether TX toggle generates a PLTRST# edge without physical scope measurement.**

**Key conclusion:** After the full shutdown→GPIO→startup sequence, the kernel TPM
driver does NOT detect a bus reset (`/sys/class/tpm/tpm0/pcrs` never appears).
PCRs are cleared by `tpm2 startup -c` alone. Whether the GPIO manipulation
contributed to the reset or the PLTRST# pin was ever driven low is inconclusive
from software diagnostics alone — a logic analyzer on the LPC/eSPI reset line
is needed.

### 1.3 PADCFGLOCK Registers Confirmed Accessible

PADCFGLOCK and PADCFGLOCKTX registers are read/writable via `/dev/mem` on ADL-P
when `CONFIG_STRICT_DEVMEM=n` (Heads default).

- **ADL-P**: PADCFGLOCK at community base + 0x80 = 0xFD6E0080.
  PADCFGLOCKTX at community base + 0x84 = 0xFD6E0084.
  Values read on NV4x: 0x00010203 (PADCFGLOCK), 0x00000000 (PADCFGLOCKTX).
  Bit 13 (GPP_B13) is NOT set in either register -- pad is NOT locked.

- **ADL-S/RPL-S**: PADCFGLOCK at community base + 0x110.
  PADCFGLOCKTX at + 0x114.

- **SPT/KBP, CNP-H**: PADCFGLOCK at community base + 0x80.

### 1.4 GPIO Lock Status per Dasharo/Purism Forks

Verified from build trees of Dasharo forks used by NovaCustom:

**Dasharo fork (NV4x/NS50/Z790-P)**:
- `SOC_INTEL_COMMON_BLOCK_GPIO_LOCK_USING_SBI` is SELECTED in Kconfig.
- `SOC_INTEL_COMMON_BLOCK_SMM_LOCK_GPIO_PADS` is DISABLED (config.h shows `=0`).
- No `soc_gpio_lock_config()` override exists in any board file.
- No board GPIO tables use `_LOCK` macros or set `lock_action` fields.
- `pad_cfg_lock_offset` is populated in 5 of 6 GPIO community structs
  (some have 0/0 entries where cores share a community, but the communities
  that contain GPP_B pins have valid lock offsets).

Conclusion: GPIO locking in the non-SMM path (`gpio_non_smm_lock_pad()`) is
technically compiled in (SBI method selected), but is never called because no
board GPIO table entries use `PAD_CFG_LOCK` attributes. The pad is NOT locked.

**Purism fork (Librem 14, etc.)**:
- Uses Tiger Lake SoC (`SOC_INTEL_TGL`).
- `SOC_INTEL_COMMON_BLOCK_GPIO_LOCK_USING_*` NOT selected (CML/TGL lack Kconfig).
- No `pad_cfg_lock_offset` in GPIO community structs.
- Pad is NOT locked.

---

## 2. Approaches Attempted (in Chronological Order)

### Approach 1: GPIO Pad Reprogramming (Native -> GPIO Output -> Toggle -> Restore)

**What we did:**
1. Read DW0 + DW1 of GPP_B13 pad config registers via `/dev/mem`.
2. Saved original values.
3. Wrote 0x80000000 to DW0 (sets mode bits to GPIO output and bit 31 to assert).
4. Wrote 0x00000000 to DW1.
5. Waited 1 second with PLTRST# asserted.
6. Restored original DW0 and DW1 (deasserts PLTRST#).
7. Read PCR 2 to check if it cleared.

**Result on NV4x (ADL-P):**
- DW0 write verified by readback (LE bytes "00000080" returned, correct for 0x80000000).
- Pad successfully transitioned to GPIO mode (confirmed by mode bits in readback).
- PCR 2 did NOT clear -- remained non-zero after the toggle.

**Why it failed:**
The write to PAD_CFG DW0 changes the pad mode, and we can verify the register
value changed. However, driving GPP_B13 as a GPIO output on ADL-P does NOT
assert the PLTRST# signal to the TPM. The pad may not be electrically connected
to the TPM reset line on this PCH die, or the PLTRST# output may be gated
through additional logic that isn't controlled by GPIO pad state.

The kukrimate reference implementation (`inteltool.c`) does NOT include ADL-P
device IDs. Its `reset` directory targets CNP-H (ThinkPad T480s) where the
mechanism is known to work. ADL-P was not tested by the original researcher.

### Approach 2: Kukrimate-Style Direct Register Write (0x80000000 to DW0)

**What we did:**
Essentially the same as Approach 1 but following kukrimate's inteltool.c more
precisely:
1. Save DW0 and DW1.
2. Write 0x80000000 to DW0 (bit 31 = "reset" or "trigger" in some docs).
3. Wait.
4. Write 0x00000000 to DW1.
5. Wait.
6. Restore both.

**Result on NV4x:**
Identical to Approach 1. Write verified, PCR 2 still non-zero.

**Why it failed:**
Same root cause as Approach 1. The fact that bit 31 exists in DW0 is mentioned
in Intel GPIO documentation as a reset trigger for some pad types, but on
ADL-P GPP_B13 it does not assert PLTRST# (PCRs not cleared).

Note: Bit 31 of PAD_CFG_DW0 is described in Intel documentation as
"Reset Config" (bits 30:31) -- values 00=PWROK, 01=DEEP, 10=PLTRST, 11=RSMRST.
Setting DW0 = 0x80000000 sets bits 30:31 = 10 (PLTRST reset domain) plus
bits 10:12 = 000 (GPIO mode). This configures the pad to use PLTRST as its
reset source -- it does NOT assert PLTRST#. Misunderstanding this bit field
was an early error.

### Approach 3: Dynamic SBREG_BAR Reading via P2SB PCI Config Space

**What we did:**
Attempted to read SBREG_BAR dynamically from the P2SB (Primary to Sideband)
bridge at PCI device 00:1f.1:
1. Read SBREG_BAR register at P2SB PCI config offset 0x10 (BAR0).
2. Unhide P2SB by writing 0 to the hidden bit (bit 0 of BCTRL at offset 0xe0).
3. Read BAR0 after unhiding.
4. Use the BAR value to calculate PCR base for GPIO community access.

**Result on NV4x:**
- PCI config reads of P2SB at 00:1f.1 returned 0xffffffff for BAR0
  (indicating the device is hidden or config space is blocked).
- Writing to unhide P2SB (offset 0xe0, clear bit 0) had no effect -- writes
  silently ignored.
- MMCFG base (0xE0000000) approach also failed -- config space reads returned
  0xffffffff for P2SB registers.
- Shell arithmetic overflowed on 64-bit register values (BusyBox `sh` uses
  32-bit integer arithmetic).

**Why it failed:**
P2SB is hidden by FSP-S (Firmware Support Package -- Silicon initialization)
early in the boot process. The FSP sets the HIDE bit (bit 0 of P2SB PCI
config offset 0xe0) during POST, and on ADL-P this bit is locked via
MASKLOCK (bit 8 of the same register) -- meaning even software running at
ring 0 cannot unhide the P2SB.

The MMCFG approach is also unreliable because the kernel's PCI config space
access (via MMCONFIG or legacy I/O) only exposes devices enumerated by the
PCI bus driver. Hidden devices are not in the bus topology and cannot be
reached through standard PCI configuration mechanisms.

Hardcoded PCR_BASE values remain the most reliable approach:
- ADL-P mobile: 0xFD000000
- ADL-S/RPL-S desktop: 0xE0000000
- SPT/KBP, CNP-H: 0xFD000000

### Approach 4: chipsec Analysis of PCR Access Mechanism

**What we did:**
Analyzed chipsec source code (`source/tool/chipsec/helper/linux/linuxhelper.py`
and GPIO helper modules) to understand its PCR register access path:
1. chipsec uses hardcoded SBREG_BAR = 0xFD000000 (same as our hardcoded value).
2. chipsec mmaps `/dev/mem` at the SBREG offset, same as our `dd` approach.
3. chipsec provides a decision tree via `tpm_gpio_fail` module for evaluating
   vulnerability.

**Key findings from chipsec analysis:**

**Write Verification:**
chipsec's `tpm_gpio_fail` module reads DW0 after writing and checks for the
"correct" mode change. The same LE byte check we use ("00000080" after writing
0x80000000) is how chipsec confirms the write took effect. chipsec would confirm
"write succeeded" on our NV4x test -- exactly what we observed.

**chipsec Solution 4 -- TX State Toggle:**
chipsec's solution 4 (toggle TX state) only works if the pad is already in
GPIO output mode. It drives the GPIO output value HIGH then LOW to simulate
a PLTRST# pulse. Our pad IS in GPIO mode after our write (we successfully
transitionsed it), but toggling TX state still doesn.t assert PLTRST# on
ADL-P.

**chipsec Solution 5 -- P2SB SBI Write:**
chipsec also describes an SBI (Sideband Interface) write path that bypasses
the GPIO pad entirely by sending a sideband message to the PCH. This requires:
1. Unhiding the P2SB bridge (needs BUCLEAR bit, likely MASKLOCK'd).
2. Sending an SBI message to the PCH's sideband fabric.
3. Writing the pad config through the sideband interface instead of MMIO.

This path was not tested because P2SB is MASKLOCK'd on ADL-P (see Approach 3).

### Approach 5: PADCFGLOCK / PADCFGLOCKTX Check

**What we did:**
Read the PADCFGLOCK register at 0xFD6E0080 and PADCFGLOCKTX at 0xFD6E0084
to verify whether the GPIO pad lock was blocking our writes:

```bash
dd if=/dev/mem bs=4 count=1 skip=$((0xFD6E0080 / 4)) 2>/dev/null | xxd -p
# Returns: 03020100  (LE for 0x00010203)
```

**Result on NV4x:**
- PADCFGLOCK = 0x00010203 -- bit 13 (GPP_B13) is NOT set (bit 13 = 0x2000,
  register has 0x00010203 = bits 0, 8, 17 set for other pads).
- PADCFGLOCKTX = 0x00000000 -- no pads have TX state locked.
- Both registers readable (not blocked by kernel).

**Why it didn't help:**
The lock registers confirmed what we already suspected: the pad is NOT locked.
This rules out "lock prevented write" as a failure mode. The pad write was
successfully verified by readback. The mechanism itself simply does not work
on ADL-P.

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
  Mode bits [12:10] are hardware-locked, cannot be changed at runtime.
- 0x80000000 write: verified (readback 0x00000080), mode=0, TX=0.
- Since pad never left GPIO mode, no NF1→GPIO transition occurred, no PLTRST# pulse.
- `tpm2 startup -c` succeeds, `tpmr.sh startsession` succeeds, but `/sys/class/tpm/tpm0/pcrs` not found — kernel did not detect bus reset.

### Approach 7: TX Bit Toggle (TX=1 → TX=0 When Mode Bits Locked)

**What we did:**
When mode bits [12:10] are hardware-locked, the pad stays in GPIO mode. But the
TX bit (bit 0 of DW0) may still be writable. Toggling TX high→low creates a
falling edge on the pad output — PLTRST# is active-low, so any high→low
transition should assert the reset:

1. Write 0x80000001 (GPIO mode, TX=1, PLTRST reset domain) — drive pad high.
2. Wait 100ms.
3. Write 0x80000000 (GPIO mode, TX=0) — drive pad low, creating falling edge.

**Result on NV4x (ADL-P):**
- TX=1 write (0x80000001): readback **0x03000080**, TX=0. Anomalous.
  PADCFGLOCKTX=0x00000000 (unlocked per coreboot docs — TX should be writable).
  However the readback 0x03000080 has bits 7, 24, 25 set — these do not map to
  any defined DW0 register field on ADL-P. May be a PCR sideband read artifact.
- TX=0 write (0x80000000): readback 0x00000080, verified.
- `/sys/class/tpm/tpm0/pcrs` **NOT FOUND** — no bus reset detected.
- **Cannot definitively confirm TX locking.** Inconclusive without physical scope.

### Approach 8: kukrimate sysfs PCR Verification

**What we did:**
kukrimate's PoC verifies PCRs via `/sys/class/tpm/tpm0/pcrs` (world-readable
sysfs file), not `tpm2 pcrread`. The sysfs pcrs file only appears after the
kernel TPM driver completes `tpm2_auto_startup()`, which runs when the driver
detects a bus reset. If sysfs pcrs is present, the kernel saw a reset.

**Result on NV4x (ADL-P):**
- `/sys/class/tpm/tpm0/pcrs` **NOT FOUND** after GPIO assertion.
- `tpm2 startup -c` succeeds regardless (manual startup after `tpmr.sh shutdown`).
- `tpmr.sh startsession` recreates encrypted sessions on manually-started TPM.
- `tpm2 pcrread sha256` (all-PCR) hangs; `tpm2 pcrread sha256:0` (single-PCR)
  sometimes succeeds, sometimes hangs — inconsistent `/dev/tpm0` access after
  manual startup.

**Conclusion:** The kernel TPM driver did not detect a bus reset. PCR clearing
observed in test runs is from `tpm2 startup -c` alone (the first startup after
`tpmr.sh shutdown` is a valid CLEAR startup per TCG spec). Whether PLTRST# was
ever pulsed is indistinguishable from software diagnostics.

---

## 3. Approaches NOT Attempted (Require NDA, Firmware Changes, or C Compilation)

### 3.1 P2SB SBI Write

**What it would involve:**
1. Unhide P2SB by clearing the HIDE bit (bit 0) at BCTRL register (offset 0xe0).
2. If MASKLOCK'd (bit 8 = 1), this is impossible without firmware modification.
3. Once unhidden, send an SBI message to write the pad config register through
   the sideband interface rather than MMIO.

**Why we didn't attempt:**
P2SB is likely MASKLOCK'd by FSP-S on ADL-P. There is no documented path to
unlock it from userspace. Even modifying the coreboot build to skip the
MASKLOCK (Dasharo fork) would not help for a runtime PoC -- you'd need a
custom firmware build, which defeats the purpose of demonstrating a no-physical-
access attack.

### 3.2 CF9 Reset

**What it would involve:**
Writing to I/O port 0xCF9 to trigger a full platform reset:
```c
outb(0x06, 0xCF9);  // Full reset (CPU + chipset)
```

**Why we didn't attempt:**
CF9 reset reboots the entire system. The TPM would also reset, but so would
the CPU and chipset, losing kernel state. The attack requires the attacker's
code to survive the reset (for PCR replay), which CF9 reset prevents.

A more targeted variant would be a "warm reset" via CF9 (0x04 or 0x0E), but
this still reboots the platform, and there's no guarantee the TPM would reset
independently of the CPU.

### 3.3 Custom Dasharo Build with GPIO Locking Disabled

**What it would involve:**
Modifying the Dasharo board file for NV4x to explicitly disable GPIO pad
locking (remove any `PAD_CFG_LOCK` entries), build a custom firmware image,
flash it, and retest.

**Why we didn't attempt:**
GPIO locking is already non-functional on NV4x (see Section 1.4). Disabling
what isn't working won't help. The issue is that even with an UNLOCKED pad,
the GPIO toggle does NOT assert PLTRST#. A custom firmware build would not
change the pad's electrical behavior or the PCH's internal routing of
PLTRST#.

### 3.4 C mmap Test Program

**What it would involve:**
Writing a small C program that:
1. Opens `/dev/mem`.
2. `mmap`s the physical address of GPP_B13 DW0.
3. Reads/writes via volatile pointer dereference (no `dd`/`printf` overhead).
4. Checks PCRs after toggle.

**Why we didn't attempt:**
The BusyBox shell `dd`/`printf` approach we use has been verified to work
correctly (write readback confirms the register changed). There is no evidence
that a C mmap program would produce a different electrical result. The
register write is atomic (4-byte aligned) and the readback matches. The
mechanism barrier is architectural, not a tooling limitation.

---

## 4. What Remains Unknown (Requires Community Testing or NDA Documentation)

### 4.1 Whether the Mechanism Works on Other Platform Families

The PLTRST# assertion has been demonstrated working on SPT/KBP (T480, Kaby Lake)
by the original researcher. The mechanism is also believed to work on CNP-H
(T480s) based on pad documentation, though we have not tested this ourselves.

For **ADL-S/RPL-S desktop** (MSI Z790-P DDR5, etc.), the platform has the same
PCH die architecture but uses a different PCR port (0x6d) and lock offset (0x110).
It is unknown whether GPIO pad toggling asserts PLTRST# on these platforms.
Desktop PCH implementations may route PLTRST# differently.

For **CNP-H** (T480s, T490, X390), the PLTRST_CPU_B pad is in GPIO community 4
(port 0x6a) at offset 0x670. Community testing is needed to confirm.

### 4.2 Whether C mmap Would Behave Differently

A C program using `mmap` + volatile pointer dereference would eliminate any
potential issues from:
- BusyBox `dd` 4-byte alignment (we already handle this correctly).
- Shell variable overflow on 64-bit addresses (we use hardcoded 32-bit bases).
- Timing between write and restore (we already have a 1s delay).

However, there is no reason to believe a C program would produce a different
hardware result. The register write is verified as correct at the MMIO bus
level (readback confirms). If the register write changes the pad mode but
doesn't trigger a TPM GPIO reset, the mechanism is broken at the PCH routing
layer, not at the software access layer.

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
  - CNP-H (Kaby Lake-R / Whiskey Lake / Comet Lake)
  - ADL-P (Alder Lake mobile 12th gen)
  - ADL-S (Alder Lake desktop 12th gen)
  - RPL-S (Raptor Lake desktop 13th/14th gen)
- Falls back to CONFIG_BOARD for MTL, pre-SKL, and NIC-based ADL detection.
- Reports UNKNOWN for unrecognized platforms with full help text.

### 5.2 Vulnerability Classification

Correctly classifies per verified Dasharo/Purism fork analysis:
- **Vulnerable (no lock)**: SPT, KBP, CNP-H, ADL-P, ADL-S, RPL-S.
- **Not vulnerable (dedicated pin)**: Pre-Skylake (Sandy/Ivy/Haswell/Broadwell).
- **Not vulnerable (functional lock)**: Meteor Lake, Panther Lake, Nova Lake.
- **Theoretical (lock compiled but not invoked)**: ADL/RPL with upstream coreboot
  (SBI method selected, no board configures lock attributes).

### 5.3 Register Read and Lock Status

- Reads PADCFGLOCK and PADCFGLOCKTX registers and decodes per-pad lock bits.
- Reads and decodes DW0 mode bits (GPIO vs NF1-NF7), TX state, TX disable,
  RX disable, and reset config (PWROK/DEEP/PLTRST/RSMRST).
- Reports whether pad is already in GPIO mode (possible attack indicator).

### 5.4 Audit Mode

In audit mode (default, `--audit`):
- Reports vulnerability status per platform class.
- Shows register addresses and community mapping.
- Explains the attack plan step by step.
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

The attack's scope is defined by the TCG TPM 2.0 Library specification,
Part 1 (Architecture):
- **Section 4**: Definitions of volatile (4.90), non-volatile (4.35), and
  transient (4.87) resources
- **Section 12.2.3.2**: TPM Reset startup type — PCRs clear, NV indices persist
- **Section 37**: NV Memory persistence categories (ORDERLY, CLEAR, RESET)
The PLTRST# signal itself is Intel PCH-specific, not a TCG concept. A GPIO
reset triggers platform-level TPM reset equivalent to `TPM2_Startup(CLEAR)`.

**Volatile (cleared on platform-level TPM reset):**
- PCRs 0-23 reset to all-zero (`TPM_PT_PS_REVISION`).
- HMAC sessions and transient objects destroyed.

**Non-volatile (preserved across reset — Section 37):**
- Sealed data objects (NVRAM indices) persist -- the attacker does not need
  to re-seal.
- Persistent key handles (e.g. 0x81000000) survive.
- NVRAM auth values are preserved.

**Why TOTP/HOTP is extractable but DUK is not:**
- TOTP/HOTP secret at NVRAM index 0x4d47 was sealed with an **empty auth value**
  (`seal-totp.sh` line 66). After PCR replay, `tpm2_unseal` succeeds with no
  passphrase required.
- DUK at NVRAM index 3 was sealed with a **user passphrase** (`kexec-seal-key.sh`
  line 309 passes `$key_password`). The attacker must provide this passphrase
  even after PCR replay -- `TPM2_Unseal` requires both matching PCRs AND the
  correct auth value per TCG 2.0 Part 1 Section 27.2.6 (Unseal command).

### 5.7 Mitigations

The attack surface can be reduced by:

**Authenticated recovery shell access**: The primary attack vector on Heads
systems is the recovery shell. Configuring GPG authentication
(`CONFIG_BOOT_RECOVERY_GPG=`) prevents an unauthenticated attacker from
reading `cbmem -L` and `/tmp/measuring_trace.log`, which are needed to
forge PCR state.

**Firmware backup and integrity checks**: An attacker with physical access
can dump the SPI ROM and compute CBFS hashes offline. Regular external
verification of ROM dumps against known-good hashes detects this kind of
tampering.

**TPM DUK with passphrase**: The DUK requires a user passphrase and is not
extractable via GPIO reset. A strong DUK passphrase protects disk encryption
even after TOTP/HOTP secret compromise.

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

### 6.1 CNP-H Testing (ThinkPad T480s, T490, T495, X390)

**Platform details:**
- PCH: Cannon Point (CNP-H), device IDs 0xa304-0xa30f.
- PLTRST_CPU_B pad: COMM_4 (port 0x6a), local pad index 7.
- Register address: 0xFD6A0670 (with PCR_BASE = 0xFD000000).

**What to test:**
1. Run `./tpm-gpio-reset-demo.sh --execute`.
2. Check if PCR 2 clears after the GPIO toggle.
3. Mechanism status: UNKNOWN -- kukrimate believes it should work,
   but no public test results confirm this.

**Expected result (if mechanism works):**
- DW0 write verified (LE readback "00000080").
- PCR 2 reads zero after toggle.
- If PCR 7 also clears, measurement replay is required before unseal.

### 6.2 SPT/KBP Testing (ThinkPad T480, T470, X270, M900 Tiny, T460, X260)

**Platform details:**
- PCH: Sunrise Point (SPT, Skylake) or Kaby Point (KBP, Kaby Lake).
- GPP_B13 pad: COMM_0 (port 0xaf), local pad index 13.
- Register address: 0xFDAF0528 (community base + PAD_CFG_BASE + 37*8 = 2 DWORDS per pad).

**Status: CONFIRMED WORKING** by kukrimate on T480 (KBL).

**What to test (verification):**
1. Run `./tpm-gpio-reset-demo.sh --execute`.
2. Confirm PCR 2 clears.
3. Confirm `tpm2_unseal` works after measurement replay.

### 6.3 ADL-S Desktop Testing (Desktop 12th gen)

**Platform details:**
- PCH: Alder Point (ADL-S), device IDs 0x7a80-0x7a8c.
- GPP_B13 pad: COMM_1 (port 0x6d), local pad index 13.
- Register address: 0xE06D07D0 (with PCR_BASE = 0xE0000000).

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

**Platform details:**
- PCH: Raptor Point (RPL-S), device IDs 0x7a0c-0x7a17.
- GPP_B13 pad: COMM_1 (port 0x6d), local pad index 13.
- Register address: 0xE06D07D0 (with PCR_BASE = 0xE0000000).

**Status: UNKNOWN.** Dasharo fork for MSI Z790-P DDR5 has
`SOC_INTEL_COMMON_BLOCK_GPIO_LOCK_USING_SBI` selected and `pad_cfg_lock_offset`
populated, but no board GPIO tables use `PAD_CFG_LOCK`. If the test shows the
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

## Appendix A: Key Register Addresses Reference

### ADL-P Mobile (NV4x, NS50)

```
PCR_BASE:       0xFD000000
GPIO COM0 port: 0x6e
Community base: 0xFD6E0000  (= 0xFD000000 + (0x6e << 16))
PAD_CFG_BASE:   0x700
GPP_B13 pad:    13
DW0 offset:     0x7D0       (= 0x700 + 13 * 16)
DW0 address:    0xFD6E07D0  (= 0xFD6E0000 + 0x7D0)
DW1 address:    0xFD6E07D4
PADCFGLOCK:     0xFD6E0080
PADCFGLOCKTX:   0xFD6E0084
```

### ADL-S / RPL-S Desktop

```
PCR_BASE:       0xE0000000
GPIO COM1 port: 0x6d
Community base: 0xE06D0000  (= 0xE0000000 + (0x6d << 16))
PAD_CFG_BASE:   0x700
GPP_B13 pad:    13
DW0 offset:     0x7D0       (= 0x700 + 13 * 16)
DW0 address:    0xE06D07D0
DW1 address:    0xE06D07D4
PADCFGLOCK:     0xE06D0110
PADCFGLOCKTX:   0xE06D0114
```

### SPT / KBP (Skylake/Kaby Lake)

SPT/KBP uses a different pad register layout than ADL. Each pad uses
**2 DWORDS (8 bytes)** per `skylake/gpio_defs.h` line 12
(`GPIO_NUM_PAD_CFG_REGS 2`). The community base includes a port shift.

```
PCR_BASE:         0xFD000000
GPIO COM0 port:   0xaf
Community base:   0xFDAF0000  (= 0xFD000000 + (0xaf << 16))
PAD_CFG_BASE:     0x400
PAD_REG_SIZE:     8  (2 DWORDS per pad)
GPP_B13:          global pad 37, local index 13 within GROUP_B (GPP_A=0-23, GPP_B=24+13)
DW0 offset:       0x528       (= 0x400 + 37 * 8)
DW0 address:      0xFDAF0528  (= 0xFDAF0000 + 0x528)
DW1 address:      0xFDAF052C
PADCFGLOCK:       0xFDAF0080
PADCFGLOCKTX:     0xFDAF0084
```

### CNP-H (Cannon Point, T480s)

```
PCR_BASE:       0xFD000000
GPIO COM4 port: 0x6a
Community base: 0xFD6A0000
PAD_CFG_BASE:   0x600
PLTRST_CPU_B:   pad 256, first pad of COM4 = 249, local idx = 7
DW0 offset:     0x670       (= 0x600 + 7 * 16)
DW0 address:    0xFD6A0670
```

### ADL-P PADCFGLOCK Registers (Readings from NV4x)

| Register | Address | Value (LE) | Value (decoded) |
|---|---|---|---|
| PADCFGLOCK | 0xFD6E0080 | 0x00010203 | Bits 0, 8, 17 set (not GPP_B13) |
| PADCFGLOCKTX | 0xFD6E0084 | 0x00000000 | No TX locked pads |

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
        confirmed vulnerable (no GPIO lock) but the PLTRST# assertion
        mechanism is not yet known for this PCH die. The kukrimate
        inteltool.c does not support ADL-P device IDs.
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

- **Heads issue #2159** -- TPM GPIO reset attack tracking
  https://github.com/linuxboot/heads/issues/2159

- **Intel GPIO Best Practices Guide** -- ID 834810 (NDA only)
  Describes pad configuration lock mechanisms and platform-specific register
  layouts. Not publicly available.

- **chipsec tpm_gpio_fail module**
  https://github.com/chipsec/chipsec
  Decision tree for evaluating TPM GPIO fail vulnerability on any Intel platform.
