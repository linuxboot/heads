#!/bin/sh
#
# based off of flashrom-x230
#
set -e -o pipefail
. /etc/functions
. /tmp/config

case "$CONFIG_FLASHROM_OPTIONS" in
  -* )
    echo "Board $CONFIG_BOARD detected, continuing..."
  ;;
  * )
    die "ERROR: No board has been configured!\n\nEach board requires specific flashrom options and it's unsafe to flash without them.\n\nAborting."
  ;;
esac

flash_rom() {
  ROM=$1
  if [ "$READ" -eq 1 ]; then
    flashrom $CONFIG_FLASHROM_OPTIONS -r "${ROM}.1" \
    || die "$ROM: Read failed"
    flashrom $CONFIG_FLASHROM_OPTIONS -r "${ROM}.2" \
    || die "$ROM: Read failed"
    flashrom $CONFIG_FLASHROM_OPTIONS -r "${ROM}.3" \
    || die "$ROM: Read failed"
    if [ `sha256sum ${ROM}.[123] | cut -f1 -d ' ' | uniq | wc -l` -eq 1 ]; then
      mv ${ROM}.1 $ROM
      rm ${ROM}.[23]
    else
      die "$ROM: Read inconsistent"
    fi
  else
    cp "$ROM" /tmp/${CONFIG_BOARD}.rom
    sha256sum /tmp/${CONFIG_BOARD}.rom
    if [ "$CLEAN" -eq 0 ]; then
      preserve_rom /tmp/${CONFIG_BOARD}.rom \
      || die "$ROM: Config preservation failed"
    fi
    # persist serial number from CBFS
    if cbfs -r serial_number > /tmp/serial 2>/dev/null; then
      echo "Persisting system serial"
      cbfs -o /tmp/${CONFIG_BOARD}.rom -d serial_number 2>/dev/null || true
      cbfs -o /tmp/${CONFIG_BOARD}.rom -a serial_number -f /tmp/serial
    fi

    flashrom $CONFIG_FLASHROM_OPTIONS -w /tmp/${CONFIG_BOARD}.rom \
    || die "$ROM: Flash failed"
  fi
}

if [ "$1" == "-c" ]; then
  CLEAN=1
  READ=0
  ROM="$2"
elif [ "$1" == "-r" ]; then
  CLEAN=0
  READ=1
  ROM="$2"
  touch $ROM
else
  CLEAN=0
  READ=0
  ROM="$1"
fi

if [ ! -e "$ROM" ]; then
	die "Usage: $0 [-c|-r] <path_to_image.rom>"
fi

flash_rom $ROM
exit 0
