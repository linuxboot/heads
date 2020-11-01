#!/bin/bash
# Boot a USB installation

. /etc/functions.sh
. /tmp/config

if [ "$CONFIG_TPM" = "y" ]; then
	# Extend PCR4 as soon as possible
	tpm extend -ix 4 -ic usb
fi

/bin/usb-scan.sh
recovery "Something failed during USB boot"
