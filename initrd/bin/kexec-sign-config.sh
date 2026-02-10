#!/bin/bash
# Sign a valid directory of kexec params
set -e -o pipefail
# shellcheck disable=SC1091
. /tmp/config
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

TRACE_FUNC

rollback="n"
update="n"
while getopts "p:c:ur" arg; do
	# SC2220: No default case needed; only valid flags are handled for strict input.
	# shellcheck disable=SC2220
	case $arg in
	p) paramsdir="$OPTARG" ;;
	c)
		counter="$OPTARG"
		rollback="y"
		;;
	u) update="y" ;;
	r) rollback="y" ;;
	esac
done

if [ -z "$paramsdir" ]; then
	die "Usage: $0 -p /boot [ -u | -c counter ]"
fi

paramsdir="${paramsdir%%/}"

assert_signable
TRACE_FUNC

# remount /boot as rw
mount -o remount,rw /boot

DEBUG "Signing kexec parameters in $paramsdir, rollback=$rollback, update=$update, counter=$counter"

# update hashes in /boot before signing
if [ "$update" = "y" ]; then
	(
		TRACE_FUNC
		DEBUG "update=y: Updating kexec hashes in /boot"
		cd /boot
		find ./ -type f ! -path './kexec*' -print0 | xargs -0 sha256sum >/boot/kexec_hashes.txt
		if [ -e /boot/kexec_default_hashes.txt ]; then
			DEBUG "/boot/kexec_default_hashes.txt exists, updating /boot/kexec_default_hashes.txt"
			DEFAULT_FILES=$(cut -f3 -d ' ' /boot/kexec_default_hashes.txt)
			# SC2086: DEFAULT_FILES is intentionally unquoted to allow for option expansion.
			# shellcheck disable=SC2086
			echo $DEFAULT_FILES | xargs sha256sum >/boot/kexec_default_hashes.txt
		fi

		#also save the file & directory structure to detect added files
		print_tree >/boot/kexec_tree.txt
		TRACE_FUNC
	) || die "$paramsdir: Failed to update hashes."

	# Remove any package trigger log files
	# We don't need them after the user decides to sign
	rm -f /boot/kexec_package_trigger*
fi

if [ "$rollback" = "y" ]; then
	rollback_file="$paramsdir/kexec_rollback.txt"

	DEBUG "rollback=y, counter=$counter, paramsdir=$paramsdir, rollback_file=$rollback_file"
	TRACE_FUNC

	if [ -n "$counter" ]; then
		DEBUG "rollback=y: provided counter=$counter, will read tpm counter next"
		TRACE_FUNC

		# use existing tpm counter
		DO_WITH_DEBUG read_tpm_counter "$counter" >/dev/null 2>&1 ||
			die "$paramsdir: Unable to read tpm counter '$counter'"
	else
		DEBUG "rollback=y: counter was not provided: checking for existing TPM counter from TPM rollback_file=$rollback_file"
		TRACE_FUNC

		if [ -e "$rollback_file" ]; then
			# Extract TPM_COUNTER from rollback file
			TPM_COUNTER=$(grep -o 'counter-[0-9a-f]*' "$rollback_file" | cut -d- -f2)
			DEBUG "rollback=y: Found TPM counter $TPM_COUNTER in rollback file $rollback_file"
		else
			DEBUG "Rollback file $rollback_file does not exist. Creating new TPM counter."
			DO_WITH_DEBUG check_tpm_counter "$rollback_file" ||
				die "$paramsdir: Unable to find/create tpm counter"

			TRACE_FUNC
			TPM_COUNTER=$(cut -d: -f1 </tmp/counter | tr -d '\n')
			DEBUG "rollback=y: Created new TPM counter $TPM_COUNTER"
		fi
	fi

	TRACE_FUNC

	# Increment the TPM counter
	DEBUG "rollback=y: Incrementing counter $TPM_COUNTER."
	increment_tpm_counter "$TPM_COUNTER" >/dev/null 2>&1 ||
		die "$paramsdir: Unable to increment tpm counter"

	# Ensure the incremented counter file exists
	incremented_counter_file="/tmp/counter-$TPM_COUNTER"
	if [ ! -e "$incremented_counter_file" ]; then
		DEBUG "TPM counter file '$incremented_counter_file' not found. Attempting to read it again."
		DO_WITH_DEBUG read_tpm_counter "$TPM_COUNTER" >/dev/null 2>&1 ||
			die "$paramsdir: TPM counter file '$incremented_counter_file' not found after incrementing."
	fi

	DEBUG "TPM counter file '$incremented_counter_file' found."

	# Create the rollback file
	sha256sum "$incremented_counter_file" >"$rollback_file" ||
		die "$paramsdir: Unable to create rollback file"
fi

TRACE_FUNC
param_files=$(find "$paramsdir"/kexec*.txt)
DEBUG "Param files to sign: $param_files"
if [ -z "$param_files" ]; then
	die "$paramsdir: No kexec parameter files to sign"
fi

	# SC2034: tries is intentionally unused for compatibility with legacy scripts.
	# shellcheck disable=SC2034
	for tries in 1 2 3; do
	confirm_gpg_card
	TRACE_FUNC

	# SC2046: Command substitution intentionally unquoted for argument expansion.
	# SC2086: param_files is intentionally unquoted to allow for option expansion.
	# shellcheck disable=SC2046,SC2086
	if DO_WITH_DEBUG sha256sum $param_files | gpg --detach-sign >"$paramsdir"/kexec.sig; then
		# successful - update the validated params
		check_config "$paramsdir"

		# remount /boot as ro
		mount -o remount,ro /boot

		exit 0
	fi
done

# remount /boot as ro
mount -o remount,ro /boot

die "$paramsdir: Unable to sign kexec hashes"
