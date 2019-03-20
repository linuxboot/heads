#!/bin/bash

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
  MECLEAN=`command -v $BLOBDIR/../../build/coreboot-*/util/me_cleaner/me_cleaner.py 2>&1`
  if [ -z "$MECLEAN" ]; then
    echo "me_cleaner.py required but not found or specified with -m. Aborting."
    exit 1;
  fi
fi

if [ -z "$IFDTOOL" ]; then
  IFDTOOL=`command -v $BLOBDIR/../../build/coreboot-*/util/ifdtool/ifdtool 2>&1`
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

cp "$FILE" $bioscopy

cd "$extractdir"
$IFDTOOL -x $bioscopy
cp "$extractdir/flashregion_3_gbe.bin" "$BLOBDIR/gbe.bin"
$MECLEAN -O "$BLOBDIR/me.bin" -r -t "$extractdir/flashregion_2_intel_me.bin"
$IFDTOOL -n "$BLOBDIR/layout.txt" $bioscopy
$IFDTOOL -x $bioscopy.new
cp "$extractdir/flashregion_0_flashdescriptor.bin" "$BLOBDIR/ifd.bin"

rm "$bioscopy"
rm "$bioscopy.new"
rm -r "$extractdir"
