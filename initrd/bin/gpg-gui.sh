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
  whiptail --clear --title "GPG Management Menu" \
    --menu 'Select the GPG function to perform' 20 90 10 \
    'r' ' Add GPG key to running BIOS + reflash' \
    'a' ' Add GPG key to standalone BIOS image + flash' \
    'l' ' List GPG keys in your keyring' \
    'g' ' Generate GPG keys on a USB security token' \
    'F' ' Factory Reset Nitrokey Pro v2/LibremKey GPG Card' \
    'x' ' Exit' \
    2>/tmp/whiptail || recovery "GUI menu failed"

  menu_choice=$(cat /tmp/whiptail)

  case "$menu_choice" in
    "x" )
      exit 0
    ;;
    "a" )
      if (whiptail --title 'ROM and GPG public key required' \
          --yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n* Your BIOS image (*.rom)\n\nAfter you select these files, this program will reflash your BIOS\n\nDo you want to proceed?" 16 90) then
        mount_usb || die "Unable to mount USB device"
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

          cat "$PUBKEY" | gpg --import
          #update /.gnupg/trustdb.gpg to ultimately trust all user provided public keys
          gpg --list-keys --fingerprint --with-colons |sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' |gpg --import-ownertrust
          gpg --update-trust
          
          cp "$ROM" /tmp/gpg-gui.rom
          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.kbx"); then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.kbx"
            if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.gpg"); then
              cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.gpg"
              if [ -e /.gnupg/pubring.gpg ];then
                rm /.gnupg/pubring.gpg
              fi
            fi
          fi
          
          #to be compatible with gpgv1
          if [ -e /.gnupg/pubring.kbx ];then
            cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.kbx" -f /.gnupg/pubring.kbx
            if [ -e /.gnupg/pubring.gpg ];then
              rm /.gnupg/pubring.gpg
            fi
          fi
          if [ -e /.gnupg/pubring.gpg ];then
            cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.gpg" -f /.gnupg/pubring.gpg
          fi

          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/trustdb.gpg") then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/trustdb.gpg"
          fi
          cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/trustdb.gpg" -f /.gnupg/trustdb.gpg

          #Remove old method owner trust exported file
          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/otrust.txt") then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/otrust.txt"
          fi

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
          --yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n\nNormally, the file should be named public.key\n\nAfter you select this file, this program will copy and reflash your BIOS\n\nDo you want to proceed?" 16 90) then
        mount_usb || die "Unable to mount USB device"
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

          cat "$PUBKEY" | gpg --import
          #update /.gnupg/trustdb.gpg to ultimately trust all user provided public keys
          gpg --list-keys --fingerprint --with-colons |sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' |gpg --import-ownertrust
          gpg --update-trust

          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.kbx"); then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.kbx"
            if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.gpg"); then
              cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.gpg"
              if [ -e /.gnupg/pubring.gpg ];then
                rm /.gnupg/pubring.gpg
              fi
            fi
          fi

          #to be compatible with gpgv1
          if [ -e /.gnupg/pubring.kbx ];then
            cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.kbx" -f /.gnupg/pubring.kbx
            if [ -e /.gnupg/pubring.gpg ];then
              rm /.gnupg/pubring.gpg
            fi
          fi
          if [ -e /.gnupg/pubring.gpg ];then
            cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.gpg" -f /.gnupg/pubring.gpg
          fi

          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/trustdb.gpg") then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/trustdb.gpg"
          fi
          cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/trustdb.gpg" -f /.gnupg/trustdb.gpg

          #Remove old method owner trust exported file
          if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/otrust.txt") then
            cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/otrust.txt"
          fi

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
    "l" )
      GPG_KEYRING=`gpg -k`
      whiptail --title 'GPG Keyring' \
        --msgbox "${GPG_KEYRING}" 16 60
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
    "F" )
      /bin/factory-reset-nitrokey-libremkey.sh 
    ;;
  esac

done
exit 0 
