#!/usr/bin/env bash
#
# compare-update-zip.sh - disassemble and compare Heads update ZIPs
#
# A Heads x86 update ZIP (produced by the Makefile update-package rule) packs
# the ROM, sha256sum.txt, and hashes.txt. hashes.txt is a build-system manifest
# (commit-derived header plus per-artifact and per-cpio-member hashes) carried
# inside the ZIP. With deterministic packaging, the ZIP should be bit-identical
# for a given commit when its packaged contents match.
#
# This script inspects ZIP/member metadata and contents, and compares two ZIPs
# to attribute differences: whole-archive/byte identity, per-member diffs, and
# for hashes.txt/sizes.txt a sorted hash-entry diff that distinguishes
# member-order differences from content differences. Optionally it keeps the
# extracted ROMs and runs host-built coreboot utilities (ifdtool/cbfstool) from
# the local build tree to diff IFD/CBFS layout.

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage: compare-update-zip.sh [--extract DIR] [--rom-tools] [--disassemble] <zip> [zip2]

Disassemble a Heads update ZIP and, when two ZIPs are given, compare them for
same-commit reproducibility.

  --extract DIR   Extract members into DIR/<a|b> and keep them (for external
                  inspection, e.g. ifdtool/cbfstool on the ROMs)
  --rom-tools     Diff host-built ifdtool/cbfstool output on the extracted ROMs
  --disassemble   Print archive/member details for <zip> and exit
  <zip> [zip2]    Compare <zip> to <zip2>; exits 0 if identical

Reports ZIP byte identity, member checksums/modes/mtimes, hashes.txt header and
content, and a sorted hash-entry diff for hashes.txt/sizes.txt.
EOF
	exit 2
}

extract_dir=""
disassemble=0
rom_tools=0
while [ $# -gt 0 ]; do
	case "$1" in
		--extract) [ $# -ge 2 ] || usage; extract_dir=$2; shift 2 ;;
		--rom-tools) rom_tools=1; shift ;;
		--disassemble) disassemble=1; shift ;;
		-*) usage ;;
		*) break ;;
	esac
