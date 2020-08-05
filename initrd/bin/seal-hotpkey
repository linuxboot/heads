#!/bin/sh
# Retrieve the sealed TOTP secret and initialize a USB Security dongle with it

. /etc/functions

HOTP_SEALED="/tmp/secret/hotp.sealed"
HOTP_SECRET="/tmp/secret/hotp.key"
HOTP_COUNTER="/boot/kexec_hotp_counter"
HOTP_KEY="/boot/kexec_hotp_key"

mount_boot()
{
  # Mount local disk if it is not already mounted
  if ! grep -q /boot /proc/mounts ; then
    mount -o ro /boot \
      || recovery "Unable to mount /boot"
  fi
}

# Use stored HOTP key branding (this might be useful after OEM reset)
if [ -r /boot/kexec_hotp_key ]; then
	HOTPKEY_BRANDING="$(cat /boot/kexec_hotp_key)"
else
	HOTPKEY_BRANDING="HOTP USB Security Dongle"
fi

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

# Store counter in file instead of TPM for now, as it conflicts with Heads
# config TPM counter as TPM 1.2 can only increment one counter between reboots
# get current value of HOTP counter in TPM, create if absent
mount_boot

#check_tpm_counter $HOTP_COUNTER hotp \
#|| die "Unable to find/create TPM counter"
#counter="$TPM_COUNTER"
#
#counter_value=$(read_tpm_counter $counter | cut -f2 -d ' ' | awk 'gsub("^000e","")')
#if [ "$counter_value" == "" ]; then
#  die "Unable to read HOTP counter"
#fi

#counter_value=$(printf "%d" 0x${counter_value})

counter_value=1

enable_usb
if ! hotp_verification info ; then
  echo "Insert your $HOTPKEY_BRANDING and press Enter to configure it"
  read
  if ! hotp_verification info ; then
    # don't leak key on failure
    shred -n 10 -z -u "$HOTP_SECRET" 2> /dev/null
    die "Unable to find $HOTPKEY_BRANDING"
  fi
fi

# Set HOTP USB Security Dongle branding based on VID
if lsusb | grep -q "20a0:" ; then
	HOTPKEY_BRANDING="Nitrokey"
elif lsusb | grep -q "316d:" ; then
	HOTPKEY_BRANDING="Librem Key"
else
	HOTPKEY_BRANDING="HOTP USB Security Dongle"
fi

echo -e ""
read -s -p "Enter your $HOTPKEY_BRANDING Admin PIN: " admin_pin
echo -e "\n"

hotp_initialize "$admin_pin" $HOTP_SECRET $counter_value "$HOTPKEY_BRANDING"
if [ $? -ne 0 ]; then
  echo -e "\n"
  read -s -p "Error setting HOTP secret, re-enter Admin PIN and try again: " admin_pin
  echo -e "\n"
  if ! hotp_initialize "$admin_pin" $HOTP_SECRET $counter_value "$HOTPKEY_BRANDING" ; then
    # don't leak key on failure
    shred -n 10 -z -u "$HOTP_SECRET" 2> /dev/null
    die "Setting HOTP secret failed"
  fi
fi

# HOTP key no longer needed
shred -n 10 -z -u "$HOTP_SECRET" 2> /dev/null

# Make sure our counter is incremented ahead of the next check
#increment_tpm_counter $counter > /dev/null \
#|| die "Unable to increment tpm counter"
#increment_tpm_counter $counter > /dev/null \
#|| die "Unable to increment tpm counter"

mount -o remount,rw /boot

counter_value=`expr $counter_value + 1`
echo $counter_value > $HOTP_COUNTER \
|| die "Unable to create hotp counter file"

# Store/overwrite HOTP USB Security Dongle branding found out beforehand
echo $HOTPKEY_BRANDING > $HOTP_KEY \
|| die "Unable to store hotp key file"

#sha256sum /tmp/counter-$counter > $HOTP_COUNTER \
#|| die "Unable to create hotp counter file"
mount -o remount,ro /boot

echo -e "\n$HOTPKEY_BRANDING initialized successfully. Press Enter to continue."
read

exit 0
