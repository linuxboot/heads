#!/bin/sh

# Sync all mounted filesystems
echo s > /proc/sysrq-trigger

# Remount all mounted filesystems in read-only mode
echo u > /proc/sysrq-trigger

# Immediately reboot the system, without unmounting or syncing filesystems
echo b > /proc/sysrq-trigger
