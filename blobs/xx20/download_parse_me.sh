#!/usr/bin/env bash

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

FINAL_ME_BIN_SHA256SUM="1eef6716aa61dd844d58eca15a85faa1bf5f82715defd30bd3373e79ca1a3339  $BLOBDIR/me.bin"
ME_EXE_SHA256SUM="48f18d49f3c7c79fa549a980f14688bc27c18645f64d9b6827a15ef5c547d210  83rf46ww.exe"
ME7_5M_UPD_PRODUCTION_SHA256SUM="760b0776b99ba94f56121d67c1f1226c77f48bd3b0799e1357a51842c79d3d36  app/ME7_5M_UPD_Production.bin"

if [ -e "$BLOBDIR/me.bin" ]; then
  echo "$BLOBDIR/me.bin found..."
  if ! echo "$FINAL_ME_BIN_SHA256SUM" | sha256sum --check; then
    echo "$BLOBDIR/me.bin doesn't pass integrity validation. Continuing..."
    rm -f "$BLOBDIR/me.bin"
  else
    echo "$BLOBDIR/me.bin already extracted and neutered outside of BUP"
    exit 0
  fi
fi

echo "### Creating temp dir"
extractdir=$(mktemp -d)
cd "$extractdir" || exit 1

echo "### Downloading https://download.lenovo.com/ibmdl/pub/pc/pccbbs/mobiles/83rf46ww.exe..."
wget  https://download.lenovo.com/ibmdl/pub/pc/pccbbs/mobiles/83rf46ww.exe || { echo "ERROR: wget not found" && exit 1; }
echo "### Verifying expected hash of 83rf46ww.exe"
echo "$ME_EXE_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on downloaded binary..." && exit 1; }


echo "### Extracting 83rf46ww.exe..."
innoextract -I app/ME7_5M_UPD_Production.bin 83rf46ww.exe || { echo "Failed calling innoextract. Tool installed on host?" && exit 1; }
echo "### Verifying expected hash of app/ME7_5M_UPD_Production.bin"
echo "$ME7_5M_UPD_PRODUCTION_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on extracted binary..." && exit 1; }


echo "###Generating neuter+deactivate+maximize reduction of ME on app/ME7_5M_UPD_Production.bin, outputting minimized ME under $BLOBDIR/me.bin... "
( python3 "$BLOBDIR/me7_update_parser.py" -O "$BLOBDIR/me.bin" app/ME7_5M_UPD_Production.bin ) || { echo "Failed to generate ME binary..." && exit 1; }

echo "### Verifying expected hash of me.bin"
echo "$FINAL_ME_BIN_SHA256SUM" | sha256sum --check || { echo "Failed sha256sum verification on final binary..." && exit 1; }


echo "###Cleaning up..."
cd - || exit 1
rm -r "$extractdir"
