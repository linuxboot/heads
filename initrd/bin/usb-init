#!/bin/sh
# Boot a USB installation

. /etc/functions
. /tmp/config

if [ "$CONFIG_TPM" = "y" ]; then
	# Extend PCR4 as soon as possible
	tpm extend -ix 4 -ic usb
fi

usb-scan
recovery "Something failed during USB boot"
