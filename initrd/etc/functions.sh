#!/bin/bash

# maintain a cross-script trace stack.  When a script sources /etc/functions
# this appends the script name/line to TRACE_STACK; the variable is exported so
# it survives into children invoked with exec.  TRACE_FUNC will prepend this
# stack to the normal function call stack, giving a full picture from init to
# the current point (even across multiple scripts).
# Only add the current script once to avoid repetition when the same script
# sources this file multiple times or invokes TRACE_FUNC repeatedly.
case "${TRACE_STACK}" in
*"main($0:"*) ;;
*)
	TRACE_STACK="${TRACE_STACK:+$TRACE_STACK -> }main($0:0)"
	export TRACE_STACK
	;;
esac

# ------- Start of functions coming from /etc/ash_functions

# DIE - fatal error: print bold red message, wait for Enter, then exit 1.
#
# Console color: bold red (\033[1;31m).
# Red is the universal "error/danger" signal; the "!!! ERROR:" text prefix
# carries the same meaning for users who cannot distinguish red from other
# colors, so color is an enhancement rather than the sole signal.
# Always visible in all output modes.
DIE() {
	TRACE_FUNC
	# Always log to debug.log regardless of output mode - fatal errors must be
	# captured for post-mortem analysis even when the console is suppressed.
	echo "!!! ERROR: $* !!!" >>/tmp/debug.log
	if [ "$CONFIG_DEBUG_OUTPUT" = "y" ]; then
		# debug mode: also route to kmsg for ordering with other debug output
		echo "!!! ERROR: $* !!!" >/dev/kmsg 2>/dev/null || true
	fi
	# Always show on console with bold red regardless of output mode.
	# /dev/console = kernel console (follows the console= kernel parameter),
	# so it reaches whatever output the kernel was configured for  --  serial,
	# framebuffer, BMC  --  without requiring any process setup and without
	# polluting stdout or stderr so callers never need to care about redirections.
	echo -e "\033[1;31m!!! ERROR: $* !!!\033[0m" >/dev/console 2>/dev/null

	# ask user to press Enter prior to exit
	INPUT "Press Enter to continue..."

	exit 1
}

# WARN - a likely problem the user should act on.
#
# Use WARN when ALL of the following are true:
#   - There is a _likely_ problem (not a rare or remote possibility)
#   - We are able to continue, possibly with degraded functionality
#   - The warning is _actionable_: there is a reasonable change the user
#     can make to silence it
# Do NOT use WARN for:
#   - Informational messages about normal operations (use INFO)
#   - Rare or unlikely edge cases that are not actionable (use DEBUG)
#   - Fatal errors where we cannot continue (use DIE)
#
# Console color: bold yellow (\033[1;33m).
# Yellow is the most universally perceptible alert color across all common
# color-deficiency types: it is bright and distinct for deuteranopes,
# protanopes, and tritanopes alike.  The "*** WARNING:" text prefix carries
# the meaning independently of color.
# debug.log and /dev/kmsg receive plain text (no ANSI).
#
# Output modes (always visible in all modes):
#   Quiet (CONFIG_QUIET_MODE=y):          /dev/console + debug.log
#   Info  (CONFIG_QUIET_MODE=n):          /dev/console + debug.log
#   Debug (CONFIG_DEBUG_OUTPUT=y):        /dev/console + debug.log
#
# Do not overuse - WARN only has value when it is infrequent enough that
# users still notice and act on it.  See doc/logging.md.
WARN() {
	TRACE_FUNC
	# Always write to debug.log - complete audit trail regardless of mode.
	echo >>/tmp/debug.log
	echo " *** WARNING: $* ***" >>/tmp/debug.log
	echo >>/tmp/debug.log
	# Bold yellow to /dev/console in all modes.
	# /dev/console = kernel console (follows console= kernel parameter): reaches
	# serial, framebuffer, BMC  --  no process setup needed, callers never need to
	# care about redirections (e.g. 2>/tmp/whiptail).
	echo >/dev/console 2>/dev/null
	echo -e "\033[1;33m *** WARNING: $* ***\033[0m" >/dev/console 2>/dev/null
	echo >/dev/console 2>/dev/null
	if [ "$CONFIG_DEBUG_OUTPUT" = "y" ]; then
		# debug mode: also route to kmsg for ordering with other debug output (no ANSI - kmsg strips it)
		echo " *** WARNING: $* ***" | tee -a /dev/kmsg >/dev/null
	fi
	sleep 1
}

# DEBUG - decision points and developer-relevant context.
#
# Use DEBUG to show the information that influences logical decisions and the
# result of those decisions.  Focus on if/else/case branches: what information
# led to the branch, and which branch was taken.
# Use DO_WITH_DEBUG to capture command invocations (command+args at DEBUG
# level, stdout/stderr at LOG level) rather than calling DEBUG directly.
# Messages may freely include internal variable names, file paths, and
# technical subsystem details - this level targets Heads developers only.
# Do NOT use DEBUG for:
#   - Command output or dumps of uncontrolled length (use LOG or DO_WITH_DEBUG)
#   - Actions a non-developer user would understand (use INFO)
#
# Console color: none (plain text only; targets developers reading raw output).
# debug.log and /dev/kmsg receive plain text (no ANSI).
# Console output goes to /dev/console (the kernel console, follows the
# console= kernel parameter) so it reaches serial, framebuffer, BMC, etc.
# without requiring any process setup and without polluting stdout or stderr
# so callers never need to care about redirections.
#
# Output modes:
#   Quiet (CONFIG_QUIET_MODE=y):          debug.log only (no console)
#   Info  (CONFIG_QUIET_MODE=n):          debug.log only (no console)
#   Debug (CONFIG_DEBUG_OUTPUT=y):        /dev/console + debug.log
#
# See doc/logging.md.
DEBUG() {
	# Always write to debug.log - debug.log is a complete audit trail regardless of mode.
	echo "DEBUG: $*" >>/tmp/debug.log
	if [ "$CONFIG_DEBUG_OUTPUT" = "y" ]; then
		# debug mode: also echo to /dev/console and kmsg.
		# fold -s -w 960 will wrap lines at 960 characters on the last space before the limit
		echo "DEBUG: $*" | fold -s -w 960 | while IFS= read -r line; do
			echo "$line" | tee -a /dev/kmsg >/dev/null
			echo "$line" >/dev/console 2>/dev/null
		done
	fi
}

# TRACE / TRACE_FUNC - execution flow through scripts and functions.
#
# TRACE_FUNC MUST be called as the first line of every script and function.
# It emits the full call chain (including cross-process subprocess boundaries)
# leading to the current location:
#   TRACE: caller(file:line) -> ... -> current_func(file:line)
# Use TRACE directly (in addition to TRACE_FUNC) only to show the raw
# unprocessed parameters received by a script or function from its caller.
# Do NOT use TRACE for logic or decisions inside the function - use DEBUG.
# Do NOT use TRACE to show processed/interpreted values - use DEBUG.
#
# Console color: none (plain text only; targets developers reading raw output).
# debug.log and /dev/kmsg receive plain text (no ANSI).
# Console output goes to /dev/console (the kernel console, follows the
# console= kernel parameter) so it reaches serial, framebuffer, BMC, etc.
# without requiring any process setup and without polluting stdout or stderr
# so callers never need to care about redirections.
#
# Output modes:
#   Quiet (CONFIG_QUIET_MODE=y):                     debug.log only (no console)
#   Info  (CONFIG_QUIET_MODE=n):                     debug.log only (no console)
#   Debug (CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT=y): /dev/console + debug.log
#
# See doc/logging.md.
TRACE() {
	# Always write to debug.log - debug.log is a complete audit trail regardless of mode.
	echo "TRACE: $*" >>/tmp/debug.log
	if [ "$CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT" = "y" ]; then
		# tracing mode: also echo to /dev/console and kmsg.
		echo "TRACE: $*" | tee -a /dev/kmsg >/dev/null
		echo "TRACE: $*" >/dev/console 2>/dev/null
	fi
}

# NOTE - explains behaviors that are _likely_ to be unexpected or confusing
#        to users new to Heads.
#
# Use NOTE only when the behavior is so unexpected that users need this
# explanation to make sense of what they are seeing.  Examples:
#   - An automatic reboot the user did not explicitly request
#   - A GPG PIN prompt appearing at a point the user would not anticipate
#   - A required action before the next step can proceed
# Unlike INFO, NOTE cannot be hidden: it always appears in every output mode.
# NOTE sleeps after printing to bring the message to the user's awareness
# and ensure it is not scrolled past before they can read it.
# Do NOT overuse: prefer INFO if the behavior is only sometimes unexpected.
# Too many NOTE messages train users to ignore them, defeating their purpose.
#
# Console color: italic white NOTE: prefix (\033[3;37m).
# White is the highest-contrast neutral hue on dark consoles (VGA/serial).
# Italic distinguishes NOTE from bold STATUS/WARN without imposing a semantic
# hue, satisfying WCAG 1.4.1 (color is not the sole signal; the NOTE: prefix
# and surrounding blank lines + 3-second sleep carry meaning independently).
# debug.log receives plain text (no ANSI).
#
# Output modes (always visible in all modes):
#   Quiet (CONFIG_QUIET_MODE=y):          console + debug.log
#   Info  (CONFIG_QUIET_MODE=n):          console + debug.log
#   Debug (CONFIG_DEBUG_OUTPUT=y):        console + debug.log
#
# See doc/logging.md.
NOTE() {
	# Console: italic white NOTE: prefix, blank lines before/after, to /dev/console.
	# /dev/console = kernel console (follows console= kernel parameter): reaches
	# serial, framebuffer, BMC  --  no process setup needed, callers never need to
	# care about redirections.
	echo >/dev/console 2>/dev/null
	echo -e "\033[3;37mNOTE:\033[0m $*" >/dev/console 2>/dev/null
	echo >/dev/console 2>/dev/null
	# Log file: echo -e so \n in the message produces real newlines
	echo -e "NOTE: $*" >>/tmp/debug.log

	# Sleep to bring the message to the user's awareness: NOTE is infrequent
	# and important enough that the user must not scroll past it unread
	sleep 3
}

# STATUS - announces an action currently in progress or just completed.
#
# Use STATUS for progress and action announcements that all users must see
# regardless of output mode.  Examples:
#   - An action starting or running: "Verifying ISO", "Building initrd",
#     "Calculating hashes - this may take a while"
#   - Completion of a security-relevant operation: "ISO signature verified",
#     "LUKS device unlocked", "Verified root hashes"
#   - A boot-path milestone: "Executing default boot for $name"
#
# Unlike INFO, STATUS is always visible in all output modes - a user in
# quiet mode must still be able to see what Heads is actively doing.
# Unlike NOTE, STATUS does not sleep - it is for routine progress and action
# confirmation, not unexpected behavior requiring deliberate user attention.
#
# Console color: bold only, no hue (\033[1m).
# No color is used for STATUS by design: STATUS is the most frequent visible
# output level and must be readable in every terminal theme (dark, light,
# high-contrast, monochrome) without relying on color perception.  The >>
# prefix provides semantic differentiation instead.
# Bold ensures STATUS stands out over plain INFO/LOG text without any color.
# Output goes to /dev/console (kernel console, follows console= kernel
# parameter) so it reaches serial, framebuffer, BMC, etc. without requiring
# any process setup and without polluting stdout or stderr so callers never
# need to care about redirections (e.g. print_tree >/boot/kexec_tree.txt).
# STATUS does NOT sleep and does NOT print blank lines: it is called frequently
# and blank lines would make output very noisy.  Use NOTE when blank lines and
# a sleep are needed to draw the user's attention.
# debug.log receives plain text (no ANSI).
#
# Output modes (always visible in all modes):
#   Quiet (CONFIG_QUIET_MODE=y):          /dev/console + debug.log
#   Info  (CONFIG_QUIET_MODE=n):          /dev/console + debug.log
#   Debug (CONFIG_DEBUG_OUTPUT=y):        /dev/console + debug.log
#
# See doc/logging.md.
STATUS() {
	# Console: bold >> prefix to /dev/console - announces an action in progress.
	echo -e "\033[1m >>\033[0m $*" >/dev/console 2>/dev/null
	echo " >> $*" >>/tmp/debug.log
}

STATUS_OK() {
	# Console: bold green "OK" prefix to /dev/console - confirms a successful result.
	# Use STATUS_OK (not STATUS) when reporting that an operation succeeded,
	# a verification passed, or a resource was confirmed available.
	# Two signals make success scannable without relying on either alone:
	#   1. "OK" text label  - readable in monochrome, on serial consoles,
	#                         and by users with color vision deficiency
	#   2. Bold green color - instant visual scan for sighted users
	# (Same convention as Linux/systemd "[  OK  ]" boot messages.)
	echo -e "\033[1;32m OK\033[0m $*" >/dev/console 2>/dev/null
	echo " OK $*" >>/tmp/debug.log
}

# INFO - high-level operational context for non-developer users.
#
# INFO is what makes "Info" output mode meaningful.  A security-conscious
# user who enables Info mode expects to see a readable audit trail of what
# Heads is doing: what is being measured, verified, sealed, or decided.
# Use INFO for:
#   - TPM PCR extensions: what is being measured and when
#     (e.g. "TPM: Extending PCR[4] with boot configuration")
#   - High-level operational decisions driven by user configuration
#     (e.g. "Not booting automatically, automatic boot is disabled")
# Do NOT use INFO for:
#   - Action progress or milestones the user must see in all modes (use STATUS)
#   - Heads-internal details: file paths, variable values, CBFS operations,
#     code-flow steps with no user-visible effect (use DEBUG instead)
#   - Messages that require Heads developer knowledge to interpret (use DEBUG)
#   - Behaviors so unexpected users need to be warned (use NOTE instead)
#
# Console color: green (\033[0;32m) in Info mode.
# In Debug mode: plain text to debug.log and /dev/kmsg (no ANSI; maintains
# ordering with DEBUG messages which also route through kmsg).
# Console output goes to /dev/console (kernel console, follows console=
# kernel parameter) so it reaches serial, framebuffer, BMC, etc. without
# requiring any process setup and without polluting stdout or stderr.
#
# Output modes:
#   Quiet (CONFIG_QUIET_MODE=y):          debug.log only (no console)
#   Info  (CONFIG_QUIET_MODE=n):          /dev/console + debug.log
#   Debug (CONFIG_DEBUG_OUTPUT=y):        /dev/console + debug.log (via kmsg for ordering)
#
# See doc/logging.md.
INFO() {
	TRACE_FUNC
	if [ "$CONFIG_DEBUG_OUTPUT" = "y" ]; then
		# debug mode: plain to debug.log, measuring_trace.log, and kmsg -
		# no ANSI, maintains ordering with DEBUG messages which also route through kmsg
		echo "INFO: $*" | tee -a /tmp/debug.log /tmp/measuring_trace.log /dev/kmsg >/dev/null
	elif [ "$CONFIG_QUIET_MODE" = "y" ]; then
		# quiet mode: no console output, but captured in both logs
		echo "INFO: $*" | tee -a /tmp/debug.log /tmp/measuring_trace.log >/dev/null
	else
		# info mode: green text to /dev/console AND both log files.
		echo -e "\033[0;32m$*\033[0m" >/dev/console 2>/dev/null
		echo "INFO: $*" | tee -a /tmp/debug.log /tmp/measuring_trace.log >/dev/null
	fi
}

# LOG - command output and verbose state dumps, always to debug.log only.
#
# Use LOG to capture raw output of commands (lsblk, lsusb, gpg --list-keys,
# tpm2 pcrread, etc.) and any output of uncontrolled or potentially large
# length.  LOG never appears on the console in any output mode - it is purely
# for post-hoc analysis of a submitted debug log.
# Prefer DO_WITH_DEBUG over calling LOG directly: DO_WITH_DEBUG captures the
# command and its arguments at DEBUG level, and routes stdout/stderr to LOG.
# Call LOG directly only when capturing output that is not a direct command
# invocation (e.g. filtering another command's stderr, state summaries).
# Do NOT use LOG for:
#   - Short, fixed-length messages about decisions (use DEBUG)
#   - Messages a user should ever see on console (use INFO, NOTE, or WARN)
#
# Output modes (never on console in any mode):
#   Quiet (CONFIG_QUIET_MODE=y):          debug.log only
#   Info  (CONFIG_QUIET_MODE=n):          debug.log only
#   Debug (CONFIG_DEBUG_OUTPUT=y):        debug.log only
#
# See doc/logging.md.
LOG() {
	echo "LOG: $*" >>/tmp/debug.log
}

# INPUT - colored prompt for interactive user input.
#
# Direct replacement for the common pattern:
#   echo "prompt"
#   read [flags] VARNAME
# The prompt is displayed bold white (\033[1;37m) to draw the user's attention.
# Bold white is chosen for maximum contrast on VGA/dark consoles (21:1 ratio)
# without relying on color perception - it is readable under all color
# deficiency types and in monochrome/high-contrast terminal modes.
# Use INPUT for all prompts that require the user to type a response.
# Do NOT use INPUT for yes/no confirmation dialogs (use whiptail instead).
#
# Usage: INPUT "prompt text" [read-flags] [VARNAME]
# Examples:
#   INPUT "Enter LUKS passphrase:" -r -s luks_passphrase
#   INPUT "Press any key to continue:" -n 1 -s dummy
#   INPUT "Enter filename:" -r filename
#
# The read flags and VARNAME are passed through to read after the prompt
# is displayed - any read option (e.g. -r, -s, -n N) is supported.
#
# Output modes (always visible in all modes):
#   All modes: console prompt in bold white to /dev/console, plain text in debug.log
#
# See doc/logging.md.

# detect_heads_tty - resolve the active interactive terminal and export it.
# Sets and exports HEADS_TTY and GPG_TTY.
# Must be called at script top-level (not inside a subshell) to take effect.
detect_heads_tty() {
	local _active _dev _candidate
	if ! HEADS_TTY=$(tty 2>/dev/null); then
		HEADS_TTY=""
		DEBUG "detect_heads_tty: tty(1) unavailable, will resolve from active consoles"
	else
		DEBUG "detect_heads_tty: tty(1) resolved HEADS_TTY=$HEADS_TTY"
	fi

	# On dual-console boards (notably qemu with CONFIG_BOOT_RECOVERY_SERIAL),
	# gui-init may inherit the recovery serial tty even though its real UI lives
	# on the main console. Prefer a non-recovery active console when available.
	if [ -n "$RECOVERY_TTY" ] && [ "$HEADS_TTY" = "$RECOVERY_TTY" ]; then
		_active=$(cat /sys/class/tty/console/active 2>/dev/null)
		DEBUG "detect_heads_tty: HEADS_TTY matches RECOVERY_TTY ($RECOVERY_TTY), active consoles='${_active:-<none>}'"
		for _dev in $_active; do
			_candidate="/dev/$_dev"
			if [ "$_candidate" != "$RECOVERY_TTY" ]; then
				[ "$_dev" = "tty0" ] && _candidate="/dev/$(cat /sys/class/tty/tty0/active 2>/dev/null || echo tty0)"
				HEADS_TTY="$_candidate"
				DEBUG "detect_heads_tty: switched interactive tty away from recovery console to $HEADS_TTY"
				break
			fi
		done
	fi

	if [ -z "$HEADS_TTY" ]; then
		_active=$(cat /sys/class/tty/console/active 2>/dev/null)
		_dev="${_active##* }"
		[ "$_dev" = "tty0" ] && _dev=$(cat /sys/class/tty/tty0/active 2>/dev/null || echo tty0)
		HEADS_TTY="/dev/${_dev:-console}"
		DEBUG "detect_heads_tty: falling back to HEADS_TTY=$HEADS_TTY from active consoles='${_active:-<none>}'"
	fi
	DEBUG "detect_heads_tty: exporting HEADS_TTY=$HEADS_TTY GPG_TTY=$HEADS_TTY"
	export HEADS_TTY
	export GPG_TTY="$HEADS_TTY"
}

