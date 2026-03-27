#! /usr/bin/env bash
# Update the Arch Linux distro signing key (Pierre Schmitz, release engineer).
# See bin/update_distro_signing_key/helper.sh for details.
#
# Key fingerprint: 3E80 CA1A 8B89 F69C BA57  D98A 76A5 EF90 5444 9A5C

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$SCRIPT_DIR/lib/helper.sh" \
	"Arch Linux" \
	"https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C" \
	"pierre@archlinux.org" \
	"initrd/etc/distro/keys/archlinux.key"
