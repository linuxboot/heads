#!/bin/ash
set -e -o pipefail
. /etc/functions

# Update initrd with CBFS files
if [ -z "$CONFIG_PCR" ]; then
	CONFIG_PCR=7
fi

CONFIG_GUID="74696e69-6472-632e-7069-6f2f75736572"

# copy EFI file named $CONFIG_GUID to /tmp, measure and extract
GUID=`uefi -l | grep "^$CONFIG_GUID"`

if [ -n "GUID" ]; then
	echo "Loading $GUID from ROM"
	TMPFILE=/tmp/uefi.$$
	uefi -r $GUID | gunzip -c > $TMPFILE \
	|| die "Failed to read config GUID from ROM"

	if [ "$CONFIG_TPM" = "y" ]; then
		tpm extend -ix "$CONFIG_PCR" -if $TMPFILE \
		|| die "$filename: tpm extend failed"
	fi

	( cd / ; cpio -iud < $TMPFILE 2>/dev/null ) \
	|| die "Failed to extract config GUID"
fi
