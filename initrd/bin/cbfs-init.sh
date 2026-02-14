#!/bin/bash
set -e -o pipefail
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

# CBFS extraction and measurement
#  This extraction and measurement cannot be suppressed by quiet mode, since 
#   config.user is not yet loaded at this point.
#  To suppress this output, set CONFIG_QUIET_MODE=y needs be be set in /etc/config
#   which is defined at build time under board configuration file to be part of initrd.cpio
#  This script is called from initrd/init so really early in the boot process to put files in place in initramfs

TRACE_FUNC

# Update initrd with CBFS files
if [ -z "$CONFIG_PCR" ]; then
	CONFIG_PCR=7
fi

DEBUG "CONFIG_CBFS_VIA_FLASHPROG='$CONFIG_CBFS_VIA_FLASHPROG'"

if [ "$CONFIG_CBFS_VIA_FLASHPROG" = "y" ]; then
	# Use flashrom directly, because we don't have /tmp/config with params for flash.sh yet
	/bin/flashprog -p internal --fmap -i COREBOOT -i FMAP -r /tmp/cbfs-init.rom \
		&& CBFS_ARG="-o /tmp/cbfs-init.rom" \
		|| echo "Failed reading Heads configuration from flash! Some features may not be available."
fi

DEBUG "CBFS_ARG='$CBFS_ARG'"

# Load individual files
# shellcheck disable=SC2086
cbfsfiles=$(cbfs -t 50 $CBFS_ARG -l 2>/dev/null | grep "^heads/initrd/")
DEBUG "cbfsfiles='$cbfsfiles'"

for cbfsname in $cbfsfiles; do
	filename=${cbfsname:12}
	if [ -n "$filename" ]; then
		mkdir -p "$(dirname "$filename")" \
		|| die "$filename: mkdir failed"
		INFO "Extracting CBFS file $cbfsname into $filename"
		# shellcheck disable=SC2086
		cbfs -t 50 $CBFS_ARG -r "$cbfsname" > "$filename" \
		|| die "$filename: cbfs file read failed"
		DEBUG "Extracted $cbfsname to $filename"
		if [ "$CONFIG_TPM" = "y" ]; then
			TRACE_FUNC
			INFO "TPM: Extending PCR[$CONFIG_PCR] with filename $filename and then its content"
			# Measure both the filename and its content.  This
			# ensures that renaming files or pivoting file content
			# will still affect the resulting PCR measurement.
			tpmr.sh extend -ix "$CONFIG_PCR" -ic "$filename"
			tpmr.sh extend -ix "$CONFIG_PCR" -if "$filename" \
			|| die "$filename: tpm extend failed"
		fi
	fi
done
