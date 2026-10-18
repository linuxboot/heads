#! /usr/bin/env bash
# Update the Kicksecure distro signing key (Patrick Schleizer).
# See bin/update_distro_signing_key/lib/helper.sh for details.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FPR="916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA"

exec "$SCRIPT_DIR/lib/helper.sh" \
	"Kicksecure" \
	"https://www.kicksecure.com/keys/derivative.asc" \
	"adrelanos@kicksecure.com" \
	"initrd/etc/distro/keys/kicksecure.key" \
	"$FPR"
