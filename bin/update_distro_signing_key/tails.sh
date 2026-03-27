#! /usr/bin/env bash
# Update the Tails distro signing key.
# See bin/update_distro_signing_key/helper.sh for details.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$SCRIPT_DIR/lib/helper.sh" \
	"Tails" \
	"https://tails.boum.org/tails-signing.key" \
	"tails@boum.org" \
	"initrd/etc/distro/keys/tails.key"
