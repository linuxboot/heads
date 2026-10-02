#! /usr/bin/env bash
# Update the Kicksecure distro signing key (Patrick Schleizer).
# See bin/update_distro_signing_key/helper.sh for details.
#
# Key fingerprint: 916B 8D99 C38E AF5E 8ADC  7A2A 8D66 066A 2EEA CCDA

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$SCRIPT_DIR/lib/helper.sh" \
	"Kicksecure" \
	"https://www.kicksecure.com/keys/derivative.asc" \
	"adrelanos@kicksecure.com" \
	"initrd/etc/distro/keys/kicksecure.key"