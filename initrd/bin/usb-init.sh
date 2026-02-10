#!/bin/bash
# Boot a USB installation

# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh
# shellcheck disable=SC1091
. /tmp/config

TRACE_FUNC

if [ "$CONFIG_TPM" = "y" ]; then
	# Extend PCR4 as soon as possible
	tpmr.sh extend -ix 4 -ic usb
fi

DO_WITH_DEBUG media-scan.sh usb
recovery "Something failed during USB boot"
