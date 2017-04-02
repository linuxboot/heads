#!/bin/sh
# Measure all of the luks disk encryption headers into
# a PCR so that we can detect disk swap attacks.

die() { echo >&2 "$@"; exit 1; }

# Measure the luks headers into PCR 6
for dev in "$@"; do
	cryptsetup luksDump $dev \
	|| die "$dev: Unable to measure"
done > /tmp/luksDump.txt

tpm extend -ix 6 -if /tmp/luksDump.txt \
|| die "Unable to extend PCR"
