#! /bin/bash

set -eo pipefail

if [ "$#" -lt 1 ]; then
	echo "usage: $0 <rom>" >&2
	echo
	echo "Checks the integrity of the specified ROM using the embedded"
	echo "SHA-256 digest in rom_digest."
	echo
	echo "If the digest is found, prints one of the following:"
	echo " OK - The digest matches the ROM."
	echo " Corrupt - The digest does not match the ROM."
	echo
	echo "If the integrity check can't be performed (no digest, or it"
	echo "can't be read, etc.), the script fails."
	exit 1
fi

ROM="$(realpath "$1")"

cd "$(dirname "${BASH_SOURCE[0]}")"

# If there is no digest, this causes the script to fail via set -e.
DIGEST_HEX="$(cbfs -o "$ROM" -r rom_digest | xxd -p | tr -d ' \n')"

calc_digest.sh -z "$ROM" "/tmp/verify-digest.tmp"

if echo "$DIGEST_HEX  /tmp/verify-digest.tmp" | sha256sum -c; then
	echo "OK"
else
	echo "Corrupt"
fi
