#!/bin/bash
# get a file and extend a TPM PCR
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

die() {
	TRACE_FUNC
        echo >&2 "$@"
        exit 1
}

INDEX="$1"
URL="$2"

if [ -z "$INDEX" ] || [ -z "$URL" ]; then
	die "Usage: $0 pcr-index url"
fi

wget "$URL" || die "$URL: failed"

FILE="$(basename "$URL")"
tpmr.sh extend -ix "$INDEX" -if "$FILE" || die "$FILE: tpm extend failed"

