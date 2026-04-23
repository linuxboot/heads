#!/bin/bash
# ISO parser test — mirrors how kexec-iso-init.sh detects boot support in Heads
#
# This script tests ISO boot compatibility by:
# 1. Mounting each ISO
# 2. Extracting and scanning initrd for boot mechanism support
# 3. Checking for installer ISOs (which don't support USB file boot)
# 4. Reporting supported boot methods and overall compatibility
#
# Usage:
#   ./run.sh                    # test all ISOs in default dir
#   ./run.sh /path/to/iso.iso  # test single ISO
#
# Output:
# - First section: ISO metadata (entries, hybrid, sample boot params)
# - Second section: Initramfs boot support detection
#
# Compatibility status:
# - OK: Known boot mechanism detected, should work
# - WARN: No known mechanism detected, may work but unverified
# - SKIP: Installer ISO - use dd instead
#
# Tested ISOs (2026-04):
# - Ubuntu Desktop, Debian Live, Tails, Fedora Live, NixOS, PureOS, Kicksecure: OK
# - Debian DVD installer: SKIP (use dd)
# - TinyCore/CorePlus: WARN (unverified)

set -e

if [ -n "$1" ] && [ -f "$1" ]; then
	ISO_DIR=$(dirname "$1")
	SINGLE_ISO="$1"
elif [ -n "$1" ]; then
	echo "Error: '$1' is not a valid ISO file"
	exit 1
fi

: "${ISO_DIR:=/home/user/Downloads/ISOs}"
: "${ISO_INIT:=$(dirname "$0")/../../initrd/bin/kexec-iso-init.sh}"
: "${PARSER:=$(dirname "$0")/../../initrd/bin/kexec-parse-boot.sh}"
: "${FUNCTIONS:=$(dirname "$0")/../../initrd/etc/functions.sh}"
: "${UNPACK:=$(dirname "$0")/../../initrd/bin/unpack_initramfs.sh}"

for cmd in fuseiso fusermount; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Missing: $cmd"
		echo "Install: apt install fuseiso  # Debian/Ubuntu"
		echo "         pacman -S fuseiso   # Arch"
		echo "         dnf install fuseiso  # Fedora"
		exit 1
	fi
done

if [ ! -d "$ISO_DIR" ]; then
	echo "ISO_DIR '$ISO_DIR' does not exist"
	echo "Set ISO_DIR=/path/to/isos before running"
	exit 1
fi

if [ ! -f "$PARSER" ]; then
	echo "Parser not found: $PARSER"
	echo "Set PARSER=/path/to/kexec-parse-boot.sh"
	exit 1
fi

if [ ! -f "$FUNCTIONS" ]; then
	echo "Functions not found: $FUNCTIONS"
	echo "Set FUNCTIONS=/path/to/functions.sh"
	exit 1
fi

if [ ! -f "$ISO_INIT" ]; then
	echo "ISO_INIT not found: $ISO_INIT"
	echo "Set ISO_INIT=/path/to/kexec-iso-init.sh"
	exit 1
fi

if [ ! -f "$UNPACK" ]; then
	echo "UNPACK not found: $UNPACK"
	echo "Set UNPACK=/path/to/unpack_initramfs.sh"
	exit 1
fi

STUB=$(mktemp)
cat >"$STUB" <<'STUB'
TRACE_FUNC() { :; }
TRACE() { :; }
DEBUG() { :; }
ERROR() { echo "ERROR: $*" >&2; }
DIE() { echo "DIE: $*" >&2; exit 1; }
WARN() { echo "WARN: $*" >&2; }
check_config() { :; }
STUB

FUNC_STUB=$(mktemp)
cat >"$FUNC_STUB" <<'STUB'
TRACE_FUNC() { :; }
TRACE() { :; }
DEBUG() { :; }
ERROR() { echo "ERROR: $*" >&2; }
DIE() { echo "DIE: $*" >&2; exit 1; }
WARN() { echo "WARN: $*" >&2; }
check_config() { :; }
zstd-decompress() { zstd -d "$@"; }
STUB

UNPACK_TEMP=$(mktemp)
sed "s|^\\. /etc/functions\\.sh|. $FUNC_STUB|" "$UNPACK" >"$UNPACK_TEMP"
chmod +x "$UNPACK_TEMP"

ISO_INIT_TEMP=$(mktemp)
sed "s|^\\. /etc/functions\\.sh|. $STUB|" "$ISO_INIT" >"$ISO_INIT_TEMP"
chmod +x "$ISO_INIT_TEMP"

