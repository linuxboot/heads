#!/bin/bash
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

TRACE_FUNC

# Shut down TPM
if [ "$CONFIG_TPM" = "y" ]; then
	tpmr.sh shutdown
fi

# Sync all mounted filesystems
echo s > /proc/sysrq-trigger

# Remount all mounted filesystems in read-only mode
echo u > /proc/sysrq-trigger

# Shut off the system
echo o > /proc/sysrq-trigger
