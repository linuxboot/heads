#! /usr/bin/env bash
# Update the Tails distro signing key.
# See bin/update_distro_signing_key/lib/helper.sh for details.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FPR="A490D0F4D311A4153E2BB7CADBB802B258ACD84F"

exec "$SCRIPT_DIR/lib/helper.sh" \
	"Tails" \
	"https://tails.net/tails-signing.key" \
	"tails@tails.net" \
	"initrd/etc/distro/keys/tails.key" \
	"$FPR"