INPUT() {
	TRACE_FUNC
	local prompt="$1"
	shift
	# Log file: plain text - no ANSI codes in debug.log
	echo "INPUT: $prompt" >>/tmp/debug.log

	if [ -n "$HEADS_TTY" ]; then
		# gui-init context: HEADS_TTY is the actual interactive terminal (set by
		# gui-init after cttyhack).  Use it for both prompt output and read so
		# that prompt and input always use the same device regardless of any
		# stdout/stderr redirections the caller may have in effect.
		# Print prompt with a trailing space so the cursor lands immediately after
		# the prompt text on the same line  --  no blank line between prompt and input.
		printf '\033[1;37m%s\033[0m ' "$prompt" >"$HEADS_TTY" 2>/dev/null
		# Forward remaining args (read flags + variable name) directly to read.
		# Note: static analyzers may report the caller's variable as "unassigned"
		# because assignment through read "$@" indirection is not visible to them.
		# This is a false positive - the variable is assigned correctly at runtime.
		read "$@" <"$HEADS_TTY"
		echo >"$HEADS_TTY" 2>/dev/null
	else
		# Pre-gui-init context (e.g. init's serial recovery shell launched with
		# explicit stdin/stdout/stderr redirects to the serial device):
		# honour the caller's redirections  --  use stderr for output and stdin for
		# read so the correct device is used without hard-coding any path.
		printf '\033[1;37m%s\033[0m ' "$prompt" >&2
		read "$@"
		echo >&2
	fi
}

# Filter known harmless LVM warning noise while preserving all other stderr.
# Messages that are expected during device scanning (e.g. "not an LVM PV") are
# redirected to the debug log only - they are not errors and should not appear
# on the console, especially in quiet mode.
_filter_lvm_stderr() {
	while IFS= read -r line; do
		case "$line" in
		*"Failed to set up async io, using sync io."*)
			continue
			;;
		*"leaked on lvm invocation"*)
			continue
			;;
		*"Cannot use "*": device is too small"* | \
			*"Cannot use "*": device is an LV"* | \
			*"Failed to find physical volume"*)
			LOG "lvm: $line"
			continue
			;;
		esac
		printf '%s\n' "$line" >&2
	done
}

# Wrapper for all runtime lvm invocations so users don't see benign async-io
# fallback warnings, especially in quiet mode.
run_lvm() {
	command lvm "$@" 2> >(_filter_lvm_stderr)
}

fw_version() {
	local FW_VER=$(dmesg | grep 'DMI' | grep -o 'BIOS.*' | cut -f2- -d ' ')
	# chop off date, since will always be epoch w/timeless builds
	echo "${FW_VER::-10}"
}

ec_version() {
	# EC firmware version from DMI type 11 OEM Strings (if present).
	# The raw sysfs entry has a 5-byte header followed by null-terminated strings.
	local raw="/sys/firmware/dmi/tables/DMI"
	[ -f "$raw" ] || return
	tail -c +6 "$raw" | tr '\0' '\n' | sed -n 's/^EC firmware version: *//p'
}

preserve_rom() {
	TRACE_FUNC
	new_rom="$1"
	old_files=$(cbfs -t 50 -l 2>/dev/null | grep "^heads/")

	for old_file in $(echo $old_files); do
		new_file=$(cbfs.sh -o $1 -l | grep -x $old_file)
		if [ -z "$new_file" ]; then
			DEBUG "Adding $old_file to $1"
			cbfs -t 50 -r $old_file >/tmp/rom.$$ ||
				DIE "Failed to read cbfs file from ROM"
			cbfs.sh -o $1 -a $old_file -f /tmp/rom.$$ ||
				DIE "Failed to write cbfs file to new ROM file"
		fi
	done
}

# Color-code a PIN/security-token retry counter for the console.
# green (3+): safe; yellow (2): one attempt used; red (<=1 or unknown): danger.
# Works for both GPG card PIN retries and HOTP dongle (Nitrokey/Librem Key) PIN counters.
pin_color() {
	case "$1" in
	[3-9] | [1-9][0-9]) printf '\033[1;32m' ;; # green: 3 or more remaining
	2) printf '\033[1;33m' ;;                  # yellow: one attempt already used
	*) printf '\033[1;31m' ;;                  # red: 0, 1, or unknown (locked/last try)
	esac
}

# Detect USB security dongle branding from USB VID:PID via lsusb.
# Runtime dongle IDs are sourced from /etc/dongle-versions.
# Sources: hotp-verification/src/device.c and targets/qemu.mk

load_usb_security_dongle_ids() {
	# /etc/dongle-versions is the single source of truth for runtime IDs.
	[ -r /etc/dongle-versions ] || return 1
	. /etc/dongle-versions || return 1
	[ -n "$USB_SECURITY_DONGLE_VIDS" ] || return 1
	return 0
}

# Returns 0 if the given tty path is a serial console.
heads_tty_is_serial() {
	case "$1" in
	/dev/ttyS* | /dev/ttyUSB* | /dev/ttyAMA* | /dev/ttyO*) return 0 ;;
	*) return 1 ;;
	esac
}

# Returns 0 if a known USB security dongle VID is present in sysfs.
# Known VIDs: 20a0 (Nitrokey/Canokey QEMU), 316d (Librem Key), 16d0 (Canokey), 1050 (Yubikey)
usb_security_dongle_vid_present() {
	load_usb_security_dongle_ids || return 1
	local vid
	for vid in $USB_SECURITY_DONGLE_VIDS; do
		if grep -l -E "^${vid}$" /sys/bus/usb/devices/*/idVendor 2>/dev/null | grep -q .; then
			return 0
		fi
	done
	return 1
}

# Wait up to 15 seconds for a known USB security dongle VID to appear in sysfs.
# Framebuffer: any key cancels. Serial (ttyS*, ttyUSB*, ttyAMA*, ttyO*): Enter cancels.
# Returns 0 if a dongle VID is detected, 1 if timed out or cancelled.
wait_for_usb_security_dongle_vid() {
	TRACE_FUNC
	local interactive_tty="${HEADS_TTY}"
	local is_serial=0
	local allow_user_cancel="y"
	local deadline remaining ch

	if heads_tty_is_serial "$interactive_tty"; then
		is_serial=1
	fi
	DEBUG "wait_for_usb_security_dongle_vid: interactive_tty='${interactive_tty:-<none>}' is_serial=$is_serial RECOVERY_TTY='${RECOVERY_TTY:-<none>}'"

	# Never consume keystrokes from the active recovery shell tty.
	if [ -n "$RECOVERY_TTY" ] && [ "$interactive_tty" = "$RECOVERY_TTY" ]; then
		allow_user_cancel="n"
		DEBUG "Disabling USB dongle wait key-cancel on recovery tty ($RECOVERY_TTY)"
	fi

	# In non-interactive/background contexts, poll only and avoid read() input capture.
	if [ -z "$interactive_tty" ] && [ ! -t 0 ]; then
		allow_user_cancel="n"
		DEBUG "wait_for_usb_security_dongle_vid: no interactive tty and stdin is not a tty, disabling user-cancel reads"
	fi
	DEBUG "wait_for_usb_security_dongle_vid: allow_user_cancel=$allow_user_cancel"

	# Drain stray buffered input on framebuffer so stale keystrokes do not
	# immediately cancel this wait.
	# NOTE: -t 0 in BusyBox returns immediately (poll-only, does not consume
	# data) so we use -t 0.01 to actually read and discard each byte.
	if [ "$allow_user_cancel" = "y" ] && [ "$is_serial" = "0" ]; then
		if [ -n "$interactive_tty" ]; then
			while IFS= read -r -t 0.01 -n 1 junk <"$interactive_tty" 2>/dev/null; do :; done
		else
			while IFS= read -r -t 0.01 -n 1 junk; do :; done
		fi
	fi

	if [ "$allow_user_cancel" != "y" ]; then
		STATUS "Waiting up to 15s for USB security dongle detection"
	elif [ "$is_serial" = "1" ]; then
		STATUS "Waiting up to 15s for USB security dongle detection (press Enter to skip)"
	else
		STATUS "Waiting up to 15s for USB security dongle detection (press any key to skip)"
	fi

	deadline=$(( $(date +%s) + 15 ))

	while :; do
		# Exit immediately when a known VID appears.
		if usb_security_dongle_vid_present; then
			DEBUG "USB security dongle VID detected in sysfs"
			STATUS_OK "USB security dongle detected"
			return 0
		fi

		remaining=$(( deadline - $(date +%s) ))
		if [ "$remaining" -le 0 ]; then
			DEBUG "Timeout waiting for USB security dongle VID after 15s"
			STATUS "No known USB security dongle detected within 15s; continuing"
			return 1
		fi

		if [ "$allow_user_cancel" != "y" ]; then
			sleep 1
		elif [ "$is_serial" = "1" ]; then
			if [ -n "$interactive_tty" ]; then
				if IFS= read -r -t 1 ch <"$interactive_tty" 2>/dev/null; then
					DEBUG "User cancelled USB dongle wait (Enter on serial)"
					STATUS "USB security dongle wait skipped by user; continuing"
					return 1
				fi
			else
				if IFS= read -r -t 1 ch; then
					DEBUG "User cancelled USB dongle wait (Enter on serial)"
					STATUS "USB security dongle wait skipped by user; continuing"
					return 1
				fi
			fi
		else
			if [ -n "$interactive_tty" ]; then
				if IFS= read -r -t 0.2 -n 1 ch <"$interactive_tty" 2>/dev/null; then
					DEBUG "User cancelled USB dongle wait (key on framebuffer)"
					STATUS "USB security dongle wait skipped by user; continuing"
					return 1
				fi
			else
				if IFS= read -r -t 0.2 -n 1 ch; then
					DEBUG "User cancelled USB dongle wait (key on framebuffer)"
					STATUS "USB security dongle wait skipped by user; continuing"
					return 1
				fi
			fi
		fi
	done
}

# Detect USB security dongle branding (Nitrokey, Yubikey, Canokey, etc.) from VID:PID.
# This helper enables USB and waits for enumeration before scanning with lsusb.
# Branding detection requires USB modules/device nodes to be available.
detect_usb_security_dongle_branding() {
	TRACE_FUNC
	local usb_was_enabled="${_USB_ENABLED:-n}"
	# Fast path: avoid USB re-init and lsusb scan when branding is already known
	# and USB has already been initialized in this process.
	if [ "$DONGLE_BRAND" != "USB Security dongle" ] \
		&& [ -n "$DONGLE_BRAND" ] \
		&& [ "$usb_was_enabled" = "y" ]; then
		DEBUG "Fast path: DONGLE_BRAND='$DONGLE_BRAND' already known, USB was enabled"
		return
	fi

	# Child scripts can inherit DONGLE_BRAND while _USB_ENABLED resets, so always
	# initialize USB unless the fast path above was taken.
	enable_usb
	[ "$usb_was_enabled" != "y" ] && wait_for_usb_devices

	# Wait up to 15s for a known dongle VID to appear; user can press any key (fb) or Enter (serial) to skip.
	# Best-effort wait only  --  branding detection continues via lsusb regardless.
	wait_for_usb_security_dongle_vid || true
	# If branding is already specific, USB is now ready and no re-scan is needed.
	[ "$DONGLE_BRAND" != "USB Security dongle" ] && [ -n "$DONGLE_BRAND" ] && return
	if ! load_usb_security_dongle_ids; then
		DEBUG "Failed to load USB security dongle IDs from /etc/dongle-versions"
		export DONGLE_BRAND="USB Security dongle"
		return
	fi
	local lsusb_out
	lsusb_out="$(lsusb)"
	DEBUG "lsusb output: $lsusb_out"
	# Check NK3 (42b2) before the broader 20a0 vendor match
	if echo "$lsusb_out" | grep -q "$USB_SECURITY_DONGLE_NK3_VIDPID"; then
		DEBUG "Detected Nitrokey 3 ($USB_SECURITY_DONGLE_NK3_VIDPID)"
		export DONGLE_BRAND="Nitrokey 3"
	elif echo "$lsusb_out" | grep -q "$USB_SECURITY_DONGLE_CANOKEY_QEMU_VIDPID"; then
		DEBUG "Detected Canokey QEMU ($USB_SECURITY_DONGLE_CANOKEY_QEMU_VIDPID)"
		export DONGLE_BRAND="Canokey"
	elif echo "$lsusb_out" | grep -q "$USB_SECURITY_DONGLE_NITROKEY_PRO_VIDPID"; then
		DEBUG "Detected Nitrokey Pro ($USB_SECURITY_DONGLE_NITROKEY_PRO_VIDPID)"
		export DONGLE_BRAND="Nitrokey Pro"
	elif echo "$lsusb_out" | grep -q "$USB_SECURITY_DONGLE_NITROKEY_STORAGE_VIDPID"; then
		DEBUG "Detected Nitrokey Storage ($USB_SECURITY_DONGLE_NITROKEY_STORAGE_VIDPID)"
		export DONGLE_BRAND="Nitrokey Storage"
	elif echo "$lsusb_out" | grep -q "$USB_SECURITY_DONGLE_LIBREM_KEY_VIDPID"; then
		DEBUG "Detected Librem Key ($USB_SECURITY_DONGLE_LIBREM_KEY_VIDPID)"
		export DONGLE_BRAND="Librem Key"
	elif echo "$lsusb_out" | grep -q "$USB_SECURITY_DONGLE_CANOKEY_VIDPID"; then
		DEBUG "Detected Canokey ($USB_SECURITY_DONGLE_CANOKEY_VIDPID)"
		export DONGLE_BRAND="Canokey"
	elif echo "$lsusb_out" | grep -q "$USB_SECURITY_DONGLE_YUBIKEY_VID_PREFIX"; then
		DEBUG "Detected Yubikey (${USB_SECURITY_DONGLE_YUBIKEY_VID_PREFIX}*)"
		export DONGLE_BRAND="Yubikey"
	else
		DEBUG "No known USB Security dongle detected"
		export DONGLE_BRAND="USB Security dongle"
	fi
}

# Display USB security dongle firmware version with color coding.
# Green if the version meets the minimum known-good version for that device,
# yellow if the firmware is older and should be upgraded.
# Minimum versions are defined in /etc/dongle-versions for easy maintainability.
# $1: raw output from "hotp_verification info"
# $2: dongle branding string (e.g. "Nitrokey", "Librem Key")
hotpkey_fw_display() {
	[ -f /tmp/hotpkey_fw_shown ] && return
	local info="$1" branding="$2" fw_ver min_ver latest_ver extras critical
	extras=""
	critical="n"

	# Load minimum recommended firmware versions
	. /etc/dongle-versions

	if echo "$info" | grep -q "Firmware Nitrokey 3:"; then
		# NK3: "Firmware Nitrokey 3: v1.8.3"
		fw_ver="$(echo "$info" | grep "Firmware Nitrokey 3:" | sed 's/.*: *//')"
		min_ver="$HOTPKEY_NK3_MIN_VER"
		latest_ver="$HOTPKEY_NK3_LATEST_VER"
		# Also capture Secrets App version
		local app_ver
		app_ver="$(echo "$info" | grep "Firmware Secrets App:" | sed 's/.*: *//')"
		[ -n "$app_ver" ] && extras=" (Secrets App: ${app_ver})"
		# Display Nitrokey 3 firmware version - check if below minimum
		if [ "$(printf '%s\n' "$fw_ver" "$min_ver" | sort -V | head -1)" != "$min_ver" ]; then
			NOTE "$branding firmware: \033[1;33m${fw_ver}\033[0m${extras} (minimum: ${min_ver}, latest known: ${latest_ver}) - upgrade recommended"
		else
			STATUS_OK "$branding firmware: ${fw_ver}${extras} (minimum: ${min_ver}, latest known: ${latest_ver})"
		fi
		touch /tmp/hotpkey_fw_shown
		return
	elif echo "$info" | grep -q "Firmware:"; then
		# Nitrokey Pro / Storage / Librem Key: "<TAB>Firmware: v0.15"
		# hotp_verification prefixes lines with a tab; omit ^ so the pattern matches.
		fw_ver="$(echo "$info" | grep "Firmware:" | sed 's/.*: *//')"
		# Normalize: ensure fw_ver has 'v' prefix for consistent sort -V comparison.
		case "$fw_ver" in v*) ;; *) fw_ver="v$fw_ver" ;; esac
		# Flag if below the external-reprogram threshold (cannot upgrade via software)
		if [ "$(printf '%s\n' "$fw_ver" "$HOTPKEY_EXTERNAL_REPROGRAM_BELOW" | sort -V | head -1)" != "$HOTPKEY_EXTERNAL_REPROGRAM_BELOW" ]; then
			critical="y"
		fi
		if [ "$branding" = "Librem Key" ]; then
			latest_ver="$HOTPKEY_LIBREM_LATEST_VER"
			# Check if firmware < v0.11 (requires external programmer/service)
			if [ "$(printf '%s\n' "$fw_ver" "$HOTPKEY_EXTERNAL_REPROGRAM_BELOW" | sort -V | head -1)" != "$HOTPKEY_EXTERNAL_REPROGRAM_BELOW" ]; then
				NOTE "$branding firmware: ${fw_ver}${extras} (latest known: ${latest_ver}) - firmware below ${HOTPKEY_EXTERNAL_REPROGRAM_BELOW} requires external programming by Purism"
			else
				NOTE "$branding firmware: ${fw_ver}${extras} (latest known: ${latest_ver}) - Librem Keys cannot be self-upgraded; contact Purism for any future firmware updates"
			fi
			touch /tmp/hotpkey_fw_shown
			return
		fi
		if [ "$branding" = "Nitrokey Storage" ]; then
			latest_ver="$HOTPKEY_STORAGE_LATEST_VER"
			if [ -n "$latest_ver" ]; then
				STATUS_OK "$branding firmware: ${fw_ver}${extras} (latest known: ${latest_ver})"
			else
				STATUS_OK "$branding firmware: ${fw_ver}${extras}"
			fi
			touch /tmp/hotpkey_fw_shown
			return
		fi
		min_ver="$HOTPKEY_NITROKEY_MIN_VER"
		latest_ver="$HOTPKEY_NITROKEY_LATEST_VER"
		# Update upgrade command for modern nitropy CLI
		upgrade_cmd="nitropy nk pro firmware update"
	else
		return
	fi

	# Green: at or above minimum.  Yellow: upgrade available.  Red: cannot upgrade via software.
	if [ "$critical" = "y" ]; then
		NOTE "$branding firmware: \033[1;31m${fw_ver}\033[0m${extras} (latest known: ${latest_ver}) - firmware below ${HOTPKEY_EXTERNAL_REPROGRAM_BELOW} cannot be upgraded via nitropy; an external programmer is required"
	elif [ "$(printf '%s\n' "$fw_ver" "$min_ver" | sort -V | head -1)" = "$min_ver" ]; then
		STATUS_OK "$branding firmware: ${fw_ver}${extras} (minimum: ${min_ver}, latest known: ${latest_ver})"
	else
		NOTE "$branding firmware: \033[1;33m${fw_ver}\033[0m${extras} (minimum: ${min_ver}, latest known: ${latest_ver}) - upgrade recommended"
	fi
	touch /tmp/hotpkey_fw_shown
}

# Release the exclusive CCID device lock so hotp_verification can access the
# dongle.  Killing scdaemon alone is insufficient: gpg-agent restarts it
# immediately.  Both must be killed; gpg-agent and scdaemon respawn on demand
# for the next GPG operation.
release_scdaemon() {
	DEBUG "release_scdaemon: killing gpg-agent and scdaemon to release CCID lock"
	killall gpg-agent scdaemon >/dev/null 2>&1 || true
}

