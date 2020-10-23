#!/bin/sh
#
set -e -o pipefail
. /etc/functions
. /etc/gui_functions
. /tmp/config

while true; do
  unset menu_choice
  whiptail --clear --title "Firmware Management Menu" \
    --menu "Select the firmware function to perform\n\nRetaining settings copies existing settings to the new firmware:\n* Keeps your GPG keyring\n* Keeps changes to the default /boot device\n\nErasing settings uses the new firmware as-is:\n* Erases any existing GPG keyring\n* Restores firmware to default factory settings\n* Clears out /boot signatures\n\nIf you are just updating your firmware, you probably want to retain\nyour settings." 20 90 10 \
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
          --yesno "You will need to insert a USB drive containing your BIOS image (*.rom).\n\nAfter you select this file, this program will reflash your BIOS.\n\nDo you want to proceed?" 16 90) then
        mount_usb
        if grep -q /media /proc/mounts ; then
          find /media ! -path '*/\.*' -type f -name '*.rom' | sort > /tmp/filelist.txt
          file_selector "/tmp/filelist.txt" "Choose the ROM to flash"
          if [ "$FILE" == "" ]; then
            return
          else
            ROM=$FILE
          fi

          if (whiptail --title 'Flash ROM?' \
              --yesno "This will replace your current ROM with:\n\n${ROM#"/media/"}\n\nDo you want to proceed?" 16 60) then
            if [ "$menu_choice" == "c" ]; then
              /bin/flash.sh -c "$ROM"
              # after flash, /boot signatures are now invalid so go ahead and clear them
              if ls /boot/kexec* >/dev/null 2>&1 ; then
                (
                  mount -o remount,rw /boot 2>/dev/null
                  rm /boot/kexec* 2>/dev/null
                  mount -o remount,ro /boot 2>/dev/null
                )
              fi
            else
              /bin/flash.sh "$ROM"
            fi
            whiptail --title 'ROM Flashed Successfully' \
              --msgbox "${ROM#"/media/"}\n\nhas been flashed successfully.\n\nPress Enter to reboot\n" 16 60
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
