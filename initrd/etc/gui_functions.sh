#!/bin/bash
# Shell functions for common operations using fbwhiptail
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

# Pause for the configured timeout before booting automatically.  Returns 0 to
# continue with automatic boot, nonzero if user interrupted.
pause_automatic_boot() {
	if IFS= read -t "$CONFIG_AUTO_BOOT_TIMEOUT" -s -n 1 -r -p \
		$'Automatic boot in '"$CONFIG_AUTO_BOOT_TIMEOUT"$' seconds unless interrupted by keypress...\n'; then
		return 1 # Interrupt automatic boot
	fi
	return 0 # Continue with automatic boot
}

mount_usb() {
	TRACE_FUNC
	# Unmount any previous USB device
	if grep -q /media /proc/mounts; then
		umount /media || die "Unable to unmount /media"
	fi
	# Mount the USB boot device
		if mount-usb.sh; then
			USB_FAILED=0
		elif [ $? -eq 5 ]; then
			exit 1
		else
			USB_FAILED=1
		fi
	if [ "$USB_FAILED" -ne 0 ]; then
		whiptail_error --title 'USB Drive Missing' \
			--msgbox "Insert your USB drive and press Enter to continue." 0 80
		if mount-usb.sh; then
			USB_FAILED=0
		elif [ $? -eq 5 ]; then
			exit 1
		else
			USB_FAILED=1
		fi
		if [ "$USB_FAILED" -ne 0 ]; then
			whiptail_error --title 'ERROR: Mounting /media Failed' \
				--msgbox "Unable to mount USB device" 0 80
		fi
	fi
}

# -- Display related functions --
# Produce a whiptail prompt with 'warning' background, works for fbwhiptail and newt
whiptail_warning() {
	# shellcheck disable=SC2086,SC2145
	# SC2086: BG_COLOR_WARNING is intentionally unquoted to allow for option expansion.
	# SC2145: "$@" is used to pass all arguments as intended.
	if [ -x /bin/fbwhiptail ]; then
		TRACE_FUNC
		DEBUG "whiptail_warning: fbwhiptail mode"
		DEBUG "whiptail_warning: BG_COLOR_WARNING=$BG_COLOR_WARNING"
		DEBUG "whiptail_warning: arguments count=$#"
		local i=1
		for arg in "$@"; do
			DEBUG "whiptail_warning: arg[$i]=$arg"
			i=$((i + 1))
		done
		whiptail $BG_COLOR_WARNING "$@"
	else
		TRACE_FUNC
		DEBUG "whiptail_warning: newt mode with NEWT_COLORS"
		DEBUG "whiptail_warning: TEXT_BG_COLOR_WARNING=$TEXT_BG_COLOR_WARNING"
		DEBUG "whiptail_warning: arguments count=$#"
		local i=1
		for arg in "$@"; do
			DEBUG "whiptail_warning: arg[$i]=$arg"
			i=$((i + 1))
		done
		env NEWT_COLORS="root=,$TEXT_BG_COLOR_WARNING" whiptail "$@"
	fi
}

# Produce a whiptail prompt with 'error' background, works for fbwhiptail and newt
whiptail_error() {
	# shellcheck disable=SC2086,SC2145
	# SC2086: BG_COLOR_ERROR is intentionally unquoted to allow for option expansion.
	# SC2145: "$@" is used to pass all arguments as intended.
	if [ -x /bin/fbwhiptail ]; then
		TRACE_FUNC
		DEBUG "whiptail_error: fbwhiptail mode"
		DEBUG "whiptail_error: BG_COLOR_ERROR=$BG_COLOR_ERROR"
		DEBUG "whiptail_error: arguments count=$#"
		local i=1
		for arg in "$@"; do
			DEBUG "whiptail_error: arg[$i]=$arg"
			i=$((i + 1))
		done
		whiptail $BG_COLOR_ERROR "$@"
	else
		TRACE_FUNC
		DEBUG "whiptail_error: newt mode with NEWT_COLORS"
		DEBUG "whiptail_error: TEXT_BG_COLOR_ERROR=$TEXT_BG_COLOR_ERROR"
		DEBUG "whiptail_error: arguments count=$#"
		local i=1
		for arg in "$@"; do
			DEBUG "whiptail_error: arg[$i]=$arg"
			i=$((i + 1))
		done
		whiptail $BG_COLOR_ERROR "$@"
	fi
}

# Produce a whiptail error prompt and exit
whiptail_error_die() {
	TRACE_FUNC
	local msg=$1
	DEBUG "whiptail_error_die called with msg: $msg"
	whiptail_error --title "Error" --msgbox "$msg" 0 80
	exit 1
}

# Produce a whiptail prompt of the given type - 'error', 'warning', or 'normal'
whiptail_type() {
	# shellcheck disable=SC2086,SC2145
	# SC2086: BG_COLOR_MAIN_MENU is intentionally unquoted to allow for option expansion.
	# SC2145: "$@" is used to pass all arguments as intended.
	TRACE_FUNC
	local TYPE="$1"
	shift
	case "$TYPE" in
		error)
			whiptail_error "$@"
			;;
		warning)
			whiptail_warning "$@"
			;;
		normal)
			whiptail "$@"
			;;
		*)
			whiptail "$@"
			;;
	esac
}

