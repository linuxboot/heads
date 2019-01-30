#!/bin/bash -e
# depends on : wget sha256sum python2.7 bspatch pv

# Librem 13 v4 and Librem 15 v4 binary blob hashes
KBL_UCODE_SHA="a420274eecca369fcca465cc46725d61c0ae8ca2e18f201b1751faf9e081fb2e"
KBL_ME_NOCONF_SHA="912271bb3ff2cf0e2e27ccfb94337baaca027e6c90b4245f9807a592c8a652e1"
KBL_ME_SHA="9c91052d457890c4a451c6ab69aabeeac98c95dce50cf462aa5c179236a27ba1"
KBL_FSP_SHA="74e579604bdc3eb6527f7add384d6b18e16eee76953748b226fe05129d83b419"
KBL_FSPM_SHA="b6431369b921df1c3ec01498e04e9dab331aa5b5fc4fbbb67b03ea87de27cd96"
KBL_FSPS_SHA="c81ffa40df0b6cd6cfde4f476d452a1f6f2217bc96a3b98a4fa4a037ee7039cf"
KBL_VBT_SHA="0ba40c1b8c0fb030a0e1a789eda8b2a7369339a410ad8c4620719e451ea69b98"

# Microcode, FSP downloadable from Github
KBL_UCODE_URL="https://github.com/platomav/CPUMicrocodes/raw/0d88b2eba0c9930e69180423d3fb9f348d5ca14f/Intel/cpu806E9_platC0_ver0000009A_2018-07-16_PRD_DDFC5B64.bin"
KBL_FSP_URL="https://github.com/IntelFsp/FSP/raw/324ffc02523bf23a907a3ff305b43b5047adf1c5/KabylakeFspBinPkg/Fsp.fd"
KBL_VBT_URL="https://github.com/IntelFsp/FSP/raw/324ffc02523bf23a907a3ff305b43b5047adf1c5/KabylakeFspBinPkg/SampleCode/Vbt/Vbt.bin"
KBL_FSP_SPLIT_URL="https://raw.githubusercontent.com/tianocore/edk2/e8a70885d8f34533b6dd69878fe95a249e9af086/IntelFsp2Pkg/Tools/SplitFspBin.py"
KBL_FSP_SPLIT_SHA="f654f6363de68ad78b1baf8b8e573b53715c3bc76f7f3c23562641e49a7033f3"

# Firmware descriptor from purism repo
KBL_DESCRIPTOR_URL="https://source.puri.sm/coreboot/coreboot-files/raw/master/descriptor-skl.bin"
KBL_DESCRIPTOR_SHA="d5110807c9d67cea6d546ac62125d87042a868177241be4ae17a2dbedef10017"

# ME Cleaner from github
ME_CLEANER_URL="https://github.com/corna/me_cleaner/raw/9e1611fdf21426d66a29a5ea62b7e30d512859e6/me_cleaner.py"
ME_CLEANER_SHA="412e95538c46d6d4d456987a8897b3d0ad1df118c51378a350540eef51c242d4"

# Intel ME binaries (unconfigured) 
# Link found on : http://www.win-raid.com/t832f39-Intel-Engine-Firmware-Repositories.html
# Update link if it changes and becomes invalid.
KBL_ME_RAR_URL="https://mega.nz/#!6JlAla6a!hvulc0ZYCj19OzOZoyKimZSh8bxHw9Qmy6bQ8h_xKTU"
KBL_ME_FILENAME="11.6.0.1126_CON_LP_C_NPDM_PRD_RGN.bin"
KBL_ME_FULL_FILENAME="Intel CSME 11.6 Firmware Repository Pack r28/$KBL_ME_FILENAME"
KBL_ME_RAR_SHA="3c23134fca8de7c9b47dd4d62498bcde549ad07565d158c69f4ed33f9bda8270"
KBL_ME_PATCH="me11.6.0.1126_config.bspatch"
KBL_ME_PATCH_URL="https://source.puri.sm/coreboot/coreboot-files/raw/master/$KBL_ME_PATCH"
KBL_ME_PATCH_SHA="63a245326979777b102da8df2f278c590c60c2cd6b4911d3ac430d3feb02646e"

# Needed to download KBL_ME_RAR_URL
MEGADOWN_URL="https://github.com/tonikelope/megadown.git"
MEGADOWN_GOOD_COMMIT="83c53ddad1c32bf6d35c61fcd12a2fa94271ff77"

