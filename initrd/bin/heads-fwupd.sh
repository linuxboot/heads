#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -e -o pipefail

# shellcheck source=/dev/null
. "${HEADS_FWUPD_FUNCTIONS_SH:-/etc/functions.sh}"
# shellcheck source=/dev/null
. "${HEADS_FWUPD_CONFIG_SH:-/tmp/config}"

CAPSULE=""
KEYRING="${CONFIG_HEADS_FWUPD_VENDOR_KEYRING:-/etc/heads-fwupd-vendor.gpg}"
WRITER="${CONFIG_HEADS_FWUPD_WRITER:-/bin/flash.sh}"
ASSUME_YES="${HEADS_FWUPD_ASSUME_YES:-${CONFIG_HEADS_FWUPD_ASSUME_YES:-n}}"
MAX_CAPSULE_SIZE="${CONFIG_HEADS_FWUPD_MAX_CAPSULE_SIZE:-}"
MAX_ROM_SIZE="${CONFIG_HEADS_FWUPD_MAX_ROM_SIZE:-}"
REBOOT="${CONFIG_HEADS_FWUPD_REBOOT:-y}"
KEEP_CAPSULE="n"
SOURCE_DEVICE=""
SOURCE_RELATIVE=""
SOURCE_ACTIVE_RELATIVE=""
QUARANTINE_ON_FAILURE="n"
WORKDIR="${TMPDIR:-/tmp}/heads-fwupd"
LOCKDIR="${TMPDIR:-/tmp}/heads-fwupd.lock"

fail() {
	if [ "$QUARANTINE_ON_FAILURE" = "y" ]; then
		QUARANTINE_ON_FAILURE="n"
		quarantine_capsule ||
			ERROR "Could not quarantine the rejected firmware update"
	fi
	ERROR "Heads firmware update rejected: $*"
	return 1
}

cleanup() {
	if grep -qs " $WORKDIR/esp " /proc/mounts; then
		if ! umount "$WORKDIR/esp" 2>/dev/null; then
			ERROR "Could not unmount the firmware update ESP; leaving the work directory intact"
			return
		fi
	fi
	rm -rf "$WORKDIR"
	rmdir "$LOCKDIR" 2>/dev/null || true
}

usage() {
	echo "Usage: $0 [--capsule FILE] [--keyring FILE] [--writer FILE] [--assume-yes] [--keep]"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--capsule)
		CAPSULE="$2"
		shift 2
		;;
	--keyring)
		KEYRING="$2"
		shift 2
		;;
	--writer)
		WRITER="$2"
		shift 2
		;;
	--assume-yes)
		ASSUME_YES="y"
		shift
		;;
	--keep)
		KEEP_CAPSULE="y"
		shift
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

EXPECTED_GUID="${CONFIG_HEADS_FWUPD_CAPSULE_GUID:-}"
CURRENT_GENERATION="${CONFIG_HEADS_FWUPD_GENERATION:-}"

[ -n "$EXPECTED_GUID" ] || fail "no capsule GUID is configured"
[ -n "$CURRENT_GENERATION" ] || fail "no firmware generation is configured"
[ -n "$MAX_CAPSULE_SIZE" ] || fail "no maximum capsule size is configured"
[ -n "$MAX_ROM_SIZE" ] || fail "no maximum firmware size is configured"
case "$CURRENT_GENERATION:$MAX_CAPSULE_SIZE:$MAX_ROM_SIZE" in
*[!0-9:]* | *::* | :*) fail "configured size or generation is invalid" ;;
esac
[ "$MAX_CAPSULE_SIZE" -gt 0 ] || fail "maximum capsule size is invalid"
[ "$MAX_ROM_SIZE" -gt 0 ] || fail "maximum firmware size is invalid"
case "$REBOOT" in
y | n) ;;
*) fail "firmware update reboot policy is invalid" ;;
esac
[ -r "$KEYRING" ] || fail "vendor keyring is unavailable"
[ -x "$WRITER" ] || fail "firmware writer is unavailable"

