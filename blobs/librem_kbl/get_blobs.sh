#!/bin/bash -e
# depends on : wget sha256sum gunzip

# Purism source
PURISM_SOURCE="https://source.puri.sm/coreboot/releases/raw/master"

# Librem 13 v4 and Librem 15 v4 binary blob hashes
KBL_UCODE_SHA="a420274eecca369fcca465cc46725d61c0ae8ca2e18f201b1751faf9e081fb2e"
KBL_DESCRIPTOR_SHA="642ca36f52aabb5198b82e013bf64a73a5148693a58376fffce322a4d438b524"
KBL_ME_SHA="0eec2e1135193941edd39d0ec0f463e353d0c6c9068867a2f32a72b64334fb34"
KBL_FSPM_SHA="5da3ad7718eb3f6700fb9d97be988d9c8bdd2d8b5910273a80928c49122d5b2d"
KBL_FSPS_SHA="c81ffa40df0b6cd6cfde4f476d452a1f6f2217bc96a3b98a4fa4a037ee7039cf"
KBL_VBT_SHA="0ba40c1b8c0fb030a0e1a789eda8b2a7369339a410ad8c4620719e451ea69b98"

# cbfstool, ifdtool, coreboot image from Purism repo
CBFSTOOL_FILE="cbfstool.gz"
CBFSTOOL_URL="$PURISM_SOURCE/tools/$CBFSTOOL_FILE"
CBFSTOOL_SHA="3994cba01a51dd34388c8be89fd329f91575c12e499dfe1b81975d9fd115ce58"
CBFSTOOL_BIN="./cbfstool"

IFDTOOL_FILE="ifdtool.gz"
IFDTOOL_URL="$PURISM_SOURCE/tools/$IFDTOOL_FILE"
IFDTOOL_SHA="08228ece4968794499ebd49a851f7d3f7f1b81352da8cd6e0c7916ac931a7d72"
IFDTOOL_BIN="./ifdtool"

COREBOOT_IMAGE="coreboot-l13v4.rom"
COREBOOT_IMAGE_FILE="$COREBOOT_IMAGE.gz"
COREBOOT_IMAGE_URL="$PURISM_SOURCE/librem_13v4/$COREBOOT_IMAGE_FILE"
COREBOOT_IMAGE_SHA="4491efd0a8b2de5a88fd7491a5d2605884ed956c3d271d7761906269b4cfb601"

die () {
    local msg=$1

    echo ""
    echo "$msg"
    exit 1
}

check_and_get_url () {
    local filename=$1
    local url=$2
    local hash=$3
    local description=$4

    if [ -f "$filename" ]; then
        sha=$(sha256sum "$filename" | awk '{print $1}')
    fi
    if [ "$sha" != "$hash" ]; then
        echo "    Downloading $description..."
        wget -O "$filename" "$url" >/dev/null 2>&1
        sha=$(sha256sum "$filename" | awk '{print $1}')
        if [ "$sha" != "$hash" ]; then
            die "Downloaded $description has the wrong SHA256 hash"
        fi
        if [ "${filename: -3}" == ".gz" ]; then
            gunzip -k $filename
        fi
    fi
    
}

check_and_get_blob () {
    local filename=$1
    local hash=$2
    local description=$3

    echo "Checking $filename"
    if [ -f "$filename" ]; then
        sha=$(sha256sum "$filename" | awk '{print $1}')
    fi
    if [ "$sha" != "$hash" ]; then
        # get tools
        check_and_get_tools
        # extract from coreboot image
        check_and_get_url $COREBOOT_IMAGE_FILE $COREBOOT_IMAGE_URL $COREBOOT_IMAGE_SHA "precompiled coreboot image"
        echo "Extracting $filename"
        if [ $filename = "descriptor.bin" ]; then
            $IFDTOOL_BIN -x $COREBOOT_IMAGE >/dev/null 2>&1
            mv flashregion_0_flashdescriptor.bin descriptor.bin
            echo "Extracting me.bin"
            mv flashregion_2_intel_me.bin me.bin
            rm flashregion_* > /dev/null 2>&1
        elif [ $filename = "me.bin" ]; then
            $IFDTOOL_BIN -x $COREBOOT_IMAGE >/dev/null 2>&1
            mv flashregion_2_intel_me.bin me.bin
            rm flashregion_* > /dev/null 2>&1
        else
            $CBFSTOOL_BIN $COREBOOT_IMAGE extract -n $filename -f $filename >/dev/null 2>&1
        fi
        sha=$(sha256sum "$filename" | awk '{print $1}')
        if [ "$sha" != "$hash" ]; then
            die "Downloaded $description has the wrong SHA256 hash"
        fi
    fi
}

echo ""

check_and_get_tools() {
    check_and_get_url $CBFSTOOL_FILE $CBFSTOOL_URL $CBFSTOOL_SHA "cbfstool"
    chmod +x $CBFSTOOL_BIN
    check_and_get_url $IFDTOOL_FILE $IFDTOOL_URL $IFDTOOL_SHA "ifdtool"
    chmod +x $IFDTOOL_BIN
}

# get tools for extraction
#check_and_get_tools

# get/verify blobs
check_and_get_blob descriptor.bin $KBL_DESCRIPTOR_SHA "Intel Flash Descriptor"
check_and_get_blob me.bin $KBL_ME_SHA "Intel ME firmware"
check_and_get_blob fspm.bin $KBL_FSPM_SHA "FSP-M"
check_and_get_blob fsps.bin $KBL_FSPS_SHA "FSP-S"
check_and_get_blob vbt.bin $KBL_VBT_SHA "Video BIOS Table"
check_and_get_blob cpu_microcode_blob.bin $KBL_UCODE_SHA "Intel Microcode Update"

#clean up after ourselves
rm -f $CBFSTOOL_BIN >/dev/null 2>&1
rm -f $IFDTOOL_BIN >/dev/null 2>&1
rm -f $COREBOOT_IMAGE >/dev/null 2>&1
rm -f *.gz >/dev/null 2>&1

echo ""
echo "All blobs have been verified and are ready for use"