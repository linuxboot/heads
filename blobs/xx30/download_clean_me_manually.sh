#!/bin/bash

function printusage {
  echo "Usage: $0 -m <me_cleaner>(optional)"
}

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$#" -eq 0 ]; then printusage; fi

while getopts ":m:" opt; do
  case $opt in
    m)
      if [ -x "$OPTARG" ]; then
        MECLEAN="$OPTARG"
      fi
      ;;
  esac
done

FINAL_ME_BIN_SHA256SUM="c140d04d792bed555e616065d48bdc327bb78f0213ccc54c0ae95f12b28896a4  $BLOBDIR/me.bin"
ME_EXE_SHA256SUM="f60e1990e2da2b7efa58a645502d22d50afd97b53a092781beee9b0322b61153  g1rg24ww.exe"
ME8_5M_PRODUCTION_SHA256SUM="821c6fa16e62e15bc902ce2e958ffb61f63349a471685bed0dc78ce721a01bfa  app/ME8_5M_Production.bin"


if [ -z "$MECLEAN" ]; then
  MECLEAN=`command -v $BLOBDIR/../../build/x86/coreboot-*/util/me_cleaner/me_cleaner.py 2>&1|head -n1`
  if [ -z "$MECLEAN" ]; then
    echo "me_cleaner.py required but not found or specified with -m. Aborting."
    exit 1;
  fi
fi

echo "### Creating temp dir"
extractdir=$(mktemp -d)
cd "$extractdir"

echo "### Downloading https://download.lenovo.com/pccbbs/mobiles/g1rg24ww.exe..."
wget  https://download.lenovo.com/pccbbs/mobiles/g1rg24ww.exe || { echo "ERROR: wget not found" && exit 1; }
echo "### Verifying expected hash of g1rg24ww.exe"
echo "$ME_EXE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on downloaded binary..." && exit 1; }

echo "### Extracting g1rg24ww.exe..."
innoextract ./g1rg24ww.exe || { echo "Failed calling innoextract. Tool installed on host?" && exit 1;}
echo "### Verifying expected hash of app/ME8_5M_Production.bin"
echo "$ME8_5M_PRODUCTION_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on extracted binary..." && exit 1; }

echo "###Applying me_cleaner to neuter+deactivate+maximize reduction of ME on $bioscopy, outputting minimized ME under $BLOBDIR/me.bin... "
$MECLEAN -r -t -O "$BLOBDIR/me.bin" app/ME8_5M_Production.bin
echo "### Verifying expected hash of me.bin"
echo "$FINAL_ME_BIN_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on final binary..." && exit 1; }


echo "###Cleaning up..."
cd - 
rm -r "$extractdir"
