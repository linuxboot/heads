#!/bin/sh
#
set -e -o pipefail
. /etc/functions
. /etc/config

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

file_selector() {
  FILE=""
  FILE_LIST=$1
  MENU_MSG=${2:-"Choose the file"}
# create file menu options
  if [ `cat "$FILE_LIST" | wc -l` -gt 0 ]; then
    option=""
    while [ -z "$option" ]
    do
      MENU_OPTIONS=""
      n=0
      while read option
      do
        n=`expr $n + 1`
        option=$(echo $option | tr " " "_")
        MENU_OPTIONS="$MENU_OPTIONS $n ${option}"
      done < $FILE_LIST

      MENU_OPTIONS="$MENU_OPTIONS a Abort"
      whiptail --clear --title "Select your File" \
        --menu "${MENU_MSG} [1-$n, a to abort]:" 20 120 8 \
        -- $MENU_OPTIONS \
        2>/tmp/whiptail || die "Aborting"

      option_index=$(cat /tmp/whiptail)

      if [ "$option_index" = "a" ]; then
        option="a"
        return
      fi

      option=`head -n $option_index $FILE_LIST | tail -1`
      if [ "$option" == "a" ]; then
        return
      fi
    done
    if [ -n "$option" ]; then
      FILE=$option
    fi
  else
    whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: No Files Found' \
      --msgbox "No Files found matching the pattern. Aborting." 16 60
    exit 1
  fi
}

while true; do
  unset menu_choice
  whiptail --clear --title "BIOS Management Menu" \
    --menu 'Select the BIOS function to perform' 20 90 10 \
    'f' ' Flash the BIOS with a new ROM' \
    'c' ' Flash the BIOS with a new cleaned ROM' \
    'a' ' Add GPG key to BIOS image' \
    'r' ' Add GPG key to running BIOS' \
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
              /bin/flash.sh -c $ROM
            else
              /bin/flash.sh $ROM
            fi
            whiptail --title 'ROM Flashed Successfully' \
              --msgbox "$ROM flashed successfully. Press Enter to reboot" 16 60
            umount /media
            /bin/reboot
          else
            exit
          fi
        fi
      fi
    ;;
    "a" )
      if (whiptail --title 'ROM and GPG public key required' \
          --yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n* Your BIOS image (*.rom)\n\nAfter you select these files, this program will reflash your BIOS\n\nDo you want to proceed?" 16 90) then
        mount_usb
        if grep -q /media /proc/mounts ; then
          find /media -name '*.key' > /tmp/filelist.txt
          find /media -name '*.asc' >> /tmp/filelist.txt
          file_selector "/tmp/filelist.txt" "Choose your GPG public key"
          if [ "$FILE" == "" ]; then
            return
          else
            PUBKEY=$FILE
          fi

          find /media -name '*.rom' > /tmp/filelist.txt
          file_selector "/tmp/filelist.txt" "Choose the ROM to load your key onto"
          if [ "$FILE" == "" ]; then
            return
          else
            ROM=$FILE
          fi

          cat $PUBKEY | gpg --import
          cp $ROM /tmp/gpg-gui.rom
          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.kbx") then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.kbx"
          fi
          cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.kbx" -f /.gnupg/pubring.kbx

          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/trustdb.gpg") then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/trustdb.gpg"
          fi
          cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/trustdb.gpg" -f /.gnupg/trustdb.gpg

          if (whiptail --title 'Flash ROM?' \
              --yesno "This will replace your old ROM with $ROM\n\nDo you want to proceed?" 16 90) then
            /bin/flash.sh /tmp/gpg-gui.rom
            whiptail --title 'ROM Flashed Successfully' \
              --msgbox "$ROM flashed successfully.\n\nIf your keys have changed, be sure to re-sign all files in /boot\nafter you reboot.\n\nPress Enter to reboot" 16 60
            umount /media
            /bin/reboot
          else
            exit 0
          fi
        fi
      fi
    ;;
    "r" )
      if (whiptail --title 'GPG public key required' \
          --yesno "Flashing the running BIOS requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n\nAfter you select this file, this program will copy and reflash your BIOS\n\nDo you want to proceed?" 16 90) then
        mount_usb
        if grep -q /media /proc/mounts ; then
          find /media -name '*.key' > /tmp/filelist.txt
          find /media -name '*.asc' >> /tmp/filelist.txt
          file_selector "/tmp/filelist.txt" "Choose your GPG public key"
          PUBKEY=$FILE

          /bin/flash.sh -r /tmp/gpg-gui.rom
          if [ ! -s /tmp/gpg-gui.rom ]; then
            whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: BIOS Read Failed!' \
              --msgbox "Unable to read BIOS" 16 60
            exit 1
          fi

          cat $PUBKEY | gpg --import
          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.kbx") then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.kbx"
          fi
          cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.kbx" -f /.gnupg/pubring.kbx

          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/trustdb.gpg") then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/trustdb.gpg"
          fi
          cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/trustdb.gpg" -f /.gnupg/trustdb.gpg

          if (whiptail --title 'Update ROM?' \
              --yesno "This will reflash your BIOS with the updated version\n\nDo you want to proceed?" 16 90) then
            /bin/flash.sh /tmp/gpg-gui.rom
            whiptail --title 'BIOS Updated Successfully' \
              --msgbox "BIOS updated successfully.\n\nIf your keys have changed, be sure to re-sign all files in /boot\nafter you reboot.\n\nPress Enter to reboot" 16 60
            umount /media
            /bin/reboot
          else
            exit 0
          fi
        fi
      fi
    ;;
    "g" )
      confirm_gpg_card
      echo "********************************************************************************"
      echo "*"
      echo "* INSTRUCTIONS:"
      echo "* Type 'admin' and then 'generate' and follow the prompts to generate a GPG key."
      echo "*"
      echo "********************************************************************************"
      gpg --card-edit
    ;;
  esac

done
exit 0