# Might be required to compile unrar in case unrar-nonfree is not installed
RAR_NONFREE_SOURCE_URL="https://www.rarlab.com/rar/unrarsrc-5.5.8.tar.gz"
RAR_NONFREE_SOURCE_SHA="9b66e4353a9944bc140eb2a919ff99482dd548f858f5e296d809e8f7cdb2fcf4"

die () {
    local msg=$1

    echo ""
    echo "$msg"
    exit 1
}

check_binary () {
    local filename=$1
    local hash=$2

    if [ ! -f "$filename" ]; then
        die "Binary blob file '$filename' does not exist"
    fi
    sha=$(sha256sum "$filename" | awk '{print $1}')
    if [ "$sha" != "$hash" ]; then
        die "Extracted binary '$filename' has the wrong SHA256 hash"
    fi
}

check_and_get_url () {
    filename=$1
    url=$2
    hash=$3
    description=$4

    if [ -f "$filename" ]; then
        sha=$(sha256sum "$filename" | awk '{print $1}')
    fi
    if [ "$sha" != "$hash" ]; then
        wget -O "$filename" "$url"
        sha=$(sha256sum "$filename" | awk '{print $1}')
        if [ "$sha" != "$hash" ]; then
            die "Downloaded $description has the wrong SHA256 hash"
        fi
    fi
    
}

get_and_split_fsp () {
    fsp="fsp.fd"
    fsp_M="fsp_M.fd"
    fsp_S="fsp_S.fd"
    fsp_T="fsp_T.fd"
    fspm="fspm.bin"
    fsps="fsps.bin"
    fsp_split="SplitFspBin.py"

    if [ -f "$fspm" ]; then
        fspm_sha=$(sha256sum "$fspm" | awk '{print $1}')
    fi
    if [ -f "$fsps" ]; then
        fsps_sha=$(sha256sum "$fsps" | awk '{print $1}')
    fi
    # No FSP-M or FSP-S
    if [ "$fspm_sha" != "$KBL_FSPM_SHA" ] || [ "$fsps_sha" != "$KBL_FSPS_SHA" ]; then
        if [ -f "$fsp" ]; then
            fsp_sha=$(sha256sum "$fsp" | awk '{print $1}')
        fi
        # No FSP.fd
        if [ "$fsp_sha" != "$KBL_FSP_SHA" ]; then
            wget -O "$fsp" "$KBL_FSP_URL"
            fsp_sha=$(sha256sum "$fsp" | awk '{print $1}')
            if [ "$fsp_sha" != "$KBL_FSP_SHA" ]; then
                die "Downloaded FSP image has the wrong SHA256 hash"
            fi
        fi
        # No FspSplit
        if [ -f "$fsp_split" ]; then
            split_sha=$(sha256sum "$fsp_split" | awk '{print $1}')
        fi
        if [ "$split_sha" != "$KBL_FSP_SHA" ]; then
            wget -O "$fsp_split" "$KBL_FSP_SPLIT_URL"
            split_sha=$(sha256sum "$fsp_split" | awk '{print $1}')
            if [ "$split_sha" != "$KBL_FSP_SPLIT_SHA" ]; then
                die "Downloaded FSP Split Tool has the wrong SHA256 hash"
            fi
        fi
        python2 "$fsp_split" split -f "$fsp"
        if [ -f "$fsp_M" ]; then
            mv "$fsp_M" "$fspm"
        fi
        if [ -f "$fsp_S" ]; then
            mv "$fsp_S" "$fsps"
        fi
        fspm_sha=$(sha256sum "$fspm" | awk '{print $1}')
        fsps_sha=$(sha256sum "$fsps" | awk '{print $1}')
        if [ "$fspm_sha" != "$KBL_FSPM_SHA" ] || [ "$fsps_sha" != "$KBL_FSPS_SHA" ]; then
            die "Extracted FSP images have the wrong SHA256 hash"
        fi
        rm -f "$fsp"
        rm -f "$fsp_split"
        rm -f "$fsp_T"
    fi
}

