#!/bin/bash
#
# NOTE: This script is used on legacy-flash boards and runs with busybox ash,
# not bash
set -e -o pipefail
. /etc/functions
. /tmp/config

echo

TRACE_FUNC

case "$CONFIG_FLASH_OPTIONS" in
  "" )
    die "ERROR: No flash options have been configured!\n\nEach board requires specific CONFIG_FLASH_OPTIONS options configured. It's unsafe to flash without them.\n\nAborting."
  ;;
  * )
    DEBUG "Flash options detected: $CONFIG_FLASH_OPTIONS"
    INFO "Board $CONFIG_BOARD detected with flash options configured. Continuing..."
  ;;
esac

# Print a status line for an operation in progress.
flash_status() { INFO "$*"; }

# Print a success status line for a completed operation.
flash_status_ok() { INFO "OK: $*"; }

# Query the SPI flash write protection status via 'flashprog wp status'.
# The wp subcommand uses a separate invocation from the main flashprog command;
# --progress is not accepted by the wp subcommand so it is stripped.
# Prints protection range and mode to stdout.
# Returns 0 if write protection is disabled or the check is unsupported.
# Returns 1 if any write protection is active.
check_spi_wp() {
  TRACE_FUNC
  local wp_out wp_rc wp_opts
  flash_status "Checking SPI write protection status..."
  # Build 'flashprog wp status' args: strip binary name and --progress flag
  wp_opts="${CONFIG_FLASH_OPTIONS#flashprog}"
  wp_opts="${wp_opts//--progress/}"
  wp_rc=0
  wp_out=$(flashprog wp status $wp_opts 2>&1) || wp_rc=$?
  echo "$wp_out"
  if [ "$wp_rc" -ne 0 ]; then
    DEBUG "WP status not available for this programmer (rc=$wp_rc)"
    flash_status_ok "Write protection status not available for this programmer"
    return 0
  fi
  if echo "$wp_out" | grep -q "Protection mode: disabled"; then
    DEBUG "SPI write protection: all regions unlocked"
    flash_status_ok "All SPI regions are write-unlocked"
    return 0
  fi
  DEBUG "SPI write protection: ACTIVE on one or more regions"
  return 1
}

