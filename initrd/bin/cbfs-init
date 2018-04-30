#!/bin/ash
set -e -o pipefail
. /etc/functions

# Update initrd with CBFS files
if [ -z "$CONFIG_PCR" ]; then
	CONFIG_PCR=7
fi

# Load individual files
cbfsfiles=`cbfs -t 50 -l 2>/dev/null | grep "^heads/initrd/"`

for cbfsname in `echo $cbfsfiles`; do
	filename=${cbfsname:12}
	if [ ! -z "$filename" ]; then
		echo "Loading $filename from CBFS"
		mkdir -p `dirname $filename` \
		|| die "$filename: mkdir failed"
		cbfs -t 50 -r $cbfsname > "$filename" \
		|| die "$filename: cbfs file read failed"
		if [ "$CONFIG_TPM" = "y" ]; then
			TMPFILE=/tmp/cbfs.$$
			echo "$filename" > $TMPFILE
			cat $filename >> $TMPFILE
			tpm extend -ix "$CONFIG_PCR" -if $TMPFILE \
			|| die "$filename: tpm extend failed"
		fi
	fi
done

# TODO: copy CBFS file named "heads/initrd.tgz" to /tmp, measure and extract
