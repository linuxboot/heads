#!/bin/sh
#
# based off of flashrom-x230 and usb-scan
#
# Scan for USB installation options
set -e -o pipefail
. /etc/functions
. /etc/config

# Mount the USB boot device
if ! grep -q /media /proc/mounts ; then
  mount-usb "$CONFIG_USB_BOOT_DEV" || USB_FAILED=1
  if [ $USB_FAILED -ne 0 ]; then
    if [ ! -e "$CONFIG_USB_BOOT_DEV" ]; then
      if [ -x /bin/whiptail ]; then
        whiptail --title 'USB Drive Missing' \
          --msgbox "Insert the USB drive containing your ROM and press Enter to continue." 16 60
      else
          echo "Insert the USB drive containing your ROM and press Enter to continue."
      fi
      USB_FAILED=0
      mount-usb "$CONFIG_USB_BOOT_DEV" || USB_FAILED=1
    fi
    if [ $USB_FAILED -ne 0 ]; then
      if [ -x /bin/whiptail ]; then
        whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: Mounting /media Failed' \
          --msgbox "Unable to mount $CONFIG_USB_BOOT_DEV" 16 60
      else
        die "ERROR: Unable to mount $CONFIG_USB_BOOT_DEV"
      fi
    fi
  fi
fi

if [ "$1" = "-c" ]; then
  CLEAN=1
else
  CLEAN=0
fi

get_menu_option() {
  if [ -x /bin/whiptail ]; then
    MENU_OPTIONS=""
    n=0
    while read option
    do
      n=`expr $n + 1`
      option=$(echo $option | tr " " "_")
      MENU_OPTIONS="$MENU_OPTIONS $n ${option}"
    done < /tmp/rom_menu.txt

    MENU_OPTIONS="$MENU_OPTIONS a abort"
    whiptail --clear --title "Select your ROM" \
      --menu "Choose the ROM to flash [1-$n, a to abort]:" 20 120 8 \
      -- $MENU_OPTIONS \
      2>/tmp/whiptail || die "Aborting flash attempt"

    option_index=$(cat /tmp/whiptail)
  else
    echo "+++ Select your ROM:"
    n=0
    while read option
    do
      n=`expr $n + 1`
      echo "$n. $option"
    done < /tmp/rom_menu.txt

    read \
      -p "Choose the ROM to flash [1-$n, a to abort]: " \
      option_index
  fi

  if [ "$option_index" = "a" ]; then
    die "Aborting flash attempt"
  fi

  option=`head -n $option_index /tmp/rom_menu.txt | tail -1`
}

flash_rom() {
  ROM=$1
  cp "$ROM" /tmp/librem.rom
  sha256sum /tmp/librem.rom
  if [ "$CLEAN" -eq 0 ]; then
    preserve_rom /tmp/librem.rom \
    || die "$ROM: Config preservation failed"
  fi

  flashrom \
    -p internal:laptop=force_I_want_a_brick,ich_spi_mode=hwseq \
    -w /tmp/librem.rom \
  || die "$ROM: Flash failed"
}

# create ROM menu options
ls -1r /media/*.rom 2>/dev/null > /tmp/rom_menu.txt || true
if [ `cat /tmp/rom_menu.txt | wc -l` -gt 0 ]; then
  option_confirm=""
  while [ -z "$option" ]
  do
    get_menu_option
  done

  if [ -n "$option" ]; then
    MOUNTED_ROM=$option
    ROM=${option:7} # remove /media/ to get device relative path

    if [ -x /bin/whiptail ]; then
      if (whiptail --title 'Flash ROM?' \
          --yesno "This will replace your old ROM with $ROM\n\nDo you want to proceed?" 16 90) then
        flash_rom $MOUNTED_ROM
        whiptail --title 'ROM Flashed Successfully' \
          --msgbox "$ROM flashed successfully. Press Enter to reboot" 16 60
        /bin/reboot
      else
        exit 0
      fi
    else
      echo "+++ Flash ROM $ROM?"
      read \
        -n 1 \
        -p "This will replace your old ROM with $ROM, Do you want to proceed? [y/N] " \
        do_flash
      echo
      if [ "$do_flash" != "y" \
        -a "$do_flash" != "Y" ]; then
        exit 0
      fi

      flash_rom $MOUNTED_ROM
      echo "$ROM flashed successfuly. Press Enter to reboot"
      read
      /bin/reboot
    fi

    die "Something failed in ROM flash"
  fi
else
  if [ -x /bin/whiptail ]; then
    whiptail --title 'No ROMs found' \
      --msgbox "No ROMs found on USB disk" 16 60
  else
    echo "No ROMs found on USB disk. Press Enter to continue"
    read
  fi
fi

exit 0