mkdir "$LOCKDIR" 2>/dev/null || exit 0
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/esp" "$WORKDIR/package" "$WORKDIR/gnupg"
chmod 700 "$WORKDIR/gnupg"
trap cleanup EXIT INT TERM

quarantine_capsule() {
	local rejected

	[ -n "$SOURCE_DEVICE" ] || return 0
	rejected="${SOURCE_RELATIVE}.rejected"
	if ! mount -o rw "$SOURCE_DEVICE" "$WORKDIR/esp"; then
		return 1
	fi
	if ! mv -f "$WORKDIR/esp/$SOURCE_RELATIVE" "$WORKDIR/esp/$rejected"; then
		umount "$WORKDIR/esp" 2>/dev/null || true
		return 1
	fi
	sync
	umount "$WORKDIR/esp"
}

capsule_size() {
	local size

	size=$(wc -c <"$1" | tr -d ' ') || return 1
	case "$size" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s' "$size"
}

copy_capsule_from_esp() {
	local device="$1"
	local relative="EFI/UpdateCapsule/fwupd-${EXPECTED_GUID}.cap"
	local size

	if ! mount -o ro "$device" "$WORKDIR/esp" 2>/dev/null; then
		return 1
	fi
	if [ ! -f "$WORKDIR/esp/$relative" ]; then
		umount "$WORKDIR/esp" || return 2
		return 1
	fi
	size=$(capsule_size "$WORKDIR/esp/$relative") || {
		umount "$WORKDIR/esp" 2>/dev/null || true
		ERROR "Could not determine the staged capsule size"
		return 2
	}
	if [ "$size" -gt "$MAX_CAPSULE_SIZE" ]; then
		umount "$WORKDIR/esp" 2>/dev/null || true
		SOURCE_DEVICE="$device"
		SOURCE_RELATIVE="$relative"
		QUARANTINE_ON_FAILURE="y"
		fail "staged firmware capsule exceeds the configured size limit" || true
		return 2
	fi
	if ! cp "$WORKDIR/esp/$relative" "$WORKDIR/update.cap"; then
		umount "$WORKDIR/esp" 2>/dev/null || true
		ERROR "Could not copy the staged firmware capsule"
		return 2
	fi
	if ! umount "$WORKDIR/esp"; then
		ERROR "Could not unmount the firmware update ESP"
		return 2
	fi
	SOURCE_DEVICE="$device"
	SOURCE_RELATIVE="$relative"
	CAPSULE="$WORKDIR/update.cap"
}

find_capsule() {
	local device
	local found="n"

	for device in $(blkid 2>/dev/null | sed -n '/TYPE="vfat"/s/:.*//p'); do
		if copy_capsule_from_esp "$device"; then
			if [ "$found" = "y" ]; then
				ERROR "Heads firmware update rejected: more than one matching capsule was found"
				return 2
			fi
			found="y"
		else
			case "$?" in
			1) ;;
			*) return 2 ;;
			esac
		fi
	done
	[ "$found" = "y" ] || return 1
}

if [ -z "$CAPSULE" ]; then
	if find_capsule; then
		QUARANTINE_ON_FAILURE="y"
	else
		case "$?" in
		1) exit 0 ;;
		*) exit 1 ;;
		esac
	fi
else
	FILE_SIZE=$(capsule_size "$CAPSULE") || fail "capsule size could not be determined"
	[ "$FILE_SIZE" -le "$MAX_CAPSULE_SIZE" ] || fail "capsule exceeds the configured size limit"
	cp "$CAPSULE" "$WORKDIR/update.cap"
	CAPSULE="$WORKDIR/update.cap"
fi

[ -s "$CAPSULE" ] || fail "capsule is empty"

