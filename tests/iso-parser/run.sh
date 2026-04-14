#!/bin/bash
# ISO parser test — mirrors how scan_boot_options() calls the parser in Heads
# Usage: ISO_DIR=/path/to/isos ./run.sh

set -e

: "${ISO_DIR:=/home/user/Downloads/ISOs}"
: "${PARSER:=$(dirname "$0")/../../initrd/bin/kexec-parse-boot.sh}"
: "${FUNCTIONS:=$(dirname "$0")/../../initrd/etc/functions.sh}"

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
	mnt=$(mktemp -d)
	if ! fuseiso "$iso" "$mnt" 2>/dev/null; then
		rmdir "$mnt" 2>/dev/null
		printf "%-60s %8s %10s  %s\n" "$(basename "$iso")" "SKIP" "?" "fuseiso failed"
		continue
	fi
	if [ ! -d "$mnt/boot" ] && [ ! -d "$mnt/isolinux" ]; then
		fusermount -u "$mnt" 2>/dev/null
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

	count=$(wc -l <"$entries" 2>/dev/null || echo 0)
	boot=$(sed -n 's/.*|append \(.*\)/\1/p' "$entries" 2>/dev/null | head -1)
	mbr=$(dd if="$iso" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
	hybrid=$([ "$mbr" = "55aa" ] && echo "yes" || echo "no")

	printf "%-60s %8s %10s  %s\n" "$(basename "$iso")" "$count" "$hybrid" "${boot:0:60}"

	fusermount -u "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null
	rmdir "$mnt" 2>/dev/null
	rm -rf "$sim" "$entries"
done

rm -f "$STUB" "$TEMP_PARSER"
