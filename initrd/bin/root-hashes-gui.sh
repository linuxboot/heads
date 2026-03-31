#!/bin/bash

set -e -o pipefail

CONFIG_ROOT_DIRLIST="bin boot lib sbin usr"
HASH_FILE="/boot/kexec_root_hashes.txt"
ROOT_MOUNT="/root"
ROOT_DETECT_UNSUPPORTED_REASON=""
ROOT_SUPPORTED_LAYOUT_MSG="Filesystem support in this build:\n- ext4 (ext2/ext3 compatible)\n- xfs\n\nSupported root layouts:\n- LUKS + ext4/ext3/ext2 or xfs\n- LUKS+LVM + ext4/ext3/ext2 or xfs\n\nNot supported:\n- btrfs"

. /etc/functions.sh
. /etc/gui_functions.sh
. /tmp/config

export CONFIG_ROOT_DIRLIST_PRETTY=$(echo $CONFIG_ROOT_DIRLIST | sed -e 's/^/\//;s/ / \//g')

show_unsupported_root_layout_and_die() {
  local ACTION="$1"

  whiptail_error --title 'ERROR: Unsupported Root Layout' \
    --msgbox "$ROOT_DETECT_UNSUPPORTED_REASON\n\n$ROOT_SUPPORTED_LAYOUT_MSG\n\nTry a supported root layout,\nor do not use root hashing,\nthen rerun $ACTION." 0 80
  die "$ROOT_DETECT_UNSUPPORTED_REASON"
}

update_root_checksums() {
  TRACE_FUNC
  if ! detect_root_device; then
    if [ -n "$ROOT_DETECT_UNSUPPORTED_REASON" ]; then
      show_unsupported_root_layout_and_die "root hash update"
    fi
    whiptail_error --title 'ERROR: No Valid Root Disk Found' \
      --msgbox "No Valid Root Disk Found" 0 80
    die "No Valid Root Disk Found"
  fi

  # mount /boot RW
  if ! grep -q /boot /proc/mounts ; then
    if ! mount -o rw /boot; then
       unmount_root_device
       whiptail_error --title 'ERROR: Unable to mount /boot' \
         --msgbox "Unable to mount /boot" 0 80
       die "Unable to mount /boot"
    fi
  else
    mount -o rw,remount /boot
  fi

  DEBUG "calculating hashes for $CONFIG_ROOT_DIRLIST_PRETTY on $ROOT_MOUNT"
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
  TRACE_FUNC
  DEBUG "verifying existing hash file for $CONFIG_ROOT_DIRLIST_PRETTY"
  if ! detect_root_device; then
    if [ -n "$ROOT_DETECT_UNSUPPORTED_REASON" ]; then
      show_unsupported_root_layout_and_die "root hash verification"
    fi
    whiptail_error --title 'ERROR: No Valid Root Disk Found' \
      --msgbox "No Valid Root Disk Found" 0 80
    die "No Valid Root Disk Found"
  fi

  # mount /boot RO
  if ! grep -q /boot /proc/mounts ; then
    if ! mount -o ro /boot; then
       unmount_root_device
       whiptail_error --title 'ERROR: Unable to mount /boot' \
         --msgbox "Unable to mount /boot" 0 80
       die "Unable to mount /boot"
    fi
  fi

  # check that root hash file exists
  if [ ! -f ${HASH_FILE} ]; then
     if (whiptail_warning --title 'WARNING: No Root Hash File Found' \
        --yesno "\nIf you just enabled root hash checking feature,
                \nthen you need to create the initial hash file.
                \nOtherwise, This could be caused by tampering.
                \n
                \nWould you like to create the hash file now?" 0 80) then
        update_root_checksums
        return 0
      else
        DEBUG "Root hash file not created (user declined)"
        exit 1
      fi
  fi

  echo "+++ Checking root hash file signature "
  if ! sha256sum `find /boot/kexec*.txt` | gpgv /boot/kexec.sig - > /tmp/hash_output; then
    ERROR=`cat /tmp/hash_output`
    whiptail_error --title 'ERROR: Signature Failure' \
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
    whiptail_error --title 'ERROR: Files Added/Removed in Root ' \
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
        DEBUG "Signatures not updated (user declined after new-files warning)"
        return 1
      fi
    fi
    return 0
  else
    CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':' | tee -a /tmp/hash_output_mismatches)
    CHANGED_FILES_COUNT=$(wc -l /tmp/hash_output_mismatches | cut -f1 -d ' ')
    whiptail_error --title 'ERROR: Root Hash Mismatch' \
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
      DEBUG "Signatures not updated (user declined after hash-check failure)"
      return 1
    fi
  fi
}

