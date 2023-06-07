#!/usr/bin/env bash

function printusage {
  echo "Usage: $0 -m <me_cleaner>(optional)"
}

ME_BIN_HASH="c140d04d792bed555e616065d48bdc327bb78f0213ccc54c0ae95f12b28896a4"

if [ -e "${output_dir}/me.bin" ]; then
  echo "me.bin already exists"
  if echo "${ME_BIN_HASH} ${output_dir}/me.bin" | sha256sum --check; then
    echo "SKIPPING: SHA256 checksum for me.bin matches."
    exit 0
  fi
  echo "me.bin exists but checksum doesn't match. Continuing..."
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--help" ]]; then
    usage
  else
    if [[ -z "${COREBOOT_DIR}" ]]; then
      echo "ERROR: No COREBOOT_DIR variable defined."
      exit 1
    fi

    output_dir="$(realpath "${1:-./}")"

    if [[ ! -f "${output_dir}/me.bin" ]]; then
      # Unpack Lenovo's Windows installer into a temporary directory and
      # extract the Intel ME blob.
      pushd "$(mktemp -d)" || exit

      curl -O https://download.lenovo.com/pccbbs/mobiles/g1rg24ww.exe
      innoextract g1rg24ww.exe

      mv app/ME8_5M_Production.bin "${COREBOOT_DIR}/util/me_cleaner"
      rm -rf ./*
      popd || exit

      # Neutralize and shrink Intel ME. Note that this doesn't include
      # --soft-disable to set the "ME Disable" or "ME Disable B" (e.g.,
      # High Assurance Program) bits, as they are defined within the Flash
      # Descriptor.
      # https://github.com/corna/me_cleaner/wiki/External-flashing#neutralize-and-shrink-intel-me-useful-only-for-coreboot
      pushd "${COREBOOT_DIR}/util/me_cleaner" || exit

      python me_cleaner.py -r -t -O me_shrinked.bin ME8_5M_Production.bin
      rm -f ME8_5M_Production.bin
      mv me_shrinked.bin "${output_dir}/me.bin"
      popd || exit
    fi

    if ! echo "${ME_BIN_HASH} ${output_dir}/me.bin" | sha256sum --check; then
      echo "ERROR: SHA256 checksum for me.bin doesn't match."
      exit 1
    fi
  fi
fi
