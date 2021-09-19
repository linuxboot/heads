#!/bin/bash -e

# depends on : wget sha256sum gunzip

# based off the get_blobs.sh script used for librems

# I'm honesly not sure if this is even necessary as S76 just has the blobs 
# sitting in their github repo (which I thought would run into redistribution 
# issues) but just in case we're going to do the safe thing and grab them from
# S76's repo

#TODO: add option to strip ME

# S76 source
url="https://github.com/system76/firmware-open/raw/master/models/lemp10/"

# blob hashes
UCODE_SHA="6eb0e4161cb7681db200be566dbe16e481cae41592a3e4f1476220fff542e61b"
DESCRIPTOR_SHA="7fa9819ef72349dd644541d213424c05e79dc0f4a9ff8b0bc7c51e4378226774"
ME_SHA="ab9fa597e787d5662ed88b19e866f0fc11e64a593cba4cc39c30748af84ee885"
VBT_SHA="2d66a84831f8675d7052b37c7943cae0f5475d50f11ec726814e8b5e7caa6659"

die () {
    local msg=$1

    echo ""
    echo "$msg"
    exit 1
}

get_and_check_blob () {
    local filename=$1
    local hash=$2
    local description=$3

    echo "Retrieving $filename"
    wget "$url$filename" >/dev/null 2>&1

    echo "Verifying $filename"
    sha=$(sha256sum "$filename" | awk '{print $1}')
    if [ "$sha" != "$hash" ]; then
    	rm -f $filename
	echo "Retrieved hash: $sha"
	echo "Correct hash: $hash"
    	die "Verification failed for $filename"
    fi
    echo "Verification successful for $filename"
    echo ""
}

echo ""
echo "Removing old blobs"

rm -f microcode.rom
rm -f vbt.rom
rm -f me.rom
rm -f fd.rom


echo ""
echo "Retrieving new blobs"
echo ""

# get/verify blobs
get_and_check_blob fd.rom $DESCRIPTOR_SHA "Intel Flash Descriptor"
get_and_check_blob me.rom $ME_SHA "Intel ME firmware"
get_and_check_blob vbt.rom $VBT_SHA "Video BIOS Table"
get_and_check_blob microcode.rom $UCODE_SHA "Intel Microcode Update"

echo "All blobs have been verified and are ready for use"
