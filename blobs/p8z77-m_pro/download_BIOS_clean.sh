#!/usr/bin/env bash
# P7 ASUS

function printusage {
  echo "Usage: $0 -m <me_cleaner> -c <COREBOOT_DIR>"
}

BLOB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$#" -eq 0 ]; then printusage; fi

while getopts ":m:c:" opt; do
  case $opt in
    m)
      if [ -x "$OPTARG" ]; then
        MECLEAN="$OPTARG"
      fi
      ;;
    c)
      if [ -x "$OPTARG" ]; then
        COREBOOT_DIR="$OPTARG"
      fi
      ;;
  esac

done


if [[ -z "${COREBOOT_DIR}" ]]; then
	COREBOOT_DIR="$(find "${BLOB_DIR}/../../build/x86/" -maxdepth 1 -type d -name 'coreboot-*')"
	if [[ -z "${COREBOOT_DIR}" ]]; then
		echo "ERROR: No COREBOOT_DIR variable defined, and no coreboot path found automagically."
		exit 1
	fi
fi

if [ -z "$MECLEAN" ]; then
  MECLEAN=`command -v $COREBOOT_DIR/util/me_cleaner/me_cleaner.py 2>&1|head -n1`
  if [ -z "$MECLEAN" ]; then
    echo "me_cleaner.py required but not found or specified with -m. Aborting."
    exit 1;
  fi
fi

CAP_ZIP_SHA256SUM="baf7f513227542c507e46735334663f63a0df5be9f6632d7b0f0cca5d3b9f980  P8Z77-M-PRO-ASUS-2203.zip"
CAP_FILE_SHA256SUM="d9bf292778655d4e20f5db2154cd6a2229e42b60ce670a68d759f1dac757aaf0  P8Z77-M-PRO-ASUS-2203.CAP"
FINAL_IFD_SHA256SUM="702570d59c11b9b70ab9d54b26ff0906a07edf15eebe63f40bcecb04b955969f  ifd.bin"
FINAL_ME_SHA256SUM="8dda1e8360fbb2da05bfcd187f6e7b8a272a67d66bc0074bbfd1410eb35e3e17  me.bin"
ZIPURL="https://dlcdnets.asus.com/pub/ASUS/mb/LGA1155/P8Z77-M_PRO/P8Z77-M-PRO-ASUS-2203.zip"

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
dd bs=1024 skip=2 if=P8Z77-M-PRO-ASUS-2203.CAP of=P8Z77-M-PRO-ASUS-2203.ROM || { echo "Failed to de-cap the ROM..." && exit 1; }

echo "### Applying me_cleaner to neuter and truncate."
$MECLEAN -S -r -t -d -O  /tmp/unneeded.bin -D "ifd.bin" -M "me.bin" P8Z77-M-PRO-ASUS-2203.ROM

if [[ "${CONFIG_ZERO_IFD_VSCC}" =~ ^(Y|y)$ ]]; then
	FINAL_IFD_SHA256SUM="092caeee117de27c0eb30587defcb6449a33c7c325b6f3c47b5a7a79670b5c3f  ifd.bin"
	echo "### Modifying VSCC length and identifiers"
	printf '\x00' | dd of=ifd.bin bs=1 seek=3837 count=1 conv=notrunc
	printf '\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF' | dd of=ifd.bin bs=1 seek=3568 count=32 conv=notrunc
	echo "### Verifying expected hashes"
else
	echo "###  Skipping VSCC modification by config"
fi
echo "$FINAL_IFD_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on generated IFD bin..." && exit 1; }
mv ifd.bin $BLOB_DIR/ifd.bin
echo "$FINAL_ME_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on generated ME binary..." && exit 1; }
mv me.bin $BLOB_DIR/me.bin

echo "###Cleaning up..."
cd -
rm -r "$extractdir"
