#!/bin/bash

if [ "${1:-}" = "--test-fixture" ]; then
	[ "$#" -eq 2 ] || exit 64
	opal_fixture_root="$2"
	opal_functions_sh="$opal_fixture_root/functions.sh"
	opal_gui_functions_sh="$opal_fixture_root/gui_functions.sh"
	opal_tool="$opal_fixture_root/backend"
	opal_prompt="$opal_fixture_root/prompt"
	opal_password_file="$opal_fixture_root/password"
	shift 2
else
	opal_functions_sh=/etc/functions.sh
	opal_gui_functions_sh=/etc/gui_functions.sh
	opal_tool=/bin/heads-opal
	opal_prompt=/bin/heads-opal-prompt
	opal_password_file=/tmp/secret/heads-opal-password
fi

# shellcheck source=/dev/null
. "$opal_functions_sh"
# shellcheck source=/dev/null
. "$opal_gui_functions_sh"

opal_discard_password_file() {
	local output_file="$1"

	[ -e "$output_file" ] || return 0
	if ! : >"$output_file"; then
		WARN "Unable to clear TCG Opal password file"
		return 1
	fi
	if ! rm -f "$output_file"; then
		WARN "Unable to remove TCG Opal password file"
		return 1
	fi
}

opal_prompt_password() {
	local device="$1"
	local output_file="$2"
	local rc

	umask 077
	opal_discard_password_file "$output_file" || return 1
	if [ -x "$opal_prompt" ]; then
		"$opal_prompt" "$device" >"$output_file"
		rc=$?
	elif whiptail_type normal --title "TCG Opal Disk Unlock" \
			--passwordbox "Enter the TCG Opal password for $device" 0 80 \
			2>"$output_file"; then
		rc=0
	else
		rc=$?
	fi
	if [ "$rc" -eq 0 ] && [ ! -s "$output_file" ]; then
		rc=5
	fi
	return "$rc"
}

opal_close_password_fd() {
	local password_fd="$1"
	local rc=0

	if ! : >"/proc/self/fd/$password_fd"; then
		WARN "Unable to clear anonymous TCG Opal password storage"
		rc=1
	fi
	exec {password_fd}>&-
	return "$rc"
}

opal_relock_device() {
	local tool="$1"
	local device="$2"
	local password_fd="$3"
	local state
	if ! "$tool" lock "$device" <"/proc/self/fd/$password_fd" \
			>>/tmp/heads-opal-output 2>&1; then
		WARN "Unable to relock TCG Opal disk $device"
		return 1
	fi
	state=$("$tool" status "$device" 2>>/tmp/heads-opal-output) || return 1
	if [ "$state" != "locked" ]; then
		WARN "$device remained in TCG Opal state '$state' after rollback"
		return 1
	fi
	return 0
}

