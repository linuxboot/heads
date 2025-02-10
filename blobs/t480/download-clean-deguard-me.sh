#!/usr/bin/env bash

set -e

function usage() {
    echo -n \
        "Usage: $(basename "$0") path_to_output_directory
Download Intel ME firmware from Dell_Inspiron_5468_donor, shrink and deguard to use for t480.
"
}
# hash sha256sum values. vendorfiles/me.bin in the Libreboot was hashed after the lb compilation.
ME_BIN_HASH="1990b42df67ba70292f4f6e2660efb909917452dcb9bd4b65ea2f86402cfa16b"
DELL_EXE_HASH="ddfbc51430699e0dfcb24a60bcb5b6e5481b325ebecf1ac177e069013189e4b0"
TB_EXE_HASH="a500a93fe6a3728aa6676c70f98cf46785ef15da7c5b1ccd7d3a478d190a28a8"

# me_cleaner is in the blobs/t480 dir
# if it is not desired, change to use me_cleaner from COREBOOT_DIR
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == "--help" ]]; then
        usage
    else
        if [[ -z "${COREBOOT_DIR}" ]]; then
            echo "ERROR: No COREBOOT_DIR variable defined."
            exit 1
        fi

        output_dir="$(realpath "${1:-./}")"
        pfs_extract="$(realpath "$(dirname "$0")/biosutilities/Dell_PFS_Extract.py")"
        deguard_path="$(realpath "$(dirname "$0")/deguard")"
        me_cleaner="$(realpath "$(dirname "$0")/me_cleaner/me_cleaner.py")"
        me_inspiron_path="Inspiron_5468_1.3.0.exe_extracted/Firmware/1 Inspiron_5468_1.3.0 -- 3 Intel Management Engine (Non-VPro) Update v11.6.0.1126.bin"

        echo "output_dir: $output_dir"
        echo "biosutil_path: $biosutil_path"
        echo "deguard_path: $deguard_path"
        echo "me_cleaner_path": $me_cleaner_path

        if [[ ! -f "${output_dir}/me.bin" ]]; then
            # Unpack Lenovo's tb Windows installer into a temporary directory and
            # check the hash. extract the firmware. pad afterwards with 0.
            pushd "$(mktemp -d)"
            temp_path="$(pwd)"
            curl -O "https://download.lenovo.com/pccbbs/mobiles/n24th13w.exe"

            if ! echo "${TB_EXE_HASH} n24th13w.exe" | sha256sum --check; then
            echo "ERROR: SHA256 checksum for tb installer doesn't match."
            exit 1
            fi

            # https://www.reddit.com/r/thinkpad/comments/9rnimi/ladies_and_gentlemen_i_present_to_you_the/ was used
            # since the lb function was incomplete.
            7z e n24th13w.exe \[0\];mv \[0\] tb.bin
            dd if=/dev/zero of=tb.bin bs=1 seek=1048575 count=1

            mv tb.bin "${output_dir}/tb.bin"

            # Unpack Dell's Windows installer into a temporary directory and
            # extract the Intel ME blob.
            curl -O "https://web.archive.org/web/20241110222323/https://dl.dell.com/FOLDER04573471M/1/Inspiron_5468_1.3.0.exe"
            # check hash after the download

            if ! echo "${DELL_EXE_HASH} Inspiron_5468_1.3.0.exe" | sha256sum --check; then
            echo "ERROR: SHA256 checksum for dell installer doesn't match."
            exit 1
            fi

            python $pfs_extract Inspiron_5468_1.3.0.exe -e


            # libreboot/coreboot me_cleaner util was copied to t480 dir to avoid changing directories
            # me_cleaner to t480 was applied without -r parameter, and keeping MFS similar to the libreboot functions in /include/vendor.sh
            python $me_cleaner -t -O me_cleaned.bin "$temp_path/$me_inspiron_path" -w MFS
            popd

            # deguard using the Mate Kukri tool was applied
            pushd "$deguard_path"
            ME11delta="thinkpad_t480"  # subdirectory under deguard's data/delta/
            ME11version="11.6.0.1126"
            ME11sku="2M"
            ME11pch="LP"

            ./finalimage.py --delta "data/delta/$ME11delta" \
                --version "$ME11version" \
                --pch "$ME11pch" --sku "$ME11sku" --fake-fpfs data/fpfs/zero \
                --input "${temp_path}/me_cleaned.bin" \
                --output "${output_dir}/me.bin"
            echo "me.bin was saved to: ${output_dir}/me.bin"
            popd

        fi

        if ! echo "${ME_BIN_HASH} ${output_dir}/me.bin" | sha256sum --check; then
            echo "ERROR: SHA256 checksum for me.bin doesn't match."
            exit 1
        fi
    fi
fi
