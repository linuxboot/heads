#!/bin/sh
#
set -e -o pipefail
. /etc/functions
. /tmp/config

gpg_flash_rom() {
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

  /bin/flash.sh /tmp/gpg-gui.rom
  whiptail --title 'BIOS Flashed Successfully' \
    --msgbox "BIOS flashed successfully.\n\nIf your keys have changed, be sure to re-sign all files in /boot\nafter you reboot.\n\nPress Enter to reboot" 16 60
  /bin/reboot
}
gpg_post_gen_mgmt() {
  GPG_GEN_KEY=`grep -A1 pub /tmp/gpg_card_edit_output | tail -n1 | sed -nr 's/^([ ])*//p'`
  gpg --export --armor $GPG_GEN_KEY > "/tmp/${GPG_GEN_KEY}.asc"
  if (whiptail --title 'Add Public Key to USB disk?' \
      --yesno "Would you like to copy the GPG public key you generated to a USB disk?\n\nOtherwise you will not be able to copy it outside of Heads later\n\nThe file will show up as ${GPG_GEN_KEY}.asc" 16 90) then
    mount-usb || die "Unable to mount USB device."
    mount -o remount,rw /media || die "Unable to remount /media in Read-Write mode. Is the device Write protected?"
    cp "/tmp/${GPG_GEN_KEY}.asc" "/media/${GPG_GEN_KEY}.asc"
    if [ $? -eq 0 ]; then
      whiptail --title "The GPG Key Copied Successfully" \
        --msgbox "${GPG_GEN_KEY}.asc copied successfully." 16 60
    else
      whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: Copy Failed' \
        --msgbox "Unable to copy ${GPG_GEN_KEY}.asc to /media" 16 60
    fi
    umount /media
  fi
  if (whiptail --title 'Add Public Key to Running BIOS?' \
      --yesno "Would you like to add the GPG public key you generated to the BIOS?\n\nThis makes it a trusted key used to sign files in /boot\n\n" 16 90) then
      /bin/flash.sh -r /tmp/gpg-gui.rom
      if [ ! -s /tmp/gpg-gui.rom ]; then
        whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: BIOS Read Failed!' \
          --msgbox "Unable to read BIOS" 16 60
        exit 1
      fi
      PUBKEY="/tmp/${GPG_GEN_KEY}.asc"
      gpg_flash_rom
  fi
}
gpg_sc_oem_reset() {
  GPG_KEY_NAME=`date +%Y%m%d%H%M%S`
  # Factory reset GPG card
  {
    echo admin
    echo factory-reset
    echo y
    echo yes
  } | gpg --command-fd=0 --status-fd=1 --pinentry-mode=loopback --card-edit > /tmp/gpg_card_edit_output || return 1
  # Generate OEM GPG keys
  {
    echo admin
    echo generate
    echo n
    echo 12345678
    echo 123456
    echo 0
    echo y
    echo "OEM Key"
    echo "oem-${GPG_KEY_NAME}@example.com"
    echo "OEM-generated key"
  } | gpg --command-fd=0 --status-fd=2 --pinentry-mode=loopback --card-edit > /tmp/gpg_card_edit_output || return 2
}

while true; do
  unset menu_choice
  whiptail --clear --title "GPG Management Menu" \
    --menu 'Select the GPG function to perform' 20 90 10 \
    'r' ' Add GPG key to running BIOS + reflash' \
    'a' ' Add GPG key to standalone BIOS image + flash' \
    'l' ' List GPG keys in your keyring' \
    'm' ' Manually generate GPG keys on a USB security token' \
    'o' ' OEM Factory reset + auto keygen USB security token' \
    'F' ' Factory Reset Librem Key GPG Card + keygen + flash' \
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
        mount-usb || die "Unable to mount USB device."
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
          cp "$ROM" /tmp/gpg-gui.rom

          if (whiptail --title 'Flash ROM?' \
              --yesno "This will replace your old ROM with $ROM\n\nDo you want to proceed?" 16 90) then
            gpg_flash_rom
          else
            exit 0
          fi
        fi
      fi
    ;;
    "r" )
      if (whiptail --title 'GPG public key required' \
          --yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n\nAfter you select this file, this program will copy and reflash your BIOS\n\nDo you want to proceed?" 16 90) then
        mount-usb || die "Unable to mount USB device."
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

          if (whiptail --title 'Update ROM?' \
              --yesno "This will reflash your BIOS with the updated version\n\nDo you want to proceed?" 16 90) then
            gpg_flash_rom
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
    "m" )
      confirm_gpg_card
      echo -e "\n\n\n\n"
      echo "********************************************************************************"
      echo "*"
      echo "* INSTRUCTIONS:"
      echo "* Type 'admin' and then 'generate' and follow the prompts to generate a GPG key."
      echo "* Type 'quit' once you have generated the key to exit GPG."
      echo "*"
      echo "********************************************************************************"
      gpg --card-edit > /tmp/gpg_card_edit_output
      if [ $? -eq 0 ]; then
        gpg_post_gen_mgmt
      fi
    ;;
    "o" )
      if (whiptail $CONFIG_WARNING_BG_COLOR --title 'WARNING: Factory Reset USB Security Token?' \
          --yesno "This will perform a FACTORY RESET of the USB security token!\n\nThis will:\n* Reset all security token passwords to default\n* Erase any keys on the security token\n* Generate new automated GPG keys on the token\n\nAny data now on the USB security token will be LOST!\n\nDo you want to proceed?" 16 120) then
        confirm_gpg_card
        gpg_sc_oem_reset
        if [ $? -eq 0 ]; then
          gpg_post_gen_mgmt
        elif [ $? -eq 1 ]; then
          GPG_OUTPUT=`cat /tmp/gpg_card_edit_output`
          whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: Factory Reset Failed!' \
            --msgbox "Factory Reset Failed!\n\n$GPG_OUTPUT" 16 120
        elif [ $? -eq 2 ]; then
          GPG_OUTPUT=`cat /tmp/gpg_card_edit_output`
          whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: Automatic Keygen Failed!' \
            --msgbox "Automatic Keygen Failed!\n\n$GPG_OUTPUT" 16 120
        fi
      fi
    ;;
    "F" )
      /bin/factory-reset-libremkey.sh 
    ;;
  esac

done
exit 0
