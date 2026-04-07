#!/bin/bash
# This script contains various functions related to LUKS (Linux Unified Key Setup) encryption management.

. /etc/functions.sh
. /etc/gui_functions.sh
. /tmp/config

# List all LUKS devices on the system that are not USB
list_local_luks_devices() {
	TRACE_FUNC
	run_lvm vgscan 2>/dev/null || true
	blkid | cut -d ':' -f 1 | while read -r device; do
		DEBUG "Checking device: $device"
		if cryptsetup isLuks "$device"; then
			DEBUG "Device $device is a LUKS device"
			dev_name=$(basename "$device")
			# Dynamically determine parent device name
			parent_dev_name=$(echo "$dev_name" | sed -E 's/(p?[0-9]+)$//') # Handles both NVMe (pX) and non-NVMe (X)
			DEBUG "Derived parent device name: $parent_dev_name"
			if [ -e "/sys/block/$parent_dev_name" ]; then
				DEBUG "Device $device exists in /sys/block"
				if ! stat -c %N "/sys/block/$parent_dev_name" 2>/dev/null | grep -q "usb"; then
					DEBUG "Device $device is not a USB device"
					echo "$device"
				else
					DEBUG "Device $device is a USB device, skipping"
				fi
			else
				DEBUG "Device $device does not exist in /sys/block, skipping"
			fi
		else
			DEBUG "Device $device is not a LUKS device"
		fi
	done | sort
}

