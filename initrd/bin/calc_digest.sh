#! /bin/bash

set -eo pipefail

ARG_ZERO=

if [ "$1" = "-z" ]; then
	ARG_ZERO=y
	shift
fi

if [ "$#" -lt 2 ]; then
	echo "usage: $0 [-z] <original-rom> <updated-rom>" >&2
	echo
	echo "Updates (or adds) rom_digest in the ROM."
	echo
	echo "By default, rom_digest is set to the ROM's SHA-256 digest (with"
	echo "rom_digest set to all-0)."
	echo
	echo "With -z, just zero rom_digest, so integrity can be checked."
	exit 1
fi

ORIGINAL_ROM="$1"
UPDATED_ROM="$2"

cp "$ORIGINAL_ROM" "$UPDATED_ROM"
dd if=/dev/zero bs=32 count=1 of=/tmp/digest.bin status=none

# Ensure there is a zeroed rom_digest file, but don't delete any existing file
if ! cbfs -l -o "$UPDATED_ROM" | grep -q '^rom_digest$'; then
	# Add the file
	cbfs -a rom_digest -o "$UPDATED_ROM" -f /tmp/digest.bin
else
	# Replace the file content
	cbfs -p rom_digest -o "$UPDATED_ROM" -f /tmp/digest.bin
fi

# If we are just zeroing the digest, we're done, otherwise calculate a digest
# and set it
if [ -z "$ARG_ZERO" ]; then
	DIGEST_HEX="$(sha256sum "$UPDATED_ROM" | cut -d\  -f1)"

	echo -n "$DIGEST_HEX" | xxd -p -r >/tmp/digest.bin
	cbfs -p rom_digest -o "$UPDATED_ROM" -f /tmp/digest.bin
fi