flash_rom() {
  TRACE_FUNC
  ROM=$1
  if [ "$READ" -eq 1 ]; then
    flash_status "Reading current firmware to $ROM..."
    $CONFIG_FLASH_OPTIONS -r "${ROM}" \
    || recovery "Backup to $ROM failed"
    flash_status_ok "Firmware read complete: $ROM"
  else
    cp "$ROM" "/tmp/${CONFIG_BOARD}.rom"
    sha256sum "/tmp/${CONFIG_BOARD}.rom"

    # Check SPI write protection before touching hardware.
    if ! check_spi_wp; then
      warn "WARNING: SPI write protection is ACTIVE on one or more regions."
      warn "         The flash write may fail or only partially succeed."
      warn "         Check the region list above before proceeding."
    fi

    if [ "$CLEAN" -eq 0 ]; then
      DEBUG "Preserving existing config in ROM"
      preserve_rom "/tmp/${CONFIG_BOARD}.rom" \
      || recovery "$ROM: Config preservation failed"
    else
      DEBUG "Clean flash: skipping config preservation"
    fi
    # persist serial number from CBFS
    if cbfs.sh -r serial_number > /tmp/serial 2>/dev/null; then
      echo "Persisting system serial"
      cbfs.sh -o "/tmp/${CONFIG_BOARD}.rom" -d serial_number 2>/dev/null || true
      cbfs.sh -o "/tmp/${CONFIG_BOARD}.rom" -a serial_number -f /tmp/serial
    fi
    # persist PCHSTRP9 from flash descriptor
    if [ "$CONFIG_BOARD" = "librem_l1um" ]; then
      echo "Persisting PCHSTRP9"
      $CONFIG_FLASH_OPTIONS -r /tmp/ifd.bin --ifd -i fd >/dev/null 2>&1 \
      || die "Failed to read flash descriptor"
      dd if=/tmp/ifd.bin bs=1 count=4 skip=292 of=/tmp/pchstrp9.bin >/dev/null 2>&1
      dd if=/tmp/pchstrp9.bin bs=1 count=4 seek=292 of="/tmp/${CONFIG_BOARD}.rom" conv=notrunc >/dev/null 2>&1
    fi

    # Save a rollback backup of the current firmware to /boot before writing.
    # Integrity is guaranteed by /boot attestation (print_tree + kexec.sig)
    # once the user signs /boot after confirming the new firmware works.
    # FLASH_BACKUP_FILE is set on successful backup; the pending_rollback marker
    # (written after flash completes) is only written when a backup was saved.
    if [ "$SAVE_BACKUP" -eq 1 ]; then
      DEBUG "Rollback backup enabled - saving current firmware before write"
      local brand_lower backup_dir backup_ts backup_file
      brand_lower="$(echo "$CONFIG_BRAND_NAME" | tr '[:upper:]' '[:lower:]')"
      backup_dir="/boot/${brand_lower}"
      backup_ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo "unknown")"
      backup_file="${backup_dir}/backup_${CONFIG_BOARD}_${backup_ts}.rom"
      flash_status "Saving rollback backup to $backup_file..."
      if grep -q " /boot " /proc/mounts 2>/dev/null; then
        mount -o remount,rw /boot 2>/dev/null || true
        mkdir -p "$backup_dir" 2>/dev/null || true
        if $CONFIG_FLASH_OPTIONS -r "$backup_file" 2>&1; then
          flash_status_ok "Rollback backup saved: $backup_file"
          FLASH_BACKUP_FILE="$backup_file"
          DEBUG "FLASH_BACKUP_FILE=$FLASH_BACKUP_FILE"
        else
          warn "WARNING: Rollback backup failed - proceeding without backup"
        fi
        mount -o remount,ro /boot 2>/dev/null || true
      else
        warn "WARNING: /boot is not mounted - rollback backup skipped"
      fi
    else
      DEBUG "Rollback backup disabled (SAVE_BACKUP=0)"
    fi

    warn "Do not power off computer.  Updating firmware, this will take a few minutes"
    flash_status "Writing firmware..."
    if [ "$NOVERIFY" -eq 1 ]; then
      NOTE "--bypass-verify active: skipping post-write verification"
      $CONFIG_FLASH_OPTIONS -w "/tmp/${CONFIG_BOARD}.rom" --noverify 2>&1 \
        || recovery "$ROM: Flash failed"
    else
      $CONFIG_FLASH_OPTIONS -w "/tmp/${CONFIG_BOARD}.rom" 2>&1 \
        || recovery "$ROM: Flash failed"
    fi
    flash_status_ok "Firmware write complete"
  fi
}

CLEAN=0
READ=0
NOVERIFY=0
SAVE_BACKUP=1  # rollback backup is on by default; disable with CONFIG_FLASH_SAVE_BACKUP=n
NO_BACKUP=0    # --no-backup hard-suppresses backup AND pending_rollback marker
ROM=""
FLASH_BACKUP_FILE=""  # set by flash_rom() only when backup saved successfully

# Apply persistent config overrides before parsing CLI flags.
# CLI flags always take final precedence.
if [ "$CONFIG_FLASH_NO_VERIFY" = "y" ]; then
  NOVERIFY=1
  DEBUG "CONFIG_FLASH_NO_VERIFY=y: post-write verification disabled by config"
fi
if [ "$CONFIG_FLASH_SAVE_BACKUP" = "n" ]; then
  SAVE_BACKUP=0
  DEBUG "CONFIG_FLASH_SAVE_BACKUP=n: rollback backup disabled by config"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c)               CLEAN=1                  ; shift ;;
    -r)               READ=1                   ; shift ;;
    --bypass-verify)  NOVERIFY=1               ; shift ;;
    --save-backup)    SAVE_BACKUP=1; NO_BACKUP=0              ; shift ;;
    --no-backup)      NO_BACKUP=1;  SAVE_BACKUP=0             ; shift ;;
    -*) die "Unknown flag: $1\nUsage: $0 [-c|-r] [--bypass-verify] [--save-backup|--no-backup] <path/to/image.(rom|zip|tgz)>" ;;
    *)  ROM="$1" ; shift ; break ;;
  esac
