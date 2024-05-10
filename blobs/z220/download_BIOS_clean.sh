#!/usr/bin/env bash

# Z220 CMT HP

function printusage {
  echo "Usage: $0 -m <me_cleaner>(optional)"
}

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$#" -eq 0 ]; then printusage; fi

while getopts ":m:i:" opt; do
  case $opt in
    m)
      if [ -x "$OPTARG" ]; then
        MECLEAN="$OPTARG"
      fi
      ;;
  esac

done

if [ -z "$MECLEAN" ]; then
  MECLEAN=`command -v $BLOBDIR/../../build/x86/coreboot-*/util/me_cleaner/me_cleaner.py 2>&1|head -n1`
  if [ -z "$MECLEAN" ]; then
    echo "me_cleaner.py required but not found or specified with -m. Aborting."
    exit 1;
  fi
fi

BIN_FILE="DOS Flash/K51_0187.BIN"
BIN_TGZ_SHA256SUM="0102d569239fdc14ca86a7afc4b16d2b12703401890b83e188f34d23844870dc  sp97120.tgz"
BIN_FILE_SHA256SUM="cc5a9c2d4827e9b1501c2dc0a464f580d4a2d65e4ff83dbab548e51839339d06  $BIN_FILE"
FINAL_IFD_SHA256SUM="ba7371fcf1c03a999adae66f4a5fccd65ae3429c1aedc0c7b7e11c548363d30e  $BLOBDIR/ifd.bin"
FINAL_ME_SHA256SUM="2ee4bbf3e49e0c1f0215d7955d2a7793c7e108014f3aa4592bfa9785c0033d0d  $BLOBDIR/me.bin"
TGZURL="https://ftp.hp.com/pub/softpaq/sp97001-97500/sp97120.tgz"

TGZFILENAME=`echo $TGZURL | sed 's/.*\///'`
ROMFILENAME=`echo $TGZFILENAME | sed 's/\.zip$/\.ROM/'`

extractdir=$(mktemp -d)
echo "### Creating temp dir $extractdir "
cd "$extractdir"

echo "### Downloading $TGZURL"
wget $TGZURL || { echo "ERROR: wget failed $TGZURL" && exit 1; }
echo "### Verifying expected hash of $TGZFILENAME"
echo "$BIN_TGZ_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on downloaded binary..." && exit 1; }

echo "### Extracting Archives"
tar -xf $TGZFILENAME DOS\ Flash || { echo "Failed unzipping $TGZFILENAME - Tool installed on host?" && exit 1;}

echo "### Verifying expected hash of $ROMFILENAME"
echo "$BIN_FILE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on extracted binary..." && exit 1; }

echo "### Applying me_cleaner to neuter and truncate. EFFS,FCRS whitelisted"
$MECLEAN -S -r -t -d -O  /tmp/unneeded.bin -D "$BLOBDIR/ifd.bin" -M "$BLOBDIR/me.bin" "$BIN_FILE"

printf '\x00' | dd of="$BLOBDIR/ifd.bin" bs=1 seek=3837 count=1 conv=notrunc
printf '\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF' | dd of="$BLOBDIR/ifd.bin" bs=1 seek=3712 count=40 conv=notrunc

echo "### Verifying expected hashes"
echo "$FINAL_IFD_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on generated IFD bin..." && exit 1; }
echo "$FINAL_ME_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on generated ME binary..." && exit 1; }

echo "###Cleaning up..."
cd -
rm -r "$extractdir"
