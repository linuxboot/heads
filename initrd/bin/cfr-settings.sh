#!/bin/bash
# shellcheck disable=SC1091

set -e -o pipefail

cfr_root=/sys/class/firmware-attributes/coreboot-cfr/attributes
test_root=

if [ "${1:-}" = "--test-root" ]; then
	[ "$#" -eq 2 ] || exit 2
	test_root=$2
	cfr_root="$test_root/sys/class/firmware-attributes/coreboot-cfr/attributes"
	. "$test_root/functions.sh"
	. "$test_root/gui_functions.sh"
else
	[ "$#" -eq 0 ] || exit 2
	[ -r /etc/functions.sh ] && . /etc/functions.sh
	[ -r /etc/gui_functions.sh ] && . /etc/gui_functions.sh
fi

if [ -n "$test_root" ]; then
	dialog_output="$test_root/dialog_output"
else
	dialog_output=/tmp/cfr-settings-whiptail.$$
fi
trap 'rm -f "$dialog_output"' EXIT

cfr_error() {
	local message=$1
	if declare -F whiptail_error >/dev/null 2>&1; then
		whiptail_error --title 'Firmware Settings Error' --msgbox "$message" 0 80 || true
	else
		printf '%s\n' "$message" >&2
	fi
}

cfr_info() {
	local message=$1
	if declare -F whiptail_type >/dev/null 2>&1; then
		whiptail_type normal --title 'Firmware Settings' --msgbox "$message" 0 80 || true
	else
		printf '%s\n' "$message" >&2
	fi
}

cfr_read_line() {
	local file=$1 allow_empty=$2 value extra fd
	[ -r "$file" ] || return 1
	exec {fd}<"$file" || return 1
	if ! IFS= read -r value <&"$fd" && [ -z "$value" ]; then
		exec {fd}<&-
		return 1
	fi
	if IFS= read -r extra <&"$fd" || [ -n "$extra" ]; then
		exec {fd}<&-
		return 1
	fi
	exec {fd}<&-
	case "$value" in
		*$'\n'*|*$'\r'*) return 1 ;;
	esac
	[ "$allow_empty" = true ] || [ -n "$value" ] || return 1
	printf '%s' "$value"
}

cfr_read_single_line() {
	cfr_read_line "$1" false
}

cfr_read_optional_line() {
	cfr_read_line "$1" true
}

