#!/bin/bash

# Script for extracting vbios blos for Lenovo W540/541 with the Nvidia K2100m dGPU

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROMPARSER="94a615302f89b94e70446270197e0f5138d678f3"
UEFIEXTRACT="UEFIExtract_NE_A58_linux_x86_64.zip"
VBIOSFINDER="c2d764975115de466fdb4963d7773b5bc8468a06"
BIOSUPDATE="gnuj39us.exe"
ROM_PARSER_SHA256SUM="f3db9e9b32c82fea00b839120e4f1c30b40902856ddc61a84bd3743996bed894  94a615302f89b94e70446270197e0f5138d678f3.zip"
UEFI_EXTRACT_SHA256SUM="c9cf4066327bdf6976b0bd71f03c9e049ae39ed19ea3b3592bae3da8615d26d7  UEFIExtract_NE_A58_linux_x86_64.zip"
VBIOS_FINDER_SHA256SUM="bd07f47fb53a844a69c609ff268249ffe7bf086519f3d20474087224a23d70c5  c2d764975115de466fdb4963d7773b5bc8468a06.zip"
BIOS_UPDATE_SHA256SUM="5d9bf9521ec6a5a95e0b81a7cced868b4d912af84bba0affc3a3a5cf61a6243c  gnuj39us.exe"
DGPU_ROM_SHA256SUM="554771749c6308a680dbb5d7bfe9c05be9b3f43accb1ed33efab6cfbec0b4133  vbios_10de_11fc_1.rom"
IGPU_ROM_SHA256SUM="48e9ddb9c119a720d58d5e64d1c38486d587679e4dc138269177e127f8fc266e  vbios_8086_0406_1.rom"

echo "### Creating temp dir"
extractdir=$(mktemp -d)
cd "$extractdir"

echo "### Installing basic dependencies"
sudo apt update && sudo apt install -y wget ruby ruby-dev bundler ruby-bundler p7zip-full upx-ucl 
sudo gem install bundler:1.17.3

echo "### Downloading rom-parser dependency"
wget https://github.com/awilliam/rom-parser/archive/"$ROMPARSER".zip || { echo "Failed to download $ROMPARSER" && exit 1; }

echo "### Verifying expected hash of rom-parser"
echo "$ROM_PARSER_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification..." && exit 1; }

echo "### Installing rom-parser dependency"
unzip "$ROMPARSER".zip
cd rom-parser-"$ROMPARSER" && make
sudo cp rom-parser /usr/sbin/

echo "### Downloading UEFIExtract dependency"
wget https://github.com/LongSoft/UEFITool/releases/download/A58/"$UEFIEXTRACT" || { echo "Failed to download $UEFIEXTRACT" && exit 1; }

echo "### Verifying expected hash of UEFIExtract"
echo "$UEFI_EXTRACT_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification..." && exit 1; }

echo "### Installing UEFIExtract"
unzip "$UEFIEXTRACT"
sudo mv UEFIExtract /usr/sbin/

echo "### Downloading VBiosFinder"
wget https://github.com/coderobe/VBiosFinder/archive/"$VBIOSFINDER".zip || { echo "Failed to download $VBIOSFINDER" && exit 1; }

echo "### Verifying expected hash of VBiosFinder"
echo "$VBIOS_FINDER_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification..." && exit 1; }

echo "### Installing VBiosFinder"
unzip "$VBIOSFINDER".zip
cd VBiosFinder-"$VBIOSFINDER" && bundle install --path=vendor/bundle

echo "### Downloading latest Lenovo bios update for t530"
wget https://download.lenovo.com/pccbbs/mobiles/"$BIOSUPDATE" || { echo "Failed to download $BIOSUPDATE" && exit 1; }

echo "### Verifying expected hash of bios update"
echo "$BIOS_UPDATE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification..." && exit 1; }

echo "### Extracting bios update"
innoextract "$extractdir"/rom-parser-"$ROMPARSER"/VBiosFinder-"$VBIOSFINDER"/"$BIOSUPDATE" || { echo "Failed to extract $BIOSUPDATE" && exit 1; }

echo "### Finding, extracting and saving vbios"
sudo ./vbiosfinder extract "$extractdir"/rom-parser-"$ROMPARSER"/VBiosFinder-"$VBIOSFINDER"/"codeGetExtractPath/GNET94WW/\$01E2000.FL1" || { echo "Failed to extract FL1" && exit 1; }

echo "Verifying expected hash of extracted roms"
cd "$extractdir"/rom-parser-"$ROMPARSER"/VBiosFinder-"$VBIOSFINDER"/output/
echo "$DGPU_ROM_SHA256SUM" | sha256sum --check || { echo "dGPU rom failed sha256sum verification..." && exit 1; }
echo "$IGPU_ROM_SHA256SUM" | sha256sum --check || { echo "iGPU rom Failed sha256sum verification..." && exit 1; }

echo "### Moving extracted roms to blobs directory"
sudo mv vbios_10de_11fc_1.rom $BLOBDIR/10de,11fc.rom
sudo mv vbios_8086_0406_1.rom $BLOBDIR/8086,0406.rom

echo "### Cleaning Up"
cd "$BLOBDIR"
sudo rm -rf "$extractdir"
