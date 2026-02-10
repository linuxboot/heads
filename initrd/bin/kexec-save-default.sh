#!/bin/bash
# Save these options to be the persistent default
set -e -o pipefail
# shellcheck disable=SC1091
. /tmp/config
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

TRACE_FUNC

while getopts "b:d:p:i:" arg; do
	case $arg in
		b) bootdir="$OPTARG" ;;
		d) paramsdev="$OPTARG" ;;
		p) paramsdir="$OPTARG" ;;
		i) index="$OPTARG" ;;
		*) die "Invalid option: $arg" ;;
	esac
done

if [ -z "$bootdir" ] || [ -z "$index" ]; then
	die "Usage: $0 -b /boot -i menu_option "
fi

if [ -z "$paramsdev" ]; then
	paramsdev="$bootdir"
fi

if [ -z "$paramsdir" ]; then
	paramsdir="$bootdir"
fi

bootdir="${bootdir%%/}"
paramsdev="${paramsdev%%/}"
paramsdir="${paramsdir%%/}"

DEBUG "kexec-save-default: bootdir='$bootdir' paramsdev='$paramsdev' paramsdir='$paramsdir' index='$index'"

TMP_MENU_FILE="/tmp/kexec/kexec_menu.txt"
ENTRY_FILE="$paramsdir/kexec_default.$index.txt"
HASH_FILE="$paramsdir/kexec_default_hashes.txt"
PRIMHASH_FILE="$paramsdir/kexec_primhdl_hash.txt"
KEY_DEVICES="$paramsdir/kexec_key_devices.txt"
KEY_LVM="$paramsdir/kexec_key_lvm.txt"

lvm_suggest=$(lvm vgscan 2>/dev/null | awk -F '"' '{print $1}' | tail -n +2)
num_lvm=$(echo "$lvm_suggest" | wc -l)
if [ "$num_lvm" -eq 1 ] && [ -n "$lvm_suggest" ]; then
	lvm_volume_group="$lvm_suggest"
elif [ -z "$lvm_suggest" ]; then
	num_lvm=0
fi
# $lvm_suggest is a multiline string, we need to convert it to a space separated string
lvm_suggest=$(echo "$lvm_suggest" | tr '\n' ' ')
DEBUG "LVM num_lvm: $num_lvm, lvm_suggest: $lvm_suggest"

# get all LUKS container devices
devices_suggest=$(blkid | cut -d ':' -f 1 | while read -r device; do
	if cryptsetup isLuks "$device"; then echo "$device"; fi
done | sort)
num_devices=$(echo "$devices_suggest" | wc -l)

if [ "$num_devices" -eq 1 ] && [ -s "$devices_suggest" ]; then
	key_devices=$devices_suggest
elif [ -z "$devices_suggest" ]; then
	num_devices=0
fi
# $devices_suggest is a multiline string, we need to convert it to a space separated string
devices_suggest=$(echo "$devices_suggest" | tr '\n' ' ')
DEBUG "LUKS num_devices: $num_devices, devices_suggest: $devices_suggest"

if [ "$num_lvm" -eq 0 ] && [ "$num_devices" -eq 0 ]; then
	#No encrypted partition found.
	:
fi

