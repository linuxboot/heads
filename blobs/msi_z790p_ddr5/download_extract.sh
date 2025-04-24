#!/usr/bin/env bash

#
# These will change over time.
#
ami_bios_url="https://download.msi.com/bos_exe/mb/7E06vAG.zip"
ami_bios_file="E7E06IMS.AG0"
me_hash="7a33a31cf22ae7e70adcd6f46b848a1e35e030b87fec2e671daf8fb416406396"
ifd_hash="72ddb02b42d2dbb1e3ae745118905941bb4dcd4e68fa082e93598278e7b38259"
#
#

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ -z "${COREBOOT_DIR}" ]]; then
  echo "ERROR: No COREBOOT_DIR variable defined."
  exit 1
fi

pushd "${COREBOOT_DIR}/util/ifdtool"
make
popd

IFDTOOL="${COREBOOT_DIR}/util/ifdtool/ifdtool"

pushd $BLOBDIR

curl -L --output ami_bios.zip "$ami_bios_url" || { echo "Downloading MSI BIOS failed." && exit 1; }

unzip -o -j ami_bios.zip "*/$ami_bios_file"

mv "$ami_bios_file" ./ami_bios.bin

$IFDTOOL -p adl ./ami_bios.bin --extract

rm ./flashregion_1_bios.bin ./flashregion_9_device_exp.bin

mv ./flashregion_0_flashdescriptor.bin ./ifd.bin
mv ./flashregion_2_intel_me.bin ./me.bin

$IFDTOOL -p adl ./ifd.bin --unlock --output ./ifd.bin
$IFDTOOL -p adl ./ifd.bin --altmedisable 1 --output ./ifd.bin

echo "$ifd_hash  ifd.bin" | sha256sum --check || { echo "ifd.bin verification failed." && exit 1; }
echo "$me_hash  me.bin" | sha256sum --check || { echo "me.bin verification failed." && exit 1; }

popd

echo "DONE!"
