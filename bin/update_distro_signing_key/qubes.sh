#! /usr/bin/env bash
# Update all Qubes OS distro signing keys (release 4.2, 4.3, weekly builds).
# See bin/update_distro_signing_key/helper.sh for details.
#
# Key fingerprints:
#   Qubes 4.2:      9C88 4DF3 F810 64A5 69A4  A9FA E022 E58F 8E34 D89F
#   Qubes 4.3:      F3FA 3F99 D628 1F7B 3A3E  5E87 1C3D 9B62 7F3F ADA4
#   Qubes weekly:   9B7E 61D3 BB70 C4B1 335C  E5B6 7B72 A119 CCCA 57BB

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/lib/helper.sh"

rc=0
run() { "$HELPER" "$@" || { local e=$?; [ $e -gt $rc ] && rc=$e; }; }

run "Qubes OS 4.2" \
	"https://keys.qubes-os.org/keys/qubes-release-4.2-signing-key.asc" \
	"Qubes OS Release 4.2 Signing Key" \
	"initrd/etc/distro/keys/qubes-4.2.key"

run "Qubes OS 4.3" \
	"https://keys.qubes-os.org/keys/qubes-release-4.3-signing-key.asc" \
	"Qubes OS Release 4.3 Signing Key" \
	"initrd/etc/distro/keys/qubes-4.3.key"

run "Qubes OS weekly builds" \
	"https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x9B7E61D3BB70C4B1335CE5B67B72A119CCCA57BB" \
	"Qubes OS Weekly Builds Signing Key" \
	"initrd/etc/distro/keys/qubes-weekly-builds-signing-key.asc"

exit "$rc"