cfr_number_valid() {
	local value=$1 minimum=$2 maximum=$3 step=$4 number
	local candidate
	for candidate in "$value" "$minimum" "$maximum" "$step"; do
		[[ "$candidate" =~ ^[0-9]{1,10}$ ]] || return 1
		(( 10#$candidate <= 4294967295 )) || return 1
	done
	number=$((10#$value)) || return 1
	minimum=$((10#$minimum)) || return 1
	maximum=$((10#$maximum)) || return 1
	step=$((10#$step)) || return 1
	(( number >= minimum && number <= maximum )) || return 1
	(( step == 0 || (number - minimum) % step == 0 ))
}

cfr_enum_values() {
	local file=$1 raw value
	local -a values
	raw=$(cfr_read_single_line "$file") || return 1
	case "$raw" in
		';'*|*';'|*';;'*) return 1 ;;
	esac
	IFS=';' read -r -a values <<< "$raw"
	[ "${#values[@]}" -gt 0 ] || return 1
	for value in "${values[@]}"; do
		[ -n "$value" ] || return 1
		case "$value" in
			*$'\n'*|*$'\r'*) return 1 ;;
		esac
		printf '%s\n' "$value"
	done
}

cfr_setting_type() {
	local setting=$1 type
	type=$(cfr_read_single_line "$setting/type") || return 1
	case "$type" in
		enumeration|integer) printf '%s' "$type" ;;
		*) return 1 ;;
	esac
}

cfr_setting_flags_valid() {
	local setting=$1 raw flag
	[ -e "$setting/flags" ] || return 0
	raw=$(cfr_read_optional_line "$setting/flags") || return 1
	raw=${raw//,/ }
	for flag in $raw; do
		case "$flag" in
			readonly|inactive|suppressed|volatile) ;;
			*) return 1 ;;
		esac
	done
}

cfr_setting_has_flag() {
	local setting=$1 wanted=$2 raw flag
	[ -e "$setting/flags" ] || return 1
	raw=$(cfr_read_optional_line "$setting/flags") || return 1
	raw=${raw//,/ }
	for flag in $raw; do
		[ "$flag" = "$wanted" ] && return 0
	done
	return 1
}

cfr_setting_writable() {
	local setting=$1 mode
	mode=$(stat -c '%a' "$setting/current_value") || return 1
	[[ "$mode" =~ ^[0-7]+$ ]] || return 1
	(( (8#$mode & 0222) != 0 ))
}

cfr_setting_valid() {
	local setting=$1 type current default minimum maximum step value raw_values
	local current_found default_found
	local -a values
	type=$(cfr_setting_type "$setting") || return 1
	cfr_setting_flags_valid "$setting" || return 1
	cfr_read_single_line "$setting/display_name" >/dev/null || return 1
	current=$(cfr_read_single_line "$setting/current_value") || return 1
	default=$(cfr_read_single_line "$setting/default_value") || return 1
	if [ "$type" = integer ]; then
		minimum=$(cfr_read_single_line "$setting/min_value") || return 1
		maximum=$(cfr_read_single_line "$setting/max_value") || return 1
		step=$(cfr_read_single_line "$setting/scalar_increment") || return 1
		cfr_number_valid "$current" "$minimum" "$maximum" "$step" || return 1
		cfr_number_valid "$default" "$minimum" "$maximum" "$step" || return 1
	else
		raw_values=$(cfr_enum_values "$setting/possible_values") || return 1
		mapfile -t values <<< "$raw_values"
		[ "${#values[@]}" -gt 0 ] || return 1
		current_found=1
		default_found=1
		for value in "${values[@]}"; do
			[ "$value" = "$current" ] && current_found=0
			[ "$value" = "$default" ] && default_found=0
		done
		[ "$current_found" -eq 0 ] || return 1
		[ "$default_found" -eq 0 ] || return 1
	fi
}

cfr_item() {
	local setting=$1 name display current writable
	name=${setting##*/}
	display=$(cfr_read_single_line "$setting/display_name") || return 1
	current=$(cfr_read_single_line "$setting/current_value") || return 1
	if cfr_setting_writable "$setting" &&
		! cfr_setting_has_flag "$setting" readonly &&
		! cfr_setting_has_flag "$setting" volatile; then
		writable=''
	else
		writable=' [read-only]'
	fi
	cfr_setting_has_flag "$setting" volatile && writable="$writable [volatile]"
	printf '%s\t%s%s (current: %s)' "$name" "$display" "$writable" "$current"
}

cfr_choose_setting() {
	local setting item name
	local -a menu
	menu=()
	for setting in "$cfr_root"/*; do
		[ -d "$setting" ] || continue
		cfr_setting_valid "$setting" || continue
		cfr_setting_has_flag "$setting" inactive && continue
		cfr_setting_has_flag "$setting" suppressed && continue
		item=$(cfr_item "$setting") || continue
	name=${item%%$'\t'*}
	item=${item#*$'\t'}
	menu+=("$name" "$item")
	done

	[ "${#menu[@]}" -gt 0 ] || {
		cfr_info 'No usable coreboot firmware settings are available.'
		return 1
	}

	if ! whiptail_type normal --title 'Coreboot Firmware Settings' \
		--menu 'Select a setting. Values are read again after every write.' \
		0 100 12 "${menu[@]}" > /dev/null 2>"$dialog_output"; then
		return 1
	fi

	[ -r "$dialog_output" ] || return 1
	cat -- "$dialog_output"
}

cfr_edit_setting() {
	local name=$1 setting="$cfr_root/$1" type current default minimum maximum step
	local selected value display pending pending_text confirmation

	[ -d "$setting" ] || {
		cfr_error 'The selected setting disappeared.'
		return 0
	}
	if cfr_setting_has_flag "$setting" inactive ||
		cfr_setting_has_flag "$setting" suppressed; then
		cfr_error 'The selected setting is inactive.'
		return 0
	fi
	cfr_setting_valid "$setting" || {
		cfr_error 'The selected setting is unavailable or contains malformed data.'
		return 0
	}
	type=$(cfr_setting_type "$setting") || return 0
	current=$(cfr_read_single_line "$setting/current_value") || return 0
	default=$(cfr_read_single_line "$setting/default_value") || return 0

	if ! cfr_setting_writable "$setting" ||
		cfr_setting_has_flag "$setting" readonly ||
		cfr_setting_has_flag "$setting" volatile; then
		display=$(cfr_read_single_line "$setting/display_name") || return 0
		cfr_info "$(printf '%s\n\nCurrent: %s\nDefault: %s\n\nThis setting is read-only in firmware.' "$display" "$current" "$default")"
		return 0
	fi

	if [ "$type" = enumeration ]; then
		local -a values choices
		local raw_values
		raw_values=$(cfr_enum_values "$setting/possible_values") || {
			cfr_error 'The setting enumeration is malformed.'
			return 0
		}
		mapfile -t values <<< "$raw_values"
		choices=()
		for value in "${values[@]}"; do
			choices+=("$value" "$value")
		done
		if ! whiptail_type normal --title "$(cfr_read_single_line "$setting/display_name")" \
			--menu "Current: $current\nDefault: $default" 0 100 12 \
			"${choices[@]}" 2>"$dialog_output"; then
			return 0
		fi
		selected=$(cat -- "$dialog_output") || return 0
		value=$selected
	else
		minimum=$(cfr_read_single_line "$setting/min_value") || return 0
		maximum=$(cfr_read_single_line "$setting/max_value") || return 0
		step=$(cfr_read_single_line "$setting/scalar_increment") || return 0
		if ! whiptail_type normal --title "$(cfr_read_single_line "$setting/display_name")" \
			--inputbox "Current: $current\nDefault: $default\nRange: $minimum-$maximum, step $step" \
			0 100 "$current" 2>"$dialog_output"; then
			return 0
		fi
		value=$(cat -- "$dialog_output") || return 0
		cfr_number_valid "$value" "$minimum" "$maximum" "$step" || {
			cfr_error 'The number is outside the firmware-provided range.'
			return 0
		}
	fi

	display=$(cfr_read_single_line "$setting/display_name") || return 0
	pending_text='pending_reboot will be checked after the write.'
	if [ -e "$cfr_root/pending_reboot" ]; then
		pending=$(cfr_read_single_line "$cfr_root/pending_reboot" || true)
		case "$pending" in
			0) pending_text='pending_reboot currently reports no reboot required.' ;;
			1) pending_text='pending_reboot currently reports that a reboot may be required.' ;;
			*) pending_text='pending_reboot is unavailable or malformed; it will be checked after the write.' ;;
		esac
	fi
	confirmation=$(printf '%s\n\nCurrent: %s\nRequested: %s\n\n%s\n\nWrite this firmware setting?' \
		"$display" "$current" "$value" "$pending_text")
	if ! whiptail_type normal --title 'Confirm Firmware Setting' \
		--yesno "$confirmation" 0 80; then
		return 0
	fi

	if ! printf '%s\n' "$value" >"$setting/current_value"; then
		cfr_error 'The firmware rejected the setting write.'
		return 0
	fi

	current=$(cfr_read_single_line "$setting/current_value") || {
		cfr_error 'The setting disappeared after the write.'
		return 0
	}
	[ "$current" = "$value" ] || {
		cfr_error 'Firmware did not retain the requested value.'
		return 0
	}

	if [ -e "$cfr_root/pending_reboot" ]; then
		local pending
		pending=$(cfr_read_single_line "$cfr_root/pending_reboot") || {
			cfr_error 'The pending-reboot state is malformed.'
			return 0
		}
		case "$pending" in
			0) ;;
			1) cfr_info 'The setting was stored. Firmware reports that a reboot is pending.' ;;
			*) cfr_error 'The pending-reboot state is malformed.' ;;
		esac
	fi
}

[ -d "$cfr_root" ] || exit 0
declare -F whiptail_type >/dev/null 2>&1 || exit 1

while true; do
	setting=$(cfr_choose_setting) || exit 0
	cfr_edit_setting "$setting"
done
