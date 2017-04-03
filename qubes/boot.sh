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
INITRD=/boot/initramfs-4.4.38-11.pvops.qubes.x86_64.img
KERNEL=/boot/vmlinuz-4.4.38-11.pvops.qubes.x86_64


recovery() {
	echo >&2 "!!!!! $@"
	rm -f /tmp/secret.key
	tpm extend -ix 4 -if recovery

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

# Measure the LUKS headers before we unseal the disk key
qubes-measure-luks $CONFIG_QUBES_DEVS \
	|| recovery "LUKS measure failed"

# Attempt to unseal the disk key from the TPM
# should we give this some number of tries?
unseal-key \
	|| recovery 'Unseal disk key failed. Starting recovery shell'

# command line arguments are include in the signature on this script,
# although the root UUID should be specified in some better manner.
kexec \
	-l \
	--module "${KERNEL} root=UUID=257b593f-d4ae-46ee-b499-14bc9ffd37d4 ro rd.qubes.hide_all_usb" \
	--module "${INITRD}" \
	--command-line "no-real-mode reboot=no" \
	"${XEN}" \
|| recovery "kexec load failed"

# Last step is to override PCR 4 so that user can't read the key
tpm extend -ix 4 -ic qubes \
	|| recovery 'Unable to scramble PCR'

echo "+++ Starting Qubes..."
exec kexec -e
