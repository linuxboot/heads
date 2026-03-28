#!/bin/bash
# get a file and extend a TPM PCR
. /etc/functions

INDEX="$1"
URL="$2"

if [ -z "$INDEX" -o -z "$URL" ]; then
	DIE "Usage: $0 pcr-index url"
fi


wget "$URL" || DIE "$URL: failed"

FILE="`basename "$URL"`"
tpmr extend -ix "$INDEX" -if "$FILE" || DIE "$FILE: tpm extend failed"