cache_gpg_signing_pin() {
	TRACE_FUNC

	# Skip if PIN already cached for this session.
	if [ -s /tmp/secret/gpg_pin ]; then
		DEBUG "GPG signing PIN already cached for this session; skipping"
		return
	fi

	#Skip prompts if we are currently using a known GPG key material Thumb drive backup and keys are unlocked
	#TODO: probably export CONFIG_GPG_KEY_BACKUP_IN_USE but not under /etc/user.config?
	#Toggle to come in next PR, but currently we don't have a way to toggle it back to n if config.user flashed back in rom
	if [[ "$CONFIG_HAVE_GPG_KEY_BACKUP" == "y" && "$CONFIG_GPG_KEY_BACKUP_IN_USE" == "y" ]]; then
		DEBUG "Using known GPG key material Thumb drive backup and keys are unlocked and useable through loopback"
		return
	fi

	# If GPG key backup is configured, ask whether to use the dongle or the backup
	# thumb drive.  Use a full-line read (no -n 1) so that buffered single
	# keystrokes from previous prompts cannot silently satisfy this read.
	local card_confirm=""
	if [ "$CONFIG_HAVE_GPG_KEY_BACKUP" == "y" ]; then
		INPUT "Use your $DONGLE_BRAND (Enter/y) or backup thumb drive (b)? [Y/b]:" -n 1 -r card_confirm
		while [ "$card_confirm" != "y" \
			-a "$card_confirm" != "Y" \
			-a "$card_confirm" != "b" \
			-a -n "$card_confirm" ]; do
			INPUT 'Invalid choice. Press Enter for dongle, type b for backup thumb drive, or x to abort:' -n 1 -r card_confirm
			if [ "$card_confirm" = "x" ]; then
				DIE "gpg card not confirmed"
			fi
		done
		DEBUG "User key source selection: '${card_confirm}' (empty or y/Y = dongle, b = backup thumb drive)"
	fi
	# Non-backup case: skip the upfront confirmation entirely.  wait_for_gpg_card
	# below does the actual check and prompts on failure.

	# If user has known GPG key material Thumb drive backup and asked to use it
	if [[ "$CONFIG_HAVE_GPG_KEY_BACKUP" == "y" && "$card_confirm" == "b" ]]; then
		DEBUG "Backup thumb drive path selected"
		#Only mount and import GPG key material thumb drive backup once
		if [ ! "$CONFIG_GPG_KEY_BACKUP_IN_USE" == "y" ]; then
			DEBUG "Backup key not yet in use this session; proceeding with mount and import"
			# Use a distinct path from CR_NONCE so we don't shred the nonce
			# that gpg_auth may have already created at /tmp/secret/cr_nonce
			# before calling confirm_gpg_card.
			local BP_NONCE="/tmp/secret/backup_test_nonce"
			local BP_SIG="$BP_NONCE.sig"

			shred -n 10 -z -u "$BP_NONCE" "$BP_SIG" >/dev/null 2>&1 || true

			gpg_admin_pin=""
			while [ -z "$gpg_admin_pin" ]; do
				INPUT "Please enter GPG Admin PIN needed to use the GPG backup thumb drive:" -r -s gpg_admin_pin
			done
			mount-usb.sh --pass "$gpg_admin_pin" || DIE "Unable to mount USB with provided GPG Admin PIN"
			DEBUG "USB backup thumb drive mounted; clearing card stubs and importing private subkeys"
			STATUS "Importing GPG private subkeys from backup thumb drive"
			# After keytocard the local keyring has card stubs in
			# private-keys-v1.d/.  gpg --import returns 0 even when it silently
			# skips overwriting an existing stub, so the stub must be removed
			# first.  Kill agent+scdaemon, delete all stub key files, then
			# import so GPG writes actual private key material and the
			# subsequent detach-sign uses the local key, not the smartcard.
			release_scdaemon
			find "${GNUPGHOME:-$HOME/.gnupg}/private-keys-v1.d" \
				-name '*.key' -delete >/dev/null 2>&1 || true
			DEBUG "Deleted card stubs from private-keys-v1.d before importing backup key"
			gpg --pinentry-mode=loopback --passphrase-file <(echo -n "${gpg_admin_pin}") \
				--import-options restore --import /media/subkeys.sec \
				>/dev/null 2>/tmp/backup-import.log || {
				DEBUG "GPG import failed: $(head -5 /tmp/backup-import.log 2>/dev/null)"
				DIE "Unable to import GPG private subkeys from backup thumb drive"
			}
			STATUS_OK "GPG private subkeys imported from backup"
			STATUS "Testing detach-sign and verifying against ROM-fused public key"
			dd if=/dev/urandom of="$BP_NONCE" bs=20 count=1 >/dev/null 2>&1 ||
				DIE "Unable to create $BP_NONCE to be detach-signed with GPG private signing subkey"
			gpg --pinentry-mode=loopback --passphrase-file <(echo -n "${gpg_admin_pin}") \
				--detach-sign "$BP_NONCE" \
				>/dev/null 2>/tmp/backup-sign.log || {
				DEBUG "GPG detach-sign failed: $(head -5 /tmp/backup-sign.log 2>/dev/null)"
				DIE "Unable to detach-sign $BP_NONCE with GPG private signing subkey using GPG Admin PIN"
			}
			DEBUG "Detach-sign succeeded; verifying against ROM-fused public key"
			if ! gpg --verify "$BP_SIG" "$BP_NONCE" >/dev/null 2>/tmp/backup-verify.log; then
				DEBUG "GPG verify failed: $(head -5 /tmp/backup-verify.log 2>/dev/null)"
				DIE "Unable to verify $BP_SIG detached signature against public key in ROM"
			fi
			STATUS_OK "Local GPG keyring is available for signing, encryption, and authentication this boot session"
			printf '%s' "$gpg_admin_pin" >/tmp/secret/gpg_pin
			chmod 600 /tmp/secret/gpg_pin
			STATUS_OK "GPG Admin PIN cached for this session"
			shred -n 10 -z -u "$BP_NONCE" "$BP_SIG" >/dev/null 2>&1 || true
			#TODO: maybe just an export instead of setting /etc/user.config otherwise could be flashed in weird corner case situation
			set_user_config "CONFIG_GPG_KEY_BACKUP_IN_USE" "y"
			DEBUG "CONFIG_GPG_KEY_BACKUP_IN_USE set; unmounting backup thumb drive"
			umount /media || DIE "Unable to unmount USB"
			# Close any LUKS mapping that may have been opened
			for dev in /dev/mapper/usb_mount_*; do
				[ -e "$dev" ] && cryptsetup close "$(basename "$dev")" 2>/dev/null || true
			done
			return
		else
			DEBUG "Backup key already in use this session (CONFIG_GPG_KEY_BACKUP_IN_USE=y); skipping mount"
		fi
	fi

	release_scdaemon
	# Clear any private key material left by a previous backup import (or
	# stale stubs from a previous smartcard session) so the agent starts
	# from a clean state.  For the smartcard path the agent re-discovers
	# card-resident keys via scdaemon when wait_for_gpg_card runs
	# gpg --card-status; fresh stubs are created automatically at that
	# point.  This mirrors what the backup path does before importing.
	find "${GNUPGHOME:-$HOME/.gnupg}/private-keys-v1.d" \
		-name '*.key' -delete >/dev/null 2>&1 || true
	DEBUG "Cleared private-keys-v1.d; agent will re-discover keys via scdaemon"

	# USB will be enabled by wait_for_gpg_card() and detect_usb_security_dongle_branding().
	# Wait for USB enumeration before accessing GPG card to avoid race condition
	STATUS "Waiting for USB device enumeration before checking GPG card"
	wait_for_usb_devices

	STATUS "Verifying presence of USB Security dongle"
	# ensure we don't exit without retrying
	errexit=$(set -o | grep errexit | awk '{print $2}')
	set +e
	DEBUG "Attempting gpg card detection (bounded wait)"
	if ! wait_for_gpg_card; then
		DEBUG "GPG card access failed with output: $gpg_output"
		# prompt for reinsertion and try a second time
		INPUT "Can't access GPG key; remove and reinsert, then press Enter to retry." ignored
		# restore prev errexit state
		if [ "$errexit" = "on" ]; then
			set -e
		fi
		# retry card status
		DEBUG "Retrying gpg --card-status after reinsertion (bounded wait)"
		wait_for_gpg_card ||
			DIE "gpg card read failed"
		DEBUG "Retry succeeded"
	fi
	STATUS_OK "GPG card is accessible"

	# Read card status and display PIN retry counters before prompting.
	# output excerpt: "PIN retry counter : 3 0 3"
	gpg_output=$(gpg --card-status 2>&1)
	pin_retry_counters=$(echo "$gpg_output" | grep 'PIN retry counter' | awk -F': ' '{print $2}')
	user_pin_retries=$(echo "$pin_retry_counters" | awk '{print $1}')
	admin_pin_retries=$(echo "$pin_retry_counters" | awk '{print $3}')

	# Re-detect dongle branding after card is detected (may have been too early in gui-init.sh)
	detect_usb_security_dongle_branding

	echo >/dev/console 2>/dev/null
	STATUS "GPG User PIN retries remaining: $(pin_color "$user_pin_retries")${user_pin_retries}\033[0m"
	STATUS "GPG Admin PIN retries remaining: $(pin_color "$admin_pin_retries")${admin_pin_retries}\033[0m"

	# Collect and validate smartcard User PIN via Heads INPUT then loopback
	# test-sign. On success, cache the PIN so all subsequent signing calls in
	# this session use --pinentry-mode=loopback --passphrase-file without
	# prompting the user again.
	SC_NONCE="/tmp/secret/sc_nonce"
	SC_SIG="$SC_NONCE.sig"
	shred -n 10 -z -u "$SC_NONCE" "$SC_SIG" >/dev/null 2>&1 || true
	dd if=/dev/urandom of="$SC_NONCE" bs=20 count=1 >/dev/null 2>&1 ||
		DIE "Unable to create nonce for smartcard PIN test-sign"
	STATUS "Testing GPG smartcard signing to cache User PIN for this session"
	sc_user_pin=""
	sc_pin_tries=0
	while [ "$sc_pin_tries" -lt 3 ]; do
		sc_pin_tries=$((sc_pin_tries + 1))
		while [ -z "$sc_user_pin" ]; do
			INPUT "Enter $DONGLE_BRAND GPG User PIN:" -r -s sc_user_pin
		done
		if gpg --pinentry-mode=loopback \
			--passphrase-file <(printf '%s' "$sc_user_pin") \
			--detach-sign "$SC_NONCE" >/dev/null 2>/tmp/sc-sign.log; then
			gpg --verify "$SC_SIG" "$SC_NONCE" >/dev/null 2>&1 ||
				DIE "GPG smartcard test-sign: signature verification failed"
			printf '%s' "$sc_user_pin" >/tmp/secret/gpg_pin
			chmod 600 /tmp/secret/gpg_pin
			STATUS_OK "GPG User PIN cached for this session"
			break
		fi
		sc_user_pin=""
		if grep -Eiq 'bad pin|wrong pin|incorrect pin|pin incorrect|pinentry.*cancel' /tmp/sc-sign.log 2>/dev/null; then
			if [ "$sc_pin_tries" -lt 3 ]; then
				WARN "Incorrect GPG User PIN (attempt $sc_pin_tries/3) - please retry"
				# Re-read counter to show updated remaining retries after the failed attempt
				gpg_output=$(gpg --card-status 2>&1)
				pin_retry_counters=$(echo "$gpg_output" | grep 'PIN retry counter' | awk -F': ' '{print $2}')
				user_pin_retries=$(echo "$pin_retry_counters" | awk '{print $1}')
				STATUS "GPG User PIN retries remaining: $(pin_color "$user_pin_retries")${user_pin_retries}\033[0m"
				continue
			fi
			DIE "Incorrect GPG User PIN after 3 attempts. Check remaining PIN retries."
		fi
		DIE "GPG smartcard test-sign failed: $(head -5 /tmp/sc-sign.log 2>/dev/null)"
	done
	shred -n 10 -z -u "$SC_NONCE" "$SC_SIG" >/dev/null 2>&1 || true

	# restore prev errexit state
	if [ "$errexit" = "on" ]; then
		set -e
	fi
}

confirm_gpg_card() {
	# enable_usb is called internally by detect_usb_security_dongle_branding
	detect_usb_security_dongle_branding
	cache_gpg_signing_pin "$@"
}

gpg_auth() {
	if [[ "$CONFIG_HAVE_GPG_KEY_BACKUP" == "y" ]]; then
		TRACE_FUNC
		# If we have a GPG key backup, we can use it to authenticate even if the card is lost
		NOTE "Please authenticate with OpenPGP smartcard/backup media to prove you are the owner of this machine"

		# Wipe any existing nonce and signature
		shred -n 10 -z -u "$CR_NONCE" "$CR_SIG" 2>/dev/null || true

		# Perform a signing-based challenge-response,
		# to authencate that the card plugged in holding
		# the key to sign the list of boot files.

		CR_NONCE="/tmp/secret/cr_nonce"
		CR_SIG="$CR_NONCE.sig"

		# Generate a random nonce
		dd \
			if=/dev/urandom \
			of="$CR_NONCE" \
			count=1 \
			bs=20 \
			2>/dev/null ||
			DIE "Unable to generate 20 random bytes"

		# Sign the nonce; cache_gpg_signing_pin ensures the PIN is cached and
		# the card is accessible before each attempt.
		for tries in 1 2 3; do
			until (confirm_gpg_card); do true; done
			if gpg --digest-algo SHA256 \
				--pinentry-mode=loopback \
				--passphrase-file /tmp/secret/gpg_pin \
				--detach-sign \
				-o "$CR_SIG" \
				"$CR_NONCE" >/dev/null 2>&1 &&
				gpg --verify "$CR_SIG" "$CR_NONCE" >/dev/null 2>&1 \
				; then
				shred -n 10 -z -u "$CR_NONCE" "$CR_SIG" 2>/dev/null || true
				DEBUG "Under /etc/ash_functions:gpg_auth: success"
				return 0
			else
				shred -n 10 -z -u "$CR_SIG" 2>/dev/null || true
				if [ "$tries" -lt 3 ]; then
					WARN "GPG authentication failed (attempt $tries/3), please try again"
					# Clear cached PIN so the next attempt re-prompts for the correct PIN.
					rm -f /tmp/secret/gpg_pin
					continue
				else
					DIE "GPG authentication failed, please reboot and try again"
				fi
			fi
		done
		return 1
	fi
}

recovery() {
	TRACE_FUNC
	if [ "$CONFIG_RESTRICTED_BOOT" = y ]; then
		NOTE "Restricted Boot enabled, recovery console disabled, rebooting in 5 seconds"
		sleep 5
		/bin/reboot.sh
	fi
	while [ true ]; do
		# Re-detect TTY on each iteration so INPUT uses the correct device
		detect_heads_tty

		# Wipe secrets at start of each iteration to ensure fresh state
		#safe to always be true. Otherwise "set -e" would make it exit here
		shred -n 10 -z -u /tmp/secret/* 2>/dev/null || true
		rm -rf /tmp/secret
		mkdir -p /tmp/secret

		# ensure /tmp/config exists for recovery scripts that depend on it
		touch /tmp/config
		. /tmp/config

		# Log board and firmware/EC versions in one go
		DEBUG "Board $CONFIG_BOARD - version $(fw_version) EC_VER: $(ec_version)"

		if [ "$CONFIG_TPM" = "y" ]; then
			INFO "TPM: Extending PCR[4] with content of string 'recovery' to prevent further secret unsealing"
			tpmr.sh extend -ix 4 -ic recovery
		fi

		#Going to recovery shell should be authenticated if supported
		gpg_auth

		# Debug and measurement logs are always captured; show copy guidance directly.
		cat /etc/DEBUG_LOG_COPY_INSTRUCTIONS
		# display any custom recovery message just before the banner
		if [ -n "$*" ]; then
			WARN "$*"
		fi

		# Show PCR state when entering recovery shell only when TPM is enabled.
		if [ "$CONFIG_TPM" = "y" ]; then
			INFO "TPM: PCR state on entering recovery shell:"
			pcrs | while IFS= read -r line; do
				INFO "$line"
			done
		fi

		# Drain any queued serial input before starting the interactive shell.
		# This avoids stale bytes being interpreted as bash commands on entry.
		# NOTE: -t 0 in BusyBox returns immediately (poll-only, does not consume
		# data) so we use -t 0.01 to actually read and discard each byte.
		if [ -n "$RECOVERY_TTY" ]; then
			while IFS= read -r -t 0.01 -n 1 _junk <"$RECOVERY_TTY" 2>/dev/null; do :; done
		else
			while IFS= read -r -t 0.01 -n 1 _junk 2>/dev/null; do :; done
		fi

		STATUS "Starting recovery shell"

		if [ -n "$RECOVERY_TTY" ]; then
			# Reopen the serial TTY on each iteration so the new session
			# leader acquires it as its controlling terminal automatically
			# (POSIX: opening a TTY as session leader without O_NOCTTY sets
			# it as the controlling terminal).  setsid -c with an inherited
			# fd fails to respawn correctly after the first bash exits.
			setsid /bin/bash <>"$RECOVERY_TTY" >&0 2>&0
		elif [ -n "$HEADS_TTY" ]; then
			# Redirect bash I/O directly to the detected TTY before
			# setsid -c steals the controlling terminal.  The
			# redirections close the inherited pipe fds from
			# DO_WITH_DEBUG in the child, and the parent is blocked
			# on waitpid during the CTTY acquisition — the pipeline
			# tee processes are idle and never collide with the
			# changed foreground process group.
			setsid -c /bin/bash <>"$HEADS_TTY" >&0 2>&0
		elif [ -x /bin/setsid ]; then
			/bin/setsid -c /bin/bash
		else
			/bin/bash
		fi
	done
}

pause_recovery() {
	TRACE_FUNC
	INPUT "Press Enter to proceed to recovery shell"
	recovery "$@"
}

combine_configs() {
	TRACE_FUNC
	cat /etc/config* >/tmp/config
}

replace_config() {
	TRACE_FUNC
	CONFIG_FILE=$1
	CONFIG_OPTION=$2
	NEW_SETTING=$3

	touch $CONFIG_FILE
	# first pull out the existing option from the global config and place in a tmp file
	awk "gsub(\"^export ${CONFIG_OPTION}=.*\",\"export ${CONFIG_OPTION}=\\\"${NEW_SETTING}\\\"\")" /tmp/config >${CONFIG_FILE}.tmp
	awk "gsub(\"^${CONFIG_OPTION}=.*\",\"${CONFIG_OPTION}=\\\"${NEW_SETTING}\\\"\")" /tmp/config >>${CONFIG_FILE}.tmp

	# then copy any remaining settings from the existing config file, minus the option you changed
	grep -v "^export ${CONFIG_OPTION}=" ${CONFIG_FILE} | grep -v "^${CONFIG_OPTION}=" >>${CONFIG_FILE}.tmp || true
	sort ${CONFIG_FILE}.tmp | uniq >${CONFIG_FILE}
	rm -f ${CONFIG_FILE}.tmp
}

# Set a config variable in a specific file to a given value - replace it if it
# exists, or add it.  If added, the variable will be exported.
set_config() {
	CONFIG_FILE="$1"
	CONFIG_OPTION="$2"
	NEW_SETTING="$3"

	if grep -q "$CONFIG_OPTION" "$CONFIG_FILE"; then
		replace_config "$CONFIG_FILE" "$CONFIG_OPTION" "$NEW_SETTING"
	else
		echo "export $CONFIG_OPTION=\"$NEW_SETTING\"" >>"$CONFIG_FILE"
	fi
}

# Set a value in config.user, re-combine configs, and update configs in the
# environment.
set_user_config() {
	CONFIG_OPTION="$1"
	NEW_SETTING="$2"

	set_config /etc/config.user "$CONFIG_OPTION" "$NEW_SETTING"
	combine_configs
	. /tmp/config
}

# Load a config value to a variable, defaulting to empty.  Does not fail if the
# config is not set (since it would expand to empty by default).
load_config_value() {
	local config_name="$1"
	if grep -q "$config_name=" /tmp/config; then
		grep "$config_name=" /tmp/config | tail -n1 | cut -f2 -d '=' | tr -d '"'
	fi
}

enable_usb() {
	TRACE_FUNC
	[ "${_USB_ENABLED:-n}" = "y" ] && { DEBUG "USB already enabled, skipping"; return; }
	#insmod.sh ehci_hcd prior of uhdc_hcd and ohci_hcd to suppress dmesg warning
	insmod.sh /lib/modules/ehci-hcd.ko || DIE "ehci_hcd: module load failed"

	if [ "$CONFIG_LINUX_USB_COMPANION_CONTROLLER" = y ]; then
		insmod.sh /lib/modules/uhci-hcd.ko || DIE "uhci_hcd: module load failed"
		insmod.sh /lib/modules/ohci-hcd.ko || DIE "ohci_hcd: module load failed"
		insmod.sh /lib/modules/ohci-pci.ko || DIE "ohci_pci: module load failed"
	fi
	insmod.sh /lib/modules/ehci-pci.ko || DIE "ehci_pci: module load failed"
	insmod.sh /lib/modules/xhci-hcd.ko || DIE "xhci_hcd: module load failed"
	insmod.sh /lib/modules/xhci-pci.ko || DIE "xhci_pci: module load failed"
	export _USB_ENABLED="y"
	DEBUG "USB modules loaded, _USB_ENABLED=y"
}

# Wait for USB bus enumeration to complete after enable_usb() loads modules.
# Uses time-bounded polling (max 2s) to avoid race conditions where device
# nodes haven't been created yet. No hardcoded sleep - checks actual readiness.
# Waits for actual USB peripheral devices (e.g., 1-1, 5-3), not just hubs/controllers.
wait_for_usb_devices() {
	TRACE_FUNC
	if [ ! -d /sys/bus/usb/devices ] || [ ! -r /proc/uptime ]; then
		DEBUG "USB sysfs or uptime not available, skipping wait"
		return
	fi

	local start now elapsed
	start=$(awk '{print $1}' /proc/uptime)
	DEBUG "Waiting for USB peripheral devices (not just hubs) - max 2s timeout"

	local iteration=0
	while :; do
		iteration=$((iteration + 1))

		# Check for actual USB peripheral devices (format: bus-port like 1-1, 5-3)
		# Root hubs are named usb1, usb2, etc. - we want devices downstream from them
		# Pattern: /sys/bus/usb/devices/[0-9]*-[0-9]*/idVendor (e.g., 1-1, 5-3.2)
		local peripheral_count=0
		if [ -d /sys/bus/usb/devices ]; then
			# Count devices matching bus-port pattern (not usb* root hubs)
			for dev in /sys/bus/usb/devices/*-*/idVendor; do
				if [ -r "$dev" ]; then
					peripheral_count=$((peripheral_count + 1))
				fi
			done
		fi

		now=$(awk '{print $1}' /proc/uptime)
		elapsed=$(awk -v s="$start" -v n="$now" 'BEGIN{printf "%.3f", n - s}')

		if [ $peripheral_count -gt 0 ]; then
			DEBUG "USB peripheral devices ready after ${elapsed}s (iteration $iteration): found $peripheral_count device(s)"
			STATUS_OK "USB peripheral devices detected"
			return
		fi

		# Timeout after 2 seconds
		if awk -v s="$start" -v n="$now" 'BEGIN{exit (n - s > 2.0) ? 0 : 1}'; then
			DEBUG "USB wait timeout at ${elapsed}s (iter $iteration): only found $peripheral_count peripheral device(s)"
			WARN "USB peripheral devices were not detected within 2s, continuing"
			return
		fi
	done
}

