#!/bin/bash
# Z690-Wifi DDR5
# Todo: lan rom?
function printusage {
  echo "Usage: $0 -c <COREBOOT_DIR>"
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

ZIP_SHA256SUM="eb804a1f443701dd9fe9c786640054b7de9c10345236546758b9591ac078c7dd  7D25vA0.zip"
ROM_SHA256SUM="e85479b99b5b48bcc9f3485ca2f9d0a0b5769044dae141d389017fea5233c69d  7D25vA0/E7D25IMS.A00"
FINAL_IFD_SHA256SUM="235459f72c6a9b88df1e1afb288680731131f603a9d659edc27ef956418d1d12 ifd.bin"
FINAL_ME_SHA256SUM="b2e3a27d222392afd35145a23ff547d486b99a8479968bb8398cbeeecb2ec1d5 me.bin"
ZIPURL="https://download.msi.com/bos_exe/mb/7D25vA0.zip"
ROMFILENAME="7D25vA0/E7D25IMS.A00"
ZIPFILENAME=`echo $ZIPURL | sed 's/.*\///'`

extractdir=$(mktemp -d)
echo "### Creating temp dir $extractdir "
cd "$extractdir"

echo "### Downloading $ZIPURL"
wget $ZIPURL || { echo "ERROR: wget failed $ZIPURL" && exit 1; }
echo "### Verifying expected hash of $ZIPFILENAME"
echo "$ZIP_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on downloaded binary..." && exit 1; }

echo "### Extracting Archives"
unzip $ZIPFILENAME || { echo "Failed unzipping $ZIPFILENAME - Tool installed on host?" && exit 1;}

echo "### Verifying expected hash of $ROMFILENAME"
echo "$ROM_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on extracted binary..." && exit 1; }

echo "### extracing IFD"
dd bs=4096 count=1 if=$ROMFILENAME of=ifd.bin || { echo "Failed extracting ifd.bin ..." && exit 1; }

echo "### extracting ME"
dd bs=4096 count=984 skip=1 if=$ROMFILENAME of=me.bin || { echo "Failed extracting me.bin ..." && exit 1; }
echo "### Enabling HAP bit to soft disable ME"
printf '\x11' |  dd of=ifd.bin bs=1 seek=478 count=1 conv=notrunc  || { echo "Failed setting HAP bit / ME soft disable ..." && exit 1; }

if [[ "${CONFIG_ZERO_IFD_VSCC}" =~ ^(Y|y)$ ]]; then
	FINAL_IFD_SHA256SUM="250fb40081b98d4a4a034ffa0d78bb6a8c6f930cfd30ebc34fc9df21153bac1a $BLOB_DIR/ifd.bin"
	echo "### Overwriting existant VSCC table"
	printf '\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF' | dd of=ifd.bin bs=1 seek=3568 count=8 conv=notrunc || { echo "Failed overwriting VSCC table ..." && exit 1; }
	echo "### Modifying VSCC length to zero"
	printf '\x00' | dd of=ifd.bin bs=1 seek=3837 count=1 conv=notrunc || { echo "Failed setting VSCC location lenght to 0x00 ..." && exit 1; }
else
	echo "### Disabled by config - VSCC table mod"
fi

echo "### Verifying expected hashes"
echo "$FINAL_IFD_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on generated IFD bin..." && exit 1; }
mv ifd.bin $BLOB_DIR/ifd.bin
echo "$FINAL_ME_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on generated ME binary..." && exit 1; }
mv me.bin $BLOB_DIR/me.bin
echo "###Cleaning up..."
cd -
rm -r "$extractdir"