done
[ $# -ge 1 ] || usage
zip1=$1
zip2=${2:-}
[ -f "$zip1" ] || { echo "not found: $zip1" >&2; exit 2; }
if [ -n "$zip2" ] && [ ! -f "$zip2" ]; then
	echo "not found: $zip2" >&2; exit 2
fi

# Extract into a caller-supplied directory (kept) or a temporary directory that
# is removed on exit unless extraction was requested to be kept.
if [ -n "$extract_dir" ]; then
	tmp=$extract_dir
	mkdir -p "$tmp"
else
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
fi

# Locate a host-built coreboot utility (ifdtool/cbfstool) in the local build
# tree. For a ZIP under build/<arch>/<board>/ the coreboot utilities live under
# build/<arch>/coreboot-*/util (the same host tools pointed to by the Makefile),
# so search the ZIP's arch directory first, then fall back to the whole build/.
find_tool() {
	local name=$1 archdir="" f d
	case "$zip1" in
		*/build/*/*/*) archdir=$(echo "$zip1" | sed -n 's#\(.*build/[^/]*\)/.*#\1#p') ;;
	esac
	for d in ${archdir:+$archdir} build; do
		[ -d "$d" ] || continue
		f=$(find "$d" -path "*/util/$name/$name" -type f 2>/dev/null | LC_ALL=C sort | head -n 1 || true)
		[ -n "$f" ] && [ -x "$f" ] && { echo "$f"; return 0; }
		f=$(find "$d" -path "*/util/$name" -type f ! -path "*/Documentation/*" 2>/dev/null | LC_ALL=C sort | head -n 1 || true)
		[ -n "$f" ] && [ -x "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

# Print archive details and checksums/modes/mtimes for every member, then
# extract members into the given directory for byte-level comparison.
inspect() {
	local z=$1 out=$2
	mkdir -p "$out"
	echo "== archive: $z"
	sha256sum "$z"
	echo "-- listing --"
	unzip -lv "$z" || unzip -l "$z"
	echo "-- members --"
	unzip -q -o "$z" -d "$out"
	( cd "$out" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
		sha256sum "$f"
		stat -c '%a %Y %n' "$f"
	done )
	if [ -f "$out/hashes.txt" ]; then
		echo "-- hashes.txt header --"
		head -n 1 "$out/hashes.txt"
	fi
}

inspect "$zip1" "$tmp/a"
[ -n "$extract_dir" ] && echo "extracted: $tmp/a"

if [ -z "$zip2" ]; then
	[ "$rom_tools" -eq 1 ] && echo "note: --rom-tools compares two ROMs; provide a second ZIP"
	exit 0
fi

echo
inspect "$zip2" "$tmp/b"
[ -n "$extract_dir" ] && echo "extracted: $tmp/b"

echo
echo "== comparison =="
if cmp -s "$zip1" "$zip2"; then
	echo "zip: identical"
	rc=0
else
	echo "zip: different"
	cmp -l "$zip1" "$zip2" | head -20 || true
	rc=1
fi

# Compare every member present in either archive. For manifest files, also
# compare the sorted hash-entry lines so an empty sorted diff reveals an
# ordering-only difference in otherwise identical content.
rom_a="" rom_b=""
for m in $( (cd "$tmp/a" && find . -type f; cd "$tmp/b" && find . -type f) 2>/dev/null | LC_ALL=C sort -u ); do
	ma="$tmp/a/$m"; mb="$tmp/b/$m"
	if [ ! -f "$ma" ]; then echo "member only in second: $m"; rc=1; continue; fi
	if [ ! -f "$mb" ]; then echo "member only in first: $m"; rc=1; continue; fi
	case "$m" in *.rom) rom_a=$ma; rom_b=$mb ;; esac
	if cmp -s "$ma" "$mb"; then
		echo "member identical: $m"
	else
		echo "member different: $m"
		diff -u "$ma" "$mb" | head -80 || true
		case "$(basename "$m")" in
			hashes.txt|sizes.txt)
				echo "-- sorted hash-entry diff (header/order-only differences excluded) --"
				diff -u \
					<(grep '^[0-9a-f]\{64\}  ' "$ma" | LC_ALL=C sort) \
					<(grep '^[0-9a-f]\{64\}  ' "$mb" | LC_ALL=C sort) | head -80 || true
				;;
		esac
		rc=1
	fi
done

# Optionally diff ROM structure with host-built coreboot tools from the local
# build tree to attribute content differences to flash regions or CBFS entries.
if [ "$rom_tools" -eq 1 ] && [ -n "$rom_a" ] && [ -n "$rom_b" ]; then
	echo
	echo "== ROM tools =="
	ifd=$(find_tool ifdtool || true)
	cbf=$(find_tool cbfstool || true)
	[ -n "$ifd" ] && echo "ifdtool: $ifd" || echo "ifdtool: not found in build tree"
	[ -n "$cbf" ] && echo "cbfstool: $cbf" || echo "cbfstool: not found in build tree"
	if [ -n "$ifd" ]; then
		echo "-- ifdtool -d (diff) --"
		diff -u <("$ifd" -d "$rom_a" 2>&1 || true) <("$ifd" -d "$rom_b" 2>&1 || true) | head -120 || true
	fi
	if [ -n "$cbf" ]; then
		echo "-- cbfstool print (diff) --"
		diff -u <("$cbf" "$rom_a" print 2>&1 || true) <("$cbf" "$rom_b" print 2>&1 || true) | head -120 || true
	fi
	[ -z "$ifd" ] && [ -z "$cbf" ] && echo "hint: build the board locally so host tools exist under build/<arch>/coreboot-*/util"
fi

if [ $rc -eq 0 ]; then
	echo "result: reproducible for compared ZIP contents"
else
	echo "result: NOT identical (see differences above)"
fi
exit $rc
