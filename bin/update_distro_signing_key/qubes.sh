#! /usr/bin/env bash
# Update all Qubes OS distro signing keys (release 4.2, 4.3, weekly builds).
# See bin/update_distro_signing_key/lib/helper.sh for details.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/lib/helper.sh"

rc=0
first=yes
# Every channel always runs and the highest status wins: Qubes rotates all
# three channels together, so no single channel may veto the next.
run() {
	local e=0
	# Separate the per-key report blocks; the first channel gets no separator,
	# whatever ran before it already left one.
	if [ "$first" != yes ]; then
		echo ""
	fi
	first=no
	"$HELPER" "$@" || e=$?
	if [ "$e" -gt "$rc" ]; then
		rc="$e"
	fi
	return 0
}

# Each key's fingerprint is declared directly above its own run, so no
# invocation can pick up another channel's pin.
FPR_42="9C884DF3F81064A569A4A9FAE022E58F8E34D89F"
run "Qubes OS 4.2" \
	"https://keys.qubes-os.org/keys/qubes-release-4.2-signing-key.asc" \
	"Qubes OS Release 4.2 Signing Key" \
	"initrd/etc/distro/keys/qubes-4.2.key" \
	"$FPR_42"

FPR_43="F3FA3F99D6281F7B3A3E5E871C3D9B627F3FADA4"
run "Qubes OS 4.3" \
	"https://keys.qubes-os.org/keys/qubes-release-4.3-signing-key.asc" \
	"Qubes OS Release 4.3 Signing Key" \
	"initrd/etc/distro/keys/qubes-4.3.key" \
	"$FPR_43"

FPR_WEEKLY="9B7E61D3BB70C4B1335CE5B67B72A119CCCA57BB"
run "Qubes OS weekly builds" \
	"https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x9B7E61D3BB70C4B1335CE5B67B72A119CCCA57BB" \
	"Qubes OS Weekly Builds Signing Key" \
	"initrd/etc/distro/keys/qubes-weekly-builds-signing-key.asc" \
	"$FPR_WEEKLY"

exit "$rc"
