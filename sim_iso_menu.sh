#!/bin/bash
# Simulate boot menu parsing for all ISOs using the real kexec-parse-boot.sh
# Tests parser output without menu-level filtering

ISO_DIR="/home/user/Downloads/ISOs"
SIM_BOOT="/tmp/sim_iso_boot"
STUB_ETC="/tmp/host_etc/functions.sh"

# Create stub functions.sh if not exists
[ -f "$STUB_ETC" ] || {
	mkdir -p "$(dirname "$STUB_ETC")"
	cat >"$STUB_ETC" <<'STUB'
TRACE_FUNC() { :; }
DEBUG() { :; }
TRACE() { :; }
ERROR() { echo "ERROR: $*" >&2; }
DIE() { echo "DIE: $*" >&2; exit 1; }
DO_WITH_DEBUG() { "$@"; }
STUB
}

echo "============================================================"
printf "%-70s %6s\n" "ISO" "ENTRIES"
echo "============================================================"

for iso in "$ISO_DIR"/*.iso; do
	[ -f "$iso" ] || continue

	iso_name=$(basename "$iso")
	echo ""
	echo ">>> $iso_name"

	mnt="/tmp/sim_iso_$$"
	mkdir -p "$mnt"
	fuseiso -n "$iso" "$mnt" 2>/dev/null || {
		rmdir "$mnt" 2>/dev/null
		continue
	}

	rm -rf "$SIM_BOOT"
	ln -s "$mnt" "$SIM_BOOT"

	output=$(mktemp)

	# Create patched parser that uses our stub
	PATCHED_PARSER="/tmp/sim_parser_$$.sh"
	sed 's|\. /etc/functions\.sh|. /tmp/host_etc/functions.sh|' \
		/home/user/heads-master/initrd/bin/kexec-parse-boot.sh >"$PATCHED_PARSER"
	chmod +x "$PATCHED_PARSER"

	# Parse all non-EFI configs
	for cfg in $(find "$mnt" -name '*.cfg' -type f 2>/dev/null | grep -v -i -E 'efi|x86_64-efi'); do
		"$PATCHED_PARSER" "$SIM_BOOT" "$cfg" >>"$output" 2>/dev/null || true
	done

	count=$(wc -l <"$output" 2>/dev/null || echo 0)
	echo "    entries: $count"
	echo ""

	n=0
	while read -r entry; do
		n=$((n + 1))
		name=$(echo "$entry" | sed -n 's/|kernel .*$//; s/|elf$//; s/|xen$//; p' | head -c 50)
		kernel=$(echo "$entry" | sed -n 's/.*|kernel \([^|]*\).*/\1/p' | head -c 50)
		initrd=$(echo "$entry" | sed -n 's/.*|initrd \([^|]*\).*/\1/p' | head -c 30)
		append=$(echo "$entry" | sed -n 's/.*|append \(.*\)/\1/p' | head -c 50)
		echo "   $n. [$name]"
		echo "      KERNEL: $kernel"
		[ -n "$initrd" ] && echo "      INITRD: $initrd"
		[ -n "$append" ] && echo "      APPEND: $append"
		[ $n -ge 10 ] && {
			remaining=$((count - 10))
			[ $remaining -gt 0 ] && echo "   ... and $remaining more"
			break
		}
	done <"$output"

	rm -f "$output" "$PATCHED_PARSER"
	rm -f "$SIM_BOOT"
	fusermount -zu "$mnt" 2>/dev/null
	rmdir "$mnt"
done

echo ""
echo "============================================================"
