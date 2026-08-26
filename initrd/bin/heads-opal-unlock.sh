#!/bin/bash

# Test fixtures override these paths; production always uses the initrd copies.
# shellcheck source=/dev/null
. "${HEADS_OPAL_FUNCTIONS_SH:-/etc/functions.sh}"
# shellcheck source=/dev/null
. "${HEADS_OPAL_GUI_FUNCTIONS_SH:-/etc/gui_functions.sh}"

opal_prompt_password() {
	local device="$1"
	local output_file="/tmp/secret/heads-opal-password"
	local rc

	if [ -n "${CONFIG_HEADS_OPAL_PROMPT:-}" ]; then
		"$CONFIG_HEADS_OPAL_PROMPT" "$device"
		return
	fi

	umask 077
	rm -f "$output_file"
	if whiptail_type normal --title "TCG Opal Disk Unlock" \
		--passwordbox "Enter the TCG Opal password for $device" 0 80 \
		2>"$output_file"; then
		if [ -s "$output_file" ]; then
			cat "$output_file"
			rc=0
		else
			rc=5
		fi
	else
		rc=$?
	fi
	: >"$output_file" 2>/dev/null || true
	rm -f "$output_file"
	return "$rc"
}

heads_opal_unlock_device() {
	local tool="$1"
	local device="$2"
	local attempts="${CONFIG_HEADS_OPAL_MAX_ATTEMPTS:-3}"
	local attempt=1
	local prompt_rc
	local rc
	local state
	local -a pipeline_status
	local -a unlock_args

	while [ "$attempt" -le "$attempts" ]; do
		unlock_args=(unlock)
		if [ "${CONFIG_HEADS_OPAL_S3_HANDOFF:-n}" = "y" ]; then
			unlock_args+=(--s3-handoff)
		fi
		unlock_args+=("$device")
		opal_prompt_password "$device" | "$tool" "${unlock_args[@]}" \
			>/tmp/heads-opal-output 2>&1
		pipeline_status=("${PIPESTATUS[@]}")
		prompt_rc="${pipeline_status[0]}"
		rc="${pipeline_status[1]}"

		case "$prompt_rc" in
		0)
			;;
		5)
			whiptail_error --title "TCG Opal Unlock Failed" \
				--msgbox "The disk password cannot be empty." 0 80
			attempt=$((attempt + 1))
			continue
			;;
		*)
			WARN "TCG Opal unlock cancelled for $device"
			return 1
			;;
		esac

		case "$rc" in
		0)
			state=$("$tool" status "$device" 2>>/tmp/heads-opal-output) || {
				WARN "Unable to confirm TCG Opal state for $device"
				return 1
			}
			if [ "$state" != "unlocked" ]; then
				WARN "$device remained in TCG Opal state '$state' after unlock"
				return 1
			fi
			STATUS_OK "Unlocked TCG Opal disk $device"
			return 0
			;;
		3)
			whiptail_error --title "TCG Opal Unlock Failed" \
				--msgbox "The password for $device was rejected. Attempt $attempt of $attempts." 0 80
			;;
		4)
			WARN "TCG Opal unlocked $device, but S3 resume handoff failed"
			whiptail_error --title "TCG Opal Resume Protection Failed" \
				--msgbox "The disk was unlocked, but its password could not be handed to firmware for suspend/resume. Boot has stopped to avoid an unusable resume path." 0 80
			return 1
			;;
		*)
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
	local tool="${CONFIG_HEADS_OPAL_TOOL:-/bin/heads-opal}"
	local scan_output
	local device
	local state
	local extra
	local found_locked=n

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
		disabled | unlocked)
			;;
		locked)
			found_locked=y
			heads_opal_unlock_device "$tool" "$device" || return 1
			;;
		*)
			WARN "Unknown TCG Opal state '$state' for $device"
			return 1
			;;
		esac
	done <<<"$scan_output"

	if [ "$found_locked" = "y" ]; then
		STATUS_OK "All locked TCG Opal disks are ready"
	fi
	return 0
}

heads_opal_main "$@"
