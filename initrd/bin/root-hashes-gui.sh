#!/bin/bash

set -e -o pipefail

CONFIG_ROOT_DIRLIST="bin boot lib sbin usr"
HASH_FILE="/boot/kexec_root_hashes.txt"
ROOT_MOUNT="/root"

. /etc/functions
. /etc/gui_functions
. /tmp/config

export CONFIG_ROOT_DIRLIST_PRETTY=$(echo $CONFIG_ROOT_DIRLIST | sed -e 's/^/\//;s/ / \//g')

update_root_checksums() {
  if ! detect_root_device; then
    whiptail $BG_COLOR_ERROR --title 'ERROR: No Valid Root Disk Found' \
      --msgbox "No Valid Root Disk Found" 16 60
    die "No Valid Root Disk Found"
  fi

  # mount /boot RW
  if ! grep -q /boot /proc/mounts ; then
    if ! mount -o rw /boot; then
       unmount_root_device
       whiptail $BG_COLOR_ERROR --title 'ERROR: Unable to mount /boot' \
         --msgbox "Unable to mount /boot" 16 60
       die "Unable to mount /boot"
    fi
  else
    mount -o rw,remount /boot
  fi

  echo "+++ Calculating hashes for all files in $CONFIG_ROOT_DIRLIST_PRETTY "
  cd $ROOT_MOUNT && find ${CONFIG_ROOT_DIRLIST} -type f ! -name '*kexec*' -print0 | xargs -0 sha256sum | tee ${HASH_FILE}
  
  # switch back to ro mode
  mount -o ro,remount /boot

  update_checksums

  whiptail --title 'Root Hashes Updated and Signed' \
    --msgbox "All files in:\n$CONFIG_ROOT_DIRLIST_PRETTY\nhave been hashed and signed successfully" 16 60

  unmount_root_device
}
check_root_checksums() {
  if ! detect_root_device; then
    whiptail $BG_COLOR_ERROR --title 'ERROR: No Valid Root Disk Found' \
      --msgbox "No Valid Root Disk Found" 16 60
    die "No Valid Root Disk Found"
  fi

  # mount /boot RO
  if ! grep -q /boot /proc/mounts ; then
    if ! mount -o ro /boot; then
       unmount_root_device
       whiptail $BG_COLOR_ERROR --title 'ERROR: Unable to mount /boot' \
         --msgbox "Unable to mount /boot" 16 60
       die "Unable to mount /boot"
    fi
  fi

  # check that root hash file exists
  if [ ! -f ${HASH_FILE} ]; then
     if (whiptail $BG_COLOR_WARNING --title 'WARNING: No Root Hash File Found' \
        --yesno "\nIf you just enabled root hash checking feature,
                \nthen you need to create the initial hash file.
                \nOtherwise, This could be caused by tampering.
                \n
                \nWould you like to create the hash file now?" 0 80) then
        update_root_checksums
        return 0
      else
        exit 1
      fi
  fi

  echo "+++ Checking root hash file signature "
  if ! sha256sum `find /boot/kexec*.txt` | gpgv /boot/kexec.sig - > /tmp/hash_output; then
    ERROR=`cat /tmp/hash_output`
    whiptail $BG_COLOR_ERROR --title 'ERROR: Signature Failure' \
      --msgbox "The signature check on hash files failed:\n${CHANGED_FILES}\nExiting to a recovery shell" 16 60
    unmount_root_device
    die 'Invalid signature'
  fi

  echo "+++ Checking for new files in $CONFIG_ROOT_DIRLIST_PRETTY "
  find ${CONFIG_ROOT_DIRLIST} -type f ! -name '*kexec*' | sort > /tmp/new_file_list
  cut -d' ' -f3- ${HASH_FILE} | sort | diff -U0 - /tmp/new_file_list > /tmp/new_file_diff || new_files_found=y
  if [ "$new_files_found" == "y" ]; then
    grep -E -v '^[+-]{3}|[@]{2} ' /tmp/new_file_diff > /tmp/new_file_diff2 # strip any output that's not a file
    mv /tmp/new_file_diff2 /tmp/new_file_diff
    CHANGED_FILES_COUNT=$(wc -l /tmp/new_file_diff | cut -f1 -d ' ')
    whiptail $BG_COLOR_ERROR --title 'ERROR: Files Added/Removed in Root ' \
      --msgbox "${CHANGED_FILES_COUNT} files were added/removed in root!\n\nHit OK to review the list of files.\n\nType \"q\" to exit the list and return to the menu." 16 60

    echo "Type \"q\" to exit the list and return to the menu." >> /tmp/new_file_diff
    less /tmp/new_file_diff
  else
    echo "+++ Verified no files added/removed "
  fi

  echo "+++ Checking hashes for all files in $CONFIG_ROOT_DIRLIST_PRETTY (this might take a while) "
  if cd $ROOT_MOUNT && sha256sum -c ${HASH_FILE} > /tmp/hash_output 2>/dev/null; then
    echo "+++ Verified root hashes "
    valid_hash='y'
    unmount_root_device

    if [ "$new_files_found" == "y" ]; then
      if (whiptail --title 'ERROR: New Files Added/Removed in Root' \
        --yesno "New files were added/removed in root.
                \n
                \nThis could be caused by tampering or by routine software updates.
                \n
                \nIf you just updated the software on your system, then that is likely
                \nthe cause and you should update your file signatures.
                \n
                \nWould you like to update your signatures now?" 0 80) then

        update_root_checksums

        return 0
      else
        return 1
      fi
    fi
    return 0
  else
    CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':' | tee -a /tmp/hash_output_mismatches)
    CHANGED_FILES_COUNT=$(wc -l /tmp/hash_output_mismatches | cut -f1 -d ' ')
    whiptail $BG_COLOR_ERROR --title 'ERROR: Root Hash Mismatch' \
      --msgbox "${CHANGED_FILES_COUNT} files failed the verification process!\n\nHit OK to review the list of files.\n\nType \"q\" to exit the list and return to the menu." 16 60
    unmount_root_device

    echo "Type \"q\" to exit the list and return to the menu." >> /tmp/hash_output_mismatches
    less /tmp/hash_output_mismatches

    #move outdated hash mismatch list
    mv /tmp/hash_output_mismatches /tmp/hash_output_mismatch_old

    if (whiptail --title 'ERROR: Root Hash Check Failed' \
      --yesno "The root hash check failed.
              \n
              \nThis could be caused by tampering or by routine software updates.
              \n
              \nIf you just updated the software on your system, then that is likely
              \nthe cause and you should update your file signatures.
              \n
              \nWould you like to update your signatures now?" 0 80) then

      update_root_checksums
      return 0
    else
      return 1
    fi
  fi
}
# detect and set /root device
# mount /root if successful
detect_root_device()
{
  echo "+++ Detecting root device "

  if [ ! -e $ROOT_MOUNT ]; then
    mkdir -p $ROOT_MOUNT
  fi
  # unmount $ROOT_MOUNT to be safe
  cd / && umount $ROOT_MOUNT 2>/dev/null

  # check $CONFIG_ROOT_DEV if set/valid
  if [ -e "$CONFIG_ROOT_DEV" ]; then
    if cryptsetup isLuks $CONFIG_ROOT_DEV >/dev/null 2>&1; then
      if cryptsetup luksOpen $CONFIG_ROOT_DEV rootdisk; then
        if mount -o ro /dev/mapper/rootdisk $ROOT_MOUNT >/dev/null 2>&1; then
          if cd $ROOT_MOUNT && ls -d $CONFIG_ROOT_DIRLIST >/dev/null 2>&1; then # CONFIG_ROOT_DEV is valid device and contains an installed OS
            return 0
          fi
        fi
      fi
    fi
  fi

  # generate list of possible boot devices
  fdisk -l | grep "Disk /dev/" | cut -f2 -d " " | cut -f1 -d ":" > /tmp/disklist

  # filter out extraneous options
  > /tmp_root_device_list
  for i in `cat /tmp/disklist`; do
    # remove block device from list if numeric partitions exist
    DEV_NUM_PARTITIONS=$((`ls -1 $i* | wc -l`-1))
    if [ ${DEV_NUM_PARTITIONS} -eq 0 ]; then
      echo $i >> /tmp_root_device_list
    else
      ls $i* | tail -${DEV_NUM_PARTITIONS} >> /tmp_root_device_list
    fi
  done

  # iterate thru possible options and check for LUKS
  for i in `cat /tmp_root_device_list`; do
    if cryptsetup isLuks $i >/dev/null 2>&1; then
      if cryptsetup luksOpen $i rootdisk; then
        if mount -o ro /dev/mapper/rootdisk $ROOT_MOUNT >/dev/null 2>&1; then
          if cd $ROOT_MOUNT && ls -d $CONFIG_ROOT_DIRLIST >/dev/null 2>&1; then
            # CONFIG_ROOT_DEV is valid device and contains an installed OS
            CONFIG_ROOT_DEV="$i"
            return 0
          fi
        fi
      fi
    fi
  done

  # no valid root device found
  echo "Unable to locate $ROOT_MOUNT files on any mounted disk"
  unmount_root_device
  return 1
}
unmount_root_device()
{
  cd /
  umount $ROOT_MOUNT 2>/dev/null
  cryptsetup luksClose rootdisk
}

checkonly="n"
createnew="n"
while getopts ":hcn" arg; do
	case $arg in
		c) checkonly="y" ;;
		n) createnew="y" ;;
		h) echo "Usage: $0 [-c|-h|-n]"; exit 0 ;;
  esac
