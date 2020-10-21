#!/bin/sh
# Mount a USB device
. /etc/functions.sh

enable_usb

if ! lsmod | grep -q usb_storage; then
  init_dev_count=$(find /dev/sd* 2>/dev/null | wc -l)
  count=$init_dev_count
  timeout=0
  echo "Scanning for USB storage devices..."
  insmod /lib/modules/usb-storage.ko >/dev/null 2>&1 \
  || die "usb_storage: module load failed"
  while [ $((init_dev_count)) -eq $((count)) ]; do
    [ $((timeout)) -ge 4 ] && break
    sleep 1
    timeout=$((timeout+1))
    count=$(find /dev/sd* 2>/dev/null | wc -l)
  done
fi

if [ ! -d /media ]; then
  mkdir /media
fi

USB_BLOCK_DEV_COUNT=$(stat -c %N /sys/block/sd* 2>/dev/null | grep usb | cut -f1 -d ' ' | sed "s/[']//g;s|/sys/block|/dev|" | wc -l)
if [ $((USB_BLOCK_DEV_COUNT)) -eq 0 ]; then
  if [ -x /bin/whiptail ]; then
    whiptail --title 'USB Drive Missing' \
      --msgbox "Insert your USB drive and press Enter to continue." 16 60
  else
    echo "+++ USB Drive Missing! Insert your USB drive and press Enter to continue."
    read -r
  fi
  sleep 1
  USB_BLOCK_DEV_COUNT=$(stat -c %N /sys/block/sd* 2>/dev/null | grep usb | cut -f1 -d ' ' | sed "s/[']//g;s|/sys/block|/dev|"| wc -l)
  if [ $((USB_BLOCK_DEV_COUNT)) -eq 0 ]; then
    if [ -x /bin/whiptail ]; then
      whiptail "$CONFIG_ERROR_BG_COLOR" --title 'ERROR: USB Drive Missing' \
        --msgbox "USB Drive Missing! Aborting mount attempt.\n\nPress Enter to continue." 16 60
    else
      echo "!!! ERROR: USB Drive Missing! Aborting mount. Press Enter to continue."
    fi
    exit 1
  fi
fi

USB_MOUNT_DEVICE=""
# Check for the common case: a single USB disk with one partition
USB_BLOCK_DEV_COUNT=$(wc -l /tmp/usb_block_devices)
if [ $((USB_BLOCK_DEV_COUNT)) -eq 1 ]; then
  USB_BLOCK_DEVICES=$(cat /tmp/usb_block_devices)
  USB_NUM_PARTITIONS=$(find "$USB_BLOCK_DEVICES"* | wc -l)
  # Subtract out block device
  USB_NUM_PARTITIONS=$((USB_NUM_PARTITIONS-1))
  if [ $((USB_NUM_PARTITIONS)) -eq 0 ]; then
    USB_MOUNT_DEVICE="$USB_BLOCK_DEVICES"
  elif [ $((USB_NUM_PARTITIONS)) -eq 1 ]; then
    USB_MOUNT_DEVICE=$(find "$USB_BLOCK_DEVICES"* | tail -n1)
  fi
fi
# otherwise, let the user pick
if [ -z "$USB_MOUNT_DEVICE" ]; then
  # > /tmp/usb_disk_list
  USB_BLOCK_DEVICES=$(cat /tmp/usb_block_devices)
  USB_NUM_PARTITIONS=$(find "$USB_BLOCK_DEVICES"* | wc -l)
  for i in $USB_BLOCK_DEVICES; do
    # remove block device from list if numeric partitions exist, since not bootable
    USB_NUM_PARTITIONS=$((USB_NUM_PARTITIONS-1))
    if [ $((USB_NUM_PARTITIONS)) -eq 0 ]; then
      USB_DISK=$(blkid | grep "$i" | grep -o 'LABEL=".*"' | cut -f2 -d '"')
      echo "$i $USB_DISK" >> /tmp/usb_disk_list
    else
      for j in $(find "$i*" | tail -$((USB_NUM_PARTITIONS))); do
        USB_DISK=$(blkid | grep "$j" | grep -o 'LABEL=".*"' | cut -f2 -d '"')
        echo "$j $USB_DISK" >> /tmp/usb_disk_list
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
