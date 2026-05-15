#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"

function usage {
  echo "Usage: $0 -m <me_cleaner>(optional)"
}

ME_BIN_HASH="c140d04d792bed555e616065d48bdc327bb78f0213ccc54c0ae95f12b28896a4"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--help" ]]; then
    usage
  else
    if [[ -z "${COREBOOT_DIR}" ]]; then
      echo "ERROR: No COREBOOT_DIR variable defined."
      exit 1
    fi

    output_dir="$(realpath "${1:-./}")"

    check_outputs "${ME_BIN_HASH} ${output_dir}/me.bin" && { echo "All outputs match. Nothing to do."; exit 0; }

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

    check_outputs "${ME_BIN_HASH} ${output_dir}/me.bin" || exit 1
  fi
fi
