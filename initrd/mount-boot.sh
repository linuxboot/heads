#!/bin/sh
# Extract the GPG signed dmsetup configuration from
# the header of the file system, validate it against
# the trusted key database, and execute it to mount
# the /boot filesystem

dev="$1"
offset="$2"

cmd=/tmp/mount-boot
cmd_sig="$cmd.asc"

if [ -z "$dev" ]; then
	dev=/dev/sda
fi

if [ -z "$offset" ]; then
	offset=256
fi

#
# Find the size of the device
# Is there a better way?
#
dev_size_file="/sys/class/block/`basename $dev`/size"
if [ ! -r "$dev_size_file" ]; then
	echo >&2 '!!!!!'
	echo >&2 '!!!!! $dev file $dev_size_file not found'
	echo >&2 '!!!!! Dropping to recovery shell'
	echo >&2 '!!!!!'
	exit -1
fi

dev_blocks=`cat "$dev_size_file"`

#
# Extract the signed file from the hard disk image
#
if ! dd if="$dev" of="$cmd_sig" bs=512 skip="`expr $dev_blocks - 1`"; then
	echo >&2 '!!!!!'
	echo >&2 '!!!!! Boot block extraction failed'
	echo >&2 '!!!!! Dropping to recovery shell'
	echo >&2 '!!!!!'
	exit -1
fi

#
# Validate the file
#
if ! gpgv --keyring /trustedkeys.gpg "$cmd_sig"; then
	echo >&2 '!!!!!'
	echo >&2 '!!!!! GPG signature on block failed'
	echo >&2 '!!!!! Dropping to recovery shell'
	echo >&2 '!!!!!'
	exit -1
fi

#
# Strip the PGP signature off the file
# (too bad gpgv doesn't do this)
#
awk < "$cmd_sig" > "$cmd" '
	/BEGIN PGP SIGNATURE/ { exit };
	do_print {print};
	/^$/ { do_print=1 };
'

#
# And execute it!
#
sh -x "$cmd"