# Open an LVM volume group, then continue looking for more layers in the 'root'
# logical volume.
open_block_device_lvm() {
  TRACE_FUNC
  local VG="$1"
  local LV MAPPER_VG MAPPER_LV name lvpath FIRST_LV_PREFERRED FIRST_LV_FALLBACK

  if ! lvm vgchange -ay "$VG"; then
    DEBUG "Can't open LVM VG: $VG"
    return 1
  fi

  # Prefer an LV named 'root' (used by Qubes), but fall back to any LV
  # in the VG.  This ensures Ubuntu-style names (e.g. ubuntu-vg/ubuntu-root)
  # also work.
  LV="/dev/$VG/root"
  if ! [ -e "$LV" ]; then
    MAPPER_VG="${VG//-/--}"
    LV="/dev/mapper/${MAPPER_VG}-root"
  fi
  if ! [ -e "$LV" ]; then
    FIRST_LV_PREFERRED=""
    FIRST_LV_FALLBACK=""
    DEBUG "LVM VG $VG has no 'root' LV, enumerating all LVs"
    # list LV names and prefer root-like names
    for name in $(lvm lvs --noheadings -o lv_name --separator ' ' "$VG" 2>/dev/null); do
      # thin pool/metadata and swap-like LVs are not root filesystems
      case "$name" in
        *pool*|*tmeta*|*tdata*|*tpool*|swap*)
          DEBUG "skipping LV name $name (not a root LV candidate)"
          continue
          ;;
      esac

      lvpath="/dev/$VG/$name"
      if ! [ -e "$lvpath" ]; then
        MAPPER_LV="${name//-/--}"
        lvpath="/dev/mapper/${VG//-/--}-${MAPPER_LV}"
      fi
      if [ -e "$lvpath" ]; then
        case "$name" in
          root|dom0|dom0-root|qubes_dom0|qubes_dom0-root|*dom0*root*|*root*)
            [ -n "$FIRST_LV_PREFERRED" ] || FIRST_LV_PREFERRED="$lvpath"
            DEBUG "preferred LV candidate $lvpath (name $name)"
            ;;
          *)
            [ -n "$FIRST_LV_FALLBACK" ] || FIRST_LV_FALLBACK="$lvpath"
            ;;
        esac
      fi
    done

    if [ -n "$FIRST_LV_PREFERRED" ]; then
      DEBUG "selecting preferred LV $FIRST_LV_PREFERRED in VG $VG"
      LV="$FIRST_LV_PREFERRED"
    elif [ -n "$FIRST_LV_FALLBACK" ]; then
      DEBUG "falling back to first mountable LV $FIRST_LV_FALLBACK in VG $VG"
      LV="$FIRST_LV_FALLBACK"
    else
      LV=""
    fi
  fi
  if ! [ -e "$LV" ]; then
    DEBUG "no usable LV found in VG $VG"
    return 1
  fi
  # Use selected LV
  open_block_device_layers "$LV"
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

  # Inform LVM about any new physical volume inside this decrypted container.
  # Some distributions (Fedora) require a vgscan before LVM will create nodes
  # under /dev/mapper, otherwise our later search won't see the logical
  # volumes.  This is harmless on systems without lvm installed.
  if command -v lvm >/dev/null 2>&1; then
    DEBUG "running vgscan to populate /dev/mapper after unlocking LUKS"
    lvm vgscan --mknodes >/dev/null 2>&1 || true
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
  local FS_DEVICE BLKID_OUT

  # Open LUKS/LVM and get the name of the block device that should contain the
  # filesystem.  If there are no LUKS/LVM layers, FS_DEVICE is just DEVICE.
  FS_DEVICE="$(open_block_device_layers "$DEVICE")" || return 1

  # Keep detection minimal for initrd: only require blkid to return some
  # metadata before mount probing. TYPE is often unavailable in this initrd.
  BLKID_OUT="$(blkid "$FS_DEVICE" 2>/dev/null || true)"
  DEBUG "blkid output for $FS_DEVICE: $BLKID_OUT"

  # If blkid reports nothing at all, this is likely not a filesystem-bearing
  # partition. Skip mount probing to avoid noisy kernel probe logs.
  if [ -z "$BLKID_OUT" ]; then
    ROOT_DETECT_UNSUPPORTED_REASON="Found partition/layer with no recognizable filesystem metadata."
    DEBUG "Skipping $FS_DEVICE: blkid returned no filesystem metadata"
    return 1
  fi

  # Mount the device
  if ! mount -o ro "$FS_DEVICE" "$ROOT_MOUNT" &>/dev/null; then
    ROOT_DETECT_UNSUPPORTED_REASON="Found partition/layer on $FS_DEVICE but it could not be mounted as root by this root-hash flow."
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
  # Deactivate the VG directly. This avoids recursive LV close probing noise
  # for LV paths that are not PVs and matches the minimal initrd workflow.
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
    close_root_device "$1"
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
  ROOT_DETECT_UNSUPPORTED_REASON=""

  # check $CONFIG_ROOT_DEV if set/valid
  # run open_root_device with fd10 closed so external tools don't inherit it
  if [ -e "$CONFIG_ROOT_DEV" ] && open_root_device "$CONFIG_ROOT_DEV" 10<&-; then
    return 0
  fi

  # generate list of possible boot devices
  fdisk -l 2>/dev/null | grep "Disk /dev/" | cut -f2 -d " " | cut -f1 -d ":" > /tmp/disklist
  DEBUG "detect_root_device: initial disklist=$(cat /tmp/disklist | tr '\n' ' ')"

  # filter out extraneous options
  > /tmp_root_device_list
  while IFS= read -r -u 10 i; do
    # remove block device from list if numeric partitions exist
    DEV_NUM_PARTITIONS=$((`ls -1 $i* | wc -l`-1))
    DEBUG "detect_root_device: candidate $i has $DEV_NUM_PARTITIONS numeric partitions"
    if [ ${DEV_NUM_PARTITIONS} -eq 0 ]; then
      echo $i >> /tmp_root_device_list
    else
      ls $i* | tail -${DEV_NUM_PARTITIONS} >> /tmp_root_device_list
    fi
  done 10</tmp/disklist

  # log the list after filtering
  DEBUG "detect_root_device: filtered candidates=$(cat /tmp_root_device_list | tr '\n' ' ')"

  # iterate through possible options
  while IFS= read -r -u 10 i; do
    DEBUG "detect_root_device: trying candidate $i"
    # close fd10 for the called command so it isn't inherited by tools like
    # lvm, which otherwise complain about a leaked descriptor.
    if open_root_device "$i" 10<&-; then
      DEBUG "detect_root_device: candidate $i succeeded"
      CONFIG_ROOT_DEV="$i"
      return 0
    else
      DEBUG "detect_root_device: candidate $i failed"
    fi
  done 10</tmp_root_device_list

  # failed to find root on physical partitions; try any mapped devices
  for m in /dev/mapper/*; do
    # skip non-existent or non-block devices such as the control node
    [ -e "$m" ] || continue
    [ -b "$m" ] || continue

    DEBUG "detect_root_device: trying mapper device $m as potential root"
    if open_root_device "$m"; then
      CONFIG_ROOT_DEV="$m"
      DEBUG "detect_root_device: mapper device $m appears to contain root files"
      return 0
    fi
  done

  # no valid root device found
  if [ -n "$ROOT_DETECT_UNSUPPORTED_REASON" ]; then
    DEBUG "$ROOT_DETECT_UNSUPPORTED_REASON"
  fi
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
       whiptail_error --title 'ERROR: Unable to mount /boot' \
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
