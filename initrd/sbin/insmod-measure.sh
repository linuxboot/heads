#!/bin/sh
# extend a TPM PCR with a module and then load it
# any arguments will also be measured

die() {
        echo >&2 "$@"
        exit 1
}

INDEX="$1"; shift
MODULE="$1"; shift

if [ -z "$INDEX" -o -z "$MODULE" ]; then
	die "Usage: $0 pcr-index module [args...]"
fi

if [ ! -r "$MODULE" ]; then
	die "$MODULE: not found?"
fi

tpm extend -ix "$INDEX" -if "$MODULE" || die "$MODULE: tpm extend failed"

if [ ! -z "$@" ]; then
	TMPFILE=/tmp/insmod.$$
	echo "$@" > $TMPFILE
	tpm extend -ix "$INDEX" -if $TMPFILE || die "$MODULE: tpm extend on arguments failed"
fi

insmod "$MODULE" "$@" || die "$MODULE: insmod failed"
