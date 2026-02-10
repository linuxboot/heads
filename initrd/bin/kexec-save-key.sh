#!/bin/bash
# Generate a TPM key used to unlock LUKS disks

# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

TRACE_FUNC
set -e -o pipefail

lvm_volume_group=""
skip_sign="n"
while getopts "sp:d:l:" arg; do
	case $arg in
	s) skip_sign="y" ;;
	p) paramsdir="$OPTARG" ;;
	d) paramsdev="$OPTARG" ;;
	l) lvm_volume_group="$OPTARG" ;;
	*) die "Invalid flag: $arg" ;;
	esac
done

DEBUG "kexec-save-key prior of parsing: paramsdir: $paramsdir, paramsdev: $paramsdev, lvm_volume_group: $lvm_volume_group"

shift "$((OPTIND - 1))"
key_devices=("$@")

DEBUG "kexec-save-key: key_devices: ${key_devices[*]}"

if [ -z "$paramsdir" ]; then
	die "Usage: $0 [-s] -p /boot [-l qubes_dom0] [/dev/sda2 /dev/sda5 ...] "
fi

if [ -z "$paramsdev" ]; then
	paramsdev="$paramsdir"
	DEBUG "kexec-save-key: paramsdev modified to : $paramsdev"
fi

paramsdev="${paramsdev%%/}"
paramsdir="${paramsdir%%/}"

DEBUG "kexec-save-key prior of last override: paramsdir: $paramsdir, paramsdev: $paramsdev, lvm_volume_group: $lvm_volume_group"

if [ -n "$lvm_volume_group" ]; then
	lvm vgchange -a y "$lvm_volume_group" ||
		die "Failed to activate the LVM group"
	for dev in /dev/"$lvm_volume_group"/*; do
		key_devices+=("$dev")
	done
fi

if [ "${#key_devices[@]}" -eq 0 ]; then
	die "No devices specified for TPM key insertion"
fi

# try to switch to rw mode
mount -o rw,remount "$paramsdev"

rm -f "$paramsdir"/kexec_key_lvm.txt || true
if [ -n "$lvm_volume_group" ]; then
	DEBUG "kexec-save-key saving under $paramsdir/kexec_key_lvm.txt : lvm_volume_group: $lvm_volume_group"
	echo "$lvm_volume_group" >"$paramsdir"/kexec_key_lvm.txt ||
		die "Failed to write lvm group to key config "
fi

rm -f "$paramsdir"/kexec_key_devices.txt || true
for dev in "${key_devices[@]}"; do
	DEBUG "Getting UUID for $dev"
	uuid=$(cryptsetup luksUUID "$dev" 2>/dev/null) ||
		die "Failed to get UUID for device $dev"
	DEBUG "Saving under $paramsdir/kexec_key_devices.txt : dev: $dev, uuid: $uuid"
	echo "$dev $uuid" >>"$paramsdir"/kexec_key_devices.txt ||
		die "Failed to add $dev:$uuid to key devices config"
done

kexec-seal-key.sh "$paramsdir" ||
	die "Failed to save and generate LUKS TPM Disk Unlock Key"

DEBUG "kexec-save-key: kexec-seal-key.sh completed"

if [ "$skip_sign" != "y" ]; then
	extparam=
	if [ "$CONFIG_IGNORE_ROLLBACK" != "y" ]; then
		DEBUG "kexec-save-key: CONFIG_IGNORE_ROLLBACK is not set, will sign with -r"
		extparam=-r
	fi
	# sign and auto-roll config counter
	DEBUG "kexec-save-key: signing updated config"
	kexec-sign-config.sh -p "$paramsdir" "$extparam" ||
		die "Failed to sign updated config"
	DEBUG "kexec-save-key: kexec-sign-config.sh completed"
fi

# switch back to ro mode
mount -o ro,remount "$paramsdev"
