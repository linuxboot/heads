#!/usr/bin/env bash
EC_BLOB_HASH=20060eba91367b71a21c7757271ac642fa0376809f8c1b51066510246ac97bdb
ACM_BLOB_HASH=b00d10f6615cf1b28f4fb4adac6631bf6e332db524e45dfafb92e539767d22a0
SINIT_BLOB_HASH=1e888aebc78d637d119c489adffa95387b53429125dc3ad61f10a5cad0496834

output_dir="$(realpath "${1:-./}")"

if [[ ! -f "${output_dir}/IVB_BIOSAC_PRODUCTION.bin" ]] || [[ ! -f "${output_dir}/sch5545_ecfw.bin" ]] || [[ ! -f "${output_dir}/SNB_IVB_SINIT_20190708_PW.bin" ]] ; then
    # Unpack Dell's Windows installer into a temporary directory and
    # extract the EC and ACM blobs

    pushd "$(mktemp -d)" || exit

    #Download Dell firmware update package
    wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.159 Safari/537.36" https://dl.dell.com/FOLDER05066036M/1/O7010A29.exe \
	    ||  wget https://web.archive.org/web/20241007124946/https://dl.dell.com/FOLDER05066036M/1/O7010A29.exe

    #Extract binary
    binwalk -e O7010A29.exe -C . --run-as=root

    #Extract blobs
    #uefi-firmware-parser -e "_O7010A29.exe.extracted/65C10" -O
    uefi-firmware-parser -b "_O7010A29.exe.extracted/65C10" -e -o extract

    #EC
    cp ./extract/volume-327768/file-d386beb8-4b54-4e69-94f5-06091f67e0d3/section0.raw sch5545_ecfw.bin
    
    mv sch5545_ecfw.bin "${output_dir}/"

    #ACM
    cp ./extract/volume-5242968/file-2d27c618-7dcd-41f5-bb10-21166be7e143/object-0.raw IVB_BIOSAC_PRODUCTION.bin
    mv IVB_BIOSAC_PRODUCTION.bin "${output_dir}/"

    #Download sinit
    wget https://cdrdv2.intel.com/v1/dl/getContent/630744 -O sinit.zip
    unzip sinit.zip
    mv 630744_003/SNB_IVB_SINIT_20190708_PW.bin "${output_dir}/" 
    
    popd || exit
fi

if ! echo "${EC_BLOB_HASH} ${output_dir}/sch5545_ecfw.bin" | sha256sum --check; then
      echo "ERROR: SHA256 checksum for sch5545_ecfw.bin doesn't match. Try again"
      rm -f "${output_dir}/sch5545_ecfw.bin"
      exit 1
fi


if ! echo "${ACM_BLOB_HASH} ${output_dir}/IVB_BIOSAC_PRODUCTION.bin" | sha256sum --check; then
      echo "ERROR: SHA256 checksum for IVB_BIOSAC_PRODUCTION.bin doesn't match. Try again"
      rm -f "${output_dir}/IVB_BIOSAC_PRODUCTION.bin"
      exit 1
fi


if ! echo "${SINIT_BLOB_HASH} ${output_dir}/SNB_IVB_SINIT_20190708_PW.bin" | sha256sum --check; then
      echo "ERROR: SHA256 checksum for SNB_IVB_SINIT_20190708_PW.bin doesn't match. Try again"
      rm -f "${output_dir}/SNB_IVB_SINIT_20190708_PW.bin"
      exit 1
fi