# Wait for gpg --card-status to succeed (bounded, no sleep).
# Sets global gpg_output with the last command output.
wait_for_gpg_card() {
	TRACE_FUNC

	#make sure usb is enabled before trying to access the card
	enable_usb

	if [ ! -r /proc/uptime ]; then
		gpg_output=$(gpg --card-status 2>&1)
		local rc=$?
		[ $rc -eq 0 ] && release_scdaemon
		return $rc
	fi

	local start now elapsed
	start=$(awk '{print $1}' /proc/uptime)
	local attempt=0
	while :; do
		attempt=$((attempt + 1))
		gpg_output=$(gpg --card-status 2>&1)
		if [ $? -eq 0 ]; then
			now=$(awk '{print $1}' /proc/uptime)
			elapsed=$(awk -v s="$start" -v n="$now" 'BEGIN{printf "%.3f", n - s}')
			DEBUG "gpg --card-status succeeded after ${elapsed}s (attempt $attempt)"
			# Card output captured; release scdaemon now so the NK3's CCID
			# session teardown begins immediately.  hotp_verification needs
			# the same CCID interface and cannot open a session until the
			# previous one is fully closed (~3s on NK3 firmware).  Releasing
			# here gives the device time to recover while the caller does its
			# own processing (e.g. user reads a dialog) before calling
			# hotp_verification.
			release_scdaemon
			return 0
		fi

		now=$(awk '{print $1}' /proc/uptime)
		elapsed=$(awk -v s="$start" -v n="$now" 'BEGIN{printf "%.3f", n - s}')
		if awk -v s="$start" -v n="$now" 'BEGIN{exit (n - s > 2.0) ? 0 : 1}'; then
			DEBUG "gpg --card-status timeout at ${elapsed}s (attempt $attempt)"
			return 1
		fi
	done
}

enable_usb_keyboard() {
	TRACE_FUNC
	# For resiliency, test CONFIG_USB_KEYBOARD_REQUIRED explicitly rather
	# than having it imply CONFIG_USER_USB_KEYBOARD at build time.
	# Otherwise, if a user got CONFIG_USER_USB_KEYBOARD=n in their
	# config.user by mistake, they could lock themselves out.
	if [ "$CONFIG_USB_KEYBOARD_REQUIRED" = y ] || [ "$CONFIG_USER_USB_KEYBOARD" = y ]; then
	enable_usb
	wait_for_usb_devices
	insmod.sh /lib/modules/usbhid.ko || DIE "usbhid: module load failed"
fi
}

# ------- End of functions coming from /etc/ash_functions

# Print <hidden> or <empty> depending on whether $1 is empty.  Useful to mask an
# optional password parameter.
mask_param() {
	if [ -z "$1" ]; then
		echo "<empty>"
	else
		echo "<hidden>"
	fi
}

# Pipe input to this to sink it to the debug log, with a name prefix.
# If the input is empty, no output is produced, so actual output is
# readily visible in logs.
#
# For example:
# ls /boot/vmlinux* | SINK_LOG "/boot kernels"
#
# To capture stderr:
# cryptsetup open /dev/sda1 media-crypt 2> >(SINK_LOG "LUKS unlock sda1 errors")
# (Note: the space between '>' is necessary in '2> >(SINK_LOG ...)')
#
# To capture both:
# tpm reset > >(SINK_LOG "tpm reset") 2>&1
# (Note: 2>&1 must follow the stdout redirection, and space between '>' is
# necessary)
SINK_LOG() {
	local name="$1"
	local line haveblank
	# If the input doesn't end with a line break, read won't give us the
	# last (unterminated) line.  Add a line break with echo to ensure we
	# don't lose any input.  Buffer up to one blank line so we can avoid
	# emitting a final (or only) blank line.
	(
		cat
		echo
	) | while IFS= read -r line; do
		[[ -n "$haveblank" ]] && LOG "$name: " # Emit buffered blank line
		if [[ -z "$line" ]]; then
			haveblank=y
		else
			haveblank=
			LOG "$name: $line"
		fi
	done
}

# Trace a command with DEBUG, then execute it.  Trace failed exit status, stdout
# and stderr, etc.
#
# DO_WITH_DEBUG is designed so it can be dropped in to most command invocations
# without side effects - it adds visibility without actually affecting the
# execution of the script.  Exit statuses, stdout, and stderr are traced, but
# they are still returned/written to the caller.
#
# A password parameter can be masked by passing --mask-position N before the
# command to execute, the debug trace will just indicate whether the password
# was empty or nonempty (which is important when use of a password is optional).
# N=0 is the name of the command to be executed, N=1 is its first parameter,
# etc.
#
# DO_WITH_DEBUG() can be added in most places where a command is executed to
# add visibility in the debug log.  For example:
#
# [DO_WITH_DEBUG] mount "$BLOCK" "$MOUNTPOINT"
#   ^-- adding DO_WITH_DEBUG will show the block device, mountpoint, and whether
#   the mount fails
#
# [DO_WITH_DEBUG --mask-position 7] tpmr.sh seal "$KEY" "$IDX" "$pcrs" "$pcrf" "$size" "$PASSWORD"
#   ^-- trace the resulting invocation, but mask the password in the log
#
# if ! [DO_WITH_DEBUG] umount "$MOUNTPOINT"; then [...]
#   ^-- it can be used when the exit status is checked, like the condition of `if`
#
# hotp_token_info="$([DO_WITH_DEBUG] hotp_verification info)"
#   ^-- output of hotp_verification info becomes visible in debug log while
#   still being captured by script
#
# [DO_WITH_DEBUG] umount "$MOUNTPOINT" &>/dev/null || true
#   ^-- if the command's stdout/stderr/failure are ignored, this still works the
#   same way with DO_WITH_DEBUG
DO_WITH_DEBUG() {
	local exit_status=0
	local cmd_output
	if [[ "$1" == "--mask-position" ]]; then
		local mask_position="$2"
		shift
		shift
		local show_args=("$@")
		show_args[$mask_position]="$(mask_param "${show_args[$mask_position]}")"
		DEBUG "${show_args[@]}"
	else
		DEBUG "$@"
	fi

	# Execute the command and capture the exit status. Tee stdout/stderr to
	# debug sinks, so they're visible but still can be used by the caller
	#
	# This is tricky when set -e / set -o pipefail may or may not be in
	# effect.
	# - Putting the command in an `if` ensures set -e won't terminate us,
	#   and also does not overwrite $? (like `|| true` would).
	# - We capture PIPESTATUS[0] whether the command succeeds or fails,
	#   since we don't know whether the pipeline status will be that of the
	#   command or 'tee' (depends on set -o pipefail).
	if ! "$@" 2> >(tee /dev/stderr | SINK_LOG "$1 stderr") | tee >(SINK_LOG "$1 stdout"); then
		exit_status="${PIPESTATUS[0]}"
	else
		exit_status="${PIPESTATUS[0]}"
	fi
	if [[ "$exit_status" -ne 0 ]]; then
		# Trace unsuccessful exit status, but only at DEBUG because this
		# may be expected.  Include the command name in case the command
		# also invoked a DO_WITH_DEBUG (it could be a script).
		DEBUG "$1: exited with status $exit_status"
	fi
	# If the command was (probably) not found, trace PATH in case it
	# prevented the command from being found
	if [[ "$exit_status" -eq 127 ]]; then
		DEBUG "$1: PATH=$PATH"
	fi

	return "$exit_status"
}

# TRACE_FUNC outputs the function call stack in a readable format.
# It helps debug the execution path leading to the current function.
#
# The format of the output is:
#	main(/path/to/script:line) -> function1(/path/to/file:line) -> function2(/path/to/file:line)
#
# Usage:
#	Call TRACE_FUNC within any function to print the call hierarchy.
TRACE_FUNC() {
	# Index [1] for BASH_SOURCE and FUNCNAME give us the caller location.
	# FUNCNAME is 'main' if called from a script outside any function.
	# BASH_LINENO is offset by 1, it provides the line that the
	# corresponding FUNCNAME was _called from_, so BASH_LINENO[0] is the
	# location of the caller.

	local i stack_trace=""

	# Traverse the call stack from the earliest caller to the direct caller of TRACE_FUNC
	# C-style for loop: bash-only (not ash/POSIX). Safe because all callers use #!/bin/bash.
	for ((i = ${#FUNCNAME[@]} - 1; i > 1; i--)); do
		stack_trace+="${FUNCNAME[i]}(${BASH_SOURCE[i]}:${BASH_LINENO[i - 1]}) -> "
	done

	# Append the direct caller (without extra " -> " at the end)
	stack_trace+="${FUNCNAME[1]}(${BASH_SOURCE[1]}:${BASH_LINENO[0]})"

	# Print the final trace output, including any inherited script-level stack
	if [ -n "$TRACE_STACK" ]; then
		TRACE "$TRACE_STACK -> $stack_trace"
	else
		TRACE "${stack_trace}"
	fi
}

# Show the entire current call stack in debug output - useful if a catastrophic
# error or something very unexpected occurs, like totally invalid parameters.
DEBUG_STACK() {
	local FRAMES
	FRAMES="${#FUNCNAME[@]}"
	DEBUG "call stack: ($((FRAMES - 1)) frames)"
	# Don't print DEBUG_STACK itself, start from 1
	for i in $(seq 1 "$((FRAMES - 1))"); do
		DEBUG "- $((i - 1)) - ${BASH_SOURCE[$i]}(${BASH_LINENO[$((i - 1))]}): ${FUNCNAME[$i]}"
	done
}

pcrs() {
	if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
		tpm2 pcrread sha256 2>&1 | grep -v '^sha256:'
	elif [ "$CONFIG_TPM" = "y" ]; then
		head -8 /sys/class/tpm/tpm0/pcrs
	fi
}

# Marker helpers for TPM state that requires reset before reseal/generate paths.
tpm_reset_required_marker_path() {
	printf %s "/tmp/secret/tpm_reset_required"
}

tpm_reset_required_reason_path() {
	printf %s "/tmp/secret/tpm_reset_required.reason"
}

tpm_reset_required_source_path() {
	printf %s "/tmp/secret/tpm_reset_required.source"
}

tpm_reset_required_timestamp_path() {
	printf %s "/tmp/secret/tpm_reset_required.timestamp"
}

debug_tpm_reset_required_state() {
	TRACE_FUNC
	local marker reason source when
	marker="$(tpm_reset_required_marker_path)"
	reason="$(tpm_reset_required_reason_path)"
	source="$(tpm_reset_required_source_path)"
	when="$(tpm_reset_required_timestamp_path)"

	if [ -f "$marker" ]; then
		DEBUG "TPM reset marker: PRESENT path=$marker"
		DEBUG "TPM reset marker: reason=$(cat "$reason" 2>/dev/null || echo '<unset>')"
		DEBUG "TPM reset marker: source=$(cat "$source" 2>/dev/null || echo '<unset>')"
		DEBUG "TPM reset marker: timestamp=$(cat "$when" 2>/dev/null || echo '<unset>')"
	else
		DEBUG "TPM reset marker: ABSENT path=$marker"
	fi
}

set_tpm_reset_required() {
	TRACE_FUNC
	local reason source
	reason="${1:-TPM state marked invalid by unknown caller}"
	source="${2:-unknown}"
	mkdir -p /tmp/secret || true
	echo "$reason" >"$(tpm_reset_required_reason_path)" 2>/dev/null || true
	echo "$source" >"$(tpm_reset_required_source_path)" 2>/dev/null || true
	date -u "+%Y-%m-%d %H:%M:%S UTC" >"$(tpm_reset_required_timestamp_path)" 2>/dev/null || true
	: >"$(tpm_reset_required_marker_path)"
	WARN "TPM reset required: $reason"
}

clear_tpm_reset_required() {
	TRACE_FUNC
	rm -f "$(tpm_reset_required_marker_path)"
	rm -f "$(tpm_reset_required_reason_path)"
	rm -f "$(tpm_reset_required_source_path)"
	rm -f "$(tpm_reset_required_timestamp_path)"
	STATUS_OK "TPM reset-required marker cleared"
}

tpm_reset_required() {
	TRACE_FUNC
	local marker
	marker="$(tpm_reset_required_marker_path)"
	if [ -f "$marker" ]; then
		DEBUG "tpm_reset_required: yes"
		debug_tpm_reset_required_state
		return 0
	fi
	DEBUG "tpm_reset_required: no"
	return 1
}

confirm_totp() {
	TRACE_FUNC
	prompt="$1"
	last_half=X
	unset totp_confirm

	while true; do

		# update the TOTP code every thirty seconds
		date=$(date "+%Y-%m-%d %H:%M:%S")
		seconds=$(date "+%s")
		half=$(expr \( $seconds % 60 \) / 30)
		if [ "$CONFIG_TPM" != "y" ]; then
			TOTP="NO TPM"
		elif [ "$half" != "$last_half" ]; then
			last_half=$half
			TOTP=$(unseal-totp.sh) ||
				recovery "TOTP code generation failed"
		fi

		echo -n "$date $TOTP: "

		# read the first character, non-blocking
		read \
			-t 1 \
			-n 1 \
			-s \
			-p "$prompt" \
			totp_confirm &&
			break

		# nothing typed, redraw the line
		echo -ne '\r'
	done

	# clean up with a newline
	echo
}

reseal_tpm_disk_decryption_key() {
	TRACE_FUNC
	local GPG_KEY_COUNT
	if tpm_reset_required; then
		WARN "Cannot reseal TPM disk decryption key while TPM state is marked invalid. Reset the TPM first (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
		return 1
	fi
	# Resealing disk-unlock material eventually requires signing /boot updates;
	# do not proceed if keyring is empty.
	GPG_KEY_COUNT=$(gpg -k 2>/dev/null | wc -l)
	if [ "$GPG_KEY_COUNT" -eq 0 ]; then
		DEBUG "Skipping TPM disk-key reseal: GPG keyring is empty (caller handles user guidance)"
		return 1
	fi

	# only relevant for TPM2; TPM1 has no primary handle concept
	if [ "$CONFIG_TPM2_TOOLS" = "y" ] && [ ! -f "/tmp/secret/primary.handle" ]; then
		WARN "Cannot reseal TPM disk decryption key; no TPM primary handle. Use the GUI menu (Options -> TPM/TOTP/HOTP Options -> Reset the TPM) to reset the TPM first."
		return 1
	fi
	#For robustness, exit early if LUKS TPM Disk Unlock Key is prohibited in board configs
	if [ "$CONFIG_TPM_DISK_UNLOCK_KEY" == "n" ]; then
		DEBUG "LUKS TPM Disk Unlock Key is prohibited in board configs"
		return
	else
		DEBUG "LUKS TPM Disk Unlock Key is allowed in board configs. Continuing"
	fi

	if ! grep -q /boot /proc/mounts; then
		mount -o ro /boot ||
			recovery "Unable to mount /boot"
	fi

	if [ -s /boot/kexec_key_devices.txt ] || [ -s /boot/kexec_key_lvm.txt ]; then
		STATUS "Validating TPM rollback counter before resealing"
		preflight_rollback_counter_before_reseal
		STATUS_OK "TPM rollback counter validated"
		STATUS "Resealing TPM Disk Unlock Key alongside TOTP/HOTP secret"
		if ! kexec-seal-key.sh /boot; then
			DIE "Failed to reseal TPM Disk Unlock Key"
		fi
		attempt=1
		while ! update_checksums; do
			WARN "Signing attempt $attempt/3 failed"
			if [ "$attempt" -ge 3 ]; then
				DIE "Failed to sign boot hashes under /boot after 3 attempts"
			fi
			attempt=$((attempt + 1))
		done
		STATUS_OK "TPM Disk Unlock Key resealed and boot hashes signed"
		STATUS "Rebooting to enable default boot option"
		sleep 3
		reboot.sh
	else
		DEBUG "No TPM disk decryption key to reseal"
	fi
}

# Enable USB storage (if not already enabled), and wait for storage devices to
# be detected.  If USB storage was already enabled, no wait occurs, this would
# have happened already when USB storage was enabled.
enable_usb_storage() {
	TRACE_FUNC
	if ! lsmod | grep -q usb_storage; then
		timeout=0
		STATUS "Scanning for USB storage devices"
		insmod.sh /lib/modules/usb-storage.ko >/dev/null 2>&1 ||
			DIE "usb_storage: module load failed"
		while [[ $(list_usb_storage | wc -l) -eq 0 ]]; do
			[[ $timeout -ge 8 ]] && break
			sleep 1
			timeout=$(($timeout + 1))
		done
	fi
}

device_has_partitions() {
	local DEVICE="$1"
	# fdisk normally says "doesn't contain a valid partition table" for
	# devices that lack a partition table - except for FAT32.
	#
	# FAT32 devices have a volume boot record that looks enough like an MBR
	# to satisfy fdisk.  In that case, fdisk prints a partition table header
	# but no partitions.
	#
	# This check covers that: [ $(fdisk -l "$b" | wc -l) -eq 5 ]
	# In both cases the output is 5 lines: 3 about device info, 1 empty line
	# and the 5th will be the table header or the invalid message.
	local DISK_DATA=$(fdisk -l "$DEVICE" 2>/dev/null)
	if echo "$DISK_DATA" | grep -q "doesn't contain a valid partition table" ||
		[ "$(echo "$DISK_DATA" | wc -l)" -eq 5 ]; then
		# No partition table
		return 1
	fi
	# There is a partition table
	return 0
}

# Build displayable disk information using sysfs (vs current BusyBox's 2TB limit per https://bugs.busybox.net/show_bug.cgi?id=16276)
# Output format: "Disk /dev/<name>: <SIZE> GB/TB" per line
# (GB for smaller disks, TB for disks >= 1000 GB)
# The /sys/block/*/size entry is always counted in 512‑byte sectors, so
# calculate using bytes from blockdev when available or multiply by 512.
disk_info_sysfs() {
	TRACE_FUNC
	local disk_info=""
	for dev in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/hd*; do
		if [ -e "$dev" ]; then
			# ignore partition entries (they contain a 'partition' file)
			if [ -e "$dev/partition" ]; then
				continue
			fi
			local devname=$(basename "$dev")
			local size_bytes=""
			if command -v blockdev >/dev/null 2>&1; then
				size_bytes=$(blockdev --getsize64 "/dev/${devname}" 2>/dev/null)
			fi
			if [ -z "$size_bytes" ] || ! [ "$size_bytes" -gt 0 ] 2>/dev/null; then
				local size_sectors_512=$(cat "$dev/size" 2>/dev/null)
				if [ -n "$size_sectors_512" ] && [ "$size_sectors_512" -gt 0 ] 2>/dev/null; then
					size_bytes=$((size_sectors_512 * 512))
				fi
			fi
			if [ -n "$size_bytes" ] && [ "$size_bytes" -gt 0 ] 2>/dev/null; then
				local size_gb=$(((size_bytes + 500000000) / 1000000000))
				# show TB when size is at least 1,000,000,000,000 bytes (≈1000 GB) for better UX
				if [ "$size_bytes" -ge 1000000000000 ]; then
					local size_tb=$(((size_bytes + 500000000000) / 1000000000000))
					printf -v disk_info "%sDisk /dev/%s: %s TB\n" "$disk_info" "$devname" "$size_tb"
				else
					printf -v disk_info "%sDisk /dev/%s: %s GB\n" "$disk_info" "$devname" "$size_gb"
				fi
			fi
		fi
	done
	# trim trailing newline so callers don't get an extra blank line
	printf "%s" "${disk_info%$'\n'}"
}

list_usb_storage() {
	TRACE_FUNC
	# List all USB storage devices, including partitions unless we received argument stating we want drives only
	# The output is a list of device names, one per line.

	if [ "$1" = "disks" ]; then
		DEBUG "Listing USB storage devices (disks only) since list_usb_storage was called with 'disks' argument"
	else
		DEBUG "Listing USB storage devices (including partitions)"
	fi

	stat -c %N /sys/block/sd* 2>/dev/null | grep usb |
		cut -f1 -d ' ' |
		sed "s/[']//g" |
		while read b; do
			# Ignore devices of size 0, such as empty SD card
			# readers on laptops attached via USB.
			if [ "$(cat "$b/size")" -gt 0 ]; then
				DEBUG "USB storage device of size greater then 0: $b"
				echo "$b"
			fi
		done |
		sed "s|/sys/block|/dev|" |
		while read b; do
			# If the device has a partition table, ignore it and
			# include the partitions instead - even if the kernel
			# hasn't detected the partitions yet.  Such a device is
			# never usable directly, and this allows the "wait for
			# disks" loop in mount-usb.sh to correctly wait for the
			# partitions.
			if ! device_has_partitions "$b"; then
				# No partition table, include this device
				DEBUG "USB storage device without partition table: $b"
				echo "$b"
			#Bypass the check for partitions if we want only disks
			elif [ "$1" = "disks" ]; then
				# disks only were requested, so we don't list partitions
				DEBUG "USB storage device with partition table: $b"
				DEBUG "We asked for disks only, so we don't want to list partitions"
				echo "$b"
			else
				# Has a partition table, include partitions
				DEBUG "USB storage device with partition table: $b"
				ls -1 "$b"* | awk 'NR!=1 {print $0}'
			fi
	done
}

# Collect all unique initramfs paths from parsed boot entries.
# Entries are pipe-delimited: name|kexectype|kernel|initrd <path>|append <params>
# Field 4 starts with "initrd " for regular entries.
# Xen/multiboot entries use "module <path>" for kernel and initramfs;
# kexec-parse-boot.sh outputs kexectype=xen in field 2 for these.
# For Xen entries: field 4 is the kernel (vmlinuz/bzImage), field 5 is initramfs.
# For non-Xen entries with module fields: all modules are treated as initramfs.
# Args: bootdir  entries_file
# Writes unique initramfs relative paths to stdout (one per line, deduplicated).
collect_initramfs_paths() {
	local bootdir="$1" entries_file="$2"
	local seen="" entry entry_type path mod_field old_ifs part
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		entry_type=$(echo "$entry" | cut -d\| -f2)
		# Scan ALL pipe-delimited fields for initrd* or module* patterns,
		# not just field 4.  Some GRUB configs (e.g. Debian installer DVD)
		# emit initrd in a different field position.
		old_ifs="$IFS"; IFS='|'
		set -- $entry
		IFS="$old_ifs"
		for part; do
			case "$part" in
			initrd\ *)
				path="${part#initrd }"
				[ -f "$bootdir/$path" ] || continue
				case " $seen " in *" $path "*) ;; *) echo "$path"; seen="$seen $path" ;; esac
				;;
			module\ *)
				if [ "$entry_type" = "xen" ]; then
					# Xen: first module is kernel, second+ are initramfs
					local _mod_count=0
					for mod_field in "$@"; do
						case "$mod_field" in
						module\ *)
							_mod_count=$((_mod_count + 1))
							[ "$_mod_count" -le 1 ] && continue
							path="${mod_field#module }"
							path="${path%% *}"
							[ -f "$bootdir/$path" ] || continue
							case " $seen " in *" $path "*) ;; *) echo "$path"; seen="$seen $path" ;; esac
							;;
						esac
					done
				else
					# Non-Xen multiboot: all module paths are initramfs
					path="${part#module }"
					path="${path%% *}"
					[ -f "$bootdir/$path" ] || continue
					case " $seen " in *" $path "*) ;; *) echo "$path"; seen="$seen $path" ;; esac
				fi
				;;
			esac
		done
	done < "$entries_file"
}

