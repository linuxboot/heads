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

# A brand can override the extension used for update packages if desired
UPDATE_PKG_EXT="${CONFIG_BRAND_UPDATE_PKG_EXT:-zip}"

# Most boards use a .rom file as a "plain" update, contents of the BIOS flash
UPDATE_PLAIN_EXT=rom
# talos-2 uses a .tgz file for its "plain" update, contains other parts as well
# as its own integrity check.  This isn't integrated with the "update package"
# workflow (as-is, a .tgz could be inside that package in theory) but more work
# would be needed to properly integrate it.
if [ "${CONFIG_BOARD%_*}" = talos-2 ]; then
  UPDATE_PLAIN_EXT=tgz
fi

# Check that a glob matches exactly one thing.  If so, echoes the single value.
# Otherwise, fails.  As always, do not quote the glob.
#
# E.g, locate a ROM with unknown version when only one should be present:
# if ROM_FILE="$(single_glob /media/heads-*.rom)"; then
#     echo "ROM is $ROM_FILE"
# else
#     echo "Failed to find a ROM" >&2
# fi
single_glob() {
  if [ "$#" -eq 1 ] && [ -f "$1" ]; then
    echo "$1"
  else
    return 1
  fi
}

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
  "x")
    exit 0
    ;;
  f | c)
    if (whiptail $BG_COLOR_WARNING --title 'Flash the BIOS with a new ROM' \
      --yesno "You will need to insert a USB drive containing your BIOS image (*.$UPDATE_PKG_EXT or\n*.$UPDATE_PLAIN_EXT).\n\nAfter you select this file, this program will reflash your BIOS.\n\nDo you want to proceed?" 0 80); then
      mount_usb
      if grep -q /media /proc/mounts; then
        if [ "${CONFIG_BOARD%_*}" = talos-2 ]; then
          find /media ! -path '*/\.*' -type f -name "*.$UPDATE_PLAIN_EXT" | sort >/tmp/filelist.txt
        else
          find /media ! -path '*/\.*' -type f \( -name "*.$UPDATE_PLAIN_EXT" -o -type f -name "*.$UPDATE_PKG_EXT" \) | sort >/tmp/filelist.txt
        fi
        file_selector "/tmp/filelist.txt" "Choose the ROM to flash"
        if [ "$FILE" == "" ]; then
          exit 1
        else
          PKG_FILE=$FILE
        fi

        # is an update package provided?
        if [ -z "${PKG_FILE##*.$UPDATE_PKG_EXT}" ]; then
          # Unzip the package
          PKG_EXTRACT="/tmp/flash_gui/update_package"
          rm -rf "$PKG_EXTRACT"
          mkdir -p "$PKG_EXTRACT"
          # If extraction fails, delete everything and fall through to the
          # integrity failure prompt.  This is the most likely path if the ROM
          # was actually corrupted in transit.  Corrupting the ZIP in a way that
          # still extracts is possible (the sha256sum detects this) but less
          # likely.
          unzip "$PKG_FILE" -d "$PKG_EXTRACT" || rm -rf "$PKG_EXTRACT"
          # Older packages had /tmp/verified_rom hard-coded in the sha256sum.txt
          # Remove that so it's a relative path to the ROM in the package.
          # Ignore failure, if there is no sha256sum.txt the sha256sum will fail
          sed -i -e 's| /tmp/verified_rom/\+| |g' "$PKG_EXTRACT/sha256sum.txt" || true
          # check file integrity
          if ! (cd "$PKG_EXTRACT" && sha256sum -cs sha256sum.txt); then
            whiptail --title 'ROM Integrity Check Failed! ' \
              --msgbox "Integrity check failed in\n$PKG_FILE.\nDid not flash.\n\nPlease check your file (e.g. re-download).\n" 16 60
            exit 1
          fi

          # The package must contain exactly one *.rom file, flash that.
          if ! PACKAGE_ROM="$(single_glob "$PKG_EXTRACT/"*."$UPDATE_PLAIN_EXT")"; then
            whiptail --title 'BIOS Image Not Found! ' \
              --msgbox "A BIOS image was not found in\n$PKG_FILE.\n\nPlease check your file (e.g. re-download).\n" 16 60
            exit 1
          fi

          if ! whiptail $BG_COLOR_WARNING --title 'Flash ROM?' \
            --yesno "This will replace your current ROM with:\n\n${PKG_FILE#"/media/"}\n\nDo you want to proceed?" 0 80; then
            exit 1
          fi

          # Continue on using the verified ROM
          ROM="$PACKAGE_ROM"
        else
          # talos-2 uses a .tgz file for its "plain" update, contains other parts as well, validated against hashes under flash.sh
          # Skip prompt for hash validation for talos-2. Only method is through tgz or through bmc with individual parts
          if [ "${CONFIG_BOARD%_*}" != talos-2 ]; then
          # a rom file was provided. exit if we shall not proceed
          ROM="$PKG_FILE"
          ROM_HASH=$(sha256sum "$ROM" | awk '{print $1}') || die "Failed to hash ROM file"
          if ! (whiptail $CONFIG_ERROR_BG_COLOR --title 'Flash ROM without integrity check?' \
            --yesno "You have provided a *.$UPDATE_PLAIN_EXT file. The integrity of the file can not be\nchecked automatically for this file type.\n\nROM: $ROM\nSHA256SUM: $ROM_HASH\n\nIf you do not know how to check the file integrity yourself,\nyou should use a *.$UPDATE_PKG_EXT file instead.\n\nIf the file is damaged, you will not be able to boot anymore.\nDo you want to proceed flashing without file integrity check?" 0 80); then
            exit 1
            fi
          else
            #We are on talos-2, so we have a tgz file. We will pass it directly to flash.sh which will take care of it
            ROM="$PKG_FILE"
          fi
        fi

        if [ "$menu_choice" == "c" ]; then
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
          --msgbox "${PKG_FILE#"/media/"}\n\nhas been flashed successfully.\n\nPress Enter to reboot\n" 0 80
        umount /media
        /bin/reboot
      fi
    fi
    ;;
  esac

done
exit 0