done

DEBUG "Flags: CLEAN=$CLEAN READ=$READ NOVERIFY=$NOVERIFY SAVE_BACKUP=$SAVE_BACKUP NO_BACKUP=$NO_BACKUP"

if [ "$NO_BACKUP" -eq 1 ]; then
  NOTE "--no-backup active: rollback backup and pending_rollback marker suppressed"
fi

if [ -z "$ROM" ]; then
  die "Usage: $0 [-c|-r] [--bypass-verify] [--save-backup|--no-backup] <path/to/image.(rom|zip|tgz)>

  (no flags)       Flash firmware, retaining GPG keyring and /boot device settings
  -c               Flash firmware, erasing all settings (factory reset)
  -r               Read/backup current firmware to the specified path
  --bypass-verify  Skip flashprog post-write verification (faster, use with care)
                   Also enabled persistently by CONFIG_FLASH_NO_VERIFY=y
  --save-backup    Force rollback backup even if CONFIG_FLASH_SAVE_BACKUP=n
                   Backup saved to /boot/<brand>/ and a pending_rollback marker
                   written so init can auto-reflash on next boot if needed
  --no-backup      Hard-suppress backup and pending_rollback marker (used by
                   automatic rollback to prevent infinite reflash loops)

Supported image formats:
  .rom  Plain ROM image - flashed directly (sha256sum printed by flashprog)
  .zip  Update package - extracted and sha256sum.txt integrity check applied
  .tgz  Talos-2 multi-component archive - sha256sum.txt integrity check applied"
fi

if [ "$READ" -eq 1 ]; then
  # -r: ROM is an output path; create it if needed then read into it
  touch "$ROM"
  flash_rom "$ROM"
else
  if [ ! -e "$ROM" ]; then
    die "ROM file not found: $ROM"
  fi
  case "${ROM##*.}" in
  zip|tgz)
    DEBUG "Package format detected: ${ROM##*.} - running prepare_flash_image"
    # Packages require extraction and integrity verification before flashing
    if ! prepare_flash_image "$ROM"; then
      die "$PREPARED_ROM_ERROR"
    fi
    flash_rom "$PREPARED_ROM"
    ;;
  *)
    DEBUG "Plain ROM or pre-built image: flashing directly"
    # Plain ROM (or pre-built /tmp file from internal callers): flash directly.
    # flash_rom() prints sha256sum for verification.
    flash_rom "$ROM"
    ;;
  esac

  # After a successful write, if a backup was saved write a pending_rollback
  # marker so init can detect this is a post-flash boot and auto-reflash
  # the backup if the new firmware fails.
  # --no-backup suppresses this to prevent infinite rollback loops.
  if [ "$NO_BACKUP" -eq 0 ] && [ -n "$FLASH_BACKUP_FILE" ]; then
    MARKER_BRAND_LOWER="$(echo "$CONFIG_BRAND_NAME" | tr '[:upper:]' '[:lower:]')"
    MARKER_DIR="/boot/${MARKER_BRAND_LOWER}"
    flash_status "Writing pending_rollback marker..."
    DEBUG "Marker dir: $MARKER_DIR"
    if grep -q " /boot " /proc/mounts 2>/dev/null; then
      mount -o remount,rw /boot 2>/dev/null || true
      mkdir -p "$MARKER_DIR" 2>/dev/null || true
      if echo "$FLASH_BACKUP_FILE" > "${MARKER_DIR}/pending_rollback" 2>/dev/null; then
        flash_status_ok "Rollback marker written: ${MARKER_DIR}/pending_rollback"
        DEBUG "pending_rollback contains: $FLASH_BACKUP_FILE"
      else
        warn "WARNING: Failed to write rollback marker"
      fi
      mount -o remount,ro /boot 2>/dev/null || true
    fi
  else
    DEBUG "Skipping pending_rollback marker (NO_BACKUP=$NO_BACKUP FLASH_BACKUP_FILE=$FLASH_BACKUP_FILE)"
  fi
fi

# don't leave temporary files lying around
rm -f /tmp/flash.sh.bak

exit 0