# Prompt for a TPM Owner Passphrase if it is not already cached in /tmp/secret/tpm_owner_passphrase.
# Sets tpm_owner_passphrase variable reused in flow, and cache file used until recovery shell is accessed.
# Tools should optionally accept a TPM passphrase on the command line, since some flows need
# it multiple times and only one prompt is ideal.
prompt_tpm_owner_password() {
	TRACE_FUNC

	if [ -s /tmp/secret/tpm_owner_passphrase ]; then
		DEBUG "/tmp/secret/tpm_owner_passphrase already cached in file. Reusing"
		tpm_owner_passphrase=$(cat /tmp/secret/tpm_owner_passphrase)
		return 0
	fi

	INPUT "TPM Owner Passphrase:" -r -s tpm_owner_passphrase

	# Cache the passphrase externally to be reused by who needs it
	DEBUG "Caching TPM Owner Passphrase to /tmp/secret/tpm_owner_passphrase"
	mkdir -p /tmp/secret || DIE "Unable to create /tmp/secret"
	echo -n "$tpm_owner_passphrase" >/tmp/secret/tpm_owner_passphrase || DIE "Unable to cache TPM owner_passphrase under /tmp/secret/tpm_owner_passphrase"
}

# Prompt for a new TPM Owner Passphrase when resetting the TPM.
# Returned in tpm_owner_passphrase and cached under /tmp/secret/tpm_owner_passphrase
# The passphrase must be 1-32 characters and must be entered twice,
# the script will loop until this is met.
prompt_new_owner_password() {
	TRACE_FUNC
	local tpm_owner_passphrase2
	tpm_owner_passphrase=1
	tpm_owner_passphrase2=2
	while [ "$tpm_owner_passphrase" != "$tpm_owner_passphrase2" ] || [ "${#tpm_owner_passphrase}" -gt 32 ] || [ -z "$tpm_owner_passphrase" ]; do
		INPUT "New TPM Owner Passphrase (2 words suggested, 1-32 characters max):" -r -s tpm_owner_passphrase
		INPUT "Repeat chosen TPM Owner Passphrase:" -r -s tpm_owner_passphrase2
		if [ "$tpm_owner_passphrase" != "$tpm_owner_passphrase2" ]; then
			WARN "Passphrases entered do not match. Try again!"
		fi
	done

	# Cache the passphrase externally to be reused by who needs it
	DEBUG "Caching TPM Owner Passphrase to /tmp/secret/tpm_owner_passphrase"
	mkdir -p /tmp/secret || DIE "Unable to create /tmp/secret"
	echo -n "$tpm_owner_passphrase" >/tmp/secret/tpm_owner_passphrase || DIE "Unable to cache TPM passphrase under /tmp/secret/tpm_owner_passphrase"
}

check_tpm_counter() {
	# $1: rollback file path
	TRACE_FUNC

	LABEL=${2:-3135106223}
	# $3 (tpm_passphrase) was used by pre-PR #2068 code but is now intentionally
	# ignored  --  counters are created with empty auth (-pwdc '') per TCG spec.
	# if the /boot.hashes file already exists, read the TPM counter ID
	# from it.
	if [ -r "$1" ]; then
		# Robustly extract the first hex string after 'counter-' on any line
		TPM_COUNTER=$(grep -Eo 'counter-[0-9a-fA-F]+' "$1" | sed -n 's/counter-//p' | head -n1 | tr -d '\n')
		DEBUG "Extracted TPM_COUNTER: '$TPM_COUNTER' from $1"
	else
		DEBUG "$1 does not exist - creating new TPM counter"
		# Create TPM counter with empty counter auth per TCG spec (no secret).
		# Owner passphrase is not needed for the counter auth itself.
		DEBUG "Invoking tpmr.sh counter_create with label $LABEL"
		# run it, then record the exit status explicitly; the '!' operator
		# cannot be used because it would hide the real return code.
		# Capture stdout (TPM1 errors print to stdout via tpmtotp printf).
		# Stderr (TPM2 errors) goes to SINK_LOG for debugging.
		# Wrapped in subshell to avoid set -e killing the script on non-zero exit.
		(
			set +e
			tpmr.sh counter_create \
				-pwdc '' \
				-la "$LABEL" \
				>/tmp/counter 2> >(tee >(SINK_LOG "tpm counter_create stderr") >&2)
			echo $? > /tmp/counter_create_rc
		)
		local rc=$(cat /tmp/counter_create_rc)
		if [ $rc -ne 0 ]; then
			DEBUG "tpmr.sh counter_create failed with status $rc"
			# "out of resources" (TPM 1.2 error 0x15) is a generic resource
			# exhaustion error (TPM_RESOURCES: "insufficient internal resources").
			# The user must reset the TPM to release internal resources.
			# Only set tpm_reset_required for this case, not for auth failures.
			if grep -qiE 'out of resources|0x15' /tmp/counter 2>/dev/null; then
				set_tpm_reset_required \
					"TPM counter creation failed (exit $rc): $(head -c 200 /tmp/counter 2>/dev/null | tr '\n' ' ')" \
					"check_tpm_counter"
				DIE "TPM out of resources (0x15). Reset the TPM through the Heads menu: Options -> TPM/TOTP/HOTP Options -> Reset the TPM"
			fi
			# don't tell the user to reset again; the TPM was just reset
			DIE "Unable to create TPM counter; TPM appears to be in a bad state. Perform OEM Factory Reset / re-ownership and try again."
		fi
		TPM_COUNTER=$(cut -d: -f1 </tmp/counter | tr -d '\n')
		DEBUG "Created new TPM counter: $TPM_COUNTER"
	fi

	if [ -z "$TPM_COUNTER" ]; then
		DIE "No TPM counter could be found or created."
	fi
}

# Return the numeric value of the rollback counter stored in the given file
# (typically /boot/kexec_rollback.txt).  Returns an empty string if the file
# doesn't exist or doesn't contain a counter entry.
get_rollback_counter_id() {
	TRACE_FUNC
	local rollback_file="$1"
	if [ -r "$rollback_file" ]; then
		grep -Eo 'counter-[0-9a-fA-F]+' "$rollback_file" | sed -n 's/counter-//p' | head -n1 | tr -d '\n'
	fi
}

# Return success when /boot appears to have prior Heads trust metadata.
# This distinguishes first ownership/fresh install from an initialized system
# where missing TPM metadata is suspicious.
has_prior_boot_trust_metadata() {
	local rollback_file
	rollback_file="${1:-/boot/kexec_rollback.txt}"
	[ -r "$rollback_file" ] || [ -r /boot/kexec_default_hashes.txt ] || [ -r /boot/kexec.sig ]
}

# Test whether the current TPM rollback counter (the one referenced by
# /boot/kexec_rollback.txt) can still be read.  Exit 0 if the counter can be
# read, non-zero otherwise.  This can be used to decide whether the TPM needs a
# full reset instead of merely resealing secrets.
counter_readable() {
	TRACE_FUNC
	# rely on colon-free output in case caller wraps in DO_WITH_DEBUG
	local id
	id=$(get_rollback_counter_id /boot/kexec_rollback.txt)
	if [ -n "$id" ]; then
		if tpmr.sh counter_read -ix "$id" >/dev/null 2>&1; then
			return 0
		fi
	fi
	return 1
}

# Validate rollback counter state before expensive operations.
# This is a non-mutating preflight intended to fail early when the configured
# rollback counter is clearly unusable.
# Parameters:
#   $1 optional rollback file path (default: /boot/kexec_rollback.txt)
#   $2 optional explicit counter id override
#   $3 optional on-error mode: 'DIE' (default) or 'return'
preflight_rollback_counter_before_reseal() {
	TRACE_FUNC
	local rollback_file counter_id attrs_lc on_error error_file
	rollback_file="${1:-/boot/kexec_rollback.txt}"
	counter_id="$2"
	on_error="${3:-DIE}"
	local reset_required_marker="/tmp/secret/rollback_reset_required"
	error_file="/tmp/rollback_preflight_error"

	fail_preflight() {
		local message="$1"
		mkdir -p /tmp/secret || true
		: >"$reset_required_marker"
		set_tpm_reset_required "$message" "preflight_rollback_counter_before_reseal"
		if [ "$on_error" = "return" ]; then
			echo "$message" >"$error_file"
			return 1
		fi
		DIE "$message"
	}

	if [ "$CONFIG_TPM" != "y" ] || [ "$CONFIG_IGNORE_ROLLBACK" = "y" ]; then
		DEBUG "Skipping rollback counter preflight: rollback checks are disabled"
		return 0
	fi

	if [ -z "$counter_id" ]; then
		counter_id="$(get_rollback_counter_id "$rollback_file")"
	fi
	if [ -z "$counter_id" ]; then
		# If rollback metadata is missing on an already initialized system,
		# this is an inconsistent TPM/boot state and should be handled before
		# TOTP/HOTP recovery workflows.
		if has_prior_boot_trust_metadata "$rollback_file"; then
			fail_preflight "Boot integrity counter file missing. This means /boot was restored or swapped. Reset TPM from GUI (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
			return 1
		fi
		DEBUG "Skipping rollback counter preflight: no counter id in $rollback_file (likely first-time initialization)"
		return 0
	fi

	DEBUG "Preflight: validating rollback counter $counter_id before protected operations"
	if ! tpmr.sh counter_read -ix "$counter_id" >/dev/null 2>&1; then
		fail_preflight "TPM integrity counter cannot be read. Possible cause: TPM was swapped or reset. This could indicate a TPM swap attack. Reset TPM from GUI (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
		return 1
	fi

	if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
		if attrs_lc="$(tpm2 nvreadpublic "0x$counter_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')"; then
			if [ -n "$attrs_lc" ]; then
				if echo "$attrs_lc" | grep -q "ownerwrite" && ! echo "$attrs_lc" | grep -q "authwrite"; then
					fail_preflight "TPM counter has invalid security policy. Reset TPM from GUI (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
					return 1
				fi
				if ! echo "$attrs_lc" | grep -Eq "authwrite|ownerwrite"; then
					fail_preflight "TPM counter is not writable. Reset TPM from GUI (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
					return 1
				fi
			else
				fail_preflight "TPM counter policy is corrupted. Reset TPM from GUI (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
				return 1
			fi
		else
			fail_preflight "Cannot read TPM counter policy. Reset TPM from GUI (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
			return 1
		fi
	fi

	if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
		DEBUG "Preflight: rollback counter $counter_id is readable and has acceptable TPM2 write attributes"
	else
		DEBUG "Preflight: rollback counter $counter_id is readable on TPM1"
		DEBUG "Preflight: post OEM Factory Reset / Re-Ownership, TOTP unseal may be unavailable until a new TOTP/HOTP secret is generated"
	fi
}

# Read the TPM counter value from the TPM.
read_tpm_counter() {
	TRACE_FUNC
	local counter_id
	counter_id="$(echo "$1" | tr -d '\n')"
	if [ ! -e /tmp/counter-"$counter_id" ]; then
		DEBUG "Counter file /tmp/counter-$counter_id not found. Attempting to read from TPM."
		tpmr.sh counter_read -ix "$counter_id" >/tmp/counter-"$counter_id" ||
			DIE "Counter read failed for index $counter_id"
	fi
	DEBUG "Counter file /tmp/counter-$counter_id read successfully."
}

increment_tpm_counter() {
	TRACE_FUNC
	local counter_id counter_present tpm_passphrase increment_ok
	counter_id="$(echo "$1" | tr -d '\n')"
	tpm_passphrase="$2"
	counter_present="n"
	increment_ok="n"
	local reset_required_marker="/tmp/secret/rollback_reset_required"

	# Check if counter is readable; if so, mark it present so the
	# "readable but not incrementable" branch below can set rollback_reset_required.
	if tpmr.sh counter_read -ix "$counter_id" >/dev/null 2>&1; then
		counter_present="y"
	fi

	# TPM2 uses owner-auth fallback in tpm2_counter_inc; TPM1 uses empty counter
	# auth (SHA1("")) per TCG spec  --  no owner passphrase needed for increment.
	# Keep the cached owner passphrase for TPM2 fallback.
	if [ -z "$tpm_passphrase" ] && [ -s /tmp/secret/tpm_owner_passphrase ]; then
		tpm_passphrase="$(cat /tmp/secret/tpm_owner_passphrase)"
	fi

	# Try to increment the counter.  We normally hide the verbose
	# output of tpmr.sh commands to avoid overwhelming the console, but we
	# must *not* swallow any interactive prompts.  The previous implementation
	# redirected the entire `tpmr.sh counter_create` invocation to a file and
	# /dev/null, which meant that when the counter was missing the password
	# prompt could not be seen by the user even though tpmr.sh printed it to the
	# controlling terminal.  Instead, capture just the stdout in a temporary
	# file while still letting stdout appear on the console (and logging
	# stderr to debug log).
	DEBUG "incrementing TPM counter $counter_id"

	if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
		# TPM2: counter_increment tries bare nvincrement (index auth) first,
		# then retries with owner auth using -pwdc value if provided.
		# One call suffices; the function handles both internally.
		DEBUG "increment_tpm_counter: TPM2 incrementing counter $counter_id"
		if (
			set -o pipefail
			DO_WITH_DEBUG --mask-position 5 \
				tpmr.sh counter_increment -ix "$counter_id" -pwdc "${tpm_passphrase:-}" \
				2>/dev/null |
				tee /tmp/counter-"$counter_id" >/dev/null
		); then
			increment_ok="y"
		fi
	else
		# TPM1 counter uses empty auth (SHA1 of "") per TCG spec.
		# NOTE: tpmtotp C code prints ALL output (success + errors) to stdout.
		# We must capture stdout to detect failures properly.
		# DO_WITH_DEBUG internally captures the command's stderr (tee /dev/stderr
		# | SINK_LOG "$1 stderr") and stdout (tee >(SINK_LOG "$1 stdout")).
		# Redirecting DO_WITH_DEBUG's own fd 2 to /dev/null is intentional: the
		# actual command stderr is already handled inside DO_WITH_DEBUG.
		if (
			set -o pipefail
			DO_WITH_DEBUG --mask-position 5 \
				tpmr.sh counter_increment -ix "$counter_id" -pwdc '' \
					2>/dev/null | tee /tmp/counter-"$counter_id" >/dev/null
		); then
			increment_ok="y"
		fi
	fi

	if [ "$increment_ok" != "y" ]; then
		if [ "$counter_present" = "y" ]; then
			mkdir -p /tmp/secret || true
			: >"$reset_required_marker"
			DIE "TPM rollback counter '$counter_id' is readable but not incrementable. Reset TPM from GUI (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
		fi

		# Check if we need to create a new counter
		DEBUG "TPM counter increment failed. Attempting to create a new counter..."

		# run counter_create but tee its stdout to a file so we still see
		# the interactive prompt and any informational messages.
		# Empty counter auth (-pwdc '') per TCG spec.
		if (
			set -o pipefail
			DO_WITH_DEBUG --mask-position 3 \
				tpmr.sh counter_create -pwdc '' -la 3135106223 \
				2> >(tee >(SINK_LOG "tpm counter_create stderr") >&2) |
				tee /tmp/new-counter >/dev/null
		); then
			NEW_COUNTER=$(cut -d: -f1 </tmp/new-counter | tr -d '\n')
			DEBUG "Created new TPM counter: $NEW_COUNTER. (counter won't be usable without reset)"
		fi

		DIE "TPM counter increment failed for rollback prevention. Reset the TPM using the GUI menu (Options -> TPM/TOTP/HOTP Options -> Reset the TPM) to clear the counter and allow a fresh one to be created."
	fi

	DEBUG "TPM counter incremented successfully for index $counter_id"
}

