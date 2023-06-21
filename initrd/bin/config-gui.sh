#!/bin/bash
#
set -e -o pipefail
. /etc/functions
. /etc/gui_functions
. /tmp/config

TRACE "Under /bin/config-gui.sh"

ROOT_HASH_FILE="/boot/kexec_root_hashes.txt"

param=$1

# Read the current ROM; if it fails display an error and exit.
read_rom() {
  /bin/flash.sh -r "$1"
  if [ ! -s "$1" ]; then
    whiptail $BG_COLOR_ERROR --title 'ERROR: BIOS Read Failed!' \
      --msgbox "Unable to read BIOS" 16 60
    exit 1
  fi
}

while true; do
  if [ ! -z "$param" ]; then
    # use first char from parameter
    menu_choice=${param::1}
    unset param
  else
    # Re-source config because we change it when an option is toggled
    . /tmp/config

    dynamic_config_options=(
      'b' ' Change the /boot device'
    )

    # Options that don't apply to basic mode
    [ "$CONFIG_BASIC" != "y" ] && dynamic_config_options+=(
        'r' ' Clear GPG key(s) and reset all user settings'
        'R' ' Change the root device for hashing'
        'D' ' Change the root directories to hash'
        'B' ' Check root hashes at boot'
        'L' " $(get_config_display_action "$CONFIG_RESTRICTED_BOOT") Restricted Boot"
    )

    # Basic itself is always available (though RB will refuse to enable it)
    dynamic_config_options+=(
        'P' " $(get_config_display_action "$CONFIG_BASIC") $CONFIG_BRAND_NAME Basic Mode"
    )

    # Blob jail is only offered if this is a configuration with the blobs in
    # firmware
    [ "$CONFIG_SUPPORT_BLOB_JAIL" = "y" ] && dynamic_config_options+=(
        'J' " $(get_config_display_action "$CONFIG_USE_BLOB_JAIL") Firmware Blob Jail"
    )

    # Basic-only options for automatic boot
    [ "$CONFIG_BASIC" = "y" ] && dynamic_config_options+=(
        'A' " $(get_inverted_config_display_action "$CONFIG_BASIC_NO_AUTOMATIC_DEFAULT") automatic default boot"
        'U' " $(get_config_display_action "$CONFIG_BASIC_USB_AUTOBOOT") USB automatic boot"
    )

    # Automatic power on - requires board support
    [ "$CONFIG_SUPPORT_AUTOMATIC_POWERON" = "y" ] && dynamic_config_options+=(
        'N' " $(get_config_display_action "$CONFIG_AUTOMATIC_POWERON") automatic power-on"
    )

    [ "$CONFIG_FINALIZE_PLATFORM_LOCKING_PRESKYLAKE" = "y" ] && dynamic_config_options+=(
        't' ' Deactivate Platform Locking to permit OS write access to firmware'
    )

    dynamic_config_options+=(
      's' ' Save the current configuration to the running BIOS' \
      'x' ' Return to Main Menu'
    )

    unset menu_choice
    whiptail $BG_COLOR_MAIN_MENU --title "Config Management Menu" \
    --menu "This menu lets you change settings for the current BIOS session.\n\nAll changes will revert after a reboot,\n\nunless you also save them to the running BIOS." 0 80 10 \
    "${dynamic_config_options[@]}" \
    2>/tmp/whiptail || recovery "GUI menu failed"

    menu_choice=$(cat /tmp/whiptail)
  fi

  case "$menu_choice" in
    "t" )
      unset CONFIG_FINALIZE_PLATFORM_LOCKING_PRESKYLAKE
      replace_config /etc/config.user "CONFIG_FINALIZE_PLATFORM_LOCKING_PRESKYLAKE" "n"
      combine_configs
      . /tmp/config
    ;;
    "x" )
      exit 0
    ;;
    "b" )
      CURRENT_OPTION=`grep 'CONFIG_BOOT_DEV=' /tmp/config | tail -n1 | cut -f2 -d '=' | tr -d '"'`
      if ! fdisk -l | grep "Disk /dev/" | cut -f2 -d " " | cut -f1 -d ":" > /tmp/disklist.txt ; then
        whiptail $BG_COLOR_ERROR --title 'ERROR: No bootable devices found' \
          --msgbox "    $ERROR\n\n" 16 60
        exit 1
      fi
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
      read_rom /tmp/config-gui.rom

      replace_rom_file /tmp/config-gui.rom "heads/initrd/etc/config.user" /etc/config.user

      if (whiptail --title 'Update ROM?' \
          --yesno "This will reflash your BIOS with the updated version\n\nDo you want to proceed?" 0 80) then
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
      if (whiptail $BG_COLOR_WARNING --title 'Reset Configuration?' \
           --yesno "This will clear all GPG keys, clear boot signatures and checksums,
                  \nreset the /boot device, clear/reset the TPM (if present),
                  \nand reflash your BIOS with the cleaned configuration.
                  \n\nDo you want to proceed?" 0 80) then
        read_rom /tmp/config-gui.rom
        # clear local keyring
        rm /.gnupg/* | true
        # clear /boot signatures/checksums
        mount -o remount,rw /boot
        rm /boot/kexec* | true
        mount -o remount,ro /boot
        # clear GPG keys and user settings
        for i in `cbfs.sh -o /tmp/config-gui.rom -l | grep -e "heads/"`; do
          cbfs.sh -o /tmp/config-gui.rom -d $i
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
    "R" )
      CURRENT_OPTION=`grep 'CONFIG_ROOT_DEV=' /tmp/config | tail -n1 | cut -f2 -d '=' | tr -d '"'`
      fdisk -l | grep "Disk /dev/" | cut -f2 -d " " | cut -f1 -d ":" > /tmp/disklist.txt
      # filter out extraneous options
      > /tmp/root_device_list.txt
      for i in `cat /tmp/disklist.txt`; do
        # remove block device from list if numeric partitions exist, since not bootable
        DEV_NUM_PARTITIONS=$((`ls -1 $i* | wc -l`-1))
        if [ ${DEV_NUM_PARTITIONS} -eq 0 ]; then
          echo $i >> /tmp/root_device_list.txt
        else
          ls $i* | tail -${DEV_NUM_PARTITIONS} >> /tmp/root_device_list.txt
        fi
      done
      file_selector "/tmp/root_device_list.txt" \
          "Choose the default root device.\n\nCurrently set to $CURRENT_OPTION." \
          "Root Device Selection"
      if [ "$FILE" == "" ]; then
        return
      else
        SELECTED_FILE=$FILE
      fi

      replace_config /etc/config.user "CONFIG_ROOT_DEV" "$SELECTED_FILE"
      combine_configs

      whiptail --title 'Config change successful' \
        --msgbox "The root device was successfully changed to $SELECTED_FILE" 16 60
    ;;
    "D" )
      CURRENT_OPTION=`grep 'CONFIG_ROOT_DIRLIST=' /tmp/config | tail -n1 | cut -f2 -d '=' | tr -d '"'`
      
      echo "The current list of directories to hash is $CURRENT_OPTION"
      echo -e "\nEnter the new list of directories separated by spaces, without any beginning forward slashes:"
      echo -e "(Press enter with the list empty to cancel)"
      read -r NEW_CONFIG_ROOT_DIRLIST

      # strip any leading forward slashes in case the user ignored us
      NEW_CONFIG_ROOT_DIRLIST=$(echo $NEW_CONFIG_ROOT_DIRLIST | sed -e 's/^\///;s/ \// /g')

      #check if list empty
      if [ -s $NEW_CONFIG_ROOT_DIRLIST ] ; then
        whiptail --title 'Config change canceled' \
        --msgbox "Root device directory change canceled by user" 16 60
        break
      fi

      replace_config /etc/config.user "CONFIG_ROOT_DIRLIST" "$NEW_CONFIG_ROOT_DIRLIST"
      combine_configs

      whiptail --title 'Config change successful' \
        --msgbox "The root directories to hash was successfully changed to:\n$NEW_CONFIG_ROOT_DIRLIST" 16 60
    ;;
    "B" )
      CURRENT_OPTION=`grep 'CONFIG_ROOT_CHECK_AT_BOOT=' /tmp/config | tail -n1 | cut -f2 -d '=' | tr -d '"'`
      if [ "$CURRENT_OPTION" = "n" ]; then
        if (whiptail --title 'Enable Root Hash Check at Boot?' \
             --yesno "This will enable checking root hashes each time you boot.
                    \nDepending on the directories you are checking, this might add
                    \na minute or more to the boot time.
                    \n\nDo you want to proceed?" 0 80) then

          replace_config /etc/config.user "CONFIG_ROOT_CHECK_AT_BOOT" "y"
          combine_configs

          # check that root hash file exists
          if [ ! -f ${ROOT_HASH_FILE} ]; then
            if (whiptail --title 'Generate Root Hash File' \
                --yesno "\nNo root hash file exists.
                        \nWould you like to create the initial hash file now?" 0 80) then
                root-hashes-gui.sh -n
              fi
          fi

          whiptail --title 'Config change successful' \
            --msgbox "The root device will be checked at each boot." 16 60

        fi
      else
        if (whiptail --title 'Disable Root Hash Check at Boot?' \
             --yesno "This will disable checking root hashes each time you boot.
                    \n\nDo you want to proceed?" 0 80) then

          replace_config /etc/config.user "CONFIG_ROOT_CHECK_AT_BOOT" "n"
          combine_configs

          whiptail --title 'Config change successful' \
            --msgbox "The root device will not be checked at each boot." 16 60
        fi
      fi
    ;;
    "P" )
      if [ "$CONFIG_RESTRICTED_BOOT" = "y" ]; then
          whiptail $BG_COLOR_ERROR --title 'Restricted Boot Active' \
            --msgbox "Disable Restricted Boot to enable Basic Mode." 16 60
      elif [ "$CONFIG_BASIC" != "y" ]; then
        if (whiptail --title "Enable $CONFIG_BRAND_NAME Basic Mode?" \
             --yesno "This will remove all signature checking on the firmware
                    \nand boot files, and disable use of the Librem Key.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_BASIC" "y"

          whiptail --title 'Config change successful' \
            --msgbox "$CONFIG_BRAND_NAME Basic mode enabled;\nsave the config change and reboot for it to go into effect." 16 60

        fi
      else
        if (whiptail --title "Disable $CONFIG_BRAND_NAME Basic Mode?" \
             --yesno "This will enable all signature checking on the firmware
                    \nand boot files, and enable use of the Librem Key.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_BASIC" "n"

          whiptail --title 'Config change successful' \
            --msgbox "$CONFIG_BRAND_NAME Basic mode has been disabled;\nsave the config change and reboot for it to go into effect." 16 60
        fi
      fi
    ;;
    "L" )
      if [ "$CONFIG_RESTRICTED_BOOT" != "y" ]; then
        if (whiptail --title 'Enable Restricted Boot Mode?' \
             --yesno "This will disable booting from any unsigned files,
                    \nincluding kernels that have not yet been signed,
                    \n.isos without signatures, raw USB disks,
                    \nand will disable failsafe boot mode.
                    \n\nThis will also disable the recovery console.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_RESTRICTED_BOOT" "y"

          whiptail --title 'Config change successful' \
            --msgbox "Restricted Boot mode enabled;\nsave the config change and reboot for it to go into effect." 16 60

        fi
      else
        if (whiptail --title 'Disable Restricted Boot Mode?' \
             --yesno "This will allow booting from unsigned devices,
                    \nand will re-enable failsafe boot mode.
                    \n\nThis will also RESET the TPM and re-enable the recovery console.
                    \n\nProceeding will automatically update the boot firmware, reset TPM and reboot!
                    \n\nDo you want to proceed?" 0 80) then

          # Wipe the TPM TOTP/HOTP secret before flashing.  Otherwise, enabling
          # Restricted Boot again might restore the firmware to an identical
          # state, and there would be no evidence that it had been temporarily
          # disabled.
          if ! wipe-totp >/dev/null 2>/tmp/error; then
            ERROR=$(tail -n 1 /tmp/error | fold -s)
            whiptail $BG_COLOR_ERROR --title 'ERROR: erasing TOTP secret' \
              --msgbox "Erasing TOTP Secret Failed\n\n${ERROR}" 16 60
            exit 1
          fi

          # We can't allow Restricted Boot to be disabled without flashing the
          # firmware - this would allow the use of unrestricted mode without
          # leaving evidence in the firmware.  Disable it by flashing the new
          # config directly.
          FLASH_USER_CONFIG=/tmp/config-gui-config-user
          cp /etc/config.user "$FLASH_USER_CONFIG"
          set_config "$FLASH_USER_CONFIG" "CONFIG_RESTRICTED_BOOT" "n"

          read_rom /tmp/config-gui.rom

          replace_rom_file /tmp/config-gui.rom "heads/initrd/etc/config.user" "$FLASH_USER_CONFIG"

          /bin/flash.sh /tmp/config-gui.rom
          whiptail --title 'BIOS Updated Successfully' \
            --msgbox "BIOS updated successfully.\n\nIf your keys have changed, be sure to re-sign all files in /boot\nafter you reboot.\n\nPress Enter to reboot" 16 60
          /bin/reboot
        fi
      fi
    ;;
    "J" )
      if [ "$CONFIG_USE_BLOB_JAIL" != "y" ]; then
        if (whiptail --title 'Enable Firmware Blob Jail?' \
             --yesno "This will enable loading of firmware from flash on each boot
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_USE_BLOB_JAIL" "y"

          whiptail --title 'Config change successful' \
            --msgbox "Firmware Blob Jail use has been enabled;\nsave the config change and reboot for it to go into effect." 16 60

        fi
      else
        if (whiptail --title 'Disable Firmware Blob Jail?' \
             --yesno "This will disable loading of firmware from flash on each boot.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_USE_BLOB_JAIL" "n"

          whiptail --title 'Config change successful' \
            --msgbox "Firmware Blob Jail use has been disabled;\nsave the config change and reboot for it to go into effect." 16 60
        fi
      fi
    ;;
    "A" )
      if [ "$CONFIG_BASIC_NO_AUTOMATIC_DEFAULT" != "y" ]; then
        if (whiptail --title 'Disable automatic default boot?' \
             --yesno "You will need to select a default boot option.
                    \nIf the boot options are changed, such as for an OS update,
                    \nyou will be prompted to select a new default.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_BASIC_NO_AUTOMATIC_DEFAULT" "y"

          whiptail --title 'Config change successful' \
            --msgbox "Automatic default boot disabled;\nsave the config change and reboot for it to go into effect." 16 60
        fi
      else
        if (whiptail --title 'Enable automatic default boot?' \
             --yesno "The first boot option will be used automatically.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_BASIC_NO_AUTOMATIC_DEFAULT" "n"

          whiptail --title 'Config change successful' \
            --msgbox "Automatic default boot enabled;\nsave the config change and reboot for it to go into effect." 16 60
        fi
      fi
    ;;
    "U" )
      if [ "$CONFIG_BASIC_USB_AUTOBOOT" != "y" ]; then
        if (whiptail --title 'Enable USB automatic boot?' \
             --yesno "During boot, an attached bootable USB disk will be booted
                    \nby default instead of the installed operating system.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_BASIC_USB_AUTOBOOT" "y"

          whiptail --title 'Config change successful' \
            --msgbox "USB automatic boot enabled;\nsave the config change and reboot for it to go into effect." 16 60
        fi
      else
        if (whiptail --title 'Disable USB automatic boot?' \
             --yesno "USB disks will no longer be booted by default.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_BASIC_USB_AUTOBOOT" "n"

          whiptail --title 'Config change successful' \
            --msgbox "USB automatic boot disabled;\nsave the config change and reboot for it to go into effect." 16 60
        fi
      fi
    ;;
    "N" )
      if [ "$CONFIG_AUTOMATIC_POWERON" != "y" ]; then
        if (whiptail --title 'Enable automatic power-on?' \
             --yesno "The system will boot automatically when power is applied.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_AUTOMATIC_POWERON" "y"

          whiptail --title 'Config change successful' \
            --msgbox "Automatic power-on enabled;\nsave the config change and reboot for it to go into effect." 16 60
        fi
      else
        if (whiptail --title 'Disable automatic power-on?' \
             --yesno "The system will stay off when power is applied.
                    \n\nDo you want to proceed?" 0 80) then

          set_user_config "CONFIG_AUTOMATIC_POWERON" "n"

          # Disable the EC BRAM setting too, otherwise it persists until
          # manually disabled.  On the off chance the user does not actually
          # flash this change, we'll enable it again during boot.
          set_ec_poweron.sh n

          whiptail --title 'Config change successful' \
            --msgbox "Automatic power-on disabled;\nsave the config change and reboot for it to go into effect." 16 60
        fi
      fi
    ;;
  esac

done
exit 0
