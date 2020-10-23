#!/bin/sh
# Save these options to be the persistent default
set -e -o pipefail
. /tmp/config
. /etc/functions

while getopts "b:d:p:i:" arg; do
	case $arg in
		b) bootdir="$OPTARG" ;;
		d) paramsdev="$OPTARG" ;;
		p) paramsdir="$OPTARG" ;;
		i) index="$OPTARG" ;;
	esac
done

if [ -z "$bootdir" -o -z "$index" ]; then
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

TMP_MENU_FILE="/tmp/kexec/kexec_menu.txt"
ENTRY_FILE="$paramsdir/kexec_default.$index.txt"
HASH_FILE="$paramsdir/kexec_default_hashes.txt"

if [ ! -r "$TMP_MENU_FILE" ]; then
	die "No menu options available, please run kexec-select-boot"
fi

entry=`head -n $index $TMP_MENU_FILE | tail -1`
if [ -z "$entry" ]; then
	die "Invalid menu index $index"
fi

KEY_DEVICES="$paramsdir/kexec_key_devices.txt"
KEY_LVM="$paramsdir/kexec_key_lvm.txt"
save_key="n"
if [[ "$CONFIG_TPM" = "y" && "$CONFIG_TPM_NO_LUKS_DISK_UNLOCK" != "y" ]]; then
	if [ ! -r "$KEY_DEVICES" ]; then
		read \
			-n 1 \
			-p "Do you wish to add a disk encryption to the TPM [y/N]: " \
			add_key_confirm
		echo

		if [ "$add_key_confirm" = "y" \
			-o "$add_key_confirm" = "Y" ]; then
			lvm_suggest="e.g. qubes_dom0 or blank"
			devices_suggest="e.g. /dev/sda2 or blank"
			save_key="y"
		fi
	else
		read \
			-n 1 \
			-p "Do you want to reseal a disk key to the TPM [y/N]: " \
			change_key_confirm
		echo

		if [ "$change_key_confirm" = "y" \
			-o "$change_key_confirm" = "Y" ]; then
			old_lvm_volume_group=""
			if [ -r "$KEY_LVM" ]; then
				old_lvm_volume_group=`cat $KEY_LVM` || true
				old_key_devices=`cat $KEY_DEVICES \
				| cut -d\  -f1 \
				| grep -v "$old_lvm_volume_group" \
				| xargs` || true
			else
				old_key_devices=`cat $KEY_DEVICES \
				| cut -d\  -f1 | xargs` || true
			fi

			lvm_suggest="was '$old_lvm_volume_group'"
			devices_suggest="was '$old_key_devices'"
			save_key="y"
		fi
	fi

	if [ "$save_key" = "y" ]; then
		echo "+++ LVM volume groups (lvm vgscan): "
		lvm vgscan || true

		read \
			-p "Encrypted LVM group? ($lvm_suggest): " \
			lvm_volume_group

		echo "+++ Block devices (blkid): "
		blkid || true

		read \
			-p "Encrypted devices? ($devices_suggest): " \
			key_devices

		save_key_params="-s -p $paramsdev"
		if [ -n "$lvm_volume_group" ]; then
			save_key_params="$save_key_params -l $lvm_volume_group $key_devices"
		else
			save_key_params="$save_key_params $key_devices"
		fi
		echo "Running kexec-save-key with params: $save_key_params"
		kexec-save-key $save_key_params \
			|| die "Failed to save the disk key"
	fi
fi

# try to switch to rw mode
mount -o rw,remount $paramsdev

if [ ! -d $paramsdir ]; then
	mkdir -p $paramsdir \
	|| die "Failed to create params directory"
fi
rm $paramsdir/kexec_default.*.txt 2>/dev/null || true
echo "$entry" > $ENTRY_FILE
cd $bootdir && kexec-boot -b "$bootdir" -e "$entry" -f | \
	xargs sha256sum > $HASH_FILE \
|| die "Failed to create hashes of boot files"
if [ ! -r $ENTRY_FILE -o ! -r $HASH_FILE ]; then
	die "Failed to write default config"
fi

# sign and auto-roll config counter
extparam=
if [ "$CONFIG_TPM" = "y" ]; then
	extparam=-r
fi
kexec-sign-config -p $paramsdir $extparam \
|| die "Failed to sign default config"

# switch back to ro mode
mount -o ro,remount $paramsdev
