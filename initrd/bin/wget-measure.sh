#!/bin/sh
# get a file and extend a TPM PCR

die() {
        echo >&2 "$@"
        exit 1
}

INDEX="$1"
URL="$2"

if [ -z "$INDEX" -o -z "$URL" ]; then
	die "Usage: $0 pcr-index url"
fi


wget "$URL" || die "$URL: failed"

FILE="`basename "$URL"`"
tpm extend -ix "$INDEX" -if "$FILE" || die "$FILE: tpm extend failed"