# Create display text for a size in bytes in either MB or GB, unit selected
# automatically, rounded to nearest
display_size() {
	TRACE_FUNC
	local size_bytes unit_divisor unit_symbol
	size_bytes="$1"

	# If it's less than 1 GB, display MB
	if [ "$((size_bytes))" -lt "$((1024 * 1024 * 1024))" ]; then
		unit_divisor=$((1024 * 1024))
		unit_symbol="MB"
	else
		unit_divisor=$((1024 * 1024 * 1024))
		unit_symbol="GB"
	fi

	# Divide by the unit divisor and round to nearest
	echo "$(((size_bytes + unit_divisor / 2) / unit_divisor)) $unit_symbol"
}

# Create display text for the size of a block device using MB or GB, rounded to
# nearest
display_block_device_size() {
	TRACE_FUNC
	local block_dev disk_size_bytes
	block_dev="$1"

	# Obtain size of thumb drive to be wiped with fdisk
	if ! disk_size_bytes="$(blockdev --getsize64 "$block_dev")"; then
		exit 1
	fi

	display_size "$disk_size_bytes"
}

# Display a menu to select a file from a list.  Pass the name of a file
# containing the list.
# --show-size: Append sizes of files listed.  Currently only supports block
#   devices.
# $1: Name of file listing files that can be chosen (one per line)
# $2: Optional prompt message
# $3: Optional prompt title
#
# Success: Sets FILE with the selected file
# User aborted: Exits successfully with FILE empty
# No entries in list: Displays error and exits unsuccessfully
file_selector() {
	# shellcheck disable=SC2086,SC2145
	# SC2086: Option variables intentionally unquoted for menu argument expansion.
	# SC2145: "$@" is used to pass all arguments as intended.
	TRACE_FUNC

	local FILE_LIST MENU_MSG MENU_TITLE CHOICE_ARGS SHOW_SIZE OPTION_SIZE option_index

	FILE=""

	if [ "$1" = "--show-size" ]; then
		SHOW_SIZE=y
		shift
	fi

	FILE_LIST=$1
	MENU_MSG=${2:-"Choose the file"}
	MENU_TITLE=${3:-"Select your File"}

	CHOICE_ARGS=()
	n=0
	while read -r option; do
		n="$((++n))"

		if [ "$SHOW_SIZE" = "y" ] && OPTION_SIZE="$(display_block_device_size "$option")"; then
			option="$option - $OPTION_SIZE"
		fi
		CHOICE_ARGS+=("$n" "$option")
	done <"$FILE_LIST"

	if [ "${#CHOICE_ARGS[@]}" -eq 0 ]; then
		whiptail_error --title 'ERROR: No Files Found' \
			--msgbox "No Files found matching the pattern. Aborting." 0 80
		exit 1
	fi

	CHOICE_ARGS+=(a Abort)

	# create file menu options
	option_index=""
	while [ -z "$option_index" ]; do
		DEBUG "CHOICE_ARGS: ${CHOICE_ARGS[*]}"
		whiptail --title "${MENU_TITLE}" \
			--menu "${MENU_MSG} [1-$n, a to abort]:" 20 120 8 \
			-- "${CHOICE_ARGS[@]}" \
			2>/tmp/whiptail || die "Aborting"

		option_index="$(cat /tmp/whiptail)"

		if [ "$option_index" != "a" ]; then
			   FILE="$(head -n "$option_index" "$FILE_LIST" | tail -1)"
			   export FILE
		fi
	done
}

show_system_info() {
	TRACE_FUNC
	battery_status="$(print_battery_state)"

	memtotal="$(grep 'MemTotal' /proc/meminfo | tr -s ' ' | cut -f2 -d ' ')"
	memtotal=$((memtotal / 1024 / 1024 + 1))
	cpustr="$(grep 'model name' /proc/cpuinfo | uniq | sed -r 's/\(R\)//;s/\(TM\)//;s/CPU //;s/model name.*: //')"
	kernel="$(uname -s -r)"

	local msgbox
	msgbox="${BOARD_NAME}

	FW_VER: ${FW_VER}
	Kernel: ${kernel}

	CPU: ${cpustr}
	Microcode: $(grep microcode /proc/cpuinfo | uniq | cut -d':' -f2 | tr -d ' ')
	RAM: ${memtotal} GB
	$battery_status
	$(fdisk -l 2>/dev/null | grep -e '/dev/sd.:' -e '/dev/nvme.*:' | sed 's/B,.*/B/')
	"

	local msgbox_rm_tabs
	msgbox_rm_tabs=$(echo "$msgbox" | tr -d "\t")

	whiptail_type "$BG_COLOR_MAIN_MENU" --title 'System Info' \
		--msgbox "$msgbox_rm_tabs" 0 80
}

# Get "Enable" or "Disable" to display in the configuration menu, based on a
# setting value
get_config_display_action() {
	[ "$1" = "y" ] && echo "Disable" || echo "Enable"
}

# Invert a config value
invert_config() {
	[ "$1" = "y" ] && echo "n" || echo "y"
}

# Get "Enable" or "Disable" for a config that internally is inverted (because it
# disables a behavior that is on by default).
get_inverted_config_display_action() {
	get_config_display_action "$(invert_config "$1")"
}
