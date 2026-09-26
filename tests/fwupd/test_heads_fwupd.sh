#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/heads-fwupd-test.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

guid="0617fcc9-0266-5650-964b-8d8deb52d992"
board="qemu-coreboot-fbwhiptail-tpm2-fwupd"

mkdir -p "$tmpdir/gnupg" "$tmpdir/package"
chmod 700 "$tmpdir/gnupg"
GNUPGHOME="$tmpdir/gnupg" gpg --batch --passphrase '' \
	--quick-generate-key 'Heads fwupd test <heads-fwupd@example.invalid>' rsa2048 sign 0 >/dev/null 2>&1
GNUPGHOME="$tmpdir/gnupg" gpg --batch --export >"$tmpdir/vendor.gpg"

cat >"$tmpdir/functions.sh" <<'EOF'
STATUS() { :; }
STATUS_OK() { :; }
ERROR() { echo "$*" >&2; }
EOF

cat >"$tmpdir/config" <<EOF
CONFIG_BOARD=$board
CONFIG_HEADS_FWUPD_CAPSULE_GUID=$guid
CONFIG_HEADS_FWUPD_GENERATION=7
CONFIG_HEADS_FWUPD_MAX_CAPSULE_SIZE=20971520
CONFIG_HEADS_FWUPD_MAX_ROM_SIZE=16777216
CONFIG_HEADS_FWUPD_REBOOT=n
EOF

cat >"$tmpdir/writer" <<EOF
#!/bin/sh
sha256sum "\$1" >"$tmpdir/written.sha256"
EOF
chmod +x "$tmpdir/writer"

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

make_capsule() {
	local generation=$1
	local manifest_guid=$2
	local manifest_board=$3
	local output=$4
	local tamper_manifest=${5:-n}
	local rom_size rom_hash payload_size image_size

	rm -rf "$tmpdir/package"
	mkdir "$tmpdir/package"
	printf 'deterministic test firmware\n' >"$tmpdir/package/firmware.rom"
	rom_size=$(wc -c <"$tmpdir/package/firmware.rom")
	rom_hash=$(sha256sum "$tmpdir/package/firmware.rom" | awk '{print $1}')
	cat >"$tmpdir/package/manifest" <<EOF
format=1
guid=$manifest_guid
board=$manifest_board
generation=$generation
version=test-$generation
size=$rom_size
sha256=$rom_hash
EOF
	GNUPGHOME="$tmpdir/gnupg" gpg --batch --yes --armor --detach-sign \
		-o "$tmpdir/package/manifest.asc" "$tmpdir/package/manifest"
	if [ "$tamper_manifest" = "y" ]; then
		sed -i 's/^version=.*/version=tampered/' "$tmpdir/package/manifest"
	fi
	tar -C "$tmpdir/package" -cf "$tmpdir/payload.tar" firmware.rom manifest manifest.asc
	payload_size=$(wc -c <"$tmpdir/payload.tar")
	image_size=$((28 + payload_size))
	{
		printf '%s' "$(guid_to_efi_hex "$guid")$(le32 28)$(le32 0)$(le32 "$image_size")" | xxd -r -p
		cat "$tmpdir/payload.tar"
	} >"$output"
}

run_consumer() {
	HEADS_FWUPD_FUNCTIONS_SH="$tmpdir/functions.sh" \
	HEADS_FWUPD_CONFIG_SH="$tmpdir/config" \
		"$repo_root/initrd/bin/heads-fwupd.sh" \
		--capsule "$1" --keyring "$tmpdir/vendor.gpg" \
		--writer "$tmpdir/writer" --assume-yes --keep
}

make_capsule 8 "$guid" "$board" "$tmpdir/valid.cap"
run_consumer "$tmpdir/valid.cap"
test -s "$tmpdir/written.sha256"

rm -f "$tmpdir/written.sha256"
sed -i 's/^CONFIG_HEADS_FWUPD_MAX_CAPSULE_SIZE=.*/CONFIG_HEADS_FWUPD_MAX_CAPSULE_SIZE=1024/' \
	"$tmpdir/config"
if run_consumer "$tmpdir/valid.cap"; then
	echo "Oversized capsule was accepted" >&2
	exit 1
fi
test ! -e "$tmpdir/written.sha256"
sed -i 's/^CONFIG_HEADS_FWUPD_MAX_CAPSULE_SIZE=.*/CONFIG_HEADS_FWUPD_MAX_CAPSULE_SIZE=20971520/' \
	"$tmpdir/config"

make_capsule 7 "$guid" "$board" "$tmpdir/rollback.cap"
if run_consumer "$tmpdir/rollback.cap"; then
	echo "Rollback capsule was accepted" >&2
	exit 1
fi
test ! -e "$tmpdir/written.sha256"

make_capsule 8 "0d063fe8-e15d-5a25-b09e-1445568ee097" "$board" "$tmpdir/wrong-guid.cap"
if run_consumer "$tmpdir/wrong-guid.cap"; then
	echo "Wrong manifest GUID was accepted" >&2
	exit 1
fi

make_capsule 8 "$guid" "another_board" "$tmpdir/wrong-board.cap"
if run_consumer "$tmpdir/wrong-board.cap"; then
	echo "Wrong board was accepted" >&2
	exit 1
fi

make_capsule 8 "$guid" "$board" "$tmpdir/bad-signature.cap" y
if run_consumer "$tmpdir/bad-signature.cap"; then
	echo "Capsule with a tampered manifest was accepted" >&2
	exit 1
fi

cp "$tmpdir/valid.cap" "$tmpdir/wrong-header-guid.cap"
printf '\000' | dd of="$tmpdir/wrong-header-guid.cap" bs=1 seek=0 conv=notrunc status=none
if run_consumer "$tmpdir/wrong-header-guid.cap"; then
	echo "Wrong capsule-header GUID was accepted" >&2
	exit 1
fi

cp "$tmpdir/valid.cap" "$tmpdir/malformed.cap"
printf '\377\377\377\177' | dd of="$tmpdir/malformed.cap" bs=1 seek=16 conv=notrunc status=none
if run_consumer "$tmpdir/malformed.cap"; then
	echo "Malformed capsule was accepted" >&2
	exit 1
fi

echo "Heads fwupd capsule tests passed"