#Reusable function when user wants to define new TPM DUK for lvms/disks
prompt_for_existing_encrypted_lvms_or_disks() {
	TRACE_FUNC
	DEBUG "num_lvm: $num_lvm, lvm_suggest: $lvm_suggest, num_devices: $num_devices, devices_suggest: $devices_suggest"

	# Create an associative array to store the suggested LVMs and their paths
	declare -A lvms_array
	# Loop through the suggested LVMs and add them to the array
	for lvm in $lvm_suggest; do
		lvms_array[$lvm]=$lvm
	done

	# Get the number of suggested LVMs
	num_lvms=${#lvms_array[@]}

	if [ "$num_lvms" -gt 1 ]; then
		DEBUG "Multiple LVMs found: $lvm_suggest"
		selected_lvms_not_existing=1
		# Create an array to store the selected LVMs
		declare -a key_lvms_array
		attempts=0

		while [ $selected_lvms_not_existing -ne 0 ] && [ $attempts -lt 3 ]; do
			DEBUG "In LVM selection loop, selected_lvms_not_existing=$selected_lvms_not_existing, attempts=$attempts"
			{
				# Read the user input and store it in a variable
				read -r \
					-p "Encrypted LVMs? (choose between/all: $lvm_suggest): " \
					key_lvms
				DEBUG "key_lvms='$key_lvms'"

				# Split the user input by spaces and add each element to the array
				IFS=' ' read -r -a key_lvms_array <<<"$key_lvms"

				# Loop through the array and check if each element is in the lvms_array
				valid=1
				for lvm in "${key_lvms_array[@]}"; do
					if [[ ! ${lvms_array[$lvm]+_} ]]; then
						# If not found, set the flag to indicate invalid input
						valid=0
						break
					fi
				done

				# If valid, set the flag to indicate valid input
				if [[ $valid -eq 1 ]]; then
					selected_lvms_not_existing=0
				else
					attempts=$((attempts + 1))
					if [ $attempts -eq 3 ]; then
						die "Failed to select valid LVMs after 3 attempts"
					fi
					warn "Invalid LVM selection, please try again"
				fi
				DEBUG "valid=$valid, selected_lvms_not_existing=$selected_lvms_not_existing"
			}
		done
	elif [ "$num_lvms" -eq 1 ]; then
		echo "Single Encrypted LVM found at $lvm_suggest."
		key_lvms=$lvm_suggest
	else
		echo "No encrypted LVMs found."
	fi

	# Create an associative array to store the suggested devices and their paths
	declare -A devices_array
	# Loop through the suggested devices and add them to the array
	for device in $devices_suggest; do
		devices_array[$device]=$device
	done

	# Get the number of suggested devices
	num_devices=${#devices_array[@]}

	if [ "$num_devices" -gt 1 ]; then
		DEBUG "Multiple LUKS devices found: $devices_suggest"
		selected_luksdevs_not_existing=1
		# Create an array to store the selected devices
		declare -a key_devices_array
		attempts=0

		while [ $selected_luksdevs_not_existing -ne 0 ] && [ $attempts -lt 3 ]; do
			DEBUG "In devices selection loop, selected_luksdevs_not_existing=$selected_luksdevs_not_existing, attempts=$attempts"
			{
				# Read the user input and store it in a variable
				read -r \
					-p "Encrypted devices? (choose between/all: $devices_suggest): " \
					key_devices
				DEBUG "key_devices='$key_devices'"

				# Split the user input by spaces and add each element to the array
				IFS=' ' read -r -a key_devices_array <<<"$key_devices"

				# Loop through the array and check if each element is in the devices_array
				valid=1
				for device in "${key_devices_array[@]}"; do
					if [[ ! ${devices_array[$device]+_} ]]; then
						# If not found, set the flag to indicate invalid input
						valid=0
						break
					fi
				done

				# If valid, set the flag to indicate valid input
				if [[ $valid -eq 1 ]]; then
					selected_luksdevs_not_existing=0
				else
					attempts=$((attempts + 1))
					if [ $attempts -eq 3 ]; then
						die "Failed to select valid devices after 3 attempts"
					fi
					warn "Invalid device selection, please try again"
				fi
				DEBUG "valid=$valid, selected_luksdevs_not_existing=$selected_luksdevs_not_existing"
			}
		done
	elif [ "$num_devices" -eq 1 ]; then
		echo "Single Encrypted Disk found at $devices_suggest."
		key_devices=$devices_suggest
	else
		echo "No encrypted devices found."
	fi

	DEBUG "Multiple LUKS devices selected: $key_devices"

}

if [ ! -r "$TMP_MENU_FILE" ]; then
	die "No menu options available, please run kexec-select-boot.sh"
fi

entry=$(head -n "$index" "$TMP_MENU_FILE" | tail -1)
if [ -z "$entry" ]; then
	die "Invalid menu index $index"
fi

DEBUG "kexec-save-default: entry length=${#entry} entry_file='$ENTRY_FILE' hash_file='$HASH_FILE'"

save_key="n"

if [ "$CONFIG_TPM" = "y" ] && [ "$CONFIG_TPM_NO_LUKS_DISK_UNLOCK" != "y" ] && [ "$CONFIG_BASIC" != y ]; then
	DEBUG "TPM is enabled and TPM_NO_LUKS_DISK_UNLOCK is not set"
	DEBUG "Checking if a a LUKS TPM Disk Unlock Key was previously set up from $KEY_DEVICES"
	#check if $KEY_DEVICES file exists and is not empty
	if [ -r "$KEY_DEVICES" ] && [ -s "$KEY_DEVICES" ]; then
		DEBUG "LUKS TPM Disk Unlock Key was previously set up from $KEY_DEVICES"
		read -r \
			-n 1 \
			-p "Do you want to reseal a Disk Unlock Key (DUK) in the TPM or change its passphrase [y/N]: " \
			change_key_confirm
		echo
		DEBUG "change_key_confirm='$change_key_confirm'"

		if [ "$change_key_confirm" = "y" ] || [ "$change_key_confirm" = "Y" ]; then
			old_lvm_volume_group=""
			if [ -r "$KEY_LVM" ]; then
				old_lvm_volume_group=$(cat "$KEY_LVM") || true
				old_key_devices=$(cut -d\  -f1 < "$KEY_DEVICES" |
					grep -v "$old_lvm_volume_group" |
					xargs) || true
			else
				old_key_devices=$(cut -d\  -f1 < "$KEY_DEVICES" | xargs) || true
			fi

			lvm_suggest="$old_lvm_volume_group"
			devices_suggest="$old_key_devices"
			save_key="y"
		fi
	else
		DEBUG "No previous LUKS TPM Disk Unlock Key was set up, confirming to add a Disk Unlock Key (DUK) to the TPM"
		read -r \
			-n 1 \
			-p "Do you wish to seal a Disk Unlock Key (DUK) in the TPM with a passphrase that will be asked prior of every default boot [y/N]: " \
			add_key_confirm
		echo
		DEBUG "add_key_confirm='$add_key_confirm'"

		if [ "$add_key_confirm" = "y" ] || [ "$add_key_confirm" = "Y" ]; then
			DEBUG "User confirmed desire to add a Disk Unlock Key (DUK) to the TPM"
			save_key="y"
		fi
	fi

	if [ "$save_key" = "y" ]; then
		DEBUG "save_key requested; lvm_volume_group='$lvm_volume_group' key_devices='$key_devices'"
		if [ -n "$old_key_devices" ] || [ -n "$old_lvm_volume_group" ]; then
			DEBUG "Previous LUKS TPM Disk Unlock Key (DUK) was set up for $old_key_devices $old_lvm_volume_group"
			read -r \
				-n 1 \
				-p "Do you want to reuse configured Encrypted LVM groups/Block devices $old_key_devices [Y/n]:" \
				reuse_past_devices
			echo
			if [ "$reuse_past_devices" = "y" ] || [ "$reuse_past_devices" = "Y" ] || [ -z "$reuse_past_devices" ]; then
				if [ -z "$key_devices" ] && [ -n "$old_key_devices" ]; then
					key_devices="$old_key_devices"
				fi
				if [ -z "$lvm_volume_group" ] && [ -n "$old_lvm_volume_group" ]; then
					lvm_volume_group="$old_lvm_volume_group"
				fi
			#User doesn't want to reuse past devices, so we need to prompt him from devices_suggest and lvm_suggest
			else
				prompt_for_existing_encrypted_lvms_or_disks
			fi
		else
			DEBUG "No previous LUKS TPM Disk Unlock Key was set up, setting up"
			prompt_for_existing_encrypted_lvms_or_disks
		fi

		save_key_params="-s -p $paramsdev"
		if [ -n "$lvm_volume_group" ]; then
			save_key_params="$save_key_params -l $lvm_volume_group $key_devices"
		else
			save_key_params="$save_key_params $key_devices"
		fi
		DEBUG "kexec-save-default: running kexec-save-key.sh $save_key_params"
		# shellcheck disable=SC2086
		kexec-save-key.sh $save_key_params ||
			die "Failed to save the LUKS TPM Disk Unlock Key (DUK)"
	fi
fi

# try to switch to rw mode
mount -o rw,remount "$paramsdev" ||
	die "Failed to remount $paramsdev as read-write"

if [ ! -d "$paramsdir" ]; then
	mkdir -p "$paramsdir" ||
		die "Failed to create params directory"
fi

if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
	if [ -f /tmp/secret/primary.handle ]; then
		DEBUG "Hashing TPM2 primary key handle..."
		sha256sum /tmp/secret/primary.handle > "$PRIMHASH_FILE" ||
			die "ERROR: Failed to Hash TPM2 primary key handle!"
		DEBUG "TPM2 primary key handle hash saved to $PRIMHASH_FILE"
	else
		die "ERROR: TPM2 primary key handle file does not exist!"
	fi
fi

rm "$paramsdir"/kexec_default.*.txt 2>/dev/null || true
echo "$entry" >"$ENTRY_FILE"

DEBUG "kexec-save-default: generating hashes for entry $ENTRY_FILE"
(
	cd "$bootdir" && kexec-boot.sh -b "$bootdir" -e "$entry" -f |
		xargs sha256sum >"$HASH_FILE"
) || die "Failed to create hashes of boot files"

DEBUG "kexec-save-default: hash generation complete"
if [ ! -r "$ENTRY_FILE" ] || [ ! -r "$HASH_FILE" ]; then
	die "Failed to write default config"
fi

if [ "$save_key" = "y" ]; then
	# logic to parse OS initrd to extract crypttab, its filepaths and its OS defined options
	initrd_decompressed="/tmp/initrd_extract"
	mkdir -p "$initrd_decompressed"
	# Get initrd filename selected to be default initrd that OS could be using to configure LUKS on boot by deploying crypttab files
	DEBUG "kexec-save-default: locating initrd for entry via kexec-boot.sh -i"
	DEBUG "kexec-save-default: entry='$entry'"
	current_default_initrd=$(kexec-boot.sh -b "$bootdir" -e "$entry" -i | head -n 1) ||
		die "Failed to locate initrd via kexec-boot.sh"
	DEBUG "kexec-save-default: initrd from kexec-boot.sh: '$current_default_initrd'"

	if [ -z "$current_default_initrd" ]; then
		DEBUG "kexec-save-default: falling back to /boot/kexec_default_hashes.txt lookup"
		current_default_initrd=$(grep -E 'initrd|initramfs' /boot/kexec_default_hashes.txt | awk '{print $NF}' | sed 's/\.\//\/boot\//g' | head -n 1) ||
			die "Failed to find initrd in /boot/kexec_default_hashes.txt"
		DEBUG "kexec-save-default: initrd from hashes: '$current_default_initrd'"
	fi

	if [ -z "$current_default_initrd" ]; then
		die "Extracted initrd path is empty from /boot/kexec_default_hashes.txt"
	fi

	echo "+++ Extracting current selected default boot's $current_default_initrd to find crypttab files..."
	unpack_initramfs.sh "$current_default_initrd" "$initrd_decompressed" ||
		die "Failed to extract initramfs from $current_default_initrd"
	crypttab_files=$(find "$initrd_decompressed" | grep crypttab 2>/dev/null) || true

	if [ -n "$crypttab_files" ]; then
		DEBUG "Found crypttab files in $current_default_initrd"
		rm -f "$bootdir"/kexec_initrd_crypttab_overrides.txt || true

		#Parsing each crypttab file found
		echo "$crypttab_files" | while read -r crypttab_file; do
			# Change crypttab file path to be relative to initrd for string manipulation
			final_initrd_filepath=${crypttab_file#/tmp/initrd_extract}
			DEBUG "Final initramfs crypttab path:$final_initrd_filepath"
			# Keep only non-commented lines for crypttab entries
			current_crypttab_entries=$(grep -v "^#" "$crypttab_file")
			DEBUG "Found initrd crypttab entries $final_initrd_filepath:$current_crypttab_entries"
			# Modify each retained crypttab line for /secret.key under intramfs to be considered as a keyfile
			modified_crypttab_entries=$(echo "$current_crypttab_entries" | sed 's/none/\/secret.key/g')
			DEBUG "Modified crypttab entries $final_initrd_filepath:$modified_crypttab_entries"
			echo "$modified_crypttab_entries" | while read -r modified_crypttab_entry; do
				echo "$final_initrd_filepath:$modified_crypttab_entry" >>"$bootdir"/kexec_initrd_crypttab_overrides.txt
			done
		done

		#insert current default boot's initrd crypttab locations into tracking file to be overwritten into initramfs at kexec-inject-key
		echo "+++ The following OS crypttab file:entry were modified from default boot's initrd:"
		cat "$bootdir"/kexec_initrd_crypttab_overrides.txt
		echo "+++ Heads added /secret.key in those entries and saved them under $bootdir/kexec_initrd_crypttab_overrides.txt"
		echo "+++ Those overrides will be part of detached signed digests and used to prepare cpio injected at kexec of selected default boot entry."
	else
		echo "+++ No crypttab file found in extracted initrd. A generic crypttab will be generated"
		if [ -e "$bootdir/kexec_initrd_crypttab_overrides.txt" ]; then
			echo "+++ Removing $bootdir/kexec_initrd_crypttab_overrides.txt"
			rm -f "$bootdir/kexec_initrd_crypttab_overrides.txt"
		fi
	fi

	# Cleanup
	cd /
	rm -rf /tmp/initrd_extract || true
fi

# sign and auto-roll config counter
extparam=
if [ "$CONFIG_TPM" = "y" ]; then
	if [ "$CONFIG_IGNORE_ROLLBACK" != "y" ]; then
		extparam=-r
	fi
fi
# Save the hash of the TPM2 primary key handle if TPM2 is enabled
if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
	if [ -f /tmp/secret/primary.handle ]; then
		sha256sum /tmp/secret/primary.handle > "$paramsdir/kexec_primhdl_hash.txt" ||
			warn "Failed to save TPM2 primary key handle hash"
	fi
fi

if [ "$CONFIG_BASIC" != "y" ]; then
	DO_WITH_DEBUG kexec-sign-config.sh -p "$paramsdir" $extparam ||
		die "Failed to sign default config"
fi

# switch back to ro mode
mount -o ro,remount "$paramsdev" ||
	die "Failed to remount $paramsdev as read-only"
