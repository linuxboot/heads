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
    echo "Board $CONFIG_BOARD detected with flash options configured. Continuing..."
  ;;
esac

flash_rom() {
  ROM=$1
  if [ "$READ" -eq 1 ]; then
    $CONFIG_FLASH_OPTIONS -r "${ROM}" \
    || recovery "Backup to $ROM failed"
  else
    cp "$ROM" /tmp/${CONFIG_BOARD}.rom
    sha256sum /tmp/${CONFIG_BOARD}.rom
    if [ "$CLEAN" -eq 0 ]; then
      preserve_rom /tmp/${CONFIG_BOARD}.rom \
      || recovery "$ROM: Config preservation failed"
    fi
    # persist serial number from CBFS
    if cbfs.sh -r serial_number > /tmp/serial 2>/dev/null; then
      echo "Persisting system serial"
      cbfs.sh -o /tmp/${CONFIG_BOARD}.rom -d serial_number 2>/dev/null || true
      cbfs.sh -o /tmp/${CONFIG_BOARD}.rom -a serial_number -f /tmp/serial
    fi
    # persist PCHSTRP9 from flash descriptor
    if [ "$CONFIG_BOARD" = "librem_l1um" ]; then
      echo "Persisting PCHSTRP9"
      $CONFIG_FLASH_OPTIONS -r /tmp/ifd.bin --ifd -i fd >/dev/null 2>&1 \
      || die "Failed to read flash descriptor"
      dd if=/tmp/ifd.bin bs=1 count=4 skip=292 of=/tmp/pchstrp9.bin >/dev/null 2>&1
      dd if=/tmp/pchstrp9.bin bs=1 count=4 seek=292 of=/tmp/${CONFIG_BOARD}.rom conv=notrunc >/dev/null 2>&1
    fi

    warn "Do not power off computer.  Updating firmware, this will take a few minutes"
    $CONFIG_FLASH_OPTIONS -w /tmp/${CONFIG_BOARD}.rom 2>&1 \
      || recovery "$ROM: Flash failed"
  fi
}

if [ "$1" = "-c" ]; then
  CLEAN=1
  READ=0
  ROM="$2"
elif [ "$1" = "-r" ]; then
  CLEAN=0
  READ=1
  ROM="$2"
else
  CLEAN=0
  READ=0
  ROM="$1"
fi

if [ "$READ" -eq 1 ]; then
  # -r: ROM is an output path; create it if needed then read into it
  touch "$ROM"
  flash_rom "$ROM"
else
  if [ ! -e "$ROM" ]; then
    die "Usage: $0 [-c|-r] <path/to/image.(rom|zip|tgz)>"
  fi
  case "${ROM##*.}" in
  zip|tgz)
    # Packages require extraction and integrity verification before flashing
    if ! prepare_flash_image "$ROM"; then
      die "$PREPARED_ROM_ERROR"
    fi
    flash_rom "$PREPARED_ROM"
    ;;
  *)
    # Plain ROM (or pre-built /tmp file from internal callers): flash directly.
    flash_rom "$ROM"
    ;;
  esac
fi

# don't leave temporary files lying around
rm -f /tmp/flash.sh.bak

exit 0
