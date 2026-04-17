#!/bin/bash
# Simulate boot menu entries for all ISOs — show counts before/after dedup+filtering

ISO_DIR="/media/ISOs"
PARSER="/home/user/heads-master/initrd/bin/kexec-parse-boot.sh"

total_before=0
total_after=0

echo "============================================================"
printf "%-70s %6s %6s\n" "ISO" "BEFORE" "AFTER"
echo "============================================================"

for iso in "$ISO_DIR"/*.iso "$ISO_DIR"/**/*.iso; do
	[ -f "$iso" ] || continue

	# Mount ISO temporarily
	mnt=$(mktemp -d)
	mount -t iso9660 -o loop,ro "$iso" "$mnt" 2>/dev/null || {
		rmdir "$mnt" 2>/dev/null
		continue
	}

	# Collect all boot entries from all .cfg files
	raw_entries=$(mktemp)
	tmp_menu=$(mktemp)
	filtered=$(mktemp)

	for cfg in $(find "$mnt" -name '*.cfg' -type f 2>/dev/null); do
		"$PARSER" /boot "$cfg" 2>/dev/null >>"$raw_entries" || true
	done

	# Count before
	before=$(wc -l <"$raw_entries" 2>/dev/null || echo 0)
	total_before=$((total_before + before))

	# Deduplicate (sort | uniq) — like -u flag
	sort -r "$raw_entries" 2>/dev/null | uniq >"$tmp_menu"

	# Filter installer noise (like -s mode does)
	grep -vEi '\|[^|]*\b(Install|Expert install|Automated install|Rescue mode|Start installer)\b' \
		"$tmp_menu" >"$filtered" 2>/dev/null || true

	# Count after
	after=$(wc -l <"$filtered" 2>/dev/null || echo 0)
	total_after=$((total_after + after))

	# Show top entries
	echo ""
	echo ">>> $(basename "$iso") ($before -> $after)"
	n=0
	while read -r entry; do
		n=$((n + 1))
		name=$(echo "$entry" | cut -d'|' -f1 | head -c 50)
		kernel=$(echo "$entry" | cut -d'|' -f3 | sed 's|kernel ||' | head -c 40)
		append=$(echo "$entry" | cut -d'|' -f5 | sed 's|append ||' | head -c 40)
		echo "   $n. [$name]"
		echo "      KERNEL: $kernel"
		[ -n "$append" ] && echo "      APPEND: $append"
		[ $n -ge 10 ] && {
			echo "   ... and $((after - 10)) more"
			break
		}
	done <"$filtered"

	umount "$mnt" 2>/dev/null
	rmdir "$mnt" 2>/dev/null
	rm -f "$raw_entries" "$tmp_menu" "$filtered"
done

echo ""
echo "============================================================"
printf "%-70s %6d %6d\n" "TOTAL" "$total_before" "$total_after"
echo "============================================================"
