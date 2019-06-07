#!/bin/sh
#
# based off of flashrom-x230
#
set -e -o pipefail
. /etc/functions
. /tmp/config

case "$CONFIG_BOARD" in
  librem* )
    FLASHROM_OPTIONS='-p internal:laptop=force_I_want_a_brick,ich_spi_mode=hwseq' 
  ;;
  x230* )
    FLASHROM_OPTIONS='--force --noverify-all --programmer internal --ifd --image bios'
  ;;
  t430* )
    FLASHROM_OPTIONS='--force --noverify-all --programmer internal:laptop=force_I_want_a_brick --ifd --image bios'
  ;;
  "kgpe-d16" )
    FLASHROM_OPTIONS='--force --noverify --programmer internal'
  ;;
  * )
    die "ERROR: No board has been configured!\n\nEach board requires specific flashrom options and it's unsafe to flash without them.\n\nAborting."
  ;;
esac

flash_rom() {
  ROM=$1
  if [ "$READ" -eq 1 ]; then
    flashrom $FLASHROM_OPTIONS -r "${ROM}.1" \
    || die "$ROM: Read failed"
    flashrom $FLASHROM_OPTIONS -r "${ROM}.2" \
    || die "$ROM: Read failed"
    flashrom $FLASHROM_OPTIONS -r "${ROM}.3" \
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

    flashrom $FLASHROM_OPTIONS -w /tmp/${CONFIG_BOARD}.rom \
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
