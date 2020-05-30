#!/bin/bash

function printusage {
  echo "Usage: $0 -f <romdump> -m <me_cleaner> -i <ifdtool>"
  exit 0
}

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MECLEAN="$BLOBDIR/me_cleaner/me_cleaner.py"
IFDTOOL="$BLOBDIR/ifdtool/ifdtool"

if [ "$#" -eq 0 ] || [ "$1" == "-h" ] || [ "$1" == "--help" ];
then printusage; fi

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

if [ ! -f "$FILE" ]; then
	echo "romdump required but not found. Aborting."
	exit 1;
fi

if [ ! -f "$MECLEAN" ]; then
	echo "me_cleaner.py required but not found. Aborting."
	exit 1;
fi
MECLEAN=$(realpath $MECLEAN)

if [ ! -f "$IFDTOOL" ]; then
	echo "ifdtool required but not found. Aborting."
	exit 1;
fi
IFDTOOL=$(realpath $IFDTOOL)

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