STUB=$(mktemp)
cat >"$STUB" <<'STUB'
TRACE_FUNC() { :; }
DEBUG() { :; }
ERROR() { echo "ERROR: $*" >&2; }
DIE() { echo "DIE: $*" >&2; exit 1; }
WARN() { echo "WARN: $*" >&2; }
check_config() { :; }
STUB

TEMP_PARSER=$(mktemp)
# Stub out TRACE/DEBUG/WARN before sourcing real functions.sh
sed "s|^\. /etc/functions\.sh|. $STUB|" "$PARSER" >"$TEMP_PARSER"
chmod +x "$TEMP_PARSER"

printf "%-60s %8s %10s  %s\n" "ISO" "ENTRIES" "HYBRID" "SAMPLE BOOT PARAMS"
printf "%-60s %8s %10s  %s\n" "---" "-------" "------" "------------------"

for iso in "$ISO_DIR"/*.iso; do
	[ -f "$iso" ] || continue
	[ -n "$SINGLE_ISO" ] && [ "$(realpath "$iso")" != "$(realpath "$SINGLE_ISO")" ] && continue
	mnt=$(mktemp -d)
	if ! fuseiso "$iso" "$mnt" 2>/dev/null; then
		rmdir "$mnt" 2>/dev/null
		printf "%-60s %8s %10s  %s\n" "$(basename "$iso")" "SKIP" "?" "fuseiso failed"
		continue
	fi
	if [ ! -d "$mnt/boot" ] && [ ! -d "$mnt/isolinux" ]; then
		fusermount -uz "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
		rmdir "$mnt" 2>/dev/null
		printf "%-60s %8s %10s  %s\n" "$(basename "$iso")" "SKIP" "?" "mount empty"
		continue
	fi
	sim=$(mktemp -u)
	rm -rf "$sim"
	ln -sf "$mnt" "$sim"

	entries=$(mktemp)
	>"$entries"
	for cfg in $(find "$mnt" -name "*.cfg" -type f 2>/dev/null | grep -v -i -E "efi|x86_64-efi"); do
		"$TEMP_PARSER" "$sim" "$cfg" >>"$entries" 2>/dev/null || true
	done

	count=$(sort -u "$entries" 2>/dev/null | wc -l || echo 0)
	boot=$(sed -n 's/.*|append \(.*\)/\1/p' "$entries" 2>/dev/null | head -1)
	mbr=$(dd if="$iso" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
	hybrid=$([ "$mbr" = "55aa" ] && echo "yes" || echo "no")

	printf "%-60s %8s %10s  %s\n" "$(basename "$iso")" "$count" "$hybrid" "${boot:0:60}"

	fusermount -uz "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
	rmdir "$mnt" 2>/dev/null
	rm -rf "$sim" "$entries"
done

echo ""
echo "=== Initramfs ISO Boot Support ==="
echo "Detecting supported boot mechanisms and quirks"
echo ""

if [ -n "$SINGLE_ISO" ]; then
	printf "\n%-60s %-40s  %s\n" "ISO" "DETECTED MECHANISM" "SUPPORTED"
	printf "\n%-60s %-40s  %s\n" "---" "--------------------" "---------"
fi

check_compatibility() {
	local supported="$1"
	local status=""
	local note=""
	case "$supported" in
	installer*) status="SKIP" ; note=" (use dd)" ;;
	anaconda*) status="WARN" ; note=" (block device req)" ;;
	std) status="WARN" ;;
	"") status="WARN" ;;
	*) status="OK" ;;
	esac
	echo "${status}${note}"
}

for iso in "$ISO_DIR"/*.iso; do
	[ -f "$iso" ] || continue
	[ -n "$SINGLE_ISO" ] && [ "$(realpath "$iso")" != "$(realpath "$SINGLE_ISO")" ] && continue
	basenameiso=$(basename "$iso")
	mnt=$(mktemp -d)
	if ! fuseiso "$iso" "$mnt" 2>/dev/null; then
		rmdir "$mnt" 2>/dev/null
		continue
	fi
	if [ ! -d "$mnt/boot" ] && [ ! -d "$mnt/isolinux" ]; then
		fusermount -uz "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
		rmdir "$mnt" 2>/dev/null
		continue
	fi

	sim=$(mktemp -u)
	rm -rf "$sim"
	ln -sf "$mnt" "$sim"

	entries=$(mktemp)
	>"$entries"
	for cfg in $(find "$mnt" -name "*.cfg" -type f 2>/dev/null | grep -v -i -E "efi|x86_64-efi"); do
		"$TEMP_PARSER" "$sim" "$cfg" >>"$entries" 2>/dev/null || true
	done
	boot_params=$(sed -n 's/.*|append \(.*\)/\1/p' "$entries" 2>/dev/null | head -1)
	rm -f "$entries"

	mechanism=""

	if [ -d "$mnt/install.amd" ] && [ -f "$mnt/install.amd/vmlinuz" ] && [ -f "$mnt/install.amd/initrd.gz" ]; then
		mechanism="installer"
	fi

	if [ -z "$mechanism" ]; then
		tmp_boot=$(mktemp -d)
		ln -sf "$mnt/boot" "$tmp_boot/boot" 2>/dev/null || ln -sf "$mnt" "$tmp_boot/boot"
		ln -sf "$mnt/isolinux" "$tmp_boot/isolinux" 2>/dev/null || true
		ln -sf "$mnt/install.amd" "$tmp_boot/install.amd" 2>/dev/null || true

		scan_initramfs_test() {
			local path="$1"
			local tmpdir=""
			local boot_content=""

			[ -r "$path" ] || return 1

			tmpdir=$(mktemp -d)
			bash "$UNPACK_TEMP" "$path" "$tmpdir" 2>/dev/null || true

			if [ -d "$tmpdir" ] && [ "$(ls -A "$tmpdir" 2>/dev/null)" ]; then
				boot_content=$(find "$tmpdir" -type f \( -name "*.sh" -o -name "*.conf" -o -name "*.cfg" -o -name "init" -o -name "*.txt" -o -path "*/scripts/*" -o -path "*/conf/*" -o -path "*/lib/live/boot/*" -o -path "*/usr/lib/live/boot/*" \) -print 2>/dev/null | xargs cat 2>/dev/null | tr -d '\0' || true) || boot_content=""
				rm -rf "$tmpdir"
			else
				rm -rf "$tmpdir"
				boot_content=$(strings "$path" 2>/dev/null | tr -d '\0') || true
			fi

			if echo "$boot_content" | grep -qEi "iso.scan|findiso"; then
				supported_boot="${supported_boot}iso-scan "
			fi
			if echo "$boot_content" | grep -qEi "live.media|live-media"; then
				supported_boot="${supported_boot}live-media "
			fi
			if echo "$boot_content" | grep -qEi "boot=live|rd.live.image|rd.live.squash"; then
				supported_boot="${supported_boot}boot-live "
			fi
			if echo "$boot_content" | grep -qEi "boot.casper|casper"; then
				supported_boot="${supported_boot}casper "
			fi
			if echo "$boot_content" | grep -qEi "nixos"; then
				supported_boot="${supported_boot}nixos "
			fi
			if echo "$boot_content" | grep -qEi "inst.stage2|inst.repo"; then
				supported_boot="${supported_boot}anaconda "
			fi
			if echo "$boot_content" | grep -qEi "overlay|overlayfs"; then
				supported_boot="${supported_boot}overlay "
			fi
			if echo "$boot_content" | grep -qEi "toram"; then
				supported_boot="${supported_boot}toram "
			fi
			if echo "$boot_content" | grep -qEi "CDLABEL|img_dev|check_dev"; then
				supported_boot="${supported_boot}device "
			fi
		}

		supported_fses=""
		supported_boot=""
		initrd=""

		initrds=$(find "$mnt" -name "initrd*" -type f 2>/dev/null)
		for p in live/initrd.img live/initrd boot/initrd* casper/initrd* install/initrd.gz install.amd/initrd.gz; do
			[ -f "$mnt/$p" ] && { initrd="$mnt/$p"; break; }
		done
		[ -z "$initrd" ] && initrd=$(echo "$initrds" | head -1)

		if [ -n "$initrd" ]; then
			timeout 30 scan_initramfs_test "$initrd" 2>/dev/null || true
		fi

		for cfg in $(find "$mnt" -name "*.cfg" -type f 2>/dev/null | grep -v -i -E "efi|x86_64-efi"); do
			cfg_content=$(cat "$cfg" 2>/dev/null | tr -d '\0') || true
			if echo "$cfg_content" | grep -qEi "boot=live|rd.live.image|rd.live.squash"; then
				supported_boot="${supported_boot}boot-live "
			fi
			if echo "$cfg_content" | grep -qEi "iso-scan|findiso"; then
				supported_boot="${supported_boot}iso-scan "
			fi
			if echo "$cfg_content" | grep -qiE "live.media"; then
				supported_boot="${supported_boot}live-media "
			fi
			if echo "$cfg_content" | grep -qiE "boot=casper"; then
				supported_boot="${supported_boot}casper "
			fi
			if echo "$cfg_content" | grep -qiE "inst.stage2|inst.repo"; then
				supported_boot="${supported_boot}anaconda "
			fi
			if echo "$cfg_content" | grep -qiE "nixos"; then
				supported_boot="${supported_boot}nixos "
			fi
			if echo "$cfg_content" | grep -qiE "overlay"; then
				supported_boot="${supported_boot}overlay "
			fi
			if echo "$cfg_content" | grep -qiE "toram"; then
				supported_boot="${supported_boot}toram "
			fi
			if echo "$cfg_content" | grep -qiE "CDLABEL|img_dev"; then
				supported_boot="${supported_boot}device "
			fi
		done

		rm -rf "$tmp_boot"

		mechanism=$(echo "${supported_boot:-std}" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ $//')
	fi

	compatibility=$(check_compatibility "$mechanism")
	mechanism_short=$(echo "$mechanism" | cut -c1-38)

	printf "%-60s %-40s  %s\n" "$basenameiso" "$mechanism_short" "$compatibility"

	simulate_param_injection() {
		local detected="$1"
		local params=""

		params="findiso=... fromiso=... iso-scan/filename=... img_dev=... img_loop=... iso=..."

		if echo "$detected" | grep -q "casper"; then
			params="$params boot=casper live-media-path=casper"
		fi
		if echo "$detected" | grep -q "boot-live"; then
			params="$params boot=live"
		fi
		if echo "$detected" | grep -q "live-media"; then
			params="$params live-media=..."
		fi

		echo "$params"
	}

	injected_params=$(simulate_param_injection "$mechanism")

	has_casper=$(echo "$injected_params" | grep -qo "boot=casper" && echo "yes" || echo "no")
	has_boot_live=$(echo "$injected_params" | grep -qo "boot=live" && echo "yes" || echo "no")

	if [ "$has_casper" = "yes" ] && [ "$has_boot_live" = "yes" ]; then
		echo "WARNING: Conflicting boot params (casper + boot-live) for $basenameiso" >&2
	fi

	fusermount -uz "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
	rmdir "$mnt" 2>/dev/null
	rm -rf "$sim"
done

echo ""
echo "=== Parameter Injection Validation ==="
echo ""

for iso in "$ISO_DIR"/*.iso; do
	[ -f "$iso" ] || continue
	basenameiso=$(basename "$iso")

	mnt=$(mktemp -d)
	if ! fuseiso "$iso" "$mnt" 2>/dev/null; then
		rmdir "$mnt" 2>/dev/null
		continue
	fi

	supported_boot=""
	for cfg in $(find "$mnt" -name "*.cfg" -type f 2>/dev/null | grep -v -i -E "efi|x86_64-efi"); do
		cfg_content=$(cat "$cfg" 2>/dev/null | tr -d '\0') || true
		if echo "$cfg_content" | grep -qEi "boot=live|rd.live.image|rd.live.squash"; then
			supported_boot="${supported_boot}boot-live "
		fi
		if echo "$cfg_content" | grep -qiE "boot=casper"; then
			supported_boot="${supported_boot}casper "
		fi
		if echo "$cfg_content" | grep -qiE "live.media"; then
			supported_boot="${supported_boot}live-media "
		fi
	done

	mechanism=$(echo "${supported_boot:-std}" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ $//')

	injected=""
	if echo "$mechanism" | grep -q "casper"; then
		injected="$injected boot=casper"
	fi
	if echo "$mechanism" | grep -q "boot-live"; then
		injected="$injected boot=live"
	fi
	if echo "$mechanism" | grep -q "live-media"; then
		injected="$injected live-media"
	fi

	conflicts=""
	has_casper=$(echo "$injected" | grep -qo "boot=casper" && echo "y" || echo "n")
	has_live=$(echo "$injected" | grep -qo "boot=live" && echo "y" || echo "n")

	if [ "$has_casper" = "y" ] && [ "$has_live" = "y" ]; then
		conflicts="CONFLICT"
	elif [ -z "$injected" ]; then
		conflicts="NO_PARAMS"
	else
		conflicts="OK"
	fi

	printf "%-60s %-20s  %s\n" "$basenameiso" "$injected" "$conflicts"

	fusermount -uz "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
	rmdir "$mnt" 2>/dev/null
done

rm -f "$STUB" "$TEMP_PARSER" "$FUNC_STUB" "$UNPACK_TEMP" "$ISO_INIT_TEMP"
