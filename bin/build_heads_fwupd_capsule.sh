#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

rom=""
guid=""
board=""
generation=""
version=""
output=""
local_user=""

usage() {
	cat <<EOF
Usage: $0 --rom FILE --guid GUID --board BOARD --generation N --version VERSION
          --output FILE [--local-user GPG_KEY]
EOF
}

while (($#)); do
	case "$1" in
	--rom)
		rom=$2
		shift 2
		;;
	--guid)
		guid=$2
		shift 2
		;;
	--board)
		board=$2
		shift 2
		;;
	--generation)
		generation=$2
		shift 2
		;;
	--version)
		version=$2
		shift 2
		;;
	--output)
		output=$2
		shift 2
		;;
	--local-user)
		local_user=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

[ -s "$rom" ] || { echo "ROM is missing or empty" >&2; exit 1; }
[[ $guid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
	echo "GUID must be a lowercase canonical GUID" >&2
	exit 1
}
[[ $board =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Board name is invalid" >&2; exit 1; }
[[ $generation =~ ^[0-9]+$ ]] || { echo "Generation must be an integer" >&2; exit 1; }
[ -n "$version" ] || { echo "Version is required" >&2; exit 1; }
[ -n "$output" ] || { echo "Output path is required" >&2; exit 1; }

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/heads-fwupd-capsule.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

cp "$rom" "$tmpdir/firmware.rom"
rom_size=$(wc -c <"$tmpdir/firmware.rom" | tr -d ' ')
rom_sha256=$(sha256sum "$tmpdir/firmware.rom" | awk '{print $1}')
cat >"$tmpdir/manifest" <<EOF
format=1
guid=$guid
board=$board
generation=$generation
version=$version
size=$rom_size
sha256=$rom_sha256
EOF

gpg_args=(--batch --yes --armor --detach-sign --output "$tmpdir/manifest.asc")
if [ -n "$local_user" ]; then
	gpg_args+=(--local-user "$local_user")
fi
gpg "${gpg_args[@]}" "$tmpdir/manifest"

tar -C "$tmpdir" -cf "$tmpdir/payload.tar" firmware.rom manifest manifest.asc
payload_size=$(wc -c <"$tmpdir/payload.tar" | tr -d ' ')
image_size=$((28 + payload_size))

guid_to_efi_hex() {
	local compact=${1//-/}
	printf '%s%s%s%s' \
		"${compact:6:2}${compact:4:2}${compact:2:2}${compact:0:2}" \
		"${compact:10:2}${compact:8:2}" \
		"${compact:14:2}${compact:12:2}" \
		"${compact:16}"
}

le32() {
	local hex
	printf -v hex '%08x' "$1"
	printf '%s' "${hex:6:2}${hex:4:2}${hex:2:2}${hex:0:2}"
}

{
	printf '%s' "$(guid_to_efi_hex "$guid")$(le32 28)$(le32 0)$(le32 "$image_size")" | xxd -r -p
	cat "$tmpdir/payload.tar"
} >"$output"

echo "$output"
