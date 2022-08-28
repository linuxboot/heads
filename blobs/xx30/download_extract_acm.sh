#!/bin/bash

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

X230_ACM_EXE_SHA256SUM="5651d17fe33323cdff35cf6390005f47741a98b6c2ea4e0a46d6149a68f28eac  g2uj33us.exe"
X230_FL1_SHA256SUM='dfef8b06618897eafe4e727cc7782a6aa6c31d5419c230e55fa39bdcd184a923  app/G2ETB7WW/$01D3000.FL1'
UEFIExtract_SHA256SUM="11ae7656e675f47e42684fe2bfb1e09f18825f9bf787892fb25c0a8d9cf04ac7  UEFIExtract_NE_A59_linux_x86_64.zip"
X230_BIOS_ACM_SHA256SUM="8f09aa059326b04f124d3dc7661fd6c4ef52ca126d790b17761cfbcb864738bf  X230_acm_bios/body.bin"
XX30_SINIT_ZIP_SHA256SUM="c94851c9a0f1b02d6ce11e57fc60620da5770f3e35bf01708f6f0cbc73ce05c8  3rd-gen-i5-i7-racm-sinit-67.zip"
XX30_SINIT_SHA256SUM="77e2c92360ad3af495cedb024fcd3250507c1c5df9cfc157179a16a590cfe4da  3rd_gen_i5_i7_RACM-SINIT_67/3rd_gen_i5_i7_RACM-SINIT_67.bin"

echo "### Creating temp dir"
extractdir=$(mktemp -d)
echo "working dir: $extractdir"
cd "$extractdir"

echo "### Downloading https://download.lenovo.com/pccbbs/mobiles/g1rg24ww.exe..."
wget https://download.lenovo.com/pccbbs/mobiles/g2uj33us.exe
echo "### Verifying expected hash of g2uj33us.exe"
echo "$X230_ACM_EXE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on downloaded binary..." && exit 1; }

echo "### Extracting g1rg24ww.exe..."
innoextract ./g2uj33us.exe || { echo "Failed calling innoextract. Tool installed on host?" && exit 1;}
echo '### Verifying expected hash of app/G2ETB7WW/$01D3000.FL1'
echo "$X230_FL1_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on extracted binary..." && exit 1; }

echo "### Downloading UEFIExtract..."
wget https://github.com/LongSoft/UEFITool/releases/download/A59/UEFIExtract_NE_A59_linux_x86_64.zip
echo "### Verifying expected checksum of UEFIExtract_NE_A59_linux_x86_64.zip ..."
echo "$UEFIExtract_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification UEFIExtract_NE_A59_linux_x86_64.zip..." && exit 1; }

echo "###Extracting BIOS ACM from app/G2ETB7WW/$01D3000.FL1 ..."
unzip UEFIExtract_NE_A59_linux_x86_64.zip
./UEFIExtract 'app/G2ETB7WW/$01D3000.FL1' 2D27C618-7DCD-41F5-BB10-21166BE7E143 -o X230_acm_bios -m body

echo "### Verifying expected hash of X230 BIOS ACM..."
echo "$X230_BIOS_ACM_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on X230 ACM BIOS BLOB..." && exit 1; }

echo "### Moving X230_acm_bios/body.bin under $BLOBDIR/x230_acm_bios.bin ..."
mv X230_acm_bios/body.bin $BLOBDIR/x230_acm_bios.bin

echo "### Downloading Ivy Bridge (xx30) SINIT ACM..."
wget https://web.archive.org/web/20220616203154/https://downloadmirror.intel.com/728789/3rd-gen-i5-i7-racm-sinit-67.zip

echo "### Verifying expected hash of BIOS ACM..."
echo "$XX30_SINIT_ZIP_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on XX30 (Ivy Bridge) SINIT ACM BLOB..." && exit 1; }

echo "###Extracting SINIT ACM blob from 3rd-gen-i5-i7-racm-sinit-67.zip ..."
unzip 3rd-gen-i5-i7-racm-sinit-67.zip

echo "### Verifying expected hash of X230 BIOS ACM..."
echo "$XX30_SINIT_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on XX30 (Ivy Bridge) SINIT ACM BLOB..." && exit 1; }

echo "### Moving 3rd_gen_i5_i7_RACM-SINIT_67/3rd_gen_i5_i7_RACM-SINIT_67.bin under $BLOBDIR/3rd_gen_i5_i7_RACM-SINIT_67.bin"
mv 3rd_gen_i5_i7_RACM-SINIT_67/3rd_gen_i5_i7_RACM-SINIT_67.bin $BLOBDIR/3rd_gen_i5_i7_RACM-SINIT_67.bin

#echo ""
echo "###Cleaning up..."
cd - > /dev/null 2>&1 
echo "Removing $extractdir ..."
#rm -r "$extractdir"
