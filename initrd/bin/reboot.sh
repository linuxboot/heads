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

# If debug output is enabled, give the user an opportunity to stop and
# enter a recovery shell. Accept 'r' or 'R' to enter recovery, any other
# key continues to the final reboot.
if [ "$CONFIG_DEBUG_OUTPUT" = "y" ]; then
	read -r -n 1 -s -p "Press any key to continue reboot or 'r' to go to recovery shell: " REPLY
	echo
	if [ "$REPLY" = "r" ] || [ "$REPLY" = "R" ]; then
		recovery "Reboot call bypassed to go into recovery shell to debug"
	fi
	DEBUG "DEBUG: TPM shutdown and filesystem operations complete"
	read -r -p "Press Enter to issue final reboot syscall: "
fi

# Use busybox reboot explicitly (symlinks removed to avoid conflicts)
if busybox --help 2>&1 | grep -q reboot; then
	DEBUG "Using busybox reboot syscall for orderly shutdown"
	INFO "Rebooting with busybox reboot..."
	sleep 1
	busybox reboot -f
else
	# Fallback to sysrq if busybox doesn't have reboot support
	DEBUG "Busybox reboot not available, falling back to sysrq"
	INFO "Rebooting through 'echo b > /proc/sysrq-trigger'..."
	sleep 1
	echo b > /proc/sysrq-trigger
fi