heads_opal_unlock_device() {
	local tool="$1"
	local device="$2"
	local attempts=3
	local attempt=1
	local output_file="$opal_password_file"
	local password_fd
	local prompt_rc
	local rc
	local state

	HEADS_OPAL_PASSWORD_FD=

	while [ "$attempt" -le "$attempts" ]; do
		opal_prompt_password "$device" "$output_file"
		prompt_rc=$?

		case "$prompt_rc" in
		0)
			;;
		5)
			opal_discard_password_file "$output_file" || return 2
			whiptail_error --title "TCG Opal Unlock Failed" \
				--msgbox "The disk password cannot be empty." 0 80
			attempt=$((attempt + 1))
			continue
			;;
		*)
			opal_discard_password_file "$output_file" || true
			WARN "TCG Opal unlock cancelled for $device"
			return 1
			;;
		esac

		if ! exec {password_fd}<>"$output_file"; then
			WARN "Unable to open TCG Opal password storage"
			opal_discard_password_file "$output_file" || true
			return 1
		fi
		if ! rm -f "$output_file"; then
			WARN "Unable to unlink TCG Opal password storage"
			opal_close_password_fd "$password_fd" || true
			return 1
		fi
		"$tool" unlock "$device" <&"$password_fd" \
			>/tmp/heads-opal-output 2>&1
		rc=$?

		case "$rc" in
		0)
			state=$("$tool" status "$device" 2>>/tmp/heads-opal-output) || {
				WARN "Unable to confirm TCG Opal state for $device"
				opal_relock_device "$tool" "$device" "$password_fd" || return 2
				opal_close_password_fd "$password_fd" || return 2
				return 1
			}
			if [ "$state" != "unlocked" ]; then
				WARN "$device remained in TCG Opal state '$state' after unlock"
				opal_relock_device "$tool" "$device" "$password_fd" || return 2
				opal_close_password_fd "$password_fd" || return 2
				return 1
			fi
			STATUS_OK "Unlocked TCG Opal disk $device"
			HEADS_OPAL_PASSWORD_FD="$password_fd"
			return 0
			;;
		3)
			opal_close_password_fd "$password_fd" || return 2
			whiptail_error --title "TCG Opal Unlock Failed" \
				--msgbox "The password for $device was rejected. Attempt $attempt of $attempts." 0 80
			;;
		4)
			opal_close_password_fd "$password_fd" || return 2
			WARN "TCG Opal S3 metadata or compatibility check failed for $device before unlock"
			whiptail_error --title "TCG Opal Resume Protection Failed" \
				--msgbox "The disk was not unlocked because its firmware resume metadata could not be prepared." 0 80
			return 1
			;;
		5)
			if ! opal_relock_device "$tool" "$device" "$password_fd"; then
				opal_close_password_fd "$password_fd" || true
				return 2
			fi
			opal_close_password_fd "$password_fd" || return 2
			WARN "TCG Opal S3 handoff failed for $device; the disk was relocked"
			whiptail_error --title "TCG Opal Resume Protection Failed" \
				--msgbox "The firmware resume handoff failed, so the disk was relocked and boot has stopped." 0 80
			return 1
			;;
		*)
			if ! opal_relock_device "$tool" "$device" "$password_fd"; then
				opal_close_password_fd "$password_fd" || true
				return 2
			fi
			opal_close_password_fd "$password_fd" || return 2
			WARN "TCG Opal backend failed for $device (status $rc)"
			return 1
			;;
		esac
		attempt=$((attempt + 1))
	done

	WARN "TCG Opal password retries exhausted for $device"
	return 1
}

heads_opal_main() {
	local tool="$opal_tool"
	local scan_output
	local device
	local state
	local extra
	local found_locked=n
	local unlock_rc
	local index
	local -a unlocked_devices=()
	local -a password_fds=()

	if [ ! -x "$tool" ]; then
		WARN "TCG Opal backend is missing: $tool"
		return 1
	fi
	if ! scan_output=$("$tool" scan 2>/tmp/heads-opal-output); then
		WARN "Unable to scan disks for TCG Opal state"
		return 1
	fi

	while read -r device state extra; do
		[ -n "$device" ] || continue
		if [ -n "$extra" ]; then
			WARN "Invalid TCG Opal scan result"
			return 1
		fi
		case "$state" in
		disabled | unlocked | locked)
			;;
		*)
			WARN "Unknown TCG Opal state '$state' for $device"
			return 1
			;;
		esac
	done <<<"$scan_output"

	while read -r device state extra; do
		[ -n "$device" ] || continue
		case "$state" in
		disabled | unlocked)
			;;
		locked)
			found_locked=y
			heads_opal_unlock_device "$tool" "$device"
			unlock_rc=$?
			if [ "$unlock_rc" -ne 0 ]; then
				for ((index = ${#unlocked_devices[@]} - 1; index >= 0; index--)); do
					opal_relock_device "$tool" "${unlocked_devices[index]}" \
						"${password_fds[index]}" || unlock_rc=2
				opal_close_password_fd "${password_fds[index]}" || unlock_rc=2
				done
				return "$unlock_rc"
			fi
			unlocked_devices+=("$device")
			password_fds+=("$HEADS_OPAL_PASSWORD_FD")
			;;
		esac
	done <<<"$scan_output"

	for password_fd in "${password_fds[@]}"; do
		opal_close_password_fd "$password_fd" || return 2
	done

	if [ "$found_locked" = "y" ]; then
		STATUS_OK "All locked TCG Opal disks are ready"
	fi
	return 0
}

heads_opal_main "$@"
