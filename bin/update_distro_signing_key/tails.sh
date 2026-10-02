#! /usr/bin/env bash
# Update the Tails distro signing key.
# See bin/update_distro_signing_key/helper.sh for details.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$SCRIPT_DIR/lib/helper.sh" \
	"Tails" \
	"https://tails.net/tails-signing.key" \
	"tails@tails.net" \
	"initrd/etc/distro/keys/tails.key"
