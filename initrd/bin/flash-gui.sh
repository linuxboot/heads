#!/bin/bash
#
set -e -o pipefail
. /etc/functions
. /etc/gui_functions
. /tmp/config

TRACE_FUNC

if [ "$CONFIG_RESTRICTED_BOOT" = y ]; then
  whiptail_error --title 'Restricted Boot Active' \
    --msgbox "Disable Restricted Boot to flash new firmware." 0 80
  exit 1
fi

# Most boards use a .rom file as a "plain" update, contents of the BIOS flash.
# talos-2 uses a .tgz for multi-component updates with built-in integrity check.
UPDATE_PLAIN_EXT="$(update_plain_ext)"

while true; do
  unset menu_choice
  whiptail_type $BG_COLOR_MAIN_MENU --title "Firmware Management Menu" \
    --menu "Select the firmware function to perform\n\nRetaining settings copies existing settings to the new firmware:\n* Keeps your GPG keyring\n* Keeps changes to the default /boot device\n\nErasing settings uses the new firmware as-is:\n* Erases any existing GPG keyring\n* Restores firmware to default factory settings\n* Clears out /boot signatures\n\nIf you are just updating your firmware, you probably want to retain\nyour settings." 0 80 10 \
    'f' ' Flash the firmware with a new ROM, retain settings' \
    'c' ' Flash the firmware with a new ROM, erase settings' \
    'x' ' Exit' \
    2>/tmp/whiptail || recovery "GUI menu failed"

  menu_choice=$(cat /tmp/whiptail)

  case "$menu_choice" in
  "x")
    exit 0
    ;;
  f | c)
    if (whiptail_warning --title 'Flash the BIOS with a new ROM' \
      --yesno "You will need to insert a USB drive containing your BIOS image (*.zip or\n*.$UPDATE_PLAIN_EXT).\n\nAfter you select this file, this program will reflash your BIOS.\n\nDo you want to proceed?" 0 80); then
      mount_usb
      if grep -q /media /proc/mounts; then
        # 'find' parameters to match desired ROM extensions
        FIND_ROM_EXTS=(\( -name "*.$UPDATE_PLAIN_EXT" -o -type f -name "*.zip" \))
        if [ "${CONFIG_BOARD%_*}" = talos-2 ]; then
          # Show only *.tgz on talos-2 (lacks ZIP update package support)
          FIND_ROM_EXTS=(-name "*.$UPDATE_PLAIN_EXT")
        fi
        # Media errors can cause this to fail (flash drive pulled, filesystem
        # corruption, etc.)
        if ! find /media ! -path '*/\.*' -type f "${FIND_ROM_EXTS[@]}" | sort >/tmp/filelist.txt; then
          whiptail --title 'Unable to read USB drive' \
            --msgbox "The USB drive is not readable.  Check the drive, reformat, or try a
                    \ndifferent drive." 16 60
          exit 1
        fi
        file_selector "/tmp/filelist.txt" "Choose the ROM to flash"
        if [ "$FILE" = "" ]; then
          exit 1
        else
          PKG_FILE=$FILE
        fi

        # Display the package file without the "/media/" prefix
        PKG_FILE_DISPLAY="${PKG_FILE#"/media/"}"

        PKG_EXTRACT="/tmp/flash_gui/update_package"

        # is an update package provided?
        if [ -z "${PKG_FILE##*.zip}" ]; then
          # Verify integrity and extract the ROM from the zip package.
          # prepare_flash_image handles extraction, sha256sum.txt validation,
          # and locating the single ROM inside.
          if ! prepare_flash_image "$PKG_FILE" "$PKG_EXTRACT"; then
            whiptail --title 'ROM Integrity Check Failed!' \
              --msgbox "Integrity check failed:\n$PKG_FILE_DISPLAY\n\n$PREPARED_ROM_ERROR\n\nDid not flash.\n\nPlease check your file (e.g. re-download).\n" 16 60
            exit 1
          fi

          if ! whiptail_warning --title 'Flash ROM?' \
            --yesno "This will replace your current ROM with:\n\n$PKG_FILE_DISPLAY\n\nDo you want to proceed?" 0 80; then
            exit 1
          fi

          ROM="$PREPARED_ROM"
        else
          # talos-2 uses a .tgz for its plain update; integrity is verified
          # automatically inside flash.sh via prepare_flash_image.
          # Skip the manual hash prompt - tgz has its own sha256sum.txt.
          if [ "${CONFIG_BOARD%_*}" != talos-2 ]; then
            # Plain .rom file: copy to /tmp and compute hash for manual verification.
            if ! prepare_flash_image "$PKG_FILE" "$PKG_EXTRACT"; then
              whiptail --title 'Failed to read ROM' \
                --msgbox "Failed to read ROM:\n$PKG_FILE_DISPLAY\n\n$PREPARED_ROM_ERROR\n\nPlease check your file (e.g. re-download).\n" 16 60
              exit 1
            fi
            ROM="$PREPARED_ROM"
            ROM_HASH="$PREPARED_ROM_HASH"
            if ! (whiptail_error --title 'Flash ROM without integrity check?' \
              --yesno "You have provided a *.$UPDATE_PLAIN_EXT file. The integrity of the file can not be\nchecked automatically for this file type.\n\nROM: $PKG_FILE_DISPLAY\nSHA256: $ROM_HASH\n\nIf you do not know how to check the file integrity yourself,\nyou should use a *.zip file instead.\n\nIf the file is damaged, you will not be able to boot anymore.\nDo you want to proceed flashing without file integrity check?" 0 80); then
              exit 1
            fi
          else
            # talos-2: pass .tgz directly to flash.sh for validated pnor assembly
            ROM="$PKG_FILE"
          fi
        fi

        if [ "$menu_choice" = "c" ]; then
          /bin/flash.sh -c "$ROM"
          # after flash, /boot signatures are now invalid so go ahead and clear them
          if ls /boot/kexec* >/dev/null 2>&1; then
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
          --msgbox "$PKG_FILE_DISPLAY\n\nhas been flashed successfully.\n\nPress Enter to reboot\n" 0 80
        umount /media
        /bin/reboot
      fi
    fi
    ;;
  esac

done
exit 0
