#!/bin/sh
# Unseal a disk key from TPM and add to a new initramfs
set -e -o pipefail
. /etc/functions

TMP_KEY_DEVICES="/tmp/kexec/kexec_key_devices.txt"
TMP_KEY_LVM="/tmp/kexec/kexec_key_lvm.txt"

INITRD="$1"

if [ -z "$INITRD" ]; then
	die "Usage: $0 /boot/initramfs... "
fi

if [ ! -r "$TMP_KEY_DEVICES" ]; then
	die "No devices defined for disk encryption"
fi

if [ -r "$TMP_KEY_LVM" ]; then
	# Activate the LVM volume group
	VOLUME_GROUP=`cat $TMP_KEY_LVM`
	if [ -z "$TMP_KEY_LVM" ]; then
		die "No LVM volume group defined for activation"
	fi
	lvm vgchange -a y $VOLUME_GROUP \
		|| die "$VOLUME_GROUP: unable to activate volume group"
fi

# Measure the LUKS headers before we unseal the disk key
cat "$TMP_KEY_DEVICES" | cut -d\  -f1 | xargs /bin/qubes-measure-luks \
	|| die "LUKS measure failed"

# Unpack the initrd and fixup the /etc/crypttab
# this is a hack to split it into two parts since
# we know that the first 0x3400 bytes are the microcode
INITRD_DIR=/tmp/secret/initrd
SECRET_CPIO=/tmp/secret/initrd.cpio
mkdir -p "$INITRD_DIR/etc"

# Attempt to unseal the disk key from the TPM
# should we give this some number of tries?
unseal_failed="n"
if ! kexec-unseal-key "$INITRD_DIR/secret.key" ; then
	unseal_failed="y"
	echo "!!! Failed to unseal the TPM LUKS disk key"
fi

# Override PCR 4 so that user can't read the key
tpm extend -ix 4 -ic generic \
	|| die 'Unable to scramble PCR'

# Check to continue
if [ "$unseal_failed" = "y" ]; then
	confirm_boot="n"
	read \
		-n 1 \
		-p "Do you wish to boot and use the disk recovery key? [Y/n] " \
		confirm_boot

	if [ "$confirm_boot" != 'y' \
		-a "$confirm_boot" != 'Y' \
		-a -n "$confirm_boot" ] \
	; then
		die "!!! Aborting boot due to failure to unseal TPM disk key"
	fi
fi

echo '+++ Building initrd'
# pad the initramfs (dracut doesn't pad the last gz blob)
# without this the kernel init/initramfs.c fails to read
# the subsequent uncompressed/compressed cpio
dd if="$INITRD" of="$SECRET_CPIO" bs=512 conv=sync \
|| die "Failed to copy initrd to /tmp"

if [ "$unseal_failed" = "n" ]; then
	# overwrite /etc/crypttab to mirror the behavior for in seal-key
	for uuid in `cat "$TMP_KEY_DEVICES" | cut -d\  -f2`; do
		echo "luks-$uuid UUID=$uuid /secret.key" >> "$INITRD_DIR/etc/crypttab"
	done
	( cd "$INITRD_DIR" ; find . -type f | cpio -H newc -o ) >> "$SECRET_CPIO"
fi
