#!/bin/sh
#
set -e -o pipefail
. /etc/functions
. /etc/gui_functions
. /tmp/config

gpg_flash_rom() {

  if [ "$1" = "replace" ]; then
    # clear local keyring
    [ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
    [ -e /.gnupg/pubring.kbx ] && rm /.gnupg/pubring.kbx
    [ -e /.gnupg/trustdb.gpg ] && rm /.gnupg/trustdb.gpg
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
  if [ -e /.gnupg/trustdb.gpg ]; then
    cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/trustdb.gpg" -f /.gnupg/trustdb.gpg
  fi

  #Remove old method owner trust exported file
  if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/otrust.txt") then
    cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/otrust.txt"
  fi

  # persist user config changes
  if (cbfs -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/etc/config.user") then
    cbfs -o /tmp/gpg-gui.rom -d "heads/initrd/etc/config.user"
  fi
  if [ -e /etc/config.user ]; then
    cbfs -o /tmp/gpg-gui.rom -a "heads/initrd/etc/config.user" -f /etc/config.user
  fi
  /bin/flash.sh /tmp/gpg-gui.rom

  if (whiptail --title 'BIOS Flashed Successfully' \
      --yesno "Would you like to update the checksums and sign all of the files in /boot?\n\nYou will need your GPG key to continue and this will modify your disk.\n\nOtherwise the system will reboot immediately." 16 90) then
    update_checksums
  else
    /bin/reboot
  fi

  whiptail --title 'Files in /boot Updated Successfully'\
    --msgbox "Checksums have been updated and /boot files signed.\n\nPress Enter to reboot" 16 60
  /bin/reboot
  
}
gpg_post_gen_mgmt() {
  GPG_GEN_KEY=`grep -A1 pub /tmp/gpg_card_edit_output | tail -n1 | sed -nr 's/^([ ])*//p'`
  gpg --export --armor $GPG_GEN_KEY > "/tmp/${GPG_GEN_KEY}.asc"
  if (whiptail --title 'Add Public Key to USB disk?' \
      --yesno "Would you like to copy the GPG public key you generated to a USB disk?\n\nYou may need it, if you want to use it outside of Heads later.\n\nThe file will show up as ${GPG_GEN_KEY}.asc" 16 90) then
    mount_usb
    mount -o remount,rw /media
    cp "/tmp/${GPG_GEN_KEY}.asc" "/media/${GPG_GEN_KEY}.asc"
    if [ $? -eq 0 ]; then
      whiptail --title "The GPG Key Copied Successfully" \
        --msgbox "${GPG_GEN_KEY}.asc copied successfully." 16 60
    else
      whiptail $BG_COLOR_ERROR --title 'ERROR: Copy Failed' \
        --msgbox "Unable to copy ${GPG_GEN_KEY}.asc to /media" 16 60
    fi
    umount /media
  fi
  if (whiptail --title 'Add Public Key to Running BIOS?' \
      --yesno "Would you like to add the GPG public key you generated to the BIOS?\n\nThis makes it a trusted key used to sign files in /boot\n\n" 16 90) then
      /bin/flash.sh -r /tmp/gpg-gui.rom
      if [ ! -s /tmp/gpg-gui.rom ]; then
        whiptail $BG_COLOR_ERROR --title 'ERROR: BIOS Read Failed!' \
          --msgbox "Unable to read BIOS" 16 60
        exit 1
      fi
      PUBKEY="/tmp/${GPG_GEN_KEY}.asc"
      gpg_flash_rom
  fi
}

gpg_add_key_reflash() {
  if (whiptail --title 'GPG public key required' \
          --yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n\nAfter you select this file, this program will copy and reflash your BIOS\n\nDo you want to proceed?" 16 90) then
    mount_usb
    if grep -q /media /proc/mounts ; then
      find /media -name '*.key' > /tmp/filelist.txt
      find /media -name '*.asc' >> /tmp/filelist.txt
      file_selector "/tmp/filelist.txt" "Choose your GPG public key"
      # bail if user didn't select a file
      if [ "$FILE" = "" ]; then
        return
      else
        PUBKEY=$FILE
      fi

      /bin/flash.sh -r /tmp/gpg-gui.rom
      if [ ! -s /tmp/gpg-gui.rom ]; then
        whiptail $BG_COLOR_ERROR --title 'ERROR: BIOS Read Failed!' \
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
}

while true; do
  unset menu_choice
  whiptail --clear --title "GPG Management Menu" \
    --menu 'Select the GPG function to perform' 20 90 10 \
    'r' ' Add GPG key to running BIOS and reflash' \
    'a' ' Add GPG key to standalone BIOS image and flash' \
    'e' ' Replace GPG key(s) in the current ROM and reflash' \
    'l' ' List GPG keys in your keyring' \
    'p' ' Export public GPG key to USB drive' \
    'g' ' Generate GPG keys manually on a USB security token' \
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
      gpg_add_key_reflash
      exit 0;
    ;;
    "e" )
      # clear local keyring
      [ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
      [ -e /.gnupg/pubring.kbx ] && rm /.gnupg/pubring.kbx
      [ -e /.gnupg/trustdb.gpg ] && rm /.gnupg/trustdb.gpg
      # add key and reflash
      gpg_add_key_reflash
    ;;
    "l" )
      GPG_KEYRING=`gpg -k`
      whiptail --title 'GPG Keyring' \
        --msgbox "${GPG_KEYRING}" 16 60
    ;;
    "p" )
        if (whiptail --title 'Export Public Key(s) to USB drive?' \
          --yesno "Would you like to copy GPG public key(s) to a USB drive?\n\nThe file will show up as public-key.asc" 16 90) then
        mount_usb
        mount -o remount,rw /media
        gpg --export --armor > "/tmp/public-key.asc"
        cp "/tmp/public-key.asc" "/media/public-key.asc"
        if [ $? -eq 0 ]; then
          whiptail --title "The GPG Key Copied Successfully" \
            --msgbox "public-key.asc copied successfully." 16 60
        else
          whiptail $BG_COLOR_ERROR --title 'ERROR: Copy Failed' \
            --msgbox "Unable to copy public-key.asc to /media" 16 60
        fi
        umount /media
      fi
    ;;
    "g" )
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
  esac

done
exit 0
