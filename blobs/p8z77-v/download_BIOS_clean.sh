#!/bin/bash
# P7 ASUS

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

CAP_ZIP_SHA256SUM="06c034597edeeaaeace86d8b5d4780d1ac9e510b4736f7259cea83bface8fc51  P8Z77-V-ASUS-2104.zip"
CAP_FILE_SHA256SUM="bd60e7b7d5227147a47509979a748316dd30b314266a92bd8105984f6d540ba4  P8Z77-V-ASUS-2104.CAP"
#FINAL_IFD_SHA256SUM="f076be608c189da9532484b8152bc34029d1b1a8e28f630799fd474c47cb3f88  $BLOBDIR/ifd.bin"
FINAL_IFD_SHA256SUM="62a080f5e94c9366ae2f341a03a82c6e1b3fd18c223f250290312c08efd1db06  $BLOBDIR/ifd.bin"
FINAL_ME_SHA256SUM="8dda1e8360fbb2da05bfcd187f6e7b8a272a67d66bc0074bbfd1410eb35e3e17  $BLOBDIR/me.bin"
ZIPURL="https://dlcdnets.asus.com/pub/ASUS/mb/LGA1155/P8Z77-V/P8Z77-V-ASUS-2104.zip"

ZIPFILENAME=`echo $ZIPURL | sed 's/.*\///'`
ROMFILENAME=`echo $ZIPFILENAME | sed 's/\.zip$/\.ROM/'`

extractdir=$(mktemp -d)
echo "### Creating temp dir $extractdir "
cd "$extractdir"

echo "### Downloading $ZIPURL"
wget $ZIPURL || { echo "ERROR: wget failed $ZIPURL" && exit 1; }
echo "### Verifying expected hash of $ZIPFILENAME"
echo "$CAP_ZIP_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on downloaded binary..." && exit 1; }

echo "### Extracting Archives"
unzip $ZIPFILENAME || { echo "Failed unzipping $ZIPFILENAME - Tool installed on host?" && exit 1;}

echo "### Verifying expected hash of $ROMFILENAME"
echo "$CAP_FILE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on extracted binary..." && exit 1; }

echo "### extracing BIOS from Capsule"
dd bs=1024 skip=2 if=P8Z77-V-ASUS-2104.CAP of=P8Z77-V-ASUS-2104.ROM || { echo "Failed to de-cap the ROM..." && exit 1; }

echo "### Applying me_cleaner to neuter and truncate. EFFS,FCRS whitelisted"
$MECLEAN -S -r -t -d -O  /tmp/unneeded.bin -D "$BLOBDIR/ifd.bin" -M "$BLOBDIR/me.bin" P8Z77-V-ASUS-2104.ROM

#echo "### Modifying VSCC length and identifiers"

#printf '\x00' | dd of="$BLOBDIR/ifd.bin" bs=1 seek=3837 count=1 conv=notrunc
#printf '\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF' | dd of="$BLOBDIR/ifd.bin" bs=1 seek=3568 count=32 conv=notrunc

echo "### Verifying expected hashes"
echo "$FINAL_IFD_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on generated IFD bin..." && exit 1; }
echo "$FINAL_ME_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on generated ME binary..." && exit 1; }

echo "###Cleaning up..."
cd -
rm -r "$extractdir"
