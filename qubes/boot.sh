#!/bin/sh
# /boot/boot.sh -- Startup Qubes
#
# The signature on this script will be verified by the ROM,
# and this script lives on the /boot partition to allow
# the system owner to change the specific Qubes boot parameters
#
# This depends on the PCR 4 being "normal-boot":
# f8fa3b6e32e7c6fe04c366e74636e505b28f3b0d
# which is only set if the top level /init script has started
# without user intervention or dropping into a recovery shell.
#
# To sign this script and the other bootable components:
#
#	gpg -a --sign --detach-sign boot.sh
#

XEN=/boot/xen-4.6.4.heads
INITRD=/boot/initramfs-4.4.14-11.pvops.qubes.x86_64.img
KERNEL=/boot/vmlinuz-4.4.14-11.pvops.qubes.x86_64


recovery() {
	echo >&2 "!!!!! $@"
	rm -f /tmp/secret.key /initrd.gz
	tpm extend -ix 4 -ic recovery

	echo >&2 "!!!!! Starting recovery shell"
	exec /bin/ash
}

. /config

echo "+++ Checking $XEN"
gpgv "${XEN}.asc" "${XEN}" \
	|| recovery 'Xen signature failed'

echo "+++ Checking $INITRD"
gpgv "${INITRD}.asc" "${INITRD}" \
	|| recovery 'Initrd signature failed'

echo "+++ Checking $KERNEL"
gpgv "${KERNEL}.asc" "${KERNEL}" \
	|| recovery 'Kernel signature failed'

# Activate the dom0 group
lvm vgchange -a y "$CONFIG_QUBES_VG" \
	|| recovery "$CONFIG_QUBES_VG: LVM volume group activate failed"

# Measure the LUKS headers before we unseal the disk key
qubes-measure-luks /dev/$CONFIG_QUBES_VG/* \
	|| recovery "LUKS measure failed"

# get the UUID of the root file system
# busybox blkid doesn't have a "just the UUID" option
ROOT_UUID=`blkid /dev/$CONFIG_QUBES_VG/00 | cut -d\" -f2`
if [ -z "$ROOT_UUID" ]; then
	recovery "$CONFIG_QUBES_VG/00: No UUID for /"
fi

echo "$CONFIG_QUBES_VG/00: UUID=$ROOT_UUID"

# Attempt to unseal the disk key from the TPM
# should we give this some number of tries?
unseal-key \
	|| recovery 'Unseal disk key failed. Starting recovery shell'

# Unpack the initrd and fixup the /etc/crypttab
# this is a hack to split it into two parts since
# we know that the first 0x3400 bytes are the microcode
INITRD_DIR=/tmp/initrd
echo '+++ Unpacking initrd'
mkdir -p $INITRD_DIR/etc
#dd if="$INITRD" bs=256 count=52 | ( cd $INITRD_DIR ; cpio -i )
#dd if="$INITRD" bs=256 skip=52 | zcat | ( cd $INITRD_DIR ; cpio -i )

mv /tmp/secret.key $INITRD_DIR/

## Update the /etc/crypttab in the initrd and install our key
## This is no longer required, now that dom0 /etc/crypttab has
## the /secret.key specified.
#for dev in /dev/$CONFIG_QUBES_VG/*; do
#	uuid=`blkid $dev | cut -d\" -f2`
#	echo luks-$uuid /dev/disk/by-uuid/$uuid /secret.key
#done > $INITRD_DIR/etc/crypttab

echo '+++ Repacking initrd'
( cd $INITRD_DIR ; find . | cpio -H newc -o ) > /initrd.cpio
cat "$INITRD" >> /initrd.cpio

# command line arguments are include in the signature on this script,
echo '+++ Loading kernel and initrd'
kexec \
	-l \
	--module "${KERNEL} root=/dev/mapper/luks-$ROOT_UUID ro rd.qubes.hide_all_usb" \
	--module /initrd.cpio \
	--command-line "no-real-mode reboot=no" \
	"${XEN}" \
|| recovery "kexec load failed"

# Last step is to override PCR 4 so that user can't read the key
tpm extend -ix 4 -ic qubes \
	|| recovery 'Unable to scramble PCR'

echo "+++ Starting Qubes..."
sleep 2
exec kexec -e