GUID_HEX=$(hexdump -v -n 16 -e '1/1 "%02x"' "$CAPSULE")
[ "${#GUID_HEX}" -eq 32 ] || fail "capsule GUID is truncated"
CAPSULE_GUID="${GUID_HEX:6:2}${GUID_HEX:4:2}${GUID_HEX:2:2}${GUID_HEX:0:2}"
CAPSULE_GUID="${CAPSULE_GUID}-${GUID_HEX:10:2}${GUID_HEX:8:2}"
CAPSULE_GUID="${CAPSULE_GUID}-${GUID_HEX:14:2}${GUID_HEX:12:2}"
CAPSULE_GUID="${CAPSULE_GUID}-${GUID_HEX:16:4}-${GUID_HEX:20:12}"
[ "$CAPSULE_GUID" = "$EXPECTED_GUID" ] || fail "capsule GUID does not match this board"

HEADER_SIZE=$(hexdump -v -s 16 -n 4 -e '1/4 "%u"' "$CAPSULE")
IMAGE_SIZE=$(hexdump -v -s 24 -n 4 -e '1/4 "%u"' "$CAPSULE")
FILE_SIZE=$(wc -c <"$CAPSULE" | tr -d ' ')
case "$HEADER_SIZE:$IMAGE_SIZE:$FILE_SIZE" in
*[!0-9:]* | ::*) fail "capsule size fields are invalid" ;;
esac
[ "$HEADER_SIZE" -ge 28 ] || fail "capsule header is too small"
[ "$HEADER_SIZE" -lt "$FILE_SIZE" ] || fail "capsule has no payload"
[ "$IMAGE_SIZE" -eq "$FILE_SIZE" ] || fail "capsule image size is incorrect"
[ "$FILE_SIZE" -le "$MAX_CAPSULE_SIZE" ] || fail "capsule exceeds the configured size limit"

tail -c "+$((HEADER_SIZE + 1))" "$CAPSULE" >"$WORKDIR/payload.tar" ||
	fail "capsule payload could not be read"
PACKAGE_LIST=$(tar -tf "$WORKDIR/payload.tar" | LC_ALL=C sort)
EXPECTED_LIST=$(printf '%s\n' firmware.rom manifest manifest.asc | LC_ALL=C sort)
[ "$PACKAGE_LIST" = "$EXPECTED_LIST" ] || fail "capsule payload has an unexpected file set"
for file in firmware.rom manifest manifest.asc; do
	tar -xOf "$WORKDIR/payload.tar" "$file" >"$WORKDIR/package/$file" ||
		fail "capsule payload is missing $file"
done

MANIFEST="$WORKDIR/package/manifest"
if [ "$(wc -l <"$MANIFEST" | tr -d ' ')" -ne 7 ] ||
	grep -Ev '^(format|guid|board|generation|version|size|sha256)=[^[:cntrl:]]+$' "$MANIFEST" >/dev/null; then
	fail "manifest format is invalid"
fi

manifest_value() {
	local key="$1"
	local value
	value=$(sed -n "s/^${key}=//p" "$MANIFEST")
	[ "$(printf '%s\n' "$value" | wc -l)" -eq 1 ] || return 1
	[ -n "$value" ] || return 1
	printf '%s' "$value"
}

FORMAT=$(manifest_value format) || fail "manifest format is missing"
MANIFEST_GUID=$(manifest_value guid) || fail "manifest GUID is missing"
MANIFEST_BOARD=$(manifest_value board) || fail "manifest board is missing"
GENERATION=$(manifest_value generation) || fail "manifest generation is missing"
VERSION=$(manifest_value version) || fail "manifest version is missing"
ROM_SIZE=$(manifest_value size) || fail "manifest ROM size is missing"
ROM_SHA256=$(manifest_value sha256) || fail "manifest ROM hash is missing"

