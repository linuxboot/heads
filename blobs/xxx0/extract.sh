#!/bin/bash

function printusage {
  echo "Usage: $0 -f <romdump> -i <ifdtool>(optional)"
  exit 0
}

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$#" -eq 0 ]; then printusage; fi

while getopts ":f:m:i:" opt; do
  case $opt in
    f)
      FILE="$OPTARG"
      ;;
    i)
      if [ -x "$OPTARG" ]; then
        IFDTOOL="$OPTARG"
      fi
      ;;
  esac
done

if [ -z "$IFDTOOL" ]; then
  IFDTOOL=`command -v $BLOBDIR/../../build/coreboot-*/util/ifdtool/ifdtool 2>&1|head -n1`
  if [ -z "$IFDTOOL" ]; then
    echo "ifdtool required but not found or specified with -m. Aborting."
    exit 1;
  fi
fi

echo "FILE: $FILE"
echo "IFD: $IFDTOOL"

bioscopy=$(mktemp)
extractdir=$(mktemp -d)

echo "###Copying $FILE under $bioscopy"
cp "$FILE" $bioscopy

cd "$extractdir"
echo "###Unlocking $bioscopy IFD..."
$IFDTOOL -u $bioscopy
echo "###Extracting regions from ROM..."
$IFDTOOL -x $bioscopy.new
echo "###Copying GBE region under $BLOBDIR/gbe.bin..."
cp "$extractdir/flashregion_3_gbe.bin" "$BLOBDIR/gbe.bin"

echo "###Cleaning up..."
rm "$bioscopy"
rm -r "$extractdir"
