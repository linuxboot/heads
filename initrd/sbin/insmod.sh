#!/bin/sh
# extend a TPM PCR with a module and then load it
# any arguments will also be measured.
# The default PCR to be extended is 5, but can be
# overridden with the MODULE_PCR environment variable

die() {
        echo >&2 "$@"
        exit 1
}

MODULE="$1"; shift

if [ -z "$MODULE_PCR" ]; then
	MODULE_PCR=5
fi


if [ -z "$MODULE" ]; then
	die "Usage: $0 module [args...]"
fi

if [ ! -r "$MODULE" ]; then
	die "$MODULE: not found?"
fi

if [ ! -r /sys/class/tpm/tpm0/pcrs -o ! -x /bin/tpm ]; then
	tpm_missing=1
fi

if [ -z "$tpm_missing" ]; then
	tpm extend -ix "$MODULE_PCR" -if "$MODULE" \
	|| die "$MODULE: tpm extend failed"
fi

if [ ! -z "$*" -a -z "$tpm_missing" ]; then
	TMPFILE=/tmp/insmod.$$
	echo "$@" > $TMPFILE
	tpm extend -ix "$MODULE_PCR" -if $TMPFILE \
	|| die "$MODULE: tpm extend on arguments failed"
fi

# Since we have replaced the real insmod, we must invoke
# the busybox insmod via the original executable
busybox insmod "$MODULE" "$@" \
|| die "$MODULE: insmod failed"
