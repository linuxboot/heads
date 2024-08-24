#!/bin/ash
#
# based off of flashrom-x230
#
# NOTE: This script is used on legacy-flash boards and runs with busybox ash,
# not bash
set -e -o pipefail
. /etc/ash_functions
. /tmp/config

echo

TRACE "Under /bin/flash.sh"

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
    flashrom $CONFIG_FLASHROM_OPTIONS -r "${ROM}" \
    || die "Backup to $ROM failed"
  else
    cp "$ROM" /tmp/${CONFIG_BOARD}.rom
    sha256sum /tmp/${CONFIG_BOARD}.rom
    if [ "$CLEAN" -eq 0 ]; then
      preserve_rom /tmp/${CONFIG_BOARD}.rom \
      || die "$ROM: Config preservation failed"
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
      flashrom $CONFIG_FLASHROM_OPTIONS -r /tmp/ifd.bin --ifd -i fd >/dev/null 2>&1 \
      || die "Failed to read flash descriptor"
      dd if=/tmp/ifd.bin bs=1 count=4 skip=292 of=/tmp/pchstrp9.bin >/dev/null 2>&1
      dd if=/tmp/pchstrp9.bin bs=1 count=4 seek=292 of=/tmp/${CONFIG_BOARD}.rom conv=notrunc >/dev/null 2>&1
    fi

    warn "Do not power off computer.  Updating firmware, this will take a few minutes"
    flashrom $CONFIG_FLASHROM_OPTIONS -w /tmp/${CONFIG_BOARD}.rom 2>&1 \
      || recovery "$ROM: Flash failed"
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
    die "Usage: $0 [-c|-r] <path/to/image.(rom|tgz)>"
fi

if [ "$READ" -eq 0 ] && [ "${ROM##*.}" = tgz ]; then
    if [ "${CONFIG_BOARD%_*}" = talos-2 ]; then
        rm -rf /tmp/verified_rom
        mkdir /tmp/verified_rom

        tar -C /tmp/verified_rom -xf $ROM || die "Rom archive $ROM could not be extracted"
    if ! (cd /tmp/verified_rom/ && sha256sum -cs sha256sum.txt); then
            die "Provided tgz image did not pass hash verification"
        fi

        echo "Reading current flash and building an update image"
        flashrom $CONFIG_FLASHROM_OPTIONS -r /tmp/flash.sh.bak \
            || die "Read of flash has failed"

        # ROM and bootblock already have ECC
        bootblock=$(echo /tmp/verified_rom/*.bootblock)
        rom=$(echo /tmp/verified_rom/*.rom)
        kernel=$(echo /tmp/verified_rom/*-zImage.bundled)
        pnor /tmp/flash.sh.bak -aw HBB < $bootblock
        pnor /tmp/flash.sh.bak -aw HBI < $rom
        pnor /tmp/flash.sh.bak -aw BOOTKERNEL < $kernel
        rm -rf /tmp/verified_rom

        ROM=/tmp/flash.sh.bak
    else
        die "$CONFIG_BOARD doesn't support tgz image format"
    fi
fi

flash_rom $ROM

# don't leave temporary files lying around
rm -f /tmp/flash.sh.bak

exit 0
