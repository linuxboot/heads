#!/bin/bash
# get a file and extend a TPM PCR
. /etc/functions

die() {
	TRACE "Under /bin/wget-measure.sh:die"
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
tpmr extend -ix "$INDEX" -if "$FILE" || die "$FILE: tpm extend failed"