# Check detached signature on kexec boot params
check_config() {
	TRACE_FUNC
	local paramsdir="${1%%/}"

	if [ ! -d /tmp/kexec ]; then
		mkdir /tmp/kexec ||
			DIE 'Failed to make kexec tmp dir'
	else
		rm -rf /tmp/kexec/* ||
			DIE 'Failed to empty kexec tmp dir'
	fi

	DEBUG "check_config: checking $paramsdir (force=$2)"

	if [ ! -r "$paramsdir/kexec.sig" -a "$CONFIG_BASIC" != "y" ]; then
		DEBUG "check_config: no $paramsdir/kexec.sig found, skipping signature check"
		return
	fi

	# Collect kexec*.txt files present in paramsdir
	local param_files=()
	for f in "$paramsdir"/kexec*.txt; do
		[ -e "$f" ] || continue
		param_files+=("$(basename "$f")")
	done
	DEBUG "check_config: ${#param_files[@]} kexec*.txt file(s) in $paramsdir: ${param_files[*]}"

	if [ ${#param_files[@]} -eq 0 ]; then
		DEBUG "check_config: no kexec*.txt files found in $paramsdir, skipping"
		return
	fi

	if [ "$2" != "force" ]; then
		# Verify using relative filenames (cd into paramsdir) so the sha256sum
		# output matches exactly what was produced during signing, where the same
		# relative names were used.  Absolute paths would differ between the
		# signing staging dir and $paramsdir, causing a spurious mismatch.
		STATUS "Verifying GPG signature on boot hashes"
		DEBUG "check_config: running (cd $paramsdir && sha256sum ${param_files[*]}) | gpgv.sh $paramsdir/kexec.sig"
		if ! (cd "$paramsdir" && sha256sum "${param_files[@]}") |
			gpgv.sh "$paramsdir/kexec.sig" - 2> >(SINK_LOG "gpgv kexec.sig"); then
			DIE 'Invalid signature on kexec boot params'
		fi
		STATUS_OK "Boot hashes signature verified"
	fi

	DEBUG "check_config: copying kexec*.txt from $paramsdir to /tmp/kexec"
	cp "$paramsdir"/kexec*.txt /tmp/kexec ||
		DIE "Failed to copy kexec boot params to tmp"
}

# Replace a file in a ROM (add it if the file does not exist)
replace_rom_file() {
	ROM="$1"
	ROM_FILE="$2"
	NEW_FILE="$3"

	if (cbfs.sh -o "$ROM" -l | grep -q "$ROM_FILE"); then
		cbfs.sh -o "$ROM" -d "$ROM_FILE"
	fi
	cbfs.sh -o "$ROM" -a "$ROM_FILE" -f "$NEW_FILE"
}


# Generate a secret for TPM-less HOTP by reading the ROM.  Output is the
# sha256sum of the ROM (binary, not printable), which can be truncated to the
# supported secret length.
secret_from_rom_hash() {
	local ROM_IMAGE="/tmp/coreboot-notpm.rom"

	INFO "TPM not detected; measuring ROM directly"

	# Read the ROM if we haven't read it yet
	if [ ! -f "${ROM_IMAGE}" ]; then
		flash.sh -r "${ROM_IMAGE}" >/dev/null 2>&1 || return 1
	fi

	sha256sum "${ROM_IMAGE}" | cut -f1 -d ' ' | fromhex_plain
}

# Refresh /boot hash of the TPM2 primary handle when available.
# This prevents a follow-up prompt to "set default boot" solely to rebuild
# kexec_primhdl_hash.txt after TPM reset/reseal flows.
refresh_tpm2_primary_handle_hash() {
	TRACE_FUNC
	local primhash_file="${1:-/boot/kexec_primhdl_hash.txt}"

	if [ "$CONFIG_TPM2_TOOLS" != "y" ]; then
		DEBUG "Skipping TPM2 primary handle hash refresh: CONFIG_TPM2_TOOLS != y"
		return 0
	fi

	if [ ! -s /tmp/secret/primary.handle ]; then
		DEBUG "Skipping TPM2 primary handle hash refresh: /tmp/secret/primary.handle not available"
		return 0
	fi

	DEBUG "Refreshing TPM2 primary key handle hash into $primhash_file"
	if ! DO_WITH_DEBUG sha256sum /tmp/secret/primary.handle >"$primhash_file"; then
		WARN "Failed to refresh TPM2 primary key handle hash at $primhash_file"
		return 1
	fi

	DEBUG "TPM2 primary key handle hash saved to $primhash_file"
	return 0
}

# Update the checksums of the files in /boot and sign them
update_checksums() {
	TRACE_FUNC
	local reset_required_marker="/tmp/secret/rollback_reset_required"
	local signing_targets
	# ensure /boot mounted
	if ! grep -q /boot /proc/mounts; then
		mount -o ro /boot ||
			recovery "Unable to mount /boot"
	fi

	# remount RW
	mount -o rw,remount /boot

	# sign and auto-roll config counter
	extparam=
	if [ "$CONFIG_TPM" = "y" ]; then
		if [ "$CONFIG_IGNORE_ROLLBACK" != "y" ]; then
			DEBUG "add -r to kexec-sign-config.sh since CONFIG_IGNORE_ROLLBACK is not set"
			extparam=-r
		fi
	fi

	# Keep this best-effort and run it before signing while /boot is RW.
	# Running after kexec-sign-config.sh can fail because that path may remount
	# /boot read-only before returning.
	if ! refresh_tpm2_primary_handle_hash; then
		WARN "Proceeding without refreshed TPM2 primary key handle hash"
	fi

	signing_targets="$(find /boot/kexec*.txt 2>/dev/null | tr '\n' ' ')"
	DEBUG "update_checksums: signing targets under /boot: ${signing_targets:-<none>}"
	DEBUG "update_checksums: rollback marker path is $reset_required_marker"
	DEBUG "update_checksums: extparam='$extparam' CONFIG_TPM='${CONFIG_TPM:-}' CONFIG_IGNORE_ROLLBACK='${CONFIG_IGNORE_ROLLBACK:-}'"
	DEBUG "update_checksums: signing is required because boot hashes under /boot changed (rollback counter and/or resealed secrets) and must be re-trusted"

	STATUS "Signing $CONFIG_BRAND_NAME boot hashes under /boot"

	# signing may prompt for TPM password; avoid DO_WITH_DEBUG which
	# severs the controlling tty for the child process.
	DEBUG "running kexec-sign-config.sh -p /boot -u $extparam"
	rm -f "$reset_required_marker"
	if ! kexec-sign-config.sh -p /boot -u $extparam; then
		if [ -e "$reset_required_marker" ]; then
			DIE "TPM rollback counter state is invalid for secure rollback protection. Reset TPM from GUI (Options -> TPM/TOTP/HOTP Options -> Reset the TPM)."
		fi
		rv=1
	else
		rv=0
	fi

	# switch back to ro mode
	mount -o ro,remount /boot

	return $rv
}

# Print the file and directory structure of /boot to caller's stdout
print_tree() {
	TRACE_FUNC
	find ./ ! -path './kexec*' -print0 | sort -z
}

# Escape zero-delimited standard input to safely display it to the user in e.g.
# `whiptail`, `less`, `echo`, `cat`. Doesn't produce shell-escaped output.
# Most printable characters are passed verbatim (exception: \).
# These escapes are used to replace their corresponding characters: #n#r#t#v#b
# Other characters are rendered as hexadecimal escapes.
# escape_zero [prefix] [escape character]
# prefix: \0 in the input will result in \n[prefix]
# escape character: character to use for escapes (default: #); \ may be interpreted by `whiptail`
escape_zero() {
	local prefix="$1"
	local echar="${2:-#}"
	local todo=""
	local echar_hex="$(echo -n "$echar" | xxd -p -c1)"
	[ ${#echar_hex} -eq 2 ] || DIE "Invalid escape character $echar passed to escape_zero(). Programming error?!"

	echo -e -n "$prefix"
	xxd -p -c1 | tr -d '\n' |
		{
			while IFS= read -r -n2 -d ''; do
				if [ -n "$todo" ]; then
					#REPLY == "  " is EOF
					[[ "$REPLY" == "  " ]] && echo '' || echo -e -n "$todo"
					todo=""
				fi

				case "$REPLY" in
				00)
					todo="\n$prefix"
					;;
				08)
					echo -n "${echar}b"
					;;
				09)
					echo -n "${echar}t"
					;;
				0a)
					echo -n "${echar}n"
					;;
				0b)
					echo -n "${echar}v"
					;;
				0d)
					echo -n "${echar}r"
					;;
				"$echar_hex")
					echo -n "$echar$echar"
					;;
				#interpreted characters:
				2[0-9a-f] | 3[0-9a-f] | 4[0-9a-f] | 5[0-9abd-f] | 6[0-9a-f] | 7[0-9a-e])
					echo -e -n '\x'"$REPLY"
					;;
				# All others are escaped
				*)
					echo -n "${echar}x$REPLY"
					;;
				esac
	done
	}
}



# Currently heads doesn't support signing file names with certain characters
# due to https://bugs.busybox.net/show_bug.cgi?id=14226. Also, certain characters
# may be intepreted by `whiptail`, `less` et al (e.g. \n, \b, ...).
assert_signable() {
	TRACE_FUNC
	# ensure /boot mounted
	detect_boot_device

	find /boot -print0 >/tmp/signable.ref
	local del='\001-\037\134\177-\377'
	LC_ALL=C tr -d "$del" </tmp/signable.ref >/tmp/signable.del || DIE "Failed to execute tr."
	if ! cmp -s "/tmp/signable.ref" "/tmp/signable.del" &>/dev/null; then
		local user_out="/tmp/hash_output_mismatches"
		local add="Please investigate!"
		[ -f "$user_out" ] && add="Please investigate the following relative paths to /boot (where # are sanitized invalid characters):"$'\n'"$(cat "$user_out")"
		recovery "Some /boot file names contain characters that are currently not supported by heads: $del"$'\n'"$add"
	fi
	rm -f /tmp/signable.*
}

# Verify the checksums of the files in /boot
verify_checksums() {
	TRACE_FUNC
	local boot_dir="$1"
	local gui="${2:-y}"

	(
		set +e -o pipefail
		local ret=0
		cd "$boot_dir" || ret=1
		sha256sum -c "$TMP_HASH_FILE" >/tmp/hash_output 2>/dev/null || ret=1

		# also make sure that the file & directory structure didn't change
		# (sha256sum won't detect added files)
		print_tree >/tmp/tree_output || ret=1
		if ! cmp -s "$TMP_TREE_FILE" /tmp/tree_output 2>/dev/null; then
			ret=1
			[[ "$gui" != "y" ]] && exit "$ret"
			# produce a diff that can safely be presented to the user
			# this is relatively hard as file names may e.g. contain backslashes etc.,
			# which are interpreted by whiptail, less, ...
			if [ -r "$TMP_TREE_FILE" ]; then
				escape_zero "(new) " <"$TMP_TREE_FILE" >"${TMP_TREE_FILE}.user" 2>/dev/null
			else
				touch "${TMP_TREE_FILE}.user"
			fi
			if [ -r /tmp/tree_output ]; then
				escape_zero "(new) " </tmp/tree_output >/tmp/tree_output.user 2>/dev/null
			else
				touch /tmp/tree_output.user
			fi
			diff "${TMP_TREE_FILE}.user" /tmp/tree_output.user 2>/dev/null | grep -E '^\+\(new\).*$' | sed -r 's/^\+\(new\)/(new)/g' >>/tmp/hash_output 2>/dev/null
			rm -f "${TMP_TREE_FILE}.user"
			rm -f /tmp/tree_output.user
		fi
		exit $ret
	)
	return $?
}

# Check if a device is an LVM2 PV, and if so print the VG name
find_lvm_vg_name() {
	TRACE_FUNC
	local DEVICE VG part
	DEVICE="$1"

	# closing fd10 should be handled by callers (detect_root_device now
	# closes it for commands before invoking us).  leaving this here can
	# interfere with future uses of fd10 elsewhere in the same shell.
	# (Note: previous versions contained a hack to close it here; see
	# commit 700ed0c141.)

	mkdir -p /tmp/root-hashes-gui
	# Try to query whether DEVICE is an LVM physical volume.  On systems
	# without LVM the command may not exist; treat that like "not a PV".
	if ! run_lvm pvs --noheadings -o vg_name "$DEVICE" >/tmp/root-hashes-gui/lvm_vg; then
		# It's not an LVM PV, or lvm failed entirely.
		DEBUG "lvm pvs failed for $DEVICE"
		# try any children shown by lsblk (handles LUKS containers with
		# internal partitions such as dm-0, dm-1 etc).
		if command -v lsblk >/dev/null 2>&1; then
			DEBUG "find_lvm_vg_name: lsblk children of $DEVICE"
			for part in $(lsblk -np -l -o NAME "$DEVICE" | tail -n +2); do
				[ -b "$part" ] || continue
				DEBUG "find_lvm_vg_name: testing child $part"
				if run_lvm pvs --noheadings -o vg_name "$part" >/tmp/root-hashes-gui/lvm_vg; then
					VG="$(awk 'NF {print $1; exit}' /tmp/root-hashes-gui/lvm_vg)"
					[ -n "$VG" ] && {
						echo "$VG"
						return 0
}

			fi
			done
		fi
		DEBUG "find_lvm_vg_name: $DEVICE is not an LVM PV"
		return 1
	fi

	VG="$(awk 'NF {print $1; exit}' /tmp/root-hashes-gui/lvm_vg)"
	if [ -z "$VG" ]; then
		DEBUG "Could not find LVM2 VG from lvm pvs output:"
		DEBUG "$(cat /tmp/root-hashes-gui/lvm_vg)"
		return 1
	fi

	echo "$VG"
}

# If a block device is a partition, check if it is a bios-grub partition on a
# GPT-partitioned disk.
is_gpt_bios_grub() {
	TRACE_FUNC
	# $1 is the device path being tested (e.g. /dev/vda1)
	local PART_DEV="$1"
	DEBUG "PART_DEV=$PART_DEV"

	# identify the base device and partition number using shell parameter expansion
	local partname device number
	partname=$(basename "$PART_DEV")

	# Split trailing digits from the base device name.
	number="${partname##*[!0-9]}"
	if [ -z "$number" ]; then
		DEBUG "cannot parse partition name '$partname'"
		return 1 # not a recognised partition
	fi

	device="${partname%"$number"}"
	# nvme/mmc names include an extra 'p' separator before the partition
	# number (e.g. nvme0n1p2, mmcblk0p1). Remove only that separator.
	if [[ "$device" == *p && "${device%p}" == *[0-9] ]]; then
		device="${device%p}"
	fi

	if [ -z "$device" ]; then
		DEBUG "cannot parse partition device from '$partname'"
		return 1
	fi

	DEBUG "DEVICE=$device NUMBER=$number"

	# GPT disks list type in column 5; fall through to 1 otherwise
	if [ "$(fdisk -l "/dev/$device" 2>/dev/null | awk '$1 == '"$number"' {print $5}')" == grub ]; then
		return 0
	fi
	return 1
}

# Test if a block device could be used as /boot - we can mount it and it
# contains /boot/grub* files.  (Here, the block device could be a partition or
# an unpartitioned device.)
#
# If the device is a partition, its type is also checked.  Some common types
# that we definitely can't mount this way are excluded to silence spurious exFAT
# errors.
#
# Any existing /boot is unmounted.  If the device is a reasonable boot device,
# it's left mounted on /boot.
mount_possible_boot_device() {
	TRACE_FUNC

	local BOOT_DEV="$1"
	local PARTITION_TYPE

	# Unmount anything on /boot.  Ignore failure since there might not be
	# anything.  If there is something mounted and we cannot unmount it for
	# some reason, mount will fail, which is handled.
	umount /boot 2>/dev/null || true

	# Skip bios-grub partitions on GPT disks, LUKS partitions, and LVM PVs,
	# we can't mount these as /boot.
	# Skip partitions we definitely can't mount for /boot.  Log each reason.
	if is_gpt_bios_grub "$BOOT_DEV"; then
		DEBUG "$BOOT_DEV is GPT BIOS/GRUB partition, skipping"
		return 1
	fi
	if cryptsetup isLuks "$BOOT_DEV"; then
		DEBUG "$BOOT_DEV is a LUKS volume, skipping"
		LUKS_PARTITION_DETECTED="y"
		return 1
	fi
	if find_lvm_vg_name "$BOOT_DEV" >/dev/null; then
		DEBUG "$BOOT_DEV is an LVM PV, skipping"
		return 1
	fi

	# Get the size of BOOT_DEV in 512-byte sectors
	sectors=$(blockdev --getsz "$BOOT_DEV")

	# Check if the partition is small (less than 2MB, which is 4096 sectors)
	if [ "$sectors" -lt 4096 ]; then
		DEBUG "Partition $BOOT_DEV is very small, likely BIOS boot. Skipping mount."
		return 1
	else
		DEBUG "Try mounting $BOOT_DEV as /boot"
		if mount -o ro "$BOOT_DEV" /boot >/dev/null 2>&1; then
			if ls -d /boot/grub* >/dev/null 2>&1; then
				# This device is a reasonable boot device
				return 0
			fi
			umount /boot || true
		fi
	fi

	return 1
}

# detect and set /boot device
# mount /boot if successful
detect_boot_device() {
	TRACE_FUNC
	local devname mounted_boot_dev
	DEBUG "CONFIG_BOOT_DEV=$CONFIG_BOOT_DEV"
	# If /boot is already mounted and appears to be a valid boot tree, just
	# use its device.  This avoids remount churn and makes the later lookup
	# fast.
	mounted_boot_dev="$(awk '$2=="/boot" {print $1; exit}' /proc/mounts)"
	if [ -n "$mounted_boot_dev" ] && ls -d /boot/grub* >/dev/null 2>&1; then
		CONFIG_BOOT_DEV="$mounted_boot_dev"
		DEBUG "Using already-mounted /boot device as CONFIG_BOOT_DEV=$CONFIG_BOOT_DEV"
		return 0
	fi
	# unmount /boot to be safe
	cd / && umount /boot 2>/dev/null

	# check $CONFIG_BOOT_DEV if set/valid
	if [ -e "$CONFIG_BOOT_DEV" ] && mount_possible_boot_device "$CONFIG_BOOT_DEV"; then
		# CONFIG_BOOT_DEV is valid device and contains an installed OS
		return 0
	fi

	# generate list of possible boot devices
	fdisk -l 2>/dev/null | grep "Disk /dev/" | cut -f2 -d " " | cut -f1 -d ":" >/tmp/disklist

	# Check each possible boot device
	for i in $(cat /tmp/disklist); do
		# If the device has partitions, check the partitions instead
		if device_has_partitions "$i"; then
			devname="$(basename "$i")"
			partitions=("/sys/class/block/$devname/$devname"?*)
		else
			partitions=("$i") # Use the device itself
		fi
		for partition in "${partitions[@]}"; do
			partition_dev=/dev/"$(basename "$partition")"
			# No sense trying something we already tried above
			if [ "$partition_dev" = "$CONFIG_BOOT_DEV" ]; then
				continue
			fi
			# If this is a reasonable boot device, select it and finish
			if mount_possible_boot_device "$partition_dev"; then
				CONFIG_BOOT_DEV="$partition_dev"
				return 0
			fi
		done
	done

	# no valid boot device found
	WARN "Unable to locate /boot files on any mounted disk"
	DEBUG "detect_boot_device: failed to find a bootable device"
	return 1
}

scan_boot_options() {
	TRACE_FUNC
	local bootdir config option_file
	bootdir="$1"
	config="$2"
	option_file="$3"

	if [ -r "$option_file" ]; then rm "$option_file"; fi
	find "$bootdir" -name "$config" -print | while IFS= read -r i; do
		case "$i" in
		*EFI* | *efi* | *x86_64-efi*) continue ;;
		esac
		DO_WITH_DEBUG kexec-parse-boot.sh "$bootdir" "$i" >>"$option_file"
	done
	# Summarize parse results: count how many boot entries were produced
	# and flag any that look like parse artifacts (isolinux menu stubs).
	if [ -s "$option_file" ]; then
		local _entry_count _artifact_count
		_entry_count=$(wc -l < "$option_file" 2>/dev/null || echo 0)
		_artifact_count=$(grep -cE '^\s*->' "$option_file" 2>/dev/null || echo 0)
		DEBUG "scan_boot_options: parsed $_entry_count entries ($_artifact_count likely artifacts) from $bootdir"
	fi
	# FC29/30+ may use BLS format grub config files
	# https://fedoraproject.org/wiki/Changes/BootLoaderSpecByDefault
	# only parse these if $option_file is still empty.
	# BLS entries may be at loader/entries (bare partition) or
	# boot/loader/entries (ISO loopback mount or embedded config).
	local bls_dir=""
	[ -d "$bootdir/loader/entries" ] && bls_dir="$bootdir/loader/entries"
	[ -z "$bls_dir" ] && [ -d "$bootdir/boot/loader/entries" ] && bls_dir="$bootdir/boot/loader/entries"
	if [ ! -s "$option_file" ] && [ -n "$bls_dir" ]; then
		find "$bootdir" -name "$config" -print | while IFS= read -r i; do
			kexec-parse-bls.sh "$bootdir" "$i" "$bls_dir" >>"$option_file"
		done
	fi
}

# truncate a file to a size only if it is longer (busybox truncate lacks '<' and
# always sets the file size)
truncate_max_bytes() {
	local bytes="$1"
	local file="$2"
	if [ "$(stat -c %s "$file")" -gt "$bytes" ]; then
		truncate -s "$bytes" "$file"
	fi
}

# Busybox xxd -p pads the last line with spaces to 60 columns, which not only
# trips up many scripts, it's very difficult to diagnose by looking at the
# output.  Delete line breaks and spaces to really get plain hex output.
tohex_plain() {
	xxd -p | tr -d '\n '
}

# Busybox xxd -p -r silently truncates lines longer than 60 hex chars.
# Shorter lines are OK, spaces are OK, and even splitting a byte across lines is
# allowed, so just fold the text to maximum 60 column lines.
# Note that also unlike GNU xxd, non-hex chars in input corrupt the output (GNU
# xxd ignores them).
fromhex_plain() {
	fold -w 60 | xxd -p -r
}

print_battery_charge() {
	local battery
	battery="$1"
	echo "$((100 * $(cat "${battery}/charge_now") / $(cat "${battery}/charge_full")))"
}

print_battery_health() {
	local battery
	battery="$1"
	echo "$((100 * $(cat "${battery}/charge_full") / $(cat "${battery}/charge_full_design")))"
}

print_battery_name() {
	local battery
	battery="$1"
	echo "$(cat "${battery}/manufacturer") $(cat "${battery}/model_name")"
}

# Print the charging and health state for all batteries
# Print the maufacturer and model name for each battery if more than 1
# The printed string contains the full formatting including leading an trailing "\n" strings
print_battery_state() {
	local battery_status
	battery_status=""
	all_batteries=(/sys/class/power_supply/BAT*)
	for battery in "${all_batteries[@]}"; do
		if [[ -d "${battery}" ]]; then
			battery_name="Battery"
			if [ "${#all_batteries[@]}" -gt 1 ]; then
				battery_name+=" $(print_battery_name "${battery}")"
			fi
			battery_status+="\n${battery_name} charge: $(print_battery_charge "${battery}")%"
			battery_status+="\n${battery_name} health: $(print_battery_health "${battery}")%"
		fi
	done
	echo "${battery_status:+${battery_status}\n}"
}

generate_random_mac_address() {
	#Borrowed from https://stackoverflow.com/questions/42660218/bash-generate-random-mac-address-unicast
	hexdump -n 6 -ve '1/1 "%.2x "' /dev/urandom | awk -v a="2,6,a,e" -v r="$RANDOM" 'BEGIN{srand(r);}NR==1{split(a,b,",");r=int(rand()*4+1);printf "%s%s:%s:%s:%s:%s:%s\n",substr($1,0,1),b[r],$2,$3,$4,$5,$6}'
}

# Add a command to be invoked at exit.  (Note that trap EXIT replaces any
# existing handler.)  Commands are invoked in reverse order, so they can be used
# to clean up resources, etc.
# The parameters are all executed as-is and do _not_ require additional quoting
# (unlike trap).  E.g.:
# at_exit shred "$file" #<-- file is expanded when calling at_exit, no extra quoting needed
at_exit() {
	AT_EXIT_HANDLERS+=("$@") # Command and args
	AT_EXIT_HANDLERS+=("$#") # Number of elements in this command
}

# Array of all exit handler command arguments with lengths of each command at
# the end.  For example:
#   at_exit echo hello
#   at_exit echo a b c
# results in:
# AT_EXIT_HANDLERS=(echo hello 2 echo a b c 4)

AT_EXIT_HANDLERS=()
# Each handler is an array AT_EXIT_HANDLER_{i}
run_at_exit_handlers() {
	local cmd_pos cmd_len
	cmd_pos="${#AT_EXIT_HANDLERS[@]}"
	# Silence trace if there are no handlers, this is common and occurs a lot
	[ "$cmd_pos" -gt 0 ] && DEBUG "Running at_exit handlers"
	while [ "$cmd_pos" -gt 0 ]; do
		cmd_pos="$((cmd_pos - 1))"
		cmd_len="${AT_EXIT_HANDLERS[$cmd_pos]}"
		cmd_pos="$((cmd_pos - cmd_len))"
		"${AT_EXIT_HANDLERS[@]:$cmd_pos:$cmd_len}"
	done
}
trap run_at_exit_handlers EXIT

# Helper function to generate diceware passphrase
generate_passphrase() {
	usage_generate_passphrase() {
		DEBUG "Usage: generate_passphrase --dictionary|-d <dictionary_file> [--number_words|-n <num_words>] [--max_length|-m <max_size>] [--lowercase|-l]"
		DEBUG "Generates a passphrase using a Diceware dictionary."
		DEBUG "  --dictionary|-d <dictionary_file>  Path to the Diceware dictionary file (defaults to /etc/diceware_dictionaries/eff_short_wordlist_2_0.txt )."
		DEBUG "  [--number_words|-n <num_words>]  Number of words in the passphrase (default: 3)."
		DEBUG "  [--max_length|-m <max_size>]  Maximum size of the passphrase (default: 256)."
		DEBUG "  [--lowercase|-l]  Use lowercase words (default: false)."
	}

	# Helper subfunction to get a random word from the dictionary
	get_random_word_from_dictionary() {
		local dictionary_file="$1" lines random

		lines="$(wc -l <"$dictionary_file")"
		# 4 random bytes are used to reduce modulo bias to an acceptable
		# level.  4 bytes with modulus 1296 results in 0.000003% bias
		# toward the first 1263 words.
		random="$(dd if=/dev/random bs=4 count=1 status=none | hexdump -e '1/4 "%u\n"')"
		((random %= lines))
		((++random)) # tail's line count is 1-based
		tail -n +"$random" "$dictionary_file" | head -1 | cut -d$'\t' -f2
	}

	TRACE_FUNC
	local dictionary_file="/etc/diceware_dictionaries/eff_short_wordlist_2_0.txt"
	local num_words=3
	local max_size=256
	local lowercase=false

	# Parse parameters
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		--dictionary | -d)
			dictionary_file="$2"
			shift
			;;
		--lowercase | -l)
			lowercase=true
			;;
		--number_words | -n)
			if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -le 0 ]]; then
				WARN "generate_passphrase: invalid number of words: $2"
				usage_generate_passphrase
				return 1
			fi
			num_words="$2"
			shift
			;;
		--max_length | -m)
			if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -le 0 ]]; then
				WARN "generate_passphrase: invalid maximum size: $2"
				usage_generate_passphrase
				return 1
			fi
			max_size="$2"
			shift
			;;
		*)
			WARN "generate_passphrase: unknown parameter: $1"
			usage_generate_passphrase
			return 1
			;;
		esac
		shift
	done

	# Validate dictionary file
	if [[ -z "$dictionary_file" || ! -f "$dictionary_file" ]]; then
		WARN "generate_passphrase: dictionary file not found or not provided: $dictionary_file"
		usage_generate_passphrase
		return 1
	fi

	local passphrase=""
	local word=""

	for ((i = 0; i < num_words; ++i)); do
		word=$(get_random_word_from_dictionary "$dictionary_file")
		if [[ "$lowercase" == "false" ]]; then
			word=${word^} # Capitalize the first letter
		fi
		passphrase+="$word "
		if [[ ${#passphrase} -gt $max_size ]]; then
			DEBUG "Passphrase exceeds max size: $max_size, removing last word"
			passphrase=${passphrase% *} # Remove the last word if it exceeds max_size
			break
		fi
	done

	#Remove passphrase trailing space from passphrase+="$word"
	passphrase=${passphrase% }
	echo "$passphrase"
	return 0
}

# Load a keymap.  Normally used to load the configured keymap, also used in
# config to test a keymap.
#
# This always resets the keymap before loading, so the result is the same even
# if other keymaps had been loaded before, and even if the new keymap doesn't
# define all keys (or if none was given).
#
# If the board defines an override keymap, it is always loaded after the keymap.
# (For example, tablets map volume up/down and power to up/down/enter, and we
# do not want a custom keymap to override that.)
#
# If the board didn't include loadkeys, this is a no-op.
load_keymap() {
	TRACE_FUNC

	if ! [ -x /bin/loadkeys ]; then
		return 0
	fi

	# Reset the keymap
	DEBUG "Loading linux kernel shipped keyboard layout keymap: share/keymaps/defkeymap.map"
	DO_WITH_DEBUG loadkeys --default

	# Load the specified keymap, if given
	if [ -n "$1" ]; then
		if [ -f "$1" ]; then
			DEBUG "Loading keyboard keymap: $1"
			DO_WITH_DEBUG loadkeys "$1"
		else
			# We can continue by ignoring the specified keymap, but
			# this might mean keys map unexpectedly.  If this is
			# desired, update or clear the keymap setting to silence
			# the warning.
			WARN "Keymap $1 does not exist, continuing without keymap"
		fi
	fi

	# Load the board keymap.  These only define the keys that must always
	# have a specific function on that board.
	if [ -f /etc/board_keys.map ]; then
		DO_WITH_DEBUG loadkeys /etc/board_keys.map
	fi
}

# fail_unseal - called by unseal-hotp.sh and unseal-totp.sh on failure.
# If HEADS_NONFATAL_UNSEAL=y (set by callers that handle failure themselves,
# e.g. gui-init's integrity report), log at DEBUG and return 1 so the caller
# can decide what to do.  Otherwise DIE, which is appropriate when the unseal
# script is run standalone and failure is unrecoverable.
fail_unseal() {
	TRACE_FUNC
	if [ "$HEADS_NONFATAL_UNSEAL" = "y" ]; then
		DEBUG "nonfatal $(basename "$0") failure: $*"
		return 1
	fi
	DIE "$*"
}

# Map blkid filesystem type to kernel module name for initrd compatibility checks.
# The kernel module for a filesystem is almost always the same as the blkid TYPE
# string (ext4 -> ext4, btrfs -> btrfs, xfs -> xfs).
# Only vfat/msdos are exceptions (kernel module is "fat", not "vfat").
initrd_fs_type_to_kmod() {
	case "$1" in
	vfat|msdos)	echo "fat" ;;
	*)		echo "$1" ;;
	esac
}

# Check whether a kernel binary has a filesystem driver built-in
# (CONFIG_EXFAT_FS=y style).  Decompresses the kernel at each
# compression magic offset and greps for built-in filesystem init
# symbols.  Only fires when no initrd module was found -- the
# uncommon path (most ISOs ship the module as .ko in initramfs).
# Built-in filesystem drivers register stable init symbols:
#   exFAT:   init_exfat_fs, exfat_init_fs_context
#   ext4:    ext4_init_fs, ext4_init_fs_context
#   vfat:    init_vfat_fs
#   FAT:     init_fat_fs, fat_init_fs_context
#   ntfs3:   init_ntfs3_fs
# Args: vmlinuz_path  kernel_mod (e.g. "exfat", "ext4", "fat")
# Returns: "OK" if built-in symbol found, "" if not.
_check_kernel_for_fs_builtin() {
	local vmlinuz="$1" kmod="$2"
	[ -f "$vmlinuz" ] || return 0
	# Build grep patterns for this filesystem type
	local _patterns=""
	case "$kmod" in
		exfat) _patterns="init_exfat_fs exfat_init_fs_context" ;;
		ext4)  _patterns="ext4_init_fs ext4_init_fs_context ext4_fill_super" ;;
		fat)   _patterns="init_fat_fs init_vfat_fs fat_init_fs_context" ;;
		ntfs3) _patterns="init_ntfs3_fs" ;;
		*)     return 0 ;;
	esac

	# Read bzImage header to find compressed payload offset
	local _setup_sects _after_setup
	_setup_sects=$(dd if="$vmlinuz" bs=1 skip=497 count=1 2>/dev/null | xxd -p)
	[ "$_setup_sects" = "00" ] && _setup_sects=04
	_after_setup=$((0x$_setup_sects * 512))

	local _zstd_cmd=""
	command -v zstd-decompress >/dev/null 2>&1 && _zstd_cmd="zstd-decompress -d"
	[ -z "$_zstd_cmd" ] && command -v zstd >/dev/null 2>&1 && _zstd_cmd="zstd -d"
	[ -z "$_zstd_cmd" ] && _zstd_cmd="zstd-decompress -d"

	local _hex _pos _magic _cmd _offset _decomp_file _dsize
	# Use direct dd (not tail|dd pipe): FUSE filesystems (fuseiso) return
	# data in 8 KiB chunks per read(); piping tail through dd bs=32768
	# would only get 8192 bytes from the first chunk, missing the payload.
	# Read 64 KiB probe window to cover ~53 KiB gaps seen on modern kernels.
	# Same pattern as _check_kernel_probe_driver.  See ADR 0001.
	_hex=$(dd if="$vmlinuz" bs=1 skip="$_after_setup" count=65536 2>/dev/null | tohex_plain)
	[ -z "$_hex" ] && return 0

	for ((_pos = 0; _pos <= ${#_hex} - 12; _pos += 2)); do
		_magic="${_hex:$_pos:6}"
		case "$_magic" in
			1f8b*|1f9e*)	_cmd="gunzip -c" ;;
			fd37*)		_cmd="xzcat" ;;
			28b5*)		[ -n "$_zstd_cmd" ] && _cmd="$_zstd_cmd" || continue ;;
			*)		continue ;;
		esac
		_offset=$((_after_setup + _pos / 2))
		_decomp_file=$(mktemp -p /tmp -t vmlinux.XXXXXX)
		tail -c+$((_offset + 1)) "$vmlinuz" 2>/dev/null | $_cmd > "$_decomp_file" 2>/dev/null
		_dsize=$(stat -c %s "$_decomp_file" 2>/dev/null || echo 0)
		if [ "$_dsize" -gt 0 ] 2>/dev/null; then
			for _pat in $_patterns; do
				grep -qF "$_pat" "$_decomp_file" 2>/dev/null && {
					rm -f "$_decomp_file"
					echo "OK"
					return 0
				}
			done
		fi
		rm -f "$_decomp_file"
	done
	return 0
}

# Check an unpacked initramfs directory for a specific kernel module.
# Args: unpack_dir  kernel_mod (e.g. "exfat", "ext4", "fat")
# Returns: ""   = initramfs has no .ko files at all (cannot verify)
#          "OK" = module found as .ko file or listed in modules.builtin
#          "!"  = initramfs has loadable modules but none matching kernel_mod
check_initramfs_for_module() {
	TRACE_FUNC
	local unpack_dir="$1"
	local kernel_mod="$2"
	local ko_files
	ko_files=$(find "$unpack_dir" -name "*.ko*" -type f 2>/dev/null | head -1) || true
	[ -z "$ko_files" ] && { DEBUG "check_initramfs_for_module($kernel_mod): no .ko files in initramfs"; return 0; }

	local ko_match
	# Find exact module name, not substring (fat must not match exfat.ko).
	ko_match=$(find "$unpack_dir" -name "${kernel_mod}.ko*" -type f 2>/dev/null | head -1) || true
	if [ -n "$ko_match" ]; then
		DEBUG "check_initramfs_for_module($kernel_mod): found $ko_match"
		echo "OK"
	elif grep -q "/${kernel_mod}\.ko$" "$unpack_dir/lib/modules/"*/modules.builtin 2>/dev/null; then
		DEBUG "check_initramfs_for_module($kernel_mod): in modules.builtin"
		echo "OK"
	else
		DEBUG "check_initramfs_for_module($kernel_mod): modules present but not found"
		echo "!"
	fi
}

