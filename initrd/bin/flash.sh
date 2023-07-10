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

flashrom_progress() {
    # The ichspi programmer now spews register status lines constantly that are brutally slow
    # to feed through the parser in flashrom_progress_tokenize.  Exclude them.
    # flashrom_progress_tokenize operates on individual tokens (not lines), so it splits by
    # spaces in 'read'.  But we also need to separate the last word on a line from the next
    # line, so replace newlines.
    grep -v -e '^HSFS:' -e '^HSFC:' | tr '\n' ' ' | flashrom_progress_tokenize "$1"
}

print_flashing_progress() {
    local spaces='                                                  '
    local hashes='##################################################'
    local percent pct1 pct2 progressbar progressbar2
    percent="$1"
    pct1=$((percent / 2))
    pct2=$((50 - percent / 2))
    progressbar=${hashes:0:$pct1}
    progressbar2=${spaces:0:$pct2}
    echo -ne "Flashing: [${progressbar}${spin:$spin_idx:1}${progressbar2}] (${percent}%)\\r"
}

flashrom_progress_tokenize() {
    local current=0
    local total_bytes="$1"
    local percent=0
    local IN=''
    local spin='-\|/'
    local spin_idx=0
    local status='init'
    local prev_word=''
    local prev_prev_word=''

    echo "Initializing Flash Programmer"
    while true ; do
        prev_prev_word=$prev_word
        prev_word=$IN
        read -r -d" " -t 0.2 IN
        spin_idx=$(( (spin_idx+1) %4 ))
        if [ "$status" == "init" ]; then
            if [ "$IN" == "contents..." ]; then
                status="reading"
                echo "Reading old flash contents. Please wait..."
            fi
        fi
        if [ "$status" == "reading" ]; then
            if echo "${IN}" | grep "done." > /dev/null ; then
                status="writing"
                IN=
            fi
        fi
        if [ "$status" == "writing" ]; then
            # walk_eraseblocks() prints info for each block, of the form
            # , 0xAAAAAA-0xBBBBBB:X
            # The 'X' is a char indicating the action, but the debug from actually erasing
            # and writing is mixed into the output so it may be separated.  It can also be
            # interrupted occasionally, so only match a complete token.
            current=$(echo "$IN" | sed -nE 's/^0x[0-9a-f]+-(0x[0-9a-f]+):.*$/\1/p')
            if [ "$current" != "" ]; then
                percent=$((100 * (current + 1) / total_bytes))
            fi
            print_flashing_progress "$percent"
            if [ "$IN" == "done." ]; then
                status="verifying"
                IN=
                print_flashing_progress 100
                echo ""
                echo "Verifying flash contents. Please wait..."
            fi
            # This appears before "Erase/write done."; skip the verifying state
            if [ "$IN" == "identical" ]; then
                status="done"
                IN=
                print_flashing_progress 100
                echo ""
                echo "The flash contents are identical to the image being flashed."
                break
            fi
        fi
        if [ "$status" == "verifying" ]; then
            if echo "${IN}" | grep "VERIFIED." > /dev/null ; then
                status="done"
                echo "The flash contents were verified and the image was flashed correctly."
                break
            elif echo "${IN}" | grep "FAILED" > /dev/null ; then
                echo 'Error while verifying flash content'
                break
            fi
        fi
    done
    echo ""
    if [ "$status" == "done" ]; then
        return 0
    else
        echo 'Error flashing coreboot -- see timestampped flashrom log in /tmp for more info'
        echo ""
        return 1
    fi
}

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

    flashrom $CONFIG_FLASHROM_OPTIONS -w /tmp/${CONFIG_BOARD}.rom \
      -V -o "/tmp/flashrom-$(date '+%Y%m%d-%H%M%S').log" 2>&1 | \
      flashrom_progress "$(stat -c %s "/tmp/${CONFIG_BOARD}.rom")" \
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
    die "Usage: $0 [-c|-r] <path/to/image.(rom|tgz)>"
fi

if [ "$READ" -eq 0 ] && [ "${ROM##*.}" = tgz ]; then
    if [ "${CONFIG_BOARD%_*}" = talos-2 ]; then
        rm -rf /tmp/verified_rom
        mkdir /tmp/verified_rom

        tar -C /tmp/verified_rom -xf $ROM || die "Rom archive $ROM could not be extracted"
        if ! (cd /tmp/verified_rom/ && sha256sum -cs hashes.txt); then
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
