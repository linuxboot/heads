#!/bin/sh
#
set -e -o pipefail
. /etc/functions
. /tmp/config

mount_usb(){
# Mount the USB boot device
  if ! grep -q /media /proc/mounts ; then
    mount-usb "$CONFIG_USB_BOOT_DEV" || USB_FAILED=1
    if [ $USB_FAILED -ne 0 ]; then
      if [ ! -e "$CONFIG_USB_BOOT_DEV" ]; then
        whiptail --title 'USB Drive Missing' \
          --msgbox "Insert your USB drive and press Enter to continue." 16 60 USB_FAILED=0
        mount-usb "$CONFIG_USB_BOOT_DEV" || USB_FAILED=1
      fi
      if [ $USB_FAILED -ne 0 ]; then
        whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: Mounting /media Failed' \
          --msgbox "Unable to mount $CONFIG_USB_BOOT_DEV" 16 60
      fi
    fi
  fi
}

while true; do
  unset menu_choice
  whiptail --clear --title "Firmware Management Menu" \
    --menu "Select the firmware function to perform\n\nRetaining settings copies existing settings to the new firmware:\n* Keeps your GPG keyring\n* Keeps changes to the default /boot device\n\nErasing settings uses the new firmware as-is:\n* Erases any existing GPG keyring\n* Restores firmware to default factory settings\n\nIf you are just updating your firmware, you probably want to retain\nyour settings." 20 90 10 \
    'f' ' Flash the firmware with a new ROM, retain settings' \
    'c' ' Flash the firmware with a new ROM, erase settings' \
    'x' ' Exit' \
    2>/tmp/whiptail || recovery "GUI menu failed"

  menu_choice=$(cat /tmp/whiptail)

  case "$menu_choice" in
    "x" )
      exit 0
    ;;
    f|c )
      if (whiptail --title 'Flash the BIOS with a new ROM' \
          --yesno "This requires you insert a USB drive containing:\n* Your BIOS image (*.rom)\n\nAfter you select this file, this program will reflash your BIOS\n\nDo you want to proceed?" 16 90) then
        mount_usb
        if grep -q /media /proc/mounts ; then
          find /media -name '*.rom' > /tmp/filelist.txt
          file_selector "/tmp/filelist.txt" "Choose the ROM to flash"
          if [ "$FILE" == "" ]; then
            return
          else
            ROM=$FILE
          fi

          if (whiptail --title 'Flash ROM?' \
              --yesno "This will replace your old ROM with $ROM\n\nDo you want to proceed?" 16 90) then
            if [ "$menu_choice" == "c" ]; then
              /bin/flash.sh -c "$ROM"
            else
              /bin/flash.sh "$ROM"
            fi
            whiptail --title 'ROM Flashed Successfully' \
              --msgbox "$ROM flashed successfully.\nPress Enter to reboot" 16 60 
            umount /media
            /bin/reboot
          else
            exit
          fi
        fi
      fi
    ;;
  esac

done
exit 0
