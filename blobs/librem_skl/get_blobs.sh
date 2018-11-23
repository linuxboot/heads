#!/bin/bash -e
# depends on : wget sha256sum python2.7 bspatch pv

# Librem 13 v2 and Librem 15 v3 binary blob hashes
SKL_UCODE_SHA="9c84936df700d74612a99e6ab581640ecf423d25a0b74a1ea23a6d9872349213"
SKL_DESCRIPTOR_SHA="d5110807c9d67cea6d546ac62125d87042a868177241be4ae17a2dbedef10017"
SKL_ME_NOCONF_SHA="70f07be7934bdbb215c66455a2b0d32651f3b2ecaf2519d83d8ca9cf475cc366"
SKL_ME_SHA="3042150c7f655293a69bcf886836732fc451439ae551a2babf3173f4f0d9a8d3"
SKL_FSP_SHA="a7dfec436f5a21a66b5a455775599d73a95170a3446849a34e89a64a2bb69820"
SKL_FSPM_SHA="7a1acc72073969e6753bbfe145f06c3f4d35e2516cb241641eae968705e2cc46"
SKL_FSPS_SHA="0dac94d249473e9d366597fd1f96a0232fb7bf045a3d08f16784961273351822"
SKL_VBT_SHA="51fa214ca44a61b171662d4c2ca6adc1aa3dc6c3d7a24bf9ae5f249f012d61c0"

# FSP downloadable from Github
SKL_UCODE_URL="https://github.com/platomav/CPUMicrocodes/raw/bfb23e48eb84dff1495d1c8789f133a1b684de27/Intel/cpu406E3_platC0_ver000000C2_2017-11-16_PRD_C6C6F699.bin"
SKL_FSP_URL="https://github.com/IntelFsp/FSP/raw/8267cde09763c0c699704fbae10e6bd121f01b6a/KabylakeFspBinPkg/Fsp.fd"
SKL_VBT_URL="https://github.com/IntelFsp/FSP/raw/8267cde09763c0c699704fbae10e6bd121f01b6a/KabylakeFspBinPkg/SampleCode/Vbt/Vbt.bin"
SKL_FSP_SPLIT_URL="https://raw.githubusercontent.com/tianocore/edk2/e8a70885d8f34533b6dd69878fe95a249e9af086/IntelFsp2Pkg/Tools/SplitFspBin.py"
SKL_FSP_SPLIT_SHA="f654f6363de68ad78b1baf8b8e573b53715c3bc76f7f3c23562641e49a7033f3"
ME_CLEANER_URL="https://github.com/corna/me_cleaner/raw/9e1611fdf21426d66a29a5ea62b7e30d512859e6/me_cleaner.py"
ME_CLEANER_SHA="412e95538c46d6d4d456987a8897b3d0ad1df118c51378a350540eef51c242d4"

SKL_DESCRIPTOR_URL="https://source.puri.sm/coreboot/coreboot-files/raw/master/descriptor-skl.bin"
SKL_ME_PATCH_URL="https://source.puri.sm/coreboot/coreboot-files/raw/master/me11.0.18_config.bspatch"
SKL_ME_PATCH_SHA="49019f89206d6371b1377cf738426c3b0ac60c4b1bb89d5d5de00481e7e4fece"

# Link found on : http://www.win-raid.com/t832f39-Intel-Engine-Firmware-Repositories.html
# Update link if it changes and becomes invalid.
SKL_ME_RAR_URL="https://mega.nz/#!DNdDVQ7I!hronBMVN8m82JciiT6UQwtwh-LVlHXIo-NzTB0324rk"
SKL_ME_FILENAME="11.0.18.1002_CON_LP_C0_NPDM_PRD_RGN.bin"
SKL_ME_FULL_FILENAME="Intel CSME 11.0 Firmware Repository Pack r52/$SKL_ME_FILENAME"
SKL_ME_RAR_SHA="28b7c31ae6888623d2271f0c74cb7bbca55a56af73b26f9796742467a841441a"

