#!/bin/bash
#
# NOTE: This script is used on legacy-flash boards and runs with busybox ash,
# not bash
set -e -o pipefail
. /etc/functions.sh
. /tmp/config

TRACE_FUNC

case "$CONFIG_FLASH_OPTIONS" in
  "" )
    DIE "ERROR: No flash options have been configured!\n\nEach board requires specific CONFIG_FLASH_OPTIONS options configured. It's unsafe to flash without them.\n\nAborting."
  ;;
  * )
    DEBUG "Flash options detected: $CONFIG_FLASH_OPTIONS"
    INFO "Board $CONFIG_BOARD detected with flash options configured"
  ;;
esac

# Adjust CONFIG_FLASH_OPTIONS depending on which function invoked this
# script. The caller must set CHANGE_FLASH_OPTIONS, e.g:
#   CHANGE_FLASH_OPTIONS=whole_spi flash.sh "$ROM"
#   CHANGE_FLASH_OPTIONS=gbe_only flash.sh "$ROM"
# In all other cases, leave CONFIG_FLASH_OPTIONS untouched.
if [ -n "$CHANGE_FLASH_OPTIONS" ] && [ -z "$CONFIG_FLASH_TOOL" ]; then
  DIE "ERROR: CONFIG_FLASH_TOOL is not set for board $CONFIG_BOARD!\n\nBoards enabling the ethernet MAC randomization feature (CONFIG_NVMUTIL / CONFIG_IFDTOOL) must define CONFIG_FLASH_TOOL, otherwise the flash command would be empty. Aborting."
fi 

case "$CHANGE_FLASH_OPTIONS" in
  whole_spi )
    # Reserved for full-SPI flows that need BIOS-region access (e.g. MRC
    # cache preservation, linuxboot/heads#2138). Not currently called.
    DEBUG "flash.sh: whole_spi path — full SPI dump, no caller yet"
    CONFIG_FLASH_OPTIONS="${CONFIG_FLASH_TOOL}"
  ;;
  gbe_only )
  DEBUG "flash.sh: called from mac_randomization(), adding gbe"
    # --noverify-all: only verify the included (gbe) region, not the whole
    # 32MB SPI (no bios), after writing. See flashprog(8): automatic verification after
    # -w/-r reads out the whole chip unless not-included regions are skipped.
    CONFIG_FLASH_OPTIONS="${CONFIG_FLASH_TOOL} --ifd --image fd --image gbe --noverify-all"
  ;;
  * )
    : # no change
  ;;
esac

flash_rom() {
  ROM=$1
  DEBUG "flash_rom: ROM=$ROM READ=$READ — selecting read or write path"
  if [ "$READ" -eq 1 ]; then
    $CONFIG_FLASH_OPTIONS -r "${ROM}" \
    || recovery "Backup to $ROM failed"
  else
    STATUS "Preparing new ROM image for flashing"
    cp "$ROM" /tmp/${CONFIG_BOARD}.rom
    STATUS "Verifying SHA-256 checksum of ROM image"
    sha256sum /tmp/${CONFIG_BOARD}.rom
    # gbe_only is the SPI read+write path used by show_mac and change_mac;
    # flashprog operates only on ifd+fd+gbe (--ifd --image fd so ifdtool
    # can locate the gbe section), so the temp .rom has no BIOS region
    # for cbfs to inject into — skip preserve_rom and serial_number persistence below.
    if [ "$CHANGE_FLASH_OPTIONS" != "gbe_only" ]; then
      if [ "$CLEAN" -eq 0 ]; then
        # preserve_rom mirrors heads/ CBFS files from the running ROM into
        # the new ROM image before flashing. Skip with -c (clean flash) flag.
        DEBUG "flash_rom: CLEAN=$CLEAN — preserving heads/ CBFS files"
        preserve_rom /tmp/${CONFIG_BOARD}.rom \
        || recovery "$ROM: Config preservation failed"
      else
        DEBUG "flash_rom: CLEAN=$CLEAN — skipping config preservation (clean flash)"
      fi
      # persist serial number from CBFS
      DEBUG "flash_rom: probing live ROM for serial_number"
      if cbfs.sh -r serial_number > /tmp/serial 2>/dev/null; then
        STATUS "Persisting system serial"
        cbfs.sh -o /tmp/${CONFIG_BOARD}.rom -d serial_number 2>/dev/null || true
        cbfs.sh -o /tmp/${CONFIG_BOARD}.rom -a serial_number -f /tmp/serial
      fi
    else
      DEBUG "flash_rom: CHANGE_FLASH_OPTIONS=$CHANGE_FLASH_OPTIONS — skipping preserve_rom and serial_number"
    fi
    # PCHSTRP9 persistence for first-gen Librem L1UM (Broadwell-DE, coreboot
    # 4.11). Glob matches historical name and EOL_-prefixed variants; the
    # *librem_l1um* suffix match (not substring) deliberately excludes
    # librem_l1um_v2 (Coffee Lake Refresh, different silicon).
    case "$CONFIG_BOARD" in
      *librem_l1um)
        STATUS "Persisting PCHSTRP9"
        $CONFIG_FLASH_OPTIONS -r /tmp/ifd.bin --ifd -i fd >/dev/null 2>&1 \
        || DIE "Failed to read flash descriptor"
        dd if=/tmp/ifd.bin bs=1 count=4 skip=292 of=/tmp/pchstrp9.bin >/dev/null 2>&1
        dd if=/tmp/pchstrp9.bin bs=1 count=4 seek=292 of=/tmp/${CONFIG_BOARD}.rom conv=notrunc >/dev/null 2>&1
        ;;
    esac

    WARN "Do not power off computer.  Updating firmware, this will take a few minutes"
    STATUS "Flashing ROM to chip"
    $CONFIG_FLASH_OPTIONS -w /tmp/${CONFIG_BOARD}.rom 2>&1 \
      || recovery "$ROM: Flash failed"
    STATUS_OK "ROM flashed successfully"
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
    DIE "Usage: $0 [-c|-r] <path/to/image.(rom|tgz)>"
fi

if [ "$READ" -eq 0 ] && [ "${ROM##*.}" = tgz ]; then
    case "$CONFIG_BOARD" in
      *talos-2*)
        rm -rf /tmp/verified_rom
        mkdir /tmp/verified_rom

        tar -C /tmp/verified_rom -xf $ROM || DIE "Rom archive $ROM could not be extracted"
    if ! (cd /tmp/verified_rom/ && sha256sum -cs sha256sum.txt); then
            DIE "Provided tgz image did not pass hash verification"
        fi

        STATUS "Reading current flash and building update image"
        $CONFIG_FLASH_OPTIONS -r /tmp/flash.sh.bak \
            || recovery "Read of flash has failed"

        # ROM and bootblock already have ECC
        bootblock=$(echo /tmp/verified_rom/*.bootblock)
        rom=$(echo /tmp/verified_rom/*.rom)
        kernel=$(echo /tmp/verified_rom/*-zImage.bundled)
        pnor /tmp/flash.sh.bak -aw HBB < $bootblock
        pnor /tmp/flash.sh.bak -aw HBI < $rom
        pnor /tmp/flash.sh.bak -aw BOOTKERNEL < $kernel
        rm -rf /tmp/verified_rom

        ROM=/tmp/flash.sh.bak
        ;;
      *)
        DIE "$CONFIG_BOARD doesn't support tgz image format"
        ;;
    esac
fi

flash_rom $ROM

# don't leave temporary files lying around
rm -f /tmp/flash.sh.bak

exit 0