# Check an unpacked initramfs for USB file-based ISO boot capability.
# Scans ALL files in the unpacked initramfs for known isoboot keywords
# (findiso, iso-scan/filename, fromiso, dmsquash-live-root, rd.live.image,
# casper).  If ANY file contains these strings, the initrd likely has code
# to locate and boot from an ISO file on a mounted filesystem.
#
# This is a CONTENT-BASED scan, not path-based: we grep across all files
# regardless of their location or distribution-specific directory layout.
# This catches dracut-live, casper, NixOS stage-1, live-boot, and any
# custom initramfs that references these boot parameters.
#
# Debian DVD installer and openSUSE Tumbleweed DVD initrds lack these
# keywords  --  they scan for physical CDROM devices (iso9660), not ISO files
# on a filesystem.  Correctly identified as non-isobootable.
#
# Args: unpack_dir   --  path to an already-unpacked initramfs directory
# Returns: "OK" if any isoboot keyword found, "" if none.
#
# Detection approach: content-based grep across ALL unpacked files (not
# path-based).  Any initramfs that supports file-based ISO booting will
# have scripts referencing these parameters somewhere in its files,
# regardless of distribution or directory layout.
#
# Keywords searched (by framework):
#   findiso         --  Debian live-boot, NixOS stage-1
#   iso-scan        --  Ubuntu casper, Fedora dracut
#   fromiso         --  GRUB loopback (legacy)
#   dmsquash-live-root  --  Fedora dracut-live
#   rd.live.image   --  Fedora dracut
#   casper          --  Ubuntu, PureOS
#   live-media      --  Debian live-boot, Tails (device filter)
#   kiwi-live       --  openSUSE kiwi (dracut-kiwi-live module)
#   archiso         --  Arch Linux live ISO
#   boot=live       --  Debian live-boot activation flag
_check_initramfs_can_isoboot() {
	local unpack_dir="$1"
	# Called per initramfs in _check_initramfs_compat loop -- no TRACE_FUNC to avoid log noise
	# Use -E for extended regex (| alternation, no backslash needed).
	# Keywords cover:
	#   findiso         --  Debian live-boot, NixOS stage-1
	#   iso-scan        --  Ubuntu casper, Fedora dracut
	#   fromiso         --  GRUB loopback
	#   dmsquash-live-root  --  Fedora dracut-live
	#   rd.live.image   --  Fedora dracut
	#   casper          --  Ubuntu, PureOS
	#   live-media      --  Debian live-boot, Tails
	#   kiwi-live       --  openSUSE kiwi
	#   archiso         --  Arch Linux live ISO
	#   boot=live       --  Debian live-boot activation
	local _grep_out
	# Exclude kernel modules (.ko, .ko.xz)  --  compiled binaries never
	# contain isoboot keywords.  BusyBox grep lacks --exclude/-I,
	# so use find to skip them before piping to grep.
	_grep_out=$(find "$unpack_dir" -type f ! -name "*.ko" ! -name "*.ko.xz" ! -name "*.ko.zst" 2>/dev/null | \
		xargs grep -lsE "findiso|iso-scan|fromiso|dmsquash-live-root|rd\.live\.image|casper|live-media|kiwi-live|archiso|boot=live" \
		2>/dev/null | head -1) || true
	if [ -n "$_grep_out" ]; then
		DEBUG "_check_initramfs_can_isoboot: match in $_grep_out"
		echo "OK"
		return 0
	fi
	DEBUG "_check_initramfs_can_isoboot: no match in $unpack_dir"
	return 0
}

# Display driver detection checks the target kernel's built-in drivers.
# The kernel's sysfb_init() binds vesafb/vesadrm/simpledrm during kernel
# initialization, before any initramfs code runs.  Detection uses
# _check_kernel_probe_driver() which decompresses the bzImage and searches
# for built-in driver symbols.

