#!/bin/bash

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROMPARSER="94a615302f89b94e70446270197e0f5138d678f3"
UEFIEXTRACT="UEFIExtract_NE_A58_linux_x86_64.zip"
VBIOSFINDER="c2d764975115de466fdb4963d7773b5bc8468a06"
BIOSUPDATE="g5uj39us.exe"
ROM_PARSER_SHA256SUM="f3db9e9b32c82fea00b839120e4f1c30b40902856ddc61a84bd3743996bed894  94a615302f89b94e70446270197e0f5138d678f3.zip"
UEFI_EXTRACT_SHA256SUM="c9cf4066327bdf6976b0bd71f03c9e049ae39ed19ea3b3592bae3da8615d26d7  UEFIExtract_NE_A58_linux_x86_64.zip"
VBIOS_FINDER_SHA256SUM="bd07f47fb53a844a69c609ff268249ffe7bf086519f3d20474087224a23d70c5  c2d764975115de466fdb4963d7773b5bc8468a06.zip"
BIOS_UPDATE_SHA256SUM="4769fdcfe34c40d285b8c7290305f04eb91d692f4bf25acd291d114353a958c2  g5uj39us.exe"
K2000M_ROM_SHA256SUM="5005b582019b16d2073cec8cd384ec908d8ff38ab286a6dd65eadc0e89bfb4a8  vbios_10de_0ffb_1.rom"
K1000M_ROM_SHA256SUM="6e28abb61cd4c69be7bd64e487681164cb487a48d77276f3108e3f192ceeee16  vbios_10de_0ffc_1.rom"
IGPU_ROM_SHA256SUM="10b292c19322e7bb7db53350d2775d37b72a784292ea5686cd0f92af929f4916  vbios_8086_0106_1.rom"

echo "### Creating temp dir"
extractdir=$(mktemp -d)
cd "$extractdir"

echo "### Installing basic dependencies"
sudo apt update && sudo apt install -y wget ruby ruby-dev ruby-bundler p7zip-full upx-ucl 

echo "### Downloading rom-parser dependency"
wget https://github.com/awilliam/rom-parser/archive/"$ROMPARSER".zip

echo "### Verifying expected hash of rom-parser"
echo "$ROM_PARSER_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification..." && exit 1; }

echo "### Installing rom-parser dependency"
unzip "$ROMPARSER".zip
cd rom-parser-"$ROMPARSER" && make
sudo cp rom-parser /usr/sbin/

echo "### Downloading UEFIExtract dependency"
wget https://github.com/LongSoft/UEFITool/releases/download/A58/"$UEFIEXTRACT"

echo "### Verifying expected hash of UEFIExtract"
echo "$UEFI_EXTRACT_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification..." && exit 1; }

echo "### Installing UEFIExtract"
unzip "$UEFIEXTRACT"
sudo mv UEFIExtract /usr/sbin/

echo "### Downloading VBiosFinder"
wget https://github.com/coderobe/VBiosFinder/archive/"$VBIOSFINDER".zip

echo "### Verifying expected hash of VBiosFinder"
echo "$VBIOS_FINDER_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification..." && exit 1; }

echo "### Installing VBiosFinder"
unzip "$VBIOSFINDER".zip
cd VBiosFinder-"$VBIOSFINDER" && bundle install --path=vendor/bundle

echo "### Downloading latest Lenovo bios update for w530"
wget https://download.lenovo.com/pccbbs/mobiles/"$BIOSUPDATE"

echo "### Verifying expected hash of bios update"
echo "$BIOS_UPDATE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification..." && exit 1; }

echo "### Finding, extracting and saving vbios"
./vbiosfinder extract "$extractdir"/rom-parser-"$ROMPARSER"/VBiosFinder-"$VBIOSFINDER"/"$BIOSUPDATE"

echo "Verifying expected hash of extracted roms"
cd output
echo "$K2000M_ROM_SHA256SUM" | sha256sum --check || { echo "K2000M rom failed sha256sum verification..." && exit 1; }
echo "$K1000M_ROM_SHA256SUM" | sha256sum --check || { echo "K1000M rom failed sha256sum verification..." && exit 1; }
echo "$IGPU_ROM_SHA256SUM" | sha256sum --check || { echo "iGPU rom Failed sha256sum verification..." && exit 1; }

echo "### Moving extracted roms to blobs directory"
mv vbios_10de_0ffb_1.rom "$BLOBDIR"/10de,0ffb.rom
mv vbios_10de_0ffc_1.rom "$BLOBDIR"/10de,0ffc.rom
mv vbios_8086_0106_1.rom "$BLOBDIR"/8086,0106.rom

echo "### Cleaning Up"
cd "$BLOBDIR"
rm -rf "$extractdir"
