#!/bin/bash
set -e -o pipefail
. /etc/functions.sh

# Board key and configuration injection from CBFS
#  At build time, board-specific trusted keys, certificates, and configuration
#  are injected into the firmware CBFS (heads/initrd/ namespace).  cbfs-init
#  extracts these into the running initramfs and measures each file into the
#  TPM to establish the board's trust chain before anything else runs.
#
#  cbfs-init runs before config.user is extracted and merged into /tmp/config,
#  so logging here is governed by the board build-time /etc/config only.
#  STATUS and STATUS_OK are always visible regardless of CONFIG_QUIET_MODE and
#  are used for the summary bracket so the user always sees progress.
#  Per-file detail is at DEBUG level (developer-facing).
#  INFO calls (TPM PCR measurements) are suppressed in quiet mode - that is
#  intentional, since quiet boards have CONFIG_QUIET_MODE=y in /etc/config.

TRACE_FUNC

# Update initrd with CBFS files
if [ -z "$CONFIG_PCR" ]; then
	CONFIG_PCR=7
fi

if [ "$CONFIG_CBFS_VIA_FLASHPROG" = "y" ]; then
	# Workaround: cbfs cannot read CBFS directly on rom_hole boards
	# See: https://github.com/osresearch/flashtools/issues/10
	STATUS "Reading SPI flash with flashprog (rom_hole workaround)..."
	if /bin/flashprog -p internal --fmap -i COREBOOT -i FMAP -r /tmp/cbfs-init.rom; then
		CBFS_ARG=" -o /tmp/cbfs-init.rom"
		STATUS_OK "ROM read"
	else
		WARN "Failed to read board keys and configuration from SPI flash - some features may not be available"
	fi
fi

# Load individual files
cbfsfiles=`cbfs -t 50 -l $CBFS_ARG 2>/dev/null | grep "^heads/initrd/"`

STATUS "Extracting GPG keyring, trustdb, and board configuration from firmware"
for cbfsname in `echo $cbfsfiles`; do
	filename=${cbfsname:12}
	if [ ! -z "$filename" ]; then
		mkdir -p `dirname $filename` \
		|| DIE "$filename: mkdir failed"
		DEBUG "Extracting $cbfsname from firmware CBFS"
		cbfs -t 50 $CBFS_ARG -r $cbfsname > "$filename" \
		|| DIE "$filename: cbfs file read failed"
		if [ "$CONFIG_TPM" = "y" ]; then
			TRACE_FUNC
			# Measure both the filename and its content.  This
			# ensures that renaming files or pivoting file content
			# will still affect the resulting PCR measurement.
			tpmr.sh extend -ix "$CONFIG_PCR" -ic "$filename"
			tpmr.sh extend -ix "$CONFIG_PCR" -if "$filename" \
			|| DIE "$filename: tpm extend failed"
		fi
	fi
done
STATUS_OK "GPG keyring, trustdb, and board configuration extracted from firmware"