# Prompt for LUKS Disk Recovery Key passphrase
prompt_luks_passphrase() {
	TRACE_FUNC
	while [[ ${#luks_current_Disk_Recovery_Key_passphrase} -lt 8 ]]; do
		INPUT "Enter the LUKS Disk Recovery Key passphrase (at least 8 characters):" -r luks_current_Disk_Recovery_Key_passphrase
		if [[ ${#luks_current_Disk_Recovery_Key_passphrase} -lt 8 ]]; then
			WARN "Passphrase must be at least 8 characters long. Please try again."
			unset luks_current_Disk_Recovery_Key_passphrase
			continue
		fi
	done
	echo -n "$luks_current_Disk_Recovery_Key_passphrase" >/tmp/secret/luks_current_Disk_Recovery_Key_passphrase
}

# Test LUKS passphrase against all found LUKS containers that are not USB
test_luks_passphrase() {
	TRACE_FUNC
	DEBUG "Testing LUKS passphrase against all found LUKS containers"
	list_local_luks_devices >/tmp/luks_devices.txt
	if [ ! -s /tmp/luks_devices.txt ]; then
		WARN "No LUKS devices found"
		return 1
	fi

	valid_luks_devices=()
	while read -r luks_device; do
		DEBUG "Testing passphrase on device: $luks_device"
		if cryptsetup open --test-passphrase "$luks_device" --key-file /tmp/secret/luks_current_Disk_Recovery_Key_passphrase; then
			DEBUG "Passphrase valid for $luks_device"
			valid_luks_devices+=("$luks_device")
		else
			DEBUG "Passphrase test failed on $luks_device"
		fi
	done </tmp/luks_devices.txt

	if [ ${#valid_luks_devices[@]} -eq 0 ]; then
		DEBUG "No valid LUKS devices found with the provided passphrase"
		return 1
	fi

	DEBUG "Valid LUKS devices found: ${valid_luks_devices[*]}"
	export LUKS="${valid_luks_devices[*]}"
	return 0
}

# Confirm with the user to use all unlockable LUKS partitions
confirm_luks_partitions() {
	TRACE_FUNC
	DEBUG "Confirming with the user to use all unlockable LUKS partitions"
	MSG="The following LUKS partitions can be unlocked:\n\n${LUKS}\n\nDo you want to use all of these partitions?"
	if [ -x /bin/whiptail ]; then
		if ! whiptail --title "Confirm LUKS Partitions" --yesno "$MSG" 0 80; then
			DIE "User aborted the operation"
		fi
	else
		INFO "$MSG"
		INPUT "Do you want to use all of these partitions? (y/n):" -n 1 -r confirm
		if [ "$confirm" != "y" ]; then
			DIE "User aborted the operation"
		fi
	fi
	DEBUG "User confirmed LUKS partitions: $LUKS"
}

# Main function to prompt for passphrase, test it, and confirm partitions
main_luks_selection() {
	TRACE_FUNC
	prompt_luks_passphrase
	if ! test_luks_passphrase; then
		DIE "Passphrase test failed on all LUKS devices"
	fi
	confirm_luks_partitions
	DEBUG "Selected LUKS partitions: $LUKS"
}

#Whiptail prompt asking user to select ratio of device to use for LUKS container between: 25, 50, 75
select_luks_container_size_percent() {
	TRACE_FUNC
	if [ -x /bin/whiptail ]; then
		#whiptail prompt asking user to select ratio of device to use for LUKS container between: 25, 50, 75
		#whiptail returns the percentage of the device to use for LUKS container
		whiptail --title "Select LUKS container size percentage of device" --menu \
			"Select LUKS container size percentage of device:" 0 80 10 \
			"10" "10%" \
			"25" "25%" \
			"50" "50%" \
			"75" "75%" \
			2>/tmp/luks_container_size_percent ||
			DIE "Error selecting LUKS container size percentage of device"
	else
		#console prompt asking user to select ratio of device to use for LUKS container between: 10, 25, 50, 75
		#console prompt returns the percentage of the device to use for LUKS container
		INPUT "Select LUKS container size percentage of device:\n  1. 10%\n  2. 25%\n  3. 50%\n  4. 75%\nChoice [1-4]:" -n 1 -r option_index
		if [ "$option_index" = "1" ]; then
			echo "10" >/tmp/luks_container_size_percent
		elif [ "$option_index" = "2" ]; then
			echo "25" >/tmp/luks_container_size_percent
		elif [ "$option_index" = "3" ]; then
			echo "50" >/tmp/luks_container_size_percent
		elif [ "$option_index" = "4" ]; then
			echo "75" >/tmp/luks_container_size_percent
		else
			DIE "Error selecting LUKS container size percentage of device"
		fi
	fi
}

# Partition a device interactively with two partitions: a LUKS container
# containing private ext4 partition and second public exFAT partition
# Size provisioning is done by percentage of the device
interactive_prepare_thumb_drive() {
	TRACE_FUNC
	#Refactoring: only one parameter needed to be prompted for: the passphrase for LUKS container if not coming from oem-provisioning
	#If no passphrase was provided, ask user to select passphrase for LUKS container
	# if no device provided as parameter, we will ask user to select device to partition
	# if no percentage provided as parameter, we will default to 10% of device to use for LUKS container
	# we will validate parameters and not make them positional and print a usage function first

	#Set defaults
	DEVICE=""       #Will list all usb storage devices if not provided as parameter
	PERCENTAGE="10" #default to 10% of device to use for LUKS container (requires a LUKS partition bigger then 32mb!)
	PASSPHRASE=""   #Will prompt user for passphrase if not provided as parameter

	#Parse parameters
	while [ $# -gt 0 ]; do
		case "$1" in
		--device)
			DEVICE=$2
			shift 2
			;;
		--percentage)
			PERCENTAGE=$2
			shift 2
			;;
		--pass)
			PASSPHRASE=$2
			shift 2
			;;
		*)
			DIE "prepare_thumb_drive: unknown argument '$1' - usage: prepare_thumb_drive [--device device] [--percentage percentage] [--pass passphrase]"
			;;
		esac
	done

	DEBUG "DEVICE to partition: $DEVICE"
	DEBUG "PERCENTAGE of device that will be used for LUKS container: $PERCENTAGE"
	#Output provided if passphrase is provided as parameter
	DEBUG "PASSPHRASE for LUKS container: ${PASSPHRASE:+provided}"

	#Prompt for passphrase if not provided as parameter
	if [ -z "$PASSPHRASE" ]; then
		#If no passphrase was provided, ask user to select passphrase for LUKS container
		#console based no whiptail
		while [[ ${#PASSPHRASE} -lt 8 ]]; do
			INPUT "Enter passphrase for LUKS container (at least 8 characters):" -r -s PASSPHRASE
			if [[ ${#PASSPHRASE} -lt 8 ]]; then
				WARN "Passphrase must be at least 8 characters long. Please try again."
				unset PASSPHRASE
				continue
			fi
			INPUT "Confirm passphrase for LUKS container:" -r -s PASSPHRASE_CONFIRM
			if [ "$PASSPHRASE" != "$PASSPHRASE_CONFIRM" ]; then
				WARN "Passphrases do not match. Please try again."
				unset PASSPHRASE
				unset PASSPHRASE_CONFIRM
			fi
		done
	fi

	#If no device was provided, ask user to select device to partition
	if [ -z "$DEVICE" ]; then
		#WARN user to disconnect all external drives
		if [ -x /bin/whiptail ]; then
			whiptail_warning --title "WARNING: Disconnect all external drives" --msgbox \
				"WARNING: Please disconnect all external drives before proceeding.\n\nHit Enter to continue." 0 80 ||
				DIE "User cancelled wiping and repartitioning of $DEVICE"
		else
			NOTE "Please disconnect all external drives before proceeding."
			INPUT "Continue? [Y/n]:" -n 1 -r response
			#transform response to uppercase with bash parameter expansion
			response=${response^^}
			#continue if response different then uppercase N
			if [[ $response =~ ^(N)$ ]]; then
				DIE "User cancelled wiping and repartitioning of $DEVICE"
			fi
		fi

		#enable usb
		enable_usb
		#enable usb storage
		enable_usb_storage

		#list all usb storage devices
		list_usb_storage disks >/tmp/devices.txt
		if [ $(cat /tmp/devices.txt | wc -l) -gt 0 ]; then
			file_selector "/tmp/devices.txt" "Select device to partition"
			if [ "$FILE" == "" ]; then
				DIE "Error: No device selected"
			else
				DEVICE=$FILE
			fi
		else
			DIE "Error: No device found"
		fi
	fi

	#Check if device is a block device
	if [ ! -b $DEVICE ]; then
		DIE "Error: $DEVICE is not a block device"
	fi

	if [ -z "$PERCENTAGE" ]; then
		#If no percentage was provided, ask user to select percentage of device to use for LUKS container
		select_luks_container_size_percent
		PERCENTAGE=$(cat /tmp/luks_container_size_percent)
	fi

	confirm_thumb_drive_format "$DEVICE" "$PERCENTAGE" ||
		DIE "User cancelled wiping and repartitioning of $DEVICE"

	prepare_thumb_drive "$DEVICE" "$PERCENTAGE" "$PASSPHRASE"
}

# Show a prompt to confirm formatting a flash drive with a percentage allocated
# to LUKS.  interactive_prepare_thumb_drive() uses this; during OEM reset it is
# used separately before performing any reset actions
#
# parameters:
# $1 - block device of flash drive
# $2 - percent of device allocated to LUKS [1-99]
confirm_thumb_drive_format() {
	TRACE_FUNC
	local DEVICE LUKS_PERCENTAGE DISK_SIZE_BYTES DISK_SIZE_DISPLAY LUKS_PERCENTAGE LUKS_SIZE_MB MSG

	DEVICE="$1"
	LUKS_PERCENTAGE="$2"

	LUKS_SIZE_MB=

	#Get disk size in bytes
	DISK_SIZE_BYTES="$(blockdev --getsize64 "$DEVICE")"
	DISK_SIZE_DISPLAY="$(display_size "$DISK_SIZE_BYTES")"
	#Convert disk size to MB
	DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
	#Calculate percentage of device in MB
	LUKS_SIZE_MB="$((DISK_SIZE_BYTES * LUKS_PERCENTAGE / 100 / 1024 / 1024))"

	MSG="WARNING: Wiping and repartitioning $DEVICE ($DISK_SIZE_DISPLAY) with $LUKS_SIZE_MB MB\n assigned to private LUKS ext4 partition,\n rest assigned to exFAT public partition.\n\nAre you sure you want to continue?"
	if [ -x /bin/whiptail ]; then
		whiptail_warning --title "WARNING: Wiping and repartitioning $DEVICE ($DISK_SIZE_DISPLAY)" --yesno \
			"$MSG" 0 80
	else
		NOTE "$MSG"
		INPUT "Continue? [Y/n]:" -n 1 -r response
		#transform response to uppercase with bash parameter expansion
		response=${response^^}
		#continue if response is Y, y, or empty, abort for anything else
		if [ -n "$response" ] && [ "${response^^}" != Y ]; then
			return 1
		fi
	fi
}

# Prepare a flash drive with a private LUKS-encrypted ext4 partition and a
# public exFAT partition.  This is not interactive - during OEM reset, any
# selections/confirmations must occur before OEM reset starts resetting the
# system.
#
# $1 - block device of flash drive
# $2 - percentage of flash drive to allocate to LUKS [1-99]
# $3 - passphrase for LUKS container
prepare_thumb_drive() {
	TRACE_FUNC

	local DEVICE PERCENTAGE PASSPHRASE DISK_SIZE_BYTES PERCENTAGE_MB
	DEVICE="$1"
	PERCENTAGE="$2"
	PASSPHRASE="$3"

	#Get disk size in bytes
	DISK_SIZE_BYTES="$(blockdev --getsize64 "$DEVICE")"
	#Calculate percentage of device in MB
	PERCENTAGE_MB="$((DISK_SIZE_BYTES * PERCENTAGE / 100 / 1024 / 1024))"

	STATUS "Preparing $DEVICE: ${PERCENTAGE_MB}MB LUKS private + exFAT public partition"
	STATUS "Please wait..."
	DEBUG "Creating empty DOS partition table on device through fdisk to start clean"
	echo -e "o\nw\n" | fdisk $DEVICE >/dev/null 2>&1 || DIE "Error creating partition table"
	DEBUG "partition device with two partitions: first one being the percent applied and rest for second partition through fdisk"
	echo -e "n\np\n1\n\n+"$PERCENTAGE_MB"M\nn\np\n2\n\n\nw\n" | fdisk $DEVICE >/dev/null 2>&1 || DIE "Error partitioning device"
	DEBUG "cryptsetup luksFormat  first partition with LUKS container aes-xts-plain64 cipher with sha256 hash and 512 bit key"
	DEBUG "Creating ${PERCENTAGE_MB}MB LUKS container on ${DEVICE}1..."
	DO_WITH_DEBUG cryptsetup --batch-mode -c aes-xts-plain64 -h sha256 -s 512 -y luksFormat ${DEVICE}1 \
		--key-file <(echo -n "${PASSPHRASE}") >/dev/null 2>&1 ||
		DIE "Error formatting LUKS container"
	DEBUG "Opening LUKS device and mapping under /dev/mapper/private..."
	DO_WITH_DEBUG cryptsetup open ${DEVICE}1 private --key-file <(echo -n "${PASSPHRASE}") >/dev/null 2>&1 ||
		DIE "Error opening LUKS container"
	DEBUG "Formatting LUKS container mapped under /dev/mapper/private as an ext4 partition..."
	mke2fs -t ext4 -L private /dev/mapper/private >/dev/null 2>&1 || DIE "Error formatting LUKS container's ext4 filesystem"
	DEBUG "Closing LUKS device /dev/mapper/private..."
	cryptsetup close private >/dev/null 2>&1 || DIE "Error closing LUKS container"
	DEBUG "Formatting second partition ${DEVICE}2 with exfat filesystem..."
	mkfs.exfat -L public ${DEVICE}2 >/dev/null 2>&1 || DIE "Error formatting second partition with exfat filesystem"
	STATUS_OK "Done."
}

# Select LUKS container
select_luks_container() {
	TRACE_FUNC
	if [ -s /boot/kexec_key_devices.txt ]; then
		DEBUG "Reusing known good LUKS container device from /boot/kexec_key_devices.txt"
		LUKS=$(cut -d ' ' -f1 /boot/kexec_key_devices.txt)
		DEBUG "LUKS container device: $(echo $LUKS)"
	elif [ -z "$LUKS" ]; then
		main_luks_selection
	fi
}

# Test LUKS current disk recovery key passphrase
test_luks_current_disk_recovery_key_passphrase() {
	TRACE_FUNC
	while :; do
		select_luks_container || return 1

		PRINTABLE_LUKS=$(echo $LUKS)

		STATUS "$PRINTABLE_LUKS: Unlocking with LUKS Disk Recovery Key passphrase"
		if [ -z "$luks_current_Disk_Recovery_Key_passphrase" ]; then
			INPUT "Enter the current LUKS Disk Recovery Key passphrase (configured at OS installation or by OEM):" -r luks_current_Disk_Recovery_Key_passphrase
			echo -n "$luks_current_Disk_Recovery_Key_passphrase" >/tmp/secret/luks_current_Disk_Recovery_Key_passphrase
		else
			echo -n "$luks_current_Disk_Recovery_Key_passphrase" >/tmp/secret/luks_current_Disk_Recovery_Key_passphrase
		fi

		for luks_container in $LUKS; do
			DEBUG "$luks_container: Test unlocking of LUKS encrypted drive content with current LUKS Disk Recovery Key passphrase..."
			if ! cryptsetup open --test-passphrase "$luks_container" --key-file /tmp/secret/luks_current_Disk_Recovery_Key_passphrase; then
				whiptail_error --title "$luks_container: Wrong current LUKS Disk Recovery Key passphrase?" --msgbox \
					"If you previously changed it and do not remember it, you will have to reinstall the OS from an external drive.\n\nTo do so, place the ISO file and its signature file on root of an external drive, and select Options-> Boot from USB \n\nHit Enter to retry." 0 80
				detect_boot_device
				mount -o remount,rw /boot
				rm -f /boot/kexec_key_devices.txt
				mount -o remount,ro /boot
				luks_secrets_cleanup
				unset LUKS
			else
				STATUS_OK "$luks_container: unlocked with current Disk Recovery Key passphrase"
				export luks_current_Disk_Recovery_Key_passphrase
			fi
		done

		if [ -n "$LUKS" ]; then
			export LUKS
			TRACE_FUNC
			DEBUG "LUKS container(s) $PRINTABLE_LUKS exported to be reused"
			break
		fi
	done
}

# Function to re-encrypt LUKS partitions
luks_reencrypt() {
	TRACE_FUNC
	test_luks_current_disk_recovery_key_passphrase || return 1

	luks_containers=($LUKS)
	TRACE_FUNC
	DEBUG "luks_containers: ${luks_containers[@]}"

	for luks_container in "${luks_containers[@]}"; do
		DEBUG "$luks_container: Test unlocking with current DRK passphrase..."
		if ! DO_WITH_DEBUG cryptsetup open --test-passphrase "$luks_container" \
			--key-file /tmp/secret/luks_current_Disk_Recovery_Key_passphrase >/dev/null 2>&1; then
			whiptail_error --title "$luks_container: Wrong current LUKS Disk Recovery Key passphrase?" --msgbox \
				"If you previously changed it and do not remember it, you will have to reinstall the OS from an external drive.\n\nTo do so, place the ISO file and its signature file on root of an external drive, and select Options-> Boot from USB \n\nHit Enter to retry." 0 80
			TRACE_FUNC
			detect_boot_device
			mount -o remount,rw /boot
			rm -f /boot/kexec_key_devices.txt
			mount -o remount,ro /boot
			luks_secrets_cleanup
			unset LUKS
			continue
		fi

		# Find the specific keyslot holding the DRK using luksDump (avoids
		# brute-forcing all 32 slots).
		DEBUG "$luks_container: identifying DRK key slot via luksDump"
		luks_version=$(cryptsetup luksDump "$luks_container" | grep "^Version" | cut -d: -f2 | tr -d '[:space:]')
		if [ "$luks_version" = "2" ]; then
			ks_regex="^[[:space:]]+([0-9]+):[[:space:]]*luks2"
			ks_sed='s/^[[:space:]]\+\([0-9]\+\):[[:space:]]*luks2/\1/g'
		elif [ "$luks_version" = "1" ]; then
			ks_regex="Key Slot ([0-9]+): ENABLED"
			ks_sed='s/Key Slot \([0-9]\+\): ENABLED/\1/'
		else
			WARN "$luks_container: unsupported LUKS version '$luks_version', skipping"
			continue
		fi
		mapfile -t used_keyslots < <(cryptsetup luksDump "$luks_container" | grep -E "$ks_regex" | sed "$ks_sed")
		DEBUG "$luks_container: used keyslots: ${used_keyslots[*]}"

		DRK_KEYSLOT=""
		for ks in "${used_keyslots[@]}"; do
			DEBUG "$luks_container: testing keyslot $ks against DRK passphrase"
			if DO_WITH_DEBUG cryptsetup open --test-passphrase "$luks_container" \
				--key-slot "$ks" \
				--key-file /tmp/secret/luks_current_Disk_Recovery_Key_passphrase >/dev/null 2>&1; then
				DRK_KEYSLOT="$ks"
				DEBUG "$luks_container: DRK slot is $DRK_KEYSLOT"
				break
			fi
		done

		if [ -z "$DRK_KEYSLOT" ]; then
			whiptail_error --title "$luks_container: Wrong current LUKS Disk Recovery Key passphrase?" --msgbox \
				"If you previously changed it and do not remember it, you will have to reinstall the OS from an external drive.\n\nTo do so, place the ISO file and its signature file on root of an external drive, and select Options-> Boot from USB \n\nHit Enter to retry." 0 80
			TRACE_FUNC
			detect_boot_device
			mount -o remount,rw /boot
			rm -f /boot/kexec_key_devices.txt
			mount -o remount,ro /boot
			luks_secrets_cleanup
			unset LUKS
			continue
		fi

		# --perf-no_read_workqueue and/or --perf-no_write_workqueue improve encryption/reencrypton performance on kernel 5.10.9+
		# bypassing dm-crypt queues.
		# Ref https://github.com/cloudflare/linux/issues/1#issuecomment-729695518
		# --resilience=none disables the resilience feature of cryptsetup, which is enabled by default
		# --force-offline-reencrypt forces the reencryption to be done offline (no read/write operations on the device)
		# --disable-locks disables the lock feature of cryptsetup, which is enabled by default

		STATUS "Reencrypting $luks_container with current Recovery Disk Key passphrase"
		WARN "DO NOT POWER DOWN MACHINE, UNPLUG AC OR REMOVE BATTERY DURING REENCRYPTION PROCESS"

		if ! DO_WITH_DEBUG cryptsetup reencrypt \
			--perf-no_read_workqueue --perf-no_write_workqueue \
			--resilience=none --force-offline-reencrypt --disable-locks \
			"$luks_container" --key-slot "$DRK_KEYSLOT" \
			--key-file /tmp/secret/luks_current_Disk_Recovery_Key_passphrase; then
			whiptail_error --title "$luks_container: Wrong current LUKS Disk Recovery Key passphrase?" --msgbox \
				"If you previously changed it and do not remember it, you will have to reinstall the OS from an external drive.\n\nTo do so, place the ISO file and its signature file on root of an external drive, and select Options-> Boot from USB \n\nHit Enter to retry." 0 80
			TRACE_FUNC
			detect_boot_device
			mount -o remount,rw /boot
			rm -f /boot/kexec_key_devices.txt
			mount -o remount,ro /boot
			luks_secrets_cleanup
			unset LUKS
		else
			export luks_current_Disk_Recovery_Key_passphrase
			export LUKS
		fi
	done

	luks_tpm_reseal_prompt
}

# Function to change LUKS passphrase
luks_change_passphrase() {
	TRACE_FUNC
	test_luks_current_disk_recovery_key_passphrase || return 1

	luks_containers=($LUKS)
	TRACE_FUNC
	DEBUG "luks_containers: ${luks_containers[@]}"
	# Prompt for new passphrase once before the per-container loop.
	# test_luks_current_disk_recovery_key_passphrase already set and exported
	# luks_current_Disk_Recovery_Key_passphrase and wrote the temp file.
	unset luks_new_Disk_Recovery_Key_passphrase
	whiptail --title 'Changing LUKS Disk Recovery Key passphrase' --msgbox \
		"Please choose a strong passphrase of your own.\n\n**DICEWARE passphrase methodology is STRONGLY ADVISED.**\n\nHit Enter to continue" 0 80
	while [[ ${#luks_new_Disk_Recovery_Key_passphrase} -lt 8 ]]; do
		INPUT "Enter your new LUKS Disk Recovery Key passphrase (at least 8 characters):" -r luks_new_Disk_Recovery_Key_passphrase
		if [[ ${#luks_new_Disk_Recovery_Key_passphrase} -lt 8 ]]; then
			WARN "Passphrase must be at least 8 characters long. Please try again."
			unset luks_new_Disk_Recovery_Key_passphrase
		fi
	done

	echo -n "$luks_current_Disk_Recovery_Key_passphrase" >/tmp/secret/luks_current_Disk_Recovery_Key_passphrase
	echo -n "$luks_new_Disk_Recovery_Key_passphrase" >/tmp/secret/luks_new_Disk_Recovery_Key_passphrase

	for luks_container in "${luks_containers[@]}"; do
		DEBUG "$luks_container: Test unlocking with current DRK passphrase..."
		if ! DO_WITH_DEBUG cryptsetup open --test-passphrase "$luks_container" \
			--key-file /tmp/secret/luks_current_Disk_Recovery_Key_passphrase >/dev/null 2>&1; then
			whiptail_error --title "$luks_container: Wrong current LUKS Disk Recovery Key passphrase?" --msgbox \
				"If you previously changed it and do not remember it, you will have to reinstall the OS from an external drive.\n\nTo do so, place the ISO file and its signature file on root of an external drive, and select Options-> Boot from USB \n\nHit Enter to retry." 0 80
			TRACE_FUNC
			detect_boot_device
			mount -o remount,rw /boot
			rm -f /boot/kexec_key_devices.txt
			mount -o remount,ro /boot
			luks_secrets_cleanup
			unset LUKS
			continue
		fi

		STATUS "Changing $luks_container LUKS passphrase to new Disk Recovery Key passphrase"
		if ! DO_WITH_DEBUG cryptsetup luksChangeKey "$luks_container" --key-file=/tmp/secret/luks_current_Disk_Recovery_Key_passphrase /tmp/secret/luks_new_Disk_Recovery_Key_passphrase; then
			whiptail_error --title 'Failed to change LUKS passphrase' --msgbox \
				"Failed to change the passphrase for $luks_container.\nPlease try again." 0 80
			continue
		fi

		STATUS_OK "Success: passphrase changed for $luks_container"
	done

	# Export the new passphrase if all containers were processed successfully
	luks_current_Disk_Recovery_Key_passphrase=$luks_new_Disk_Recovery_Key_passphrase
	export luks_current_Disk_Recovery_Key_passphrase
	export luks_new_Disk_Recovery_Key_passphrase
	export LUKS

	luks_tpm_reseal_prompt
}

# Cleanup LUKS secrets
luks_secrets_cleanup() {
	TRACE_FUNC

	#Cleanup
	shred -n 10 -z -u /tmp/secret/luks_new_Disk_Recovery_Key_passphrase 2>/dev/null || true
	shred -n 10 -z -u /tmp/secret/luks_current_Disk_Recovery_Key_passphrase 2>/dev/null || true

	#Unset variables (when in same boot)
	unset luks_current_Disk_Recovery_Key_passphrase
	unset luks_new_Disk_Recovery_Key_passphrase
	unset LUKS
}

luks_tpm_reseal_prompt() {
	# Warn user that TPM must be resealed before rebooting after LUKS changes
	# Only prompt if TPM is enabled AND there's a disk unlock key to reseal
	if [ "$CONFIG_TPM" = "y" ] && [ -s /boot/kexec_key_devices.txt ]; then
		whiptail_warning --title 'TPM Reseal Required' \
			--menu "LUKS passphrase changed - you MUST generate new TOTP/HOTP secret to reseal the TPM.\n\nOtherwise the system will not boot on next reboot.\n\nWhat would you like to do?" 0 80 2 \
			'g' ' Generate new TOTP/HOTP secret now' \
			'r' ' Return to Options menu' \
			2>/tmp/whiptail || return
		local luks_passphrase_change_action
		luks_passphrase_change_action=$(cat /tmp/whiptail)
		case "$luks_passphrase_change_action" in
		g)
			# Call TPM/TOTP/HOTP Options menu directly to generate new secret
			show_tpm_totp_hotp_options_menu
			;;
		r)
			return
			;;
		esac
	fi
}
