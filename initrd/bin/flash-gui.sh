#!/bin/bash
#
set -e -o pipefail
. /etc/functions
. /etc/gui_functions
. /tmp/config

TRACE "Under /bin/flash-gui.sh"

if [ "$CONFIG_RESTRICTED_BOOT" = y ]; then
  whiptail $BG_COLOR_ERROR --title 'Restricted Boot Active' \
    --msgbox "Disable Restricted Boot to flash new firmware." 0 80
  exit 1
fi

while true; do
  unset menu_choice
  whiptail $BG_COLOR_MAIN_MENU --title "Firmware Management Menu" \
    --menu "Select the firmware function to perform\n\nRetaining settings copies existing settings to the new firmware:\n* Keeps your GPG keyring\n* Keeps changes to the default /boot device\n\nErasing settings uses the new firmware as-is:\n* Erases any existing GPG keyring\n* Restores firmware to default factory settings\n* Clears out /boot signatures\n\nIf you are just updating your firmware, you probably want to retain\nyour settings." 0 80 10 \
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
      if (whiptail $BG_COLOR_WARNING --title 'Flash the BIOS with a new ROM' \
          --yesno "You will need to insert a USB drive containing your BIOS image (*.rom or *.tgz).\n\nAfter you select this file, this program will reflash your BIOS.\n\nDo you want to proceed?" 0 80) then
        mount_usb
        if grep -q /media /proc/mounts ; then
          find /media ! -path '*/\.*' -type f \( -name '*.rom' -o -name '*.tgz' -o -type f -name '*.npf' \) | sort > /tmp/filelist.txt
          file_selector "/tmp/filelist.txt" "Choose the ROM to flash"
          if [ "$FILE" == "" ]; then
            return
          else
            ROM=$FILE
          fi

          # is a .npf provided?
          if [ -z "${ROM##*.npf}" ]; then
            # unzip to /tmp/verified_rom
            mkdir /tmp/verified_rom
            unzip $ROM -d /tmp/verified_rom
            # check file integrity
            if (cd /tmp/verified_rom/ && sha256sum -cs /tmp/verified_rom/sha256sum.txt) ; then
              ROM="$(head -n1 /tmp/verified_rom/sha256sum.txt | cut -d ' ' -f 3)"
            else
              whiptail --title 'ROM Integrity Check Failed! ' \
                --msgbox "$ROM integrity check failed. Did not flash.\n\nPlease check your file (e.g. re-download).\n" 16 60
              exit
            fi
          else
            # exit if we shall not proceed
            if ! (whiptail $CONFIG_ERROR_BG_COLOR --title 'Flash ROM without integrity check?' \
                --yesno "You have provided a *.rom file. The integrity of the file can not be\nchecked for this file.\nIf you do not know how to check the file integrity yourself,\nyou should use a *.npf file instead.\n\nIf the file is damaged, you will not be able to boot anymore.\nDo you want to proceed flashing without file integrity check?" 16 60) then
              exit
            fi
          fi

          if (whiptail $BG_COLOR_WARNING --title 'Flash ROM?' \
              --yesno "This will replace your current ROM with:\n\n${ROM#"/media/"}\n\nDo you want to proceed?" 0 80) then
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
              --msgbox "${ROM#"/media/"}\n\nhas been flashed successfully.\n\nPress Enter to reboot\n" 0 80
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