[ "$FORMAT" = "1" ] || fail "manifest version is unsupported"
[ "$MANIFEST_GUID" = "$EXPECTED_GUID" ] || fail "signed manifest GUID does not match this board"
[ "$MANIFEST_BOARD" = "$CONFIG_BOARD" ] || fail "signed manifest targets another board"
case "$GENERATION:$CURRENT_GENERATION:$ROM_SIZE" in
*[!0-9:]* | ::*) fail "manifest numeric fields are invalid" ;;
esac
[ "$GENERATION" -gt "$CURRENT_GENERATION" ] || fail "firmware generation is not newer"
[ "$ROM_SIZE" -le "$MAX_ROM_SIZE" ] || fail "firmware exceeds the configured size limit"

ACTUAL_SIZE=$(wc -c <"$WORKDIR/package/firmware.rom" | tr -d ' ')
ACTUAL_SHA256=$(sha256sum "$WORKDIR/package/firmware.rom" | awk '{print $1}')
[ "$ACTUAL_SIZE" -eq "$ROM_SIZE" ] || fail "firmware size does not match the signed manifest"
[ "$ACTUAL_SHA256" = "$ROM_SHA256" ] || fail "firmware hash does not match the signed manifest"

STATUS "Verifying firmware signature"
gpg --homedir "$WORKDIR/gnupg" --batch --quiet --no-default-keyring \
	--keyring "$WORKDIR/vendor.gpg" --import "$KEYRING" >/dev/null 2>&1 ||
	fail "vendor keyring could not be loaded"
gpg --homedir "$WORKDIR/gnupg" --batch --quiet --no-default-keyring \
	--keyring "$WORKDIR/vendor.gpg" --verify \
	"$WORKDIR/package/manifest.asc" "$MANIFEST" >/dev/null 2>&1 ||
	fail "vendor signature verification failed"

QUARANTINE_ON_FAILURE="n"

if [ "$ASSUME_YES" != "y" ]; then
	whiptail_warning --title "Apply Heads Firmware Update?" \
		--yesno "A signed firmware update for $CONFIG_BOARD was found.\n\nVersion: $VERSION\nGeneration: $GENERATION\n\nApply it now?" 0 80 || exit 0
fi

change_capsule_request_state() {
	local from="$1"
	local to="$2"

	if ! mount -o rw "$SOURCE_DEVICE" "$WORKDIR/esp"; then
		return 1
	fi
	if [ -e "$WORKDIR/esp/$to" ]; then
		umount "$WORKDIR/esp" 2>/dev/null || true
		return 1
	fi
	if ! mv "$WORKDIR/esp/$from" "$WORKDIR/esp/$to"; then
		umount "$WORKDIR/esp" 2>/dev/null || true
		return 1
	fi
	sync
	umount "$WORKDIR/esp"
}

remove_capsule_request() {
	if ! mount -o rw "$SOURCE_DEVICE" "$WORKDIR/esp"; then
		return 1
	fi
	if ! rm "$WORKDIR/esp/$SOURCE_ACTIVE_RELATIVE"; then
		umount "$WORKDIR/esp" 2>/dev/null || true
		return 1
	fi
	sync
	umount "$WORKDIR/esp"
}

if [ "$KEEP_CAPSULE" != "y" ] && [ -n "$SOURCE_DEVICE" ]; then
	SOURCE_ACTIVE_RELATIVE="${SOURCE_RELATIVE}.applying"
	change_capsule_request_state "$SOURCE_RELATIVE" "$SOURCE_ACTIVE_RELATIVE" ||
		fail "could not mark the staged update as applying"
fi

if ! "$WRITER" "$WORKDIR/package/firmware.rom"; then
	if [ -n "$SOURCE_ACTIVE_RELATIVE" ]; then
		change_capsule_request_state "$SOURCE_ACTIVE_RELATIVE" "$SOURCE_RELATIVE" ||
			ERROR "Could not restore the staged update after the writer failed"
	fi
	fail "firmware writer failed"
fi

if [ -n "$SOURCE_ACTIVE_RELATIVE" ]; then
	remove_capsule_request || fail "could not remove the applied firmware update request"
fi

STATUS_OK "Heads firmware update applied"
if [ "$REBOOT" = "y" ]; then
	/bin/reboot.sh
	fail "system did not reboot after applying firmware"
fi
