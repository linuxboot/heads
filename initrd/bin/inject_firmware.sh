#!/bin/bash

# If blob jail is enabled, copy initrd and inject firmware.
# Prints new initrd path (in memory) if firmware was injected.
#
# This does not alter the initrd on disk:
# * Signatures are not invalidated
# * If the injection fails for any reason, we just proceed with the original
#   initrd (lacking firmware, but still booting).
# * If, somehow, this injection malfunctions (without failing outright) and
#   prevents a boot, the user can work around it just by disabling blob jail.
#   We do not risk ruining the real initrd.
#
# The injection has some requirements on the initrd that are all true for
# Debian:
# * initrd must be a gzipped cpio (Linux supports other compression methods)
# * /init must be a shell script (so we can inject a command to copy firmware)
# * There must be an 'exec run-init ... ${rootmnt} ...' line that moves the
#   real root to / and invokes init
#
# If the injection can't be performed, boot will continue with no firmware.

set -e -o pipefail

. /tmp/config
. /etc/functions

if [ "$(load_config_value CONFIG_USE_BLOB_JAIL)" != "y" ]; then
	# Blob jail not active, nothing to do
	exit 0
fi

ORIG_INITRD="$1"

# Extract the init script from the initrd
INITRD_ROOT="/tmp/inject_firmware_initrd_root"
rm -rf "$INITRD_ROOT" || true
mkdir "$INITRD_ROOT"
# Unpack just 'init' from the original initrd
unpack_initramfs.sh "$ORIG_INITRD" "$INITRD_ROOT" init

# Copy the firmware into the initrd
for f in $(cbfs -l | grep firmware); do
	mkdir -p "$INITRD_ROOT/$(dirname "$f")"
	cbfs -r "$f" > "$INITRD_ROOT/$f"
	if [[ "$f" == *.lzma ]]; then
		lzma -d "$INITRD_ROOT/$f"
	fi
done

# awk will happily pass through a binary file, so look for the match we want
# before modifying init to ensure it's a shell script and not an ELF, etc.
if ! grep -E -q '^exec run-init .*\$\{rootmnt\}' "$INITRD_ROOT/init"; then
	warn "Can't apply firmware blob jail, unknown init script"
	exit 0
fi

# In general, firmware files must be available _both_ during the initrd _and_
# once root is moved to /.  Firmware loading may happen in either phase (e.g.
# i915 GUC firmware is usually loaded in the initrd because i915 is used there,
# but Wi-Fi/BT modules typically are not in the initrd, they're loaded later).
#
# We want to place the firmware after boot in /run, since this is a tmpfs mount
# - it works even if the root filesystem is read-only and does not persist
# anything.  But we cannot place it there for the initrd, since the initrd also
# mounts a tmpfs on /run.  We can only specify one custom firmware path, but we
# can change it at runtime.
#
# So during the initrd, the firmware is in /firmware, and we provide that path
# on the kernel command line.  Just before invoking the real init (after root is
# mounted), we copy it to /run/firmware and also change the firmware path.
#
# Debian's init script ends with an "exec run-init ..." (followed by a few lines
# to print a message in case it fails).  At that point, root is mounted, and
# run-init will move it to / and then exec init.  We can insert the firmware
# actions just before that, so we don't have to know anything about how root was
# mounted.
#
# The root path is in ${rootmnt}, which should appear in the run-init command.
# If it doesn't, then we don't understand the init script.
AWK_INSERT_CP='
BEGIN{inserted=0}
/^exec run-init .*\$\{rootmnt\}/ && inserted==0 {
	print "cp -r /firmware ${rootmnt}/run/firmware"
	print "echo -n /run/firmware >${rootmnt}/sys/module/firmware_class/parameters/path"
	inserted=1
}
{print $0}'

awk -e "$AWK_INSERT_CP" "$INITRD_ROOT/init" >"$INITRD_ROOT/init_fw"
mv "$INITRD_ROOT/init_fw" "$INITRD_ROOT/init"
chmod a+x "$INITRD_ROOT/init"

# Pad the original initrd to 512 byte blocks.  Uncompressed cpio contents must
# be 4-byte aligned, and anecdotally gzip frames might not be padded by dracut.
# Linux ignores zeros between archive segments, so any extra padding is not
# harmful.
FW_INITRD="/tmp/inject_firmware_initrd.cpio.gz"
dd if="$ORIG_INITRD" of="$FW_INITRD" bs=512 conv=sync status=none > /dev/null 2>&1
# Pack up the new contents and append to the initrd.  Don't spend time
# compressing this.
(cd "$INITRD_ROOT"; find . | cpio -o -H newc) >>"$FW_INITRD"
# Use this initrd
echo "$FW_INITRD"
