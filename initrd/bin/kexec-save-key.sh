#!/bin/bash
# Generate a TPM key used to unlock LUKS disks

. /etc/functions.sh

TRACE_FUNC
set -e -o pipefail
. /etc/functions.sh

lvm_volume_group=""
skip_sign="n"
while getopts "sp:d:l:" arg; do
	case $arg in
	s) skip_sign="y" ;;
	p) paramsdir="$OPTARG" ;;
	d) paramsdev="$OPTARG" ;;
	l) lvm_volume_group="$OPTARG" ;;
	esac
done

DEBUG "kexec-save-key.sh prior of parsing: paramsdir: $paramsdir, paramsdev: $paramsdev, lvm_volume_group: $lvm_volume_group"

shift $(expr $OPTIND - 1)
key_devices="$@"

DEBUG "kexec-save-key.sh: key_devices: $key_devices"

if [ -z "$paramsdir" ]; then
	DIE "Usage: $0 [-s] -p /boot [-l qubes_dom0] [/dev/sda2 /dev/sda5 ...] "
fi

if [ -z "$paramsdev" ]; then
	paramsdev="$paramsdir"
	DEBUG "kexec-save-key.sh: paramsdev modified to : $paramsdev"
fi

paramsdev="${paramsdev%%/}"
paramsdir="${paramsdir%%/}"

DEBUG "kexec-save-key.sh prior of last override: paramsdir: $paramsdir, paramsdev: $paramsdev, lvm_volume_group: $lvm_volume_group"

if [ -n "$lvm_volume_group" ]; then
	run_lvm vgchange -a y $lvm_volume_group ||
		DIE "Failed to activate the LVM group"
	for dev in /dev/$lvm_volume_group/*; do
		key_devices="$key_devices $dev"
	done
fi

if [ -z "$key_devices" ]; then
	DIE "No devices specified for TPM key insertion"
fi

# try to switch to rw mode
mount -o rw,remount "$paramsdev"

rm -f "$paramsdir/kexec_key_lvm.txt" || true
if [ -n "$lvm_volume_group" ]; then
	DEBUG "kexec-save-key.sh saving under $paramsdir/kexec_key_lvm.txt : lvm_volume_group: $lvm_volume_group"
	echo "$lvm_volume_group" >"$paramsdir/kexec_key_lvm.txt" ||
		DIE "Failed to write lvm group to key config"
fi

rm -f "$paramsdir/kexec_key_devices.txt" || true
for dev in $key_devices; do
	DEBUG "Getting UUID for $dev"
	uuid=$(cryptsetup luksUUID "$dev" 2>/dev/null) ||
		DIE "Failed to get UUID for device $dev"
	DEBUG "Saving under $paramsdir/kexec_key_devices.txt : dev: $dev, uuid: $uuid"
	echo "$dev $uuid" >>"$paramsdir/kexec_key_devices.txt" ||
		DIE "Failed to add $dev:$uuid to key devices config"
done

# kexec-seal-key.sh tests the DRK passphrase, filters kexec_key_devices.txt to
# only the unlockable subset, then seals the DUK into TPM NVRAM.
kexec-seal-key.sh "$paramsdir" ||
	DIE "Failed to save and generate LUKS TPM Disk Unlock Key"

if [ "$skip_sign" != "y" ]; then
	extparam=
	if [ "$CONFIG_IGNORE_ROLLBACK" != "y" ]; then
		DEBUG "kexec-save-key.sh: CONFIG_IGNORE_ROLLBACK is not set, will sign with -r"
		extparam=-r
	fi
	# Sign the updated /boot — kexec_key_devices.txt now reflects only the
	# devices that actually received a DUK (may be a subset of what was passed).
	DO_WITH_DEBUG kexec-sign-config.sh -p "$paramsdir" $extparam ||
		DIE "Failed to sign updated config"
fi

# switch back to ro mode
mount -o ro,remount $paramsdev
