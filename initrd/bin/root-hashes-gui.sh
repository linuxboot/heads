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
      --msgbox "No Valid Root Disk Found" 0 80
    die "No Valid Root Disk Found"
  fi

  # mount /boot RW
  if ! grep -q /boot /proc/mounts ; then
    if ! mount -o rw /boot; then
       unmount_root_device
       whiptail $BG_COLOR_ERROR --title 'ERROR: Unable to mount /boot' \
         --msgbox "Unable to mount /boot" 0 80
       die "Unable to mount /boot"
    fi
  else
    mount -o rw,remount /boot
  fi

  echo "+++ Calculating hashes for all files in $CONFIG_ROOT_DIRLIST_PRETTY "
  # Intentional wordsplit
  # shellcheck disable=SC2086
  (cd "$ROOT_MOUNT" && find ${CONFIG_ROOT_DIRLIST} -type f ! -name '*kexec*' -print0 | xargs -0 sha256sum) >"${HASH_FILE}"
  
  # switch back to ro mode
  mount -o ro,remount /boot

  update_checksums

  whiptail --title 'Root Hashes Updated and Signed' \
    --msgbox "All files in:\n$CONFIG_ROOT_DIRLIST_PRETTY\nhave been hashed and signed successfully" 0 80

  unmount_root_device
}
check_root_checksums() {
  if ! detect_root_device; then
    whiptail $BG_COLOR_ERROR --title 'ERROR: No Valid Root Disk Found' \
      --msgbox "No Valid Root Disk Found" 0 80
    die "No Valid Root Disk Found"
  fi

  # mount /boot RO
  if ! grep -q /boot /proc/mounts ; then
    if ! mount -o ro /boot; then
       unmount_root_device
       whiptail $BG_COLOR_ERROR --title 'ERROR: Unable to mount /boot' \
         --msgbox "Unable to mount /boot" 0 80
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
      --msgbox "The signature check on hash files failed:\n${CHANGED_FILES}\nExiting to a recovery shell" 0 80
    unmount_root_device
    die 'Invalid signature'
  fi

  echo "+++ Checking for new files in $CONFIG_ROOT_DIRLIST_PRETTY "
  (cd "$ROOT_MOUNT" && find ${CONFIG_ROOT_DIRLIST} -type f ! -name '*kexec*') | sort > /tmp/new_file_list
  cut -d' ' -f3- ${HASH_FILE} | sort | diff -U0 - /tmp/new_file_list > /tmp/new_file_diff || new_files_found=y
  if [ "$new_files_found" == "y" ]; then
    grep -E -v '^[+-]{3}|[@]{2} ' /tmp/new_file_diff > /tmp/new_file_diff2 # strip any output that's not a file
    mv /tmp/new_file_diff2 /tmp/new_file_diff
    CHANGED_FILES_COUNT=$(wc -l /tmp/new_file_diff | cut -f1 -d ' ')
    whiptail $BG_COLOR_ERROR --title 'ERROR: Files Added/Removed in Root ' \
      --msgbox "${CHANGED_FILES_COUNT} files were added/removed in root!\n\nHit OK to review the list of files.\n\nType \"q\" to exit the list and return to the menu." 0 80

    echo "Type \"q\" to exit the list and return to the menu." >> /tmp/new_file_diff
    less /tmp/new_file_diff
  else
    echo "+++ Verified no files added/removed "
  fi

  echo "+++ Checking hashes for all files in $CONFIG_ROOT_DIRLIST_PRETTY (this might take a while) "
  if (cd $ROOT_MOUNT && sha256sum -c ${HASH_FILE} > /tmp/hash_output 2>/dev/null); then
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
      --msgbox "${CHANGED_FILES_COUNT} files failed the verification process!\n\nHit OK to review the list of files.\n\nType \"q\" to exit the list and return to the menu." 0 80
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

# Open an LVM volume group, then continue looking for more layers in the 'root'
# logical volume.
open_block_device_lvm() {
  TRACE_FUNC
  local VG="$1"

  if ! lvm vgchange -ay "$VG"; then
    DEBUG "Can't open LVM VG: $VG"
    return 1
  fi

  # Use the LV 'root'.  This is the default name used by Qubes.  There's no
  # way to configure this at the moment.
  if ! [ -e "/dev/mapper/$VG-root" ]; then
    DEBUG "LVM volume group does not have 'root' logical volume"
    return 1
  fi

  # Use the root LV now
  open_block_device_layers "/dev/mapper/$VG-root"
}

# Open a LUKS device, then continue looking for more layers.
open_block_device_luks() {
  TRACE_FUNC
  local DEVICE="$1"
  local LUKSDEV
  LUKSDEV="$(basename "$DEVICE")_crypt"

  # Open the LUKS device.  This may prompt interactively for the passphrase, so
  # hook it up to the console even if stdout/stdin have been redirected.
  if ! cryptsetup open "$DEVICE" "$LUKSDEV"; then
    DEBUG "Can't open LUKS volume: $DEVICE"
    return 1
  fi

  open_block_device_layers "/dev/mapper/$LUKSDEV"
}

# Open block device layers to access /root recursively.  If another layer (LUKS
# or LVM) can be identified, open it and recurse into the new device.  When all
# recognized layers are opened, print the final block device and exit
# successfully (open_root_device will try to mount it).
#
# This only fails if we can recognize another LUKS or LVM layer, but cannot open
# it.  It succeeds otherwise, even if no layers are recognized, because we
# should try to mount the block device directly in that case.
open_block_device_layers() {
  TRACE_FUNC
  local DEVICE="$1"
  local VG

  if ! [ -e "$DEVICE" ]; then
    DEBUG "Block device doesn't exit: $DEVICE"
    # This shouldn't really happen, we thought we opened the last layer
    # successfully.  The call stack reveals what LUKS/LVM2 layers have been
    # opened so far.
    DEBUG_STACK
    return 1
  fi

  # Try to open a LUKS layer
  if cryptsetup isLuks "$DEVICE" &>/dev/null; then
    open_block_device_luks "$DEVICE" || return 1
  # Try to open an LVM layer
  elif VG="$(find_lvm_vg_name "$DEVICE")"; then
    open_block_device_lvm "$VG" || return 1
  else
    # The given block device exists but is not any layer we understand.  Stop
    # opening layers and try to mount it.
    echo "$DEVICE"
  fi
}

# Try to open a block device as /root.  open_block_device_layers() is used to
# open LUKS and LVM layers before mounting the filesystem.
#
# This function does not clean up anything if it is unsuccessful.  Use
# try_open_root_device() to also clean up when unsuccessful.
open_root_device_no_clean_up() {
  TRACE_FUNC
  local DEVICE="$1"
  local FS_DEVICE

  # Open LUKS/LVM and get the name of the block device that should contain the
  # filesystem.  If there are no LUKS/LVM layers, FS_DEVICE is just DEVICE.
  FS_DEVICE="$(open_block_device_layers "$DEVICE")" || return 1

  # Mount the device
  if ! mount -o ro "$FS_DEVICE" "$ROOT_MOUNT" &>/dev/null; then
    DEBUG "Can't mount filesystem on $FS_DEVICE from $DEVICE"
    return 1
  fi

  # The filesystem must have all of the directories configured.  (Intentional
  # word-split)
  # shellcheck disable=SC2086
  if ! (cd "$ROOT_MOUNT" && ls -d $CONFIG_ROOT_DIRLIST &>/dev/null); then
    DEBUG "Root filesystem on $DEVICE lacks one of the configured directories: $CONFIG_ROOT_DIRLIST"
    return 1
  fi

  # Root is mounted now and the directories are present
  return 0
}

# If an LVM VG is open, close any layers within it, then close the LVM VG.
close_block_device_lvm() {
  TRACE_FUNC
  local VG="$1"

  # We always use the LV 'root' currently
  local LV="/dev/mapper/$VG-root"
  if [ -e "$LV" ]; then
    close_block_device_layers "$LV"
  fi

  # The LVM VG might be open even if no 'root' LV exists, still try to close it.
  lvm vgchange -an "$VG" || \
    DEBUG "Can't close LVM VG: $VG"
}

# If a LUKS device is open, close any layers within the LUKS device, then close
# the LUKS device.
close_block_device_luks() {
  TRACE_FUNC
  local DEVICE="$1"
  local LUKSDEV
  LUKSDEV="$(basename "$DEVICE")_crypt"

  if [ -e "/dev/mapper/$LUKSDEV" ]; then
    # Close inner layers before trying to close LUKS
    close_block_device_layers "/dev/mapper/$LUKSDEV"
    cryptsetup close "$LUKSDEV" || \
      DEBUG "Can't close LUKS volume: $LUKSDEV"
  fi
}

# Close the root device, including unmounting the filesystem and closing all
# layers.  This can close a partially-opened device if an error occurs.
close_block_device_layers() {
  TRACE_FUNC
  local DEVICE="$1"
  local VG

  if ! [ -e "$DEVICE" ]; then
    DEBUG "Block device doesn't exit: $DEVICE"
    # Like in open_root_device(), this shouldn't really happen, show the layers
    # up to this point via the call stack.
    DEBUG_STACK
    return 1
  fi

  if cryptsetup isLuks "$DEVICE"; then
    close_block_device_luks "$DEVICE"
  elif VG="$(find_lvm_vg_name "$DEVICE")"; then
    close_block_device_lvm "$VG"
  fi
  # Otherwise, we've handled all the layers we understood, there's nothing left
  # to do.
}

# Try to open the root device, and clean up if unsuccessful.
open_root_device() {
  TRACE_FUNC
  if ! open_root_device_no_clean_up "$1"; then
    unmount_root_device
    return 1
  fi

  return 0
}

# Close the root device, including unmounting the filesystem and closing all
# layers.  This can close a partially-opened device if an error occurs.  This
# never fails, if an error occurs it still tries to close anything it can.
close_root_device() {
  TRACE_FUNC
  local DEVICE="$1"

  # Unmount the filesystem if it is mounted.  If it is not mounted, ignore the
  # failure.  If it is mounted but can't be unmounted, this will fail and we
  # will fail to close any LUKS/LVM layers too.
  umount "$ROOT_MOUNT" &>/dev/null || true

  close_block_device_layers "$DEVICE" || true
}

# detect and set /root device
# mount /root if successful
detect_root_device()
{
  TRACE_FUNC

  echo "+++ Detecting root device "

  if [ ! -e $ROOT_MOUNT ]; then
    mkdir -p $ROOT_MOUNT
  fi
  # Ensure nothing is opened/mounted
  unmount_root_device

  # check $CONFIG_ROOT_DEV if set/valid
  if [ -e "$CONFIG_ROOT_DEV" ] && open_root_device "$CONFIG_ROOT_DEV"; then
    return 0
  fi

  # generate list of possible boot devices
  fdisk -l | grep "Disk /dev/" | cut -f2 -d " " | cut -f1 -d ":" > /tmp/disklist

  # filter out extraneous options
  > /tmp_root_device_list
  while IFS= read -r -u 10 i; do
    # remove block device from list if numeric partitions exist
    DEV_NUM_PARTITIONS=$((`ls -1 $i* | wc -l`-1))
    if [ ${DEV_NUM_PARTITIONS} -eq 0 ]; then
      echo $i >> /tmp_root_device_list
    else
      ls $i* | tail -${DEV_NUM_PARTITIONS} >> /tmp_root_device_list
    fi
  done 10</tmp/disklist

  # iterate through possible options
  while IFS= read -r -u 10 i; do
    if open_root_device "$i"; then
      # CONFIG_ROOT_DEV is valid device and contains an installed OS
      CONFIG_ROOT_DEV="$i"
      return 0
    fi
  done 10</tmp_root_device_list

  # no valid root device found
  echo "Unable to locate $ROOT_MOUNT files on any mounted disk"
  return 1
}

unmount_root_device()
{
  [ -e "$CONFIG_ROOT_DEV" ] && close_root_device "$CONFIG_ROOT_DEV"
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
         --msgbox "Unable to mount /boot" 0 80
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
          --msgbox "All files in $CONFIG_ROOT_DIRLIST_PRETTY passed the verification process" 0 80
      fi
    ;;
    "u" )
      update_root_checksums
    ;;
  esac

done
exit 0