done

if [ "$checkonly" = "y" ]; then
  check_root_checksums
  if [ -e /tmp/hash_output_mismatches ]; then # if this file exists, there were errors
    exit 1
  else
    exit 0
  fi
fi

if [ "$createnew" = "y" ]; then
  update_root_checksums
  exit 0
fi

while true; do
  unset menu_choice

  # mount /boot RO to detect hash file
  if ! grep -q /boot /proc/mounts ; then
    if ! mount -o ro /boot; then
       unmount_root_device
       whiptail $BG_COLOR_ERROR --title 'ERROR: Unable to mount /boot' \
         --msgbox "Unable to mount /boot" 16 60
       die "Unable to mount /boot"
    fi
  fi

  if [ "$CONFIG_ROOT_CHECK_AT_BOOT" = "y" ]; then
    AT_BOOT="enabled"
  else
    AT_BOOT="disabled"
  fi
  if [ -e "$HASH_FILE" ]; then
    HASH_FILE_DATE=$(stat -c %y ${HASH_FILE})
    whiptail --title "Root Disk Verification Menu" \
      --menu "This feature lets you detect tampering in files on your root disk.\n\nHash file last updated: ${HASH_FILE_DATE}\n\nYou can check and update hashes for files in:\n $CONFIG_ROOT_DIRLIST_PRETTY\n\nAutomatic checks are ${AT_BOOT} at boot.\n\nSelect the function to perform:" 0 80 10 \
      'c' ' Check root hashes' \
      'u' ' Update root hashes' \
      'x' ' Exit' \
      2>/tmp/whiptail || recovery "GUI menu failed"
  else
    whiptail --title "Root Disk Verification Menu" \
      --menu "This feature lets you detect tampering in files on your root disk.\n\nNo hash file has been created yet\n\nYou can create hashes for files in:\n $CONFIG_ROOT_DIRLIST_PRETTY\n\nAutomatic checks are ${AT_BOOT} at boot.\n\nSelect the function to perform:" 0 80 10 \
      'u' ' Create root hashes' \
      'x' ' Exit' \
      2>/tmp/whiptail || recovery "GUI menu failed"
  fi

  menu_choice=$(cat /tmp/whiptail)

  case "$menu_choice" in
    "x" )
      exit 0
    ;;
    "c" )
      check_root_checksums
      if [ $? -eq 0 ]; then
        whiptail --title 'Verified Root Hashes' \
          --msgbox "All files in $CONFIG_ROOT_DIRLIST_PRETTY passed the verification process" 16 60
      fi
    ;;
    "u" )
      update_root_checksums
    ;;
  esac

done
exit 0
