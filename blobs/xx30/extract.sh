#!/usr/bin/env bash

function printusage {
  echo "Usage: $0 -f <romdump> -m <me_cleaner>(optional) -i <ifdtool>(optional)"
  exit 0
}

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$#" -eq 0 ]; then printusage; fi

while getopts ":f:m:i:" opt; do
  case $opt in
    f)
      FILE="$OPTARG"
      ;;
    m)
      if [ -x "$OPTARG" ]; then
        MECLEAN="$OPTARG"
      fi
      ;;
    i)
      if [ -x "$OPTARG" ]; then
        IFDTOOL="$OPTARG"
      fi
      ;;
  esac
done

if [ -z "$MECLEAN" ]; then
  MECLEAN=`command -v $BLOBDIR/../../build/coreboot-*/util/me_cleaner/me_cleaner.py 2>&1|head -n1`
  if [ -z "$MECLEAN" ]; then
    echo "me_cleaner.py required but not found or specified with -m. Aborting."
    exit 1;
  fi
fi

if [ -z "$IFDTOOL" ]; then
  IFDTOOL=`command -v $BLOBDIR/../../build/coreboot-*/util/ifdtool/ifdtool 2>&1|head -n1`
  if [ -z "$IFDTOOL" ]; then
    echo "ifdtool required but not found or specified with -m. Aborting."
    exit 1;
  fi
fi

echo "FILE: $FILE"
echo "ME: $MECLEAN"
echo "IFD: $IFDTOOL"

bioscopy=$(mktemp)
extractdir=$(mktemp -d)

echo "###Copying $FILE under $bioscopy"
cp "$FILE" $bioscopy

cd "$extractdir"
echo "###Unlocking $bioscopy IFD..."
$IFDTOOL -u $bioscopy
echo "###Extracting regions from ROM..."
$IFDTOOL -x $bioscopy
echo "###Copying GBE region under $BLOBDIR/gbe.bin..."
cp "$extractdir/flashregion_3_gbe.bin" "$BLOBDIR/gbe.bin"
echo "###Applying me_cleaner to neuter+deactivate+maximize reduction of ME on $bioscopy, outputting minimized ME under $BLOBDIR/me.bin and adapting BIOS+ME regions under $BLOBDIR/ifd.bin... "
$MECLEAN -r -t -d -O /tmp/unneeded.bin -D "$BLOBDIR/ifd.bin" -M "$BLOBDIR/me.bin" "$bioscopy"

echo "###Cleaning up..."
rm "$bioscopy"
rm -r "$extractdir"
