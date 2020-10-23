#!/bin/sh
# Retrieve the sealed file and counter from the NVRAM, unseal it and compute the hotp

. /etc/functions

HOTP_SEALED="/tmp/secret/hotp.sealed"
HOTP_SECRET="/tmp/secret/hotp.key"
HOTP_COUNTER="/boot/kexec_hotp_counter"

mount_boot_or_die()
{
  # Mount local disk if it is not already mounted
  if ! grep -q /boot /proc/mounts ; then
    mount -o ro /boot \
      || die "Unable to mount /boot"
  fi
}

# Store counter in file instead of TPM for now, as it conflicts with Heads
# config TPM counter as TPM 1.2 can only increment one counter between reboots
# get current value of HOTP counter in TPM, create if absent
mount_boot_or_die

#check_tpm_counter $HOTP_COUNTER hotp \
#|| die "Unable to find/create TPM counter"
#counter="$TPM_COUNTER"
#
#counter_value=$(read_tpm_counter $counter | cut -f2 -d ' ' | awk 'gsub("^000e","")')
#

counter_value=$(cat $HOTP_COUNTER)

if [ "$counter_value" == "" ]; then
  die "Unable to read HOTP counter"
fi

#counter_value=$(printf "%d" 0x${counter_value})

tpm nv_readvalue \
	-in 4d47 \
	-sz 312 \
	-of "$HOTP_SEALED" \
|| die "Unable to retrieve sealed file from TPM NV"

tpm unsealfile  \
	-hk 40000000 \
	-if "$HOTP_SEALED" \
	-of "$HOTP_SECRET" \
|| die "Unable to unseal HOTP secret"

shred -n 10 -z -u "$HOTP_SEALED" 2> /dev/null

if ! hotp $counter_value < "$HOTP_SECRET"; then
	shred -n 10 -z -u "$HOTP_SECRET" 2> /dev/null
	die 'Unable to compute HOTP hash?'
fi

shred -n 10 -z -u "$HOTP_SECRET" 2> /dev/null

#increment_tpm_counter $counter > /dev/null \
#|| die "Unable to increment tpm counter"

mount -o remount,rw /boot

counter_value=`expr $counter_value + 1`
echo $counter_value > $HOTP_COUNTER \
|| die "Unable to create hotp counter file"

#sha256sum /tmp/counter-$counter > $HOTP_COUNTER \
#|| die "Unable to create hotp counter file"
mount -o remount,ro /boot

exit 0