get_and_patch_me_11 () {
    if [ -f "me.bin" ]; then
        sha=$(sha256sum "me.bin" | awk '{print $1}')
    fi
    if [ "$sha" != "$KBL_ME_SHA" ]; then
        local rar_filename=me_11_repository.rar
        local unrar='unrar-nonfree'

        if [ -f "$rar_filename" ]; then
            sha=$(sha256sum "$rar_filename" | awk '{print $1}')
        fi
        if ! type "$unrar" &> /dev/null; then
            wget -O unrar.tar.gz "$RAR_NONFREE_SOURCE_URL"
            sha=$(sha256sum unrar.tar.gz | awk '{print $1}')
            if [ "$sha" != "$RAR_NONFREE_SOURCE_SHA" ]; then
                die "Unrar source package has the wrong SHA256 hash"
            fi
            tar -xzvf unrar.tar.gz
            (
                cd unrar
                make
            )
            unrar="`pwd`/unrar/unrar"
        fi
        if [ "$sha" != "$KBL_ME_RAR_SHA" ]; then
            if [ ! -d megadown ]; then
                git clone $MEGADOWN_URL
            fi
            (
                cd megadown
                git checkout $MEGADOWN_GOOD_COMMIT
                echo -e "\n\nDownloading ME 11 Repository from $KBL_ME_RAR_URL"
                echo "Please be patient while the download finishes..."
                rm -f ../$rar_filename 2> /dev/null
                ./megadown "$KBL_ME_RAR_URL" -o ../$rar_filename 2>/dev/null
            )
            sha=$(sha256sum "$rar_filename" | awk '{print $1}')
            if [ "$sha" != "$KBL_ME_RAR_SHA" ]; then
                # We'll assume the rar file was updated again
                me_dirname=$("$unrar" l "$rar_filename" | grep '\.\.\.D\.\.\.' | tr  -s [:blank:] | cut -d' ' -f 6-)
                KBL_ME_FULL_FILENAME="$me_dirname/$KBL_ME_FILENAME"
            fi
        fi
        if type "$unrar" &> /dev/null; then
            "$unrar" e -y "$rar_filename" "$KBL_ME_FULL_FILENAME"
        else
            die "Couldn't extract ME image. Requires unrar-nonfree"
        fi
        sha=""
        if [ -f "$KBL_ME_FILENAME" ]; then
            sha=$(sha256sum "$KBL_ME_FILENAME" | awk '{print $1}')
        fi
        if [ "$sha" != "$KBL_ME_NOCONF_SHA" ]; then
            die "Couldn't extract ME image with the correct SHA256 hash"
        fi
        check_and_get_url $KBL_ME_PATCH $KBL_ME_PATCH_URL $KBL_ME_PATCH_SHA "ME Patch"
        bspatch "$KBL_ME_FILENAME" "me.bin" "$KBL_ME_PATCH"
        rm -f "$KBL_ME_PATCH"
        rm -f "$KBL_ME_FILENAME"
        rm -f "$rar_filename"
    fi
}

apply_me_cleaner() {
    if [ -f "me_cleaner.py" ]; then
        sha=$(sha256sum "me_cleaner.py" | awk '{print $1}')
    fi
    if [ "$sha" != "$ME_CLEANER_SHA" ]; then
        wget -O "me_cleaner.py" "$ME_CLEANER_URL"
        sha=$(sha256sum "me_cleaner.py" | awk '{print $1}')
        if [ "$sha" != "$ME_CLEANER_SHA" ]; then
            die "Downloaded ME Cleaner has the wrong SHA256 hash"
        fi
    fi
    cat descriptor.bin me.bin > desc_me.bin
    python2 "me_cleaner.py" -s desc_me.bin
    python2 "me_cleaner.py" -w "MFS" me.bin
    dd if=desc_me.bin of=descriptor.bin bs=4096 count=1
    rm -f desc_me.bin
    rm -f me_cleaner.py
}

check_and_get_url descriptor.bin $KBL_DESCRIPTOR_URL $KBL_DESCRIPTOR_SHA "Intel Flash Descriptor"
check_binary descriptor.bin $KBL_DESCRIPTOR_SHA
get_and_patch_me_11
check_binary me.bin $KBL_ME_SHA
apply_me_cleaner
get_and_split_fsp
check_binary fspm.bin $KBL_FSPM_SHA
check_binary fsps.bin $KBL_FSPS_SHA
check_and_get_url vbt.bin $KBL_VBT_URL $KBL_VBT_SHA "Video BIOS Table"
check_and_get_url cpu_microcode_blob.bin $KBL_UCODE_URL $KBL_UCODE_SHA "Intel Microcode Update"

echo ""
echo "Blobs have been downloaded/verified and are ready for use"
