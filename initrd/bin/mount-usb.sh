#!/bin/bash
# Mount a USB device
. /etc/functions.sh

enable_usb

if ! lsmod | grep -q usb_storage; then
  count=$(find /dev/sd* 2>/dev/null | wc -l)
  timeout=0
  echo "Scanning for USB storage devices..."
  insmod /lib/modules/usb-storage.ko >/dev/null 2>&1 \
  || die "usb_storage: module load failed"
  while [[ $count == $(find /dev/sd* 2>/dev/null | wc -l) ]]; do
    [[ $timeout -ge 4 ]] && break
    sleep 1
    timeout=$((timeout+1))
  done
fi

if [ ! -d /media ]; then
  mkdir /media
fi

stat -c %N /sys/block/sd* 2>/dev/null | grep usb | cut -f1 -d ' ' | sed "s/[']//g;s|/sys/block|/dev|" > /tmp/usb_block_devices
USB_BLOCK_DEVICES=$(cat /tmp/usb_block_devices)
if [ -z  "$USB_BLOCK_DEVICES" ]; then
  if [ -x /bin/whiptail ]; then
    whiptail --title 'USB Drive Missing' \
      --msgbox "Insert your USB drive and press Enter to continue." 16 60
  else
    echo "+++ USB Drive Missing! Insert your USB drive and press Enter to continue."
    read -r
  fi
  sleep 1
  stat -c %N /sys/block/sd* 2>/dev/null | grep usb | cut -f1 -d ' ' | sed "s/[']//g;s|/sys/block|/dev|" > /tmp/usb_block_devices
  USB_BLOCK_DEVICES=$(cat /tmp/usb_block_devices)
  if [ -z "$USB_BLOCK_DEVICE" ]; then
    if [ -x /bin/whiptail ]; then
      # shellcheck disable=2086
      whiptail $BG_COLOR_ERROR --title 'ERROR: USB Drive Missing' \
        --msgbox "USB Drive Missing! Aborting mount attempt.\n\nPress Enter to continue." 16 60
    else
      echo "!!! ERROR: USB Drive Missing! Aborting mount. Press Enter to continue."
    fi
    exit 1
  fi
fi

USB_MOUNT_DEVICE=""
# Check for the common case: a single USB disk with one partition
USB_BLOCK_DEVICE_COUNT=$(wc -l /tmp/usb_block_devices)
if [ $((USB_BLOCK_DEVICE_COUNT)) -eq 1 ]; then
  USB_BLOCK_DEVICE=$(cat /tmp/usb_block_devices)
  # Subtract out block device
  USB_BLOCK_DEVICE_COUNT=$(find "$USB_BLOCK_DEVICE*" | wc -l)
  USB_NUM_PARTITIONS=$((USB_BLOCK_DEVICE_COUNT-1))
  if [ $((USB_NUM_PARTITIONS)) -eq 0 ]; then
    USB_MOUNT_DEVICE=${USB_BLOCK_DEVICE}
  elif [ $((USB_NUM_PARTITIONS)) -eq 1 ]; then
    USB_MOUNT_DEVICE=$(find "$USB_BLOCK_DEVICE*" | tail -n1)
  fi
fi
# otherwise, let the user pick
if [ -z "$USB_MOUNT_DEVICE" ]; then
  # > /tmp/usb_disk_list
  USB_BLOCK_DEVICES=$(cat /tmp/usb_block_devices)
  for i in $USB_BLOCK_DEVICES; do
    # remove block device from list if numeric partitions exist, since not bootable
    USB_BLOCK_DEVICE_COUNT=$(find "$i*" | wc -l)
    USB_NUM_PARTITIONS=$((USB_BLOCK_DEVICE_COUNT-1))
    if [ $((USB_NUM_PARTITIONS)) -eq 0 ]; then
      BLK_LABELS=$(blkid | grep "$i" | grep -o 'LABEL=".*"' | cut -f2 -d '"')
      echo "$i $BLK_LABELS" >> /tmp/usb_disk_list
    else
      for j in $(find "$i*" | tail -$((USB_NUM_PARTITIONS))); do
        BLK_LABELS=$(blkid | grep "$j" | grep -o 'LABEL=".*"' | cut -f2 -d '"')
        echo "$j $BLK_LABELS"  >> /tmp/usb_disk_list
      done
    fi
  done

  if [ -x /bin/whiptail ]; then
    MENU_OPTIONS=""
    n=0
    while read -r option
    do
      n=$((n + 1))
      option=$(echo "$option" | tr " " "_")
      MENU_OPTIONS="$MENU_OPTIONS $n ${option}"
    done < /tmp/usb_disk_list

    MENU_OPTIONS="$MENU_OPTIONS a Abort"
    whiptail --clear --title "Select your USB disk" \
      --menu "Choose your USB disk [1-$n, a to abort]:" 20 120 8 \
      -- "$MENU_OPTIONS" \
      2>/tmp/whiptail

    option_index=$(cat /tmp/whiptail)
  else
    echo "+++ Select your USB disk:"
    n=0
    while read -r option
    do
      n=$((n + 1))
      echo "$n. $option"
    done < /tmp/usb_disk_list

    read -r \
      -p "Choose your USB disk [1-$n, a to abort]: " \
      option_index
  fi

  if [ "$option_index" = "a" ]; then
    exit 5
  fi
  USB_MOUNT_DEVICE=$(head -n $((option_index)) /tmp/usb_disk_list | tail -1 | sed 's/\ .*$//')
fi

if [ "$1" = "rw" ]; then
  mount -o rw "$USB_MOUNT_DEVICE" /media
else
  mount -o ro "$USB_MOUNT_DEVICE" /media
fi
