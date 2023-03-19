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
    i)
      if [ -x "$OPTARG" ]; then
        IFDTOOL="$OPTARG"
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

if [ -z "$IFDTOOL" ]; then
  IFDTOOL=`command -v $BLOBDIR/../../build/x86/coreboot-*/util/ifdtool/ifdtool 2>&1|head -n1`
  if [ -z "$IFDTOOL" ]; then
    echo "ifdtool required but not found or specified with -i. Aborting."
    exit 1;
  fi
fi

CAP_ZIP_SHA256SUM="9ea900eccd4a649237b000f1a34beb73cd92fb203d9639d8b7d22ef2a030d360  P8Z77-V-PRO-ASUS-2104.zip"
CAP_FILE_SHA256SUM="7cf39a893cd6af774e3623a6b80c3e8f8989934b384eff28aba4726e80faa962  P8Z77-V-PRO-ASUS-2104.CAP"
FINAL_IFD_SHA256SUM="e8be1dc16b79d6031df5e599bc5811c83aeccece7589e6386366f3e37fa0fb07 flashregion_0_flashdescriptor.bin"
FINAL_ME_SHA256SUM="8dda1e8360fbb2da05bfcd187f6e7b8a272a67d66bc0074bbfd1410eb35e3e17 $BLOBDIR/me.bin"
FINAL_GBE_SHA256SUM="fca4deb13633712113e1824bfd5afa32f487ca7129ca012fecf5d7502ec1d5ba  flashregion_3_gbe.bin"
ZIPURL="https://dlcdnets.asus.com/pub/ASUS/mb/LGA1155/P8Z77-V_PRO/P8Z77-V-PRO-ASUS-2104.zip"

ZIPFILENAME=`echo $ZIPURL | sed 's/.*\///'`
ROMFILENAME=`echo $ZIPFILENAME | sed 's/\.zip$/\.ROM/'`

extractdir=$(mktemp -d)
echo "### Creating temp dir $extractdir "
cd "$extractdir"

/bin/cat <<EOF > layout.txt
00000000:00000fff fd
0001c000:007fffff bios
00003000:0001bfff me
00001000:00002fff gb
EOF


echo "### Downloading $ZIPURL"
wget $ZIPURL || { echo "ERROR: wget failed $ZIPURL" && exit 1; }
echo "### Verifying expected hash of $ZIPFILENAME"
echo "$CAP_ZIP_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on downloaded binary..." && exit 1; }

echo "### Extracting Archives"
unzip $ZIPFILENAME || { echo "Failed unzipping $ZIPFILENAME - Tool installed on host?" && exit 1;}

echo "### Verifying expected hash of $ROMFILENAME"
echo "$CAP_FILE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on extracted binary..." && exit 1; }

echo "### extracing BIOS from Capsule"
dd bs=1024 skip=2 if=P8Z77-V-PRO-ASUS-2104.CAP of=P8Z77-V-PRO-ASUS-2104.ROM || { echo "Failed to de-cap the ROM..." && exit 1; }

echo "### Stock variant AltME & ME Cleaner"
$IFDTOOL -M 1 $ROMFILENAME
echo "### extract stock ME"
$IFDTOOL -x $ROMFILENAME.new

echo "### Applying me_cleaner to neuter and truncate. EFFS,FCRS whitelisted"
$MECLEAN -r -t -O "$BLOBDIR/me.bin" flashregion_2_intel_me.bin

echo "### Verifying expected hash of me.bin"
echo "$FINAL_ME_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on final binary..." && exit 1; }
rm flashregion*.bin
echo "### Resizing ..."
$IFDTOOL -D 8 $ROMFILENAME.new || { echo "Failed density resize " && exit 1;}
$IFDTOOL --newlayout layout.txt $ROMFILENAME.new.new || { echo "Failed new layout ..." && exit 1;}
echo "### Extracting final IFD"
$IFDTOOL -x $ROMFILENAME.new.new.new || { echo "Failed ifdtool. Tool installed on host?" && exit 1;}

printf '\x00' | dd of=flashregion_0_flashdescriptor.bin bs=1 seek=3837 count=1 conv=notrunc
printf '\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF' | dd of=flashregion_0_flashdescriptor.bin bs=1 seek=3568 count=32 conv=notrunc

echo "### Verifying expected hash of IFD"
echo "$FINAL_IFD_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on factory IFD bin..." && exit 1; }
cp flashregion_0_flashdescriptor.bin $BLOBDIR/ifd.bin || { echo "Failed to copy IFD ..." && exit 1; }
echo "$FINAL_GBE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on factory IFD bin..." && exit 1; }
cp flashregion_3_gbe.bin $BLOBDIR/gbe.bin || { echo "Failed to copy GBE ..." && exit 1; }


echo "###Cleaning up..."
cd -
rm -r "$extractdir"
