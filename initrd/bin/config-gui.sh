#!/bin/sh
#
set -e -o pipefail
. /etc/functions
. /etc/gui_functions
. /tmp/config

param=$1

while true; do
  if [ ! -z "$param" ]; then
    # use first char from parameter
    menu_choice=${param::1}
    unset param
  else
    unset menu_choice
    whiptail --clear --title "Config Management Menu" \
    --menu "This menu lets you change settings for the current BIOS session.\n\nAll changes will revert after a reboot,\n\nunless you also save them to the running BIOS." 20 90 10 \
    'b' ' Change the /boot device' \
    's' ' Save the current configuration to the running BIOS' \
    'r' ' Clear GPG key(s) and reset all user settings' \
    'x' ' Return to Main Menu' \
    2>/tmp/whiptail || recovery "GUI menu failed"

    menu_choice=$(cat /tmp/whiptail)
  fi

  case "$menu_choice" in
    "x" )
      exit 0
    ;;
    "b" )
      CURRENT_OPTION=`grep 'CONFIG_BOOT_DEV=' /tmp/config | tail -n1 | cut -f2 -d '=' | tr -d '"'`
      fdisk -l | grep "Disk" | cut -f2 -d " " | cut -f1 -d ":" > /tmp/disklist.txt
      # filter out extraneous options
      > /tmp/boot_device_list.txt
      for i in `cat /tmp/disklist.txt`; do
        # remove block device from list if numeric partitions exist, since not bootable
        DEV_NUM_PARTITIONS=$((`ls -1 $i* | wc -l`-1))
        if [ ${DEV_NUM_PARTITIONS} -eq 0 ]; then
          echo $i >> /tmp/boot_device_list.txt
        else
          ls $i* | tail -${DEV_NUM_PARTITIONS} >> /tmp/boot_device_list.txt
        fi
      done
      file_selector "/tmp/boot_device_list.txt" \
          "Choose the default /boot device.\n\nCurrently set to $CURRENT_OPTION." \
          "Boot Device Selection"
      if [ "$FILE" == "" ]; then
        return
      else
        SELECTED_FILE=$FILE
      fi

      # unmount /boot if needed
      if grep -q /boot /proc/mounts ; then
        umount /boot 2>/dev/null
      fi
      # mount newly selected /boot device
      if ! mount -o ro $SELECTED_FILE /boot 2>/tmp/error ; then
        ERROR=`cat /tmp/error`
        whiptail $BG_COLOR_ERROR --title 'ERROR: unable to mount /boot' \
          --msgbox "    $ERROR\n\n" 16 60
        exit 1
      fi

      replace_config /etc/config.user "CONFIG_BOOT_DEV" "$SELECTED_FILE"
      combine_configs

      whiptail --title 'Config change successful' \
        --msgbox "The /boot device was successfully changed to $SELECTED_FILE" 16 60
    ;;
    "s" )
      /bin/flash.sh -r /tmp/config-gui.rom
      if [ ! -s /tmp/config-gui.rom ]; then
        whiptail $BG_COLOR_ERROR --title 'ERROR: BIOS Read Failed!' \
          --msgbox "Unable to read BIOS" 16 60
        exit 1
      fi

      if (cbfs -o /tmp/config-gui.rom -l | grep -q "heads/initrd/etc/config.user") then
        cbfs -o /tmp/config-gui.rom -d "heads/initrd/etc/config.user"
      fi
      cbfs -o /tmp/config-gui.rom -a "heads/initrd/etc/config.user" -f /etc/config.user

      if (whiptail --title 'Update ROM?' \
          --yesno "This will reflash your BIOS with the updated version\n\nDo you want to proceed?" 16 90) then
        /bin/flash.sh /tmp/config-gui.rom
        whiptail --title 'BIOS Updated Successfully' \
          --msgbox "BIOS updated successfully.\n\nIf your keys have changed, be sure to re-sign all files in /boot\nafter you reboot.\n\nPress Enter to reboot" 16 60
        /bin/reboot
      else
        exit 0
      fi
    ;;
    "r" )
      # prompt for confirmation
      if (whiptail --title 'Reset Configuration?' \
           --yesno "This will clear all GPG keys, clear boot signatures and checksums,
                  \nreset the /boot device, clear/reset the TPM (if present),
                  \nand reflash your BIOS with the cleaned configuration.
                  \n\nDo you want to proceed?" 16 90) then
        # read current firmware
        /bin/flash.sh -r /tmp/config-gui.rom
        if [ ! -s /tmp/config-gui.rom ]; then
          whiptail $BG_COLOR_ERROR --title 'ERROR: BIOS Read Failed!' \
            --msgbox "Unable to read BIOS" 16 60
          exit 1
        fi
        # clear local keyring
        rm /.gnupg/* | true
        # clear /boot signatures/checksums
        mount -o remount,rw /boot
        rm /boot/kexec* | true
        mount -o remount,ro /boot
        # clear GPG keys and user settings
        for i in `cbfs -o /tmp/config-gui.rom -l | grep -e "heads/"`; do
          cbfs -o /tmp/config-gui.rom -d $i
        done
        # flash cleared ROM
        /bin/flash.sh -c /tmp/config-gui.rom
        # reset TPM if present
        if [ "$CONFIG_TPM" = "y" ]; then
          /bin/tpm-reset
        fi
        whiptail --title 'Configuration Reset Updated Successfully' \
          --msgbox "Configuration reset and BIOS updated successfully.\n\nPress Enter to reboot" 16 60
        /bin/reboot
      else
        exit 0
      fi
    ;;
  esac

done
exit 0
