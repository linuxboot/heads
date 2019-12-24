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

flashrom_progress() {
    local current=0
    local total_bytes=0
    local percent=0
    local IN=''
    local spin='-\|/'
    local spin_idx=0
    local progressbar=''
    local progressbar2=''
    local status='init'
    local prev_word=''
    local prev_prev_word=''

    progressbar2=$(for i in `seq 48` ; do echo -ne ' ' ; done)
    echo -e "\nInitializing internal Flash Programmer"
    while true ; do
        prev_prev_word=$prev_word
        prev_word=$IN
        read -r -d' ' IN || break
        if [ "$total_bytes" != "0" ]; then
            current=$(echo "$IN" | grep -E -o '0x[0-9a-f]+-0x[0-9a-f]+:.*' | grep -E -o "0x[0-9a-f]+" | tail -n 1)
            if [ "${current}" != "" ]; then
                percent=$((100 * (current + 1) / total_bytes))
                pct1=$((percent / 2))
                pct2=$((49 - percent / 2))
                progressbar=$(for i in `seq $pct1 2>/dev/null` ; do echo -ne '#' ; done)
                progressbar2=$(for i in `seq $pct2 2>/dev/null` ; do echo -ne ' ' ; done)
            fi
        else
            if [ "$prev_prev_word"  == "Reading" ] && [ "$IN" == "bytes" ]; then
                # flashrom may read the descriptor first, so ensure total_bytes is at least 4MB
                if [[ $prev_word -gt  4194303 ]]; then
                    total_bytes=$prev_word
                    echo "Total flash size : $total_bytes bytes"
                fi
            fi
        fi
        if [ "$percent" -gt 99 ]; then
            spin_idx=4
        else
            spin_idx=$(( (spin_idx+1) %4 ))
        fi
        if [ "$status" == "init" ]; then
            if [ "$IN" == "contents..." ]; then
                status="reading"
                echo "Reading old flash contents. Please wait..."
            fi
        fi
        if [ "$status" == "reading" ]; then
            if echo "${IN}" | grep "done." > /dev/null ; then
                status="writing"
            fi
        fi
        if [ "$status" == "writing" ]; then
            echo -ne "Flashing: [${progressbar}${spin:$spin_idx:1}${progressbar2}] (${percent}%)\\r"
            if echo "$IN" | grep "Verifying" > /dev/null ; then
                status="verifying"
                echo ""
                echo "Verifying flash contents. Please wait..."
            fi
            if echo "$IN" | grep "identical" > /dev/null ; then
                status="done"
		        echo ""
                echo "The flash contents are identical to the image being flashed."
            fi
        fi
        if [ "$status" == "verifying" ]; then
            if echo "${IN}" | grep "VERIFIED." > /dev/null ; then
                status="done"
                echo "The flash contents were verified and the image was flashed correctly."
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
    # persist PCHSTRP9 from flash descriptor
    if [ "$CONFIG_BOARD" = "librem_l1um" ]; then
      echo "Persisting PCHSTRP9"
      flashrom $CONFIG_FLASHROM_OPTIONS -r /tmp/ifd.bin --ifd -i fd >/dev/null 2>&1 \
      || die "Failed to read flash descriptor"
      dd if=/tmp/ifd.bin bs=1 count=4 skip=292 of=/tmp/pchstrp9.bin >/dev/null 2>&1
      dd if=/tmp/pchstrp9.bin bs=1 count=4 seek=292 of=/tmp/${CONFIG_BOARD}.rom conv=notrunc >/dev/null 2>&1
    fi

    flashrom $CONFIG_FLASHROM_OPTIONS -w /tmp/${CONFIG_BOARD}.rom \
      -V -o "/tmp/flashrom-$(date '+%Y%m%d-%H%M%S').log" 2>&1 | flashrom_progress \
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
