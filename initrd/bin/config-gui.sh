#!/bin/sh
#
set -e -o pipefail
. /etc/functions
. /tmp/config

file_selector() {
  FILE=""
  FILE_LIST=$1
  MENU_MSG=${2:-"Choose the file"}
  MENU_TITLE=${3:-"Select your File"}
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
      whiptail --clear --title "${MENU_TITLE}" \
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
        let DEV_NUM_PARTITIONS=`ls -1 $i* | wc -l`-1
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

      replace_config /etc/config.user "CONFIG_BOOT_DEV" "$SELECTED_FILE"
      combine_configs

      # mount newly selected /boot device
      if ! ( umount /boot 2>/tmp/error && \
          mount -o ro $SELECTED_FILE /boot 2>/tmp/error ); then
        ERROR=`cat /tmp/error`
        whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: unable to mount /boot' \
          --msgbox "Unable to un/re-mount /boot:\n\n$ERROR" 16 60
        exit 1
      fi

      whiptail --title 'Config change successful' \
        --msgbox "The /boot device was successfully changed to $SELECTED_FILE" 16 60
    ;;
    "s" )
      /bin/flash.sh -r /tmp/config-gui.rom
      if [ ! -s /tmp/config-gui.rom ]; then
        whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: BIOS Read Failed!' \
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
          whiptail $CONFIG_ERROR_BG_COLOR --title 'ERROR: BIOS Read Failed!' \
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