# Needed to download SKL_ME_RAR_URL
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
    if [ "$fspm_sha" != "$SKL_FSPM_SHA" ] || [ "$fsps_sha" != "$SKL_FSPS_SHA" ]; then
        if [ -f "$fsp" ]; then
            fsp_sha=$(sha256sum "$fsp" | awk '{print $1}')
        fi
        # No FSP.fd
        if [ "$fsp_sha" != "$SKL_FSP_SHA" ]; then
            wget -O "$fsp" "$SKL_FSP_URL"
            fsp_sha=$(sha256sum "$fsp" | awk '{print $1}')
            if [ "$fsp_sha" != "$SKL_FSP_SHA" ]; then
                die "Downloaded FSP image has the wrong SHA256 hash"
            fi
        fi
        # No FspSplit
        if [ -f "$fsp_split" ]; then
            split_sha=$(sha256sum "$fsp_split" | awk '{print $1}')
        fi
        if [ "$split_sha" != "$SKL_FSP_SHA" ]; then
            wget -O "$fsp_split" "$SKL_FSP_SPLIT_URL"
            split_sha=$(sha256sum "$fsp_split" | awk '{print $1}')
            if [ "$split_sha" != "$SKL_FSP_SPLIT_SHA" ]; then
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
        if [ "$fspm_sha" != "$SKL_FSPM_SHA" ] || [ "$fsps_sha" != "$SKL_FSPS_SHA" ]; then
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
    if [ "$sha" != "$SKL_ME_SHA" ]; then
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
        if [ "$sha" != "$SKL_ME_RAR_SHA" ]; then
            if [ ! -d megadown ]; then
                git clone $MEGADOWN_URL
            fi
            (
                cd megadown
                git checkout $MEGADOWN_GOOD_COMMIT
                echo -e "\n\nDownloading ME 11 Repository from $SKL_ME_RAR_URL"
                echo "Please be patient while the download finishes..."
                ./megadown "$SKL_ME_RAR_URL" -o ../$rar_filename 2>/dev/null
            )
            sha=$(sha256sum "$rar_filename" | awk '{print $1}')
            if [ "$sha" != "$SKL_ME_RAR_SHA" ]; then
                # We'll assume the rar file was updated again
                me_dirname=$("$unrar" l "$rar_filename" | grep '\.\.\.D\.\.\.' | tr  -s [:blank:] | cut -d' ' -f 6-)
                SKL_ME_FULL_FILENAME="$me_dirname/$SKL_ME_FILENAME"
            fi
        fi
        if type "$unrar" &> /dev/null; then
            "$unrar" e -y "$rar_filename" "$SKL_ME_FULL_FILENAME"
        else
            die "Couldn't extract ME image. Requires unrar-nonfree"
        fi
        sha=""
        if [ -f "$SKL_ME_FILENAME" ]; then
            sha=$(sha256sum "$SKL_ME_FILENAME" | awk '{print $1}')
        fi
        if [ "$sha" != "$SKL_ME_NOCONF_SHA" ]; then
            die "Couldn't extract ME image with the correct SHA256 hash"
        fi
        check_and_get_url me11.0.18_config.bspatch $SKL_ME_PATCH_URL $SKL_ME_PATCH_SHA "ME Patch"
        bspatch "$SKL_ME_FILENAME" "me.bin" me11.0.18_config.bspatch
        rm -f me11.0.18_config.bspatch
        rm -f "$SKL_ME_FILENAME"
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

check_and_get_url descriptor.bin $SKL_DESCRIPTOR_URL $SKL_DESCRIPTOR_SHA "Intel Flash Descriptor"
check_binary descriptor.bin $SKL_DESCRIPTOR_SHA
get_and_patch_me_11
check_binary me.bin $SKL_ME_SHA
apply_me_cleaner
get_and_split_fsp
check_binary fspm.bin $SKL_FSPM_SHA
check_binary fsps.bin $SKL_FSPS_SHA
check_and_get_url vbt.bin $SKL_VBT_URL $SKL_VBT_SHA "Video BIOS Table"
check_and_get_url cpu_microcode_blob.bin $SKL_UCODE_URL $SKL_UCODE_SHA "Intel Microcode Update"