show_totp_until_esc() {
	local now_str status_line current_totp ch
	# totp_ever_unsealed: set to 1 on first successful unseal; used to detect
	# mid-session secret wipe (e.g. another console entered recovery shell).
	local last_totp_time=0 last_totp="" totp_ever_unsealed=0

	# Use the same terminal the user is actively interacting with.
	# HEADS_TTY is set by gui-init (after cttyhack) to the actual interactive
	# terminal  --  both output (status line) and input (Esc / Enter detection)
	# must use the same device.  Falls back to stdout/stdin (file descriptor
	# 1/0) when HEADS_TTY is not set so that callers' redirections are
	# respected (same behaviour as the original pre-HEADS_TTY code).
	local interactive_tty="${HEADS_TTY}"

	# Serial consoles (ttyS*, ttyUSB*, ttyAMA*) do not reliably support raw-mode
	# single-character reads: bash's "read -n 1" puts the tty into raw mode via
	# tcsetattr, but some serial line disciplines block indefinitely despite the
	# -t timeout.  On serial we accept Enter (line-mode read) instead of Esc.
	local is_serial=0
	if heads_tty_is_serial "$interactive_tty"; then
		is_serial=1
	fi

	if [ -n "$interactive_tty" ]; then
		printf "\n" >"$interactive_tty" 2>/dev/null # reserve a line for updates
	else
		printf "\n" # reserve a line for updates
	fi

	# Drain any pending keystrokes (e.g. a stray Esc from the previous prompt).
	# NOTE: -t 0 in BusyBox returns immediately (poll-only, does not consume
	# data) so we use -t 0.01 to actually read and discard each byte.
	if [ "$is_serial" = "0" ]; then
		if [ -n "$interactive_tty" ]; then
			while IFS= read -r -t 0.01 -n 1 junk <"$interactive_tty" 2>/dev/null; do :; done
		else
			while IFS= read -r -t 0.01 -n 1 junk; do :; done
		fi
	fi

	local last_sec=0
	while :; do
		now_str=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
		local now_epoch
		now_epoch=$(date +%s)
		local now_sec=$now_epoch

		# Refresh TOTP once per second for fresh validation.
		if [ "$CONFIG_TPM" = "y" ] && [ "$CONFIG_TOTP_SKIP_QRCODE" != "y" ]; then
			if [ $((now_epoch - last_totp_time)) -ge 1 ] || [ -z "$last_totp" ]; then
				if current_totp=$(unseal-totp.sh 2>/dev/null); then
					last_totp="$current_totp"
					last_totp_time=$now_epoch
					totp_ever_unsealed=1
				elif [ "$totp_ever_unsealed" = "1" ]; then
					# Previously succeeded but now fails: TPM secrets were wiped
					# mid-session (e.g. another console entered the recovery shell).
					DIE "TOTP secret no longer accessible: TPM secrets were wiped. Boot integrity cannot be confirmed."
				else
					# Never succeeded yet; clear and retry next second
					last_totp=""
					last_totp_time=0
				fi
			fi
		fi

		# Only update display when the second changes to avoid flicker
		if [ "$now_sec" -ne "$last_sec" ]; then
			last_sec=$now_sec
			local totp_field=""
			if [ "$CONFIG_TPM" = "y" ] && [ "$CONFIG_TOTP_SKIP_QRCODE" != "y" ]; then
				if [ -n "$last_totp" ]; then
					totp_field=" | TOTP code: $last_totp"
				else
					totp_field=" | TOTP unavailable"
				fi
			fi
			if [ "$is_serial" = "1" ]; then
				status_line="\033[1m[$now_str]${totp_field} | Press Enter to continue...\033[0m"
			else
				status_line="\033[1m[$now_str]${totp_field} | Press Esc to continue...\033[0m"
			fi
			if [ -n "$interactive_tty" ]; then
				printf "\r%b\033[K" "$status_line" >"$interactive_tty" 2>/dev/null
			else
				printf "\r%b\033[K" "$status_line"
			fi
		fi

		if [ "$is_serial" = "1" ]; then
			# Line-mode read: no raw mode required; times out after 1 s.
			# Any input (Enter) continues.
			if [ -n "$interactive_tty" ]; then
				if IFS= read -r -t 1 ch <"$interactive_tty" 2>/dev/null; then
					printf "\n\n" >"$interactive_tty" 2>/dev/null
					return 0
				fi
			else
				if IFS= read -r -t 1 ch; then
					printf "\n\n"
					return 0
				fi
			fi
		else
			# Framebuffer: raw single-char poll (200 ms).  ESC continues.
			if [ -n "$interactive_tty" ]; then
				if IFS= read -r -t 0.2 -n 1 ch <"$interactive_tty" 2>/dev/null; then
					if [ "$ch" = $'\e' ]; then
						printf "\n\n" >"$interactive_tty" 2>/dev/null
						return 0
					fi
					# Ignore other keys and continue polling
				fi
			else
				if IFS= read -r -t 0.2 -n 1 ch; then
					if [ "$ch" = $'\e' ]; then
						printf "\n\n"
						return 0
					fi
			# Ignore other keys and continue polling
			fi
		fi
	fi
	done
}

# Check a decompressed kernel binary for built-in framebuffer driver symbols.
# With Heads' VLFB kexec patch (orig_video_isVGA=0x23, patch 0003), sysfb
# creates "vesa-framebuffer".  The following built-in drivers can bind:
#
# Priority 1: vesadrm (DRM sysfb, kernel 7.x SUSE path)
#   Symbol: vesadrm_probe / vesadrm_platform_driver_init
#   Binds to: "vesa-framebuffer"
# Priority 2: vesafb (fbdev, kernel 5.x/6.x)
#   Symbol: vesafb_probe / vesafb_driver_init
#   Binds to: "vesa-framebuffer" (5.x/6.x fbdev)
# Priority 3: simpledrm + SYSFB_SIMPLEFB (simpledrm via sysfb)
#   Symbol: simpledrm_probe / simpledrm_platform_driver_init
#   Also checks: sysfb_parse_mode (confirms simple-framebuffer device)
#   Binds to: "simple-framebuffer" (via sysfb_parse_mode)
#
# Args: vmlinuz_path  driver_name  [setup_sects  after_setup  probe_hex  zstd_cmd]
# Returns: "OK:<symbol>" if symbol found (e.g. "OK:vesadrm", "OK:vesafb", "OK:simpledrm_probe"),
#   "" if decompressed but symbol not found,
#   "!" if decompression failed
_check_kernel_probe_driver() {
	local vmlinuz="$1" driver="$2"
	local setup_sects="${3:-}" after_setup="${4:-}" probe_hex="${5:-}" zstd_cmd="${6:-}"
	# Called per kernel entry in check_kernel_for_fb loop -- no TRACE_FUNC to avoid log noise

	if [ -z "$probe_hex" ]; then
		setup_sects=$(dd if="$vmlinuz" bs=1 skip=497 count=1 2>/dev/null | xxd -p)
		[ "$setup_sects" = "00" ] && setup_sects=04
		after_setup=$((0x$setup_sects * 512))
		# Use direct dd with skip/count (no tail+dd pipe) because FUSE
		# filesystems (fuseiso) return data in 8 KiB chunks per read().
		# piping tail | dd bs=32768 count=1 would only get 8192 bytes
		# from the first chunk, missing the compressed payload entirely.
		# Read 64 KiB probe window: some kernels (EFI handoff) have a
		# large gap between setup sectors and compressed payload.
		probe_hex=$(dd if="$vmlinuz" bs=1 skip="$after_setup" count=65536 2>/dev/null | tohex_plain)
		[ -z "$probe_hex" ] && return 0

		command -v zstd-decompress >/dev/null 2>&1 && zstd_cmd="zstd-decompress -d"
		[ -z "$zstd_cmd" ] && command -v zstd >/dev/null 2>&1 && zstd_cmd="zstd -d"
		# Last resort: try zstd-decompress even if command -v failed.
		# BusyBox's applet name resolution strips the -decompress suffix
		# and runs the zstd applet with -d, but this only works when the
		# applet is invoked (pipe), not via command -v (no symlink exists).
		# Matches unpack_initramfs.sh line 110 behavior.
		[ -z "$zstd_cmd" ] && zstd_cmd="zstd-decompress -d"

		# Fast path: try strings on raw kernel before decompression.
		# Single strings+grep pass checks ALL relevant driver symbols
		# in one go.  Uses grep -F (fixed strings)  --  faster than
		# per-symbol grep -q loops on compressed kernels.
		# head -1 takes the first match; || true prevents pipefail
		# abort when head terminates the pipe early (SIGPIPE).
		local _fast_path_symbol
		_fast_path_symbol=$(strings "$vmlinuz" 2>/dev/null | grep -oF \
			-e "${driver}_probe" -e "${driver}_pci_probe" \
			-e "${driver}_driver_init" -e "${driver}_pci_driver_init" \
			-e "simpledrm_probe" -e "simpledrm_driver_init" \
		| head -1) || true
		if [ -n "$_fast_path_symbol" ]; then
			# Driver symbol found in raw strings: return OK immediately.
			# simpledrm found: fall through to decompression to verify
			# the "simple-framebuffer" device string (not in compressed
			# section of raw bzImage, so not visible via strings).
			if ! echo "$_fast_path_symbol" | grep -q 'simpledrm'; then
				DEBUG "_check_kernel_probe_driver: $driver: fast path found $_fast_path_symbol"
				echo "OK:$_fast_path_symbol"
				return 0
			fi
			DEBUG "_check_kernel_probe_driver: $driver: fast path found simpledrm, verifying via decompression"
		fi
		DEBUG "_check_kernel_probe_driver: $driver: fast path found nothing, proceeding to decompression"
	fi

	DEBUG "_check_kernel_probe_driver: $driver: probe_hex has ${#probe_hex} hex chars (${#probe_hex} chars = ${#probe_hex} hex nibbles)"
	local pos magic decomp_ok="n" last_offset="-1"
	for ((pos = 0; pos <= ${#probe_hex} - 12; pos += 2)); do
		magic="${probe_hex:$pos:6}"
		local cmd="" offset=""
		case "$magic" in
			1f8b*|1f9e*)	cmd="gunzip -c" ;;
			fd37*)		cmd="xzcat" ;;
			28b5*)		[ -n "$zstd_cmd" ] && cmd="$zstd_cmd" || continue ;;
			*)		continue ;;
		esac
		offset=$((after_setup + pos / 2))
		[ "$((offset - last_offset))" -lt 4 ] 2>/dev/null && [ "$last_offset" -ge 0 ] && continue

		DEBUG "_check_kernel_probe_driver: $driver: found ${magic:0:4} magic at offset $offset, trying $cmd"

		local decomp_file
		decomp_file=$(mktemp -p /tmp -t vmlinux.XXXXXX)
		tail -c+$((offset + 1)) "$vmlinuz" 2>/dev/null | $cmd > "$decomp_file" 2>/dev/null
		local dsize=$(stat -c %s "$decomp_file" 2>/dev/null || echo 0)
		if [ "$dsize" -gt 0 ] 2>/dev/null; then
			decomp_ok="y"
			DEBUG "_check_kernel_probe_driver: $driver: decompressed $dsize bytes"
			# Search for framebuffer drivers that bind with our VLFB
			# kexec-tools patch (orig_video_isVGA=0x23):
			#
			# Priority 1: vesadrm (DRM sysfb, kernel 7.x SUSE path)
			#   Binds to "vesa-framebuffer" created by sysfb from VLFB.
			#
			# Priority 2: vesafb (fbdev, kernel 5.x/6.x)
			#   Binds to "vesa-framebuffer" on older kernels with FB_VESA.
			#
			# Priority 3: simpledrm + sysfb_parse_mode (SYSFB_SIMPLEFB=y)
			#   sysfb_parse_mode confirms simple-framebuffer device is created.
			#
			if [ "$driver" = "vesafb" ]; then
				local _found_symbol
				_found_symbol=$(grep -aFo -e "vesadrm_probe" -e "vesadrm_platform_driver_init" \
					-e "vesafb_probe" -e "vesafb_driver_init" \
					-e "simpledrm_probe" -e "simpledrm_platform_driver_init" \
					"$decomp_file" 2>/dev/null) || true
				# Prefer vesadrm over other drivers: with our VLFB kexec
				# patch, vesadrm is the DRM path (7.x) that actually binds.
				if echo "$_found_symbol" | grep -q 'vesadrm'; then
					_found_symbol=$(echo "$_found_symbol" | grep 'vesadrm' | head -1)
				fi
				if [ -n "$_found_symbol" ]; then
					if echo "$_found_symbol" | grep -q 'vesadrm'; then
						DEBUG "_check_kernel_probe_driver: $driver: found vesadrm (VLFB DRM, 7.x)"
						rm -f "$decomp_file"
						echo "OK:vesadrm"
						return 0
					elif echo "$_found_symbol" | grep -q 'vesafb'; then
						DEBUG "_check_kernel_probe_driver: $driver: found vesafb (VLFB fbdev, 5.x/6.x)"
						rm -f "$decomp_file"
						echo "OK:vesafb"
						return 0
					elif echo "$_found_symbol" | grep -q 'simpledrm'; then
						# simpledrm requires SYSFB_SIMPLEFB=y for sysfb to
						# create a "simple-framebuffer" device.  Verify the
						# symbol unique to drivers/firmware/sysfb_simplefb.c.
						if grep -aFq 'sysfb_parse_mode' "$decomp_file" 2>/dev/null; then
							DEBUG "_check_kernel_probe_driver: $driver: found simpledrm + sysfb_parse_mode (SYSFB_SIMPLEFB=y)"
							rm -f "$decomp_file"
							echo "OK:simpledrm_sysfb"
							return 0
						else
							DEBUG "_check_kernel_probe_driver: $driver: simpledrm but no sysfb_parse_mode (SYSFB_SIMPLEFB=n)"
						fi
					fi
				fi
			else
				local _search_patterns="${driver}_probe ${driver}_pci_probe ${driver}_driver_init ${driver}_pci_driver_init"
				DEBUG "_check_kernel_probe_driver: $driver: searching decompressed kernel for driver symbols"
				# Generic driver: same grep -aFo pass (single scan,
				# -a forces text mode on binary decompressed kernel,
				# fixed strings, avoids per-symbol grep -q overhead)
				local _found_symbol
				_found_symbol=$(grep -aFo -e "${driver}_probe" -e "${driver}_pci_probe" -e "${driver}_driver_init" -e "${driver}_pci_driver_init" \
					"$decomp_file" 2>/dev/null | head -1) || true
				if [ -n "$_found_symbol" ]; then
					DEBUG "_check_kernel_probe_driver: $driver: found $_found_symbol"
					rm -f "$decomp_file"
					echo "OK:$_found_symbol"
					return 0
				fi
			fi
			DEBUG "_check_kernel_probe_driver: $driver: decompressed OK but none of [$_search_patterns] found"
		fi
		rm -f "$decomp_file"
		last_offset=$offset
	done

	if [ "$decomp_ok" = "n" ]; then
		DEBUG "_check_kernel_probe_driver: $driver: no decompressor produced output (tried all magics)"
		echo "!"
		return 0
	fi
}

# Check if a kernel has a specific display driver built in.
# Decompresses the kernel and searches for the driver's probe/init symbols.
# Returns the matching symbol (e.g. "OK:<driver>_probe") if found,
# "" if not, "!" if kernel can't be decompressed.
check_kernel_has_driver() {
	TRACE_FUNC
	local vmlinuz="$1" driver_name="$2"
	[ ! -f "$vmlinuz" ] && return 0
	_check_kernel_probe_driver "$vmlinuz" "$driver_name"
}

# Check whether the target kernel has a built-in framebuffer driver
# (vesadrm, vesafb, or simpledrm_sysfb).  Decompresses the candidate
# kernel and searches for driver symbols.
# Args: bootdir  [entries_file]
# Returns: "OK:<symbol>" if found (e.g. "OK:vesadrm", "OK:vesafb", "OK:simpledrm_sysfb"),
#   "" if not found, "!" if decompression failed.
check_kernel_for_fb() {
	TRACE_FUNC
	local bootdir="$1" entries_file="${2:-}" vmlinuz=""

	if [ -f "$bootdir" ]; then
		vmlinuz="$bootdir"
	elif [ -d "$bootdir" ]; then
		if [ -n "$entries_file" ] && grep -q "|xen|" "$entries_file" 2>/dev/null; then
			while IFS= read -r entry; do
				[ -z "$entry" ] && continue
				local etype e4
				etype=$(echo "$entry" | cut -d\| -f2)
				e4=$(echo "$entry" | cut -d\| -f4)
				if [ "$etype" = "xen" ]; then
					vmlinuz="${e4#module }"; vmlinuz="${vmlinuz%% *}"
					[ -f "$bootdir/$vmlinuz" ] && vmlinuz="$bootdir/$vmlinuz" && break
				fi
			done < "$entries_file"
		fi
		if [ -z "$vmlinuz" ]; then
			vmlinuz=$(find "$bootdir" \( -name "vmlinuz*" -o -name "bzImage*" \) -type f 2>/dev/null | grep -v "memtest" | head -1) || true
		fi
	fi
	[ -z "$vmlinuz" ] && return 0

	local result
	result=$(_check_kernel_probe_driver "$vmlinuz" "vesafb")
	echo "$result"
}

# Detect the active GPU display driver from the running system.
# Checks PCI display controllers first (most specific), then falls
# back to the active framebuffer device.  Returns the driver name
# (e.g. "i915", "ast", "bochs-drm", "simpledrmdrmfb", "vesafb") or
# empty string (exit 1) if detection fails.
# On libgfxinit/FSP GOP boards, the initial Heads kernel uses
# the fbdev console for Heads' console.  The target kernel receives
# normalized XRGB8888 with VLFB type.
#
# The detected driver tells us what the target kernel needs: if the
# board has an Intel GPU driven by i915, the target kernel needs i915
# (or a framebuffer for continuous display on libgfxinit boards).
#
# Detection methods in order:
# Build the final kernel cmdline with ISO-finding param enforcement.
# All processing (REMOVE, cleanup, key enforcement) is centralized here
# so the preview shown to the user exactly matches what kexec-boot.sh executes.
# Args:
#   iso_params   --  ISO's original kernel cmdline (from GRUB/syslinux)
#   param_add    --  ADD params (universal + loopback.cfg)
#   param_remove --  words/keys to strip (CONFIG_BOOT_KERNEL_REMOVE)
#   board_add    --  board-level ADD overrides (CONFIG_BOOT_KERNEL_ADD)
# Returns: final cmdline with REMOVE applied, ADD prepended, board_add appended.
# Priority: board_add > injected keys > ISO originals.
_build_final_cmdline() {
	local _iso_params="$1" _param_add="$2" _param_remove="$3" _board_add="$4"
	local _clean_add="" _combined=""

	TRACE_FUNC

	DEBUG "_build_final_cmdline: param_add='$_param_add' param_remove='$_param_remove' board_add='$_board_add'"
	DEBUG "_build_final_cmdline: iso_params='$_iso_params'"

	# Clean ADD: strip GRUB --- separator
	_clean_add=$(echo "$_param_add" | sed 's/ --- / /g;s/^--- //g;s/ ---$//g' | xargs)

	# Apply REMOVE to ADD, ISO params, and Board ADD
	for _remove_word in $_param_remove; do
		_clean_add=" $_clean_add "
		_clean_add="${_clean_add// $_remove_word / }"
		_iso_params=" $_iso_params "
		_iso_params="${_iso_params// $_remove_word / }"
		_board_add=" $_board_add "
		_board_add="${_board_add// $_remove_word / }"
	done
	_clean_add=$(echo "${_clean_add# }" | xargs)
	_iso_params=$(echo "${_iso_params# }" | xargs)
	_board_add=$(echo "${_board_add# }" | xargs)
	DEBUG "_build_final_cmdline: after remove on ADD='$_clean_add'"
	DEBUG "_build_final_cmdline: after remove on iso='$_iso_params'"

	# Combine: Heads ADD (prepended) + ISO originals
	_combined="$_clean_add $_iso_params"
	_combined=$(echo "$_combined" | xargs)
	DEBUG "_build_final_cmdline: combined='$_combined'"

	# Enforce ISO-finding keys: for each known key that Heads injects,
	# replace all occurrences in _combined with the Heads value, then
	# deduplicate (remove every occurrence, re-append once).
	# Keys not in the injected list are left untouched.
	for _iso_key in iso-scan/filename findiso img_dev img_loop iso live-media; do
		_heads_value=$(echo "$_clean_add" | grep -oE "(^| )$_iso_key=[^ ]*" | head -1 | sed 's/^ //')
		if [ -n "$_heads_value" ]; then
			DEBUG "_build_final_cmdline: enforcing $_iso_key -> '$_heads_value'"
			_combined=$(echo "$_combined" | sed "s| $_iso_key=[^ ]*| $_heads_value|g")
			_combined=$(echo "$_combined" | sed "s|^$_iso_key=[^ ]*|$_heads_value|")
			_dedup_guard=0
			while echo "$_combined" | grep -q " $_iso_key="; do
				_combined=$(echo "$_combined" | sed "s| $_iso_key=[^ ]*||")
				_dedup_guard=$((_dedup_guard + 1))
				[ "$_dedup_guard" -gt 100 ] && break
			done
			_combined=$(echo "$_combined" | sed "s|^$_iso_key=[^ ]*||")
			_combined="$_combined $_heads_value"
			DEBUG "_build_final_cmdline: after enforce $_iso_key='$_combined'"
		fi
	done

	# Append Board ADD last (always wins -- never touched by enforce).
	# Only append words not already present in _combined to avoid duplicates.
	for _add_word in $_board_add; do
		case " $_combined " in
			*" $_add_word "*) ;;
			*) _combined="$_combined $_add_word" ;;
		esac
	done
	_combined=$(echo "$_combined" | xargs)
	DEBUG "_build_final_cmdline: final='$_combined'"
	echo "$_combined"
}

