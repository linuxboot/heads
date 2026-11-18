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
# for hashes.txt/sizes.txt a sorted entry diff that distinguishes
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
content, and a sorted entry diff for hashes.txt/sizes.txt.
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
[ $# -ge 1 ] && [ $# -le 2 ] || usage
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
tmp=$(cd "$tmp" && pwd)

# inspect() clears "$tmp/a" and "$tmp/b" before it reads its ZIP. Reject an
# input that lies inside a directory cleared before that input is read.
extract_abs=$(cd -P -- "$tmp" && pwd -P)
# True if the input path, or any symlink in its chain, lies inside a directory
# that inspect() clears before reading the input.
input_overlaps_extract() {
	local p=$1 comp cur prefix="" target
	case "$p" in /*) ;; *) prefix=$PWD/ ;; esac
	cur=$prefix
	local IFS=/
	for comp in $p; do
		case "$comp" in ""|".") continue ;; "..") cur=${cur%/}; cur=${cur%/*}/; continue ;; esac
		cur=${cur%/}/$comp
		while :; do
			case "$cur" in
				"$extract_abs/a"/*|"$extract_abs/b"/*) return 0 ;;
			esac
			[ -L "$cur" ] || break
			target=$(readlink -- "$cur")
			case "$target" in
				/*) cur=$target ;;
				*) cur=$(dirname -- "$cur")/$target ;;
			esac
			cur=$(cd -P -- "$(dirname -- "$cur")" 2>/dev/null && pwd -P)/$(basename -- "$cur") || return 0
		done
	done
	return 1
}
input_overlaps_extract "$zip1" && { echo "input inside extraction directory: $zip1" >&2; exit 2; }
if [ -n "$zip2" ]; then
	input_overlaps_extract "$zip2" && { echo "input inside extraction directory: $zip2" >&2; exit 2; }
fi

# Locate a host-built coreboot utility (ifdtool/cbfstool) in the local build
# tree. For a ZIP under build/<arch>/<board>/ the coreboot utilities live under
# build/<arch>/coreboot-*/util (the same host tools pointed to by the Makefile),
# so search the ZIP's arch directory first, then fall back to the whole build/.
# Only coreboot build outputs are trusted: candidates under the physical
# extraction root are filtered out so a crafted archive can never supply an
# executable that is run here.
find_tool() {
	local name=$1 arch="" root f pat
	case "$zip1" in
		*/build/*/*|build/*/*) arch=$(echo "$zip1" | sed -n 's#.*build/\([^/]*\)/.*#\1#p') ;;
	esac
	root=$(cd build 2>/dev/null && pwd -P) || return 1
	# Search only the trusted ./build tree. The ZIP's architecture is a
	# preference filter, never a search root, so a directory chosen by the
	# archive path cannot supply an executable.
	for try_arch in "$arch" ""; do
		for pat in "*/coreboot-*/util/$name/$name" "*/coreboot-*/util/$name"; do
			f=$(find "$root" -path "$pat" -type f ! -path "*/Documentation/*" -print 2>/dev/null \
				| LC_ALL=C grep -v -F -e "$extract_abs/" \
				| { if [ -n "$try_arch" ]; then LC_ALL=C grep -F -e "/build/$try_arch/" || true; else cat; fi; } \
				| LC_ALL=C sort | head -n 1 || true)
			[ -n "$f" ] && [ -x "$f" ] && { echo "$f"; return 0; }
		done
	done
	return 1
}

# Replace a literal path in tool output without interpreting it as a regex or
# sed program (member names come from an untrusted archive).
normalize_rom_path() {
	local path=$1 line
	while IFS= read -r line || [ -n "$line" ]; do
		printf '%s\n' "${line//"$path"/<rom>}"
	done
}

# Print archive details and checksums/modes/mtimes for every member, then
# extract members into the given directory for byte-level comparison.
inspect() {
	local z=$1 out=$2
	rm -rf "$out"
	mkdir -p "$out"
	echo "== archive: $z"
	sha256sum "$z"
	echo "-- listing --"
	unzip -lv "$z" || unzip -l "$z"
	echo "-- members --"
	unzip -q -o "$z" -d "$out"
	if [ -n "$(find "$out" -type l -print -quit 2>/dev/null)" ]; then
		echo "refusing symlink members in $z" >&2
		exit 2
	fi
	( cd "$out" && find . -type f -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
		sha256sum "$f"
		stat -c '%a %Y %n' "$f"
	done )
	if [ -f "$out/hashes.txt" ] && [ ! -L "$out/hashes.txt" ]; then
		echo "-- hashes.txt header --"
		head -n 1 "$out/hashes.txt"
	fi
}

inspect "$zip1" "$tmp/a"
[ -n "$extract_dir" ] && echo "extracted: $tmp/a"

if [ "$disassemble" -eq 1 ] || [ -z "$zip2" ]; then
	[ -z "$zip2" ] && [ "$rom_tools" -eq 1 ] && echo "note: --rom-tools compares two ROMs; provide a second ZIP"
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
while IFS= read -r -d '' m; do
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
				if [ "$(basename "$m")" = sizes.txt ]; then
					entry='^[[:space:]]*[0-9][0-9]*:'
				else
					entry='^[0-9a-f]\{64\}  '
				fi
				echo "-- sorted entry diff (header/order-only differences excluded) --"
				diff -u \
					<(grep "$entry" "$ma" | LC_ALL=C sort) \
					<(grep "$entry" "$mb" | LC_ALL=C sort) | head -80 || true
				;;
		esac
		rc=1
	fi
done < <( (cd "$tmp/a" && find . -type f -print0; cd "$tmp/b" && find . -type f -print0) 2>/dev/null | LC_ALL=C sort -zu )

# Optionally diff ROM structure with host-built coreboot tools from the local
# build tree to attribute content differences to flash regions or CBFS entries.
inspection_failed=0
if [ "$rom_tools" -eq 1 ] && [ -n "$rom_a" ] && [ -n "$rom_b" ]; then
	echo
	echo "== ROM tools =="
	ifd=$(find_tool ifdtool || true)
	cbf=$(find_tool cbfstool || true)
	[ -n "$ifd" ] && echo "ifdtool: $ifd" || echo "ifdtool: not found in build tree"
	[ -n "$cbf" ] && echo "cbfstool: $cbf" || echo "cbfstool: not found in build tree"
	if [ -n "$ifd" ]; then
		echo "-- ifdtool -d (diff) --"
		ifd_a=""; ifd_b=""; ifd_rc_a=0; ifd_rc_b=0
		ifd_a=$("$ifd" -d "$rom_a" 2>&1) || ifd_rc_a=$?
		ifd_b=$("$ifd" -d "$rom_b" 2>&1) || ifd_rc_b=$?
		if [ "$ifd_rc_a" -ne 0 ] || [ "$ifd_rc_b" -ne 0 ]; then
			echo "ifdtool inspection failed (a=$ifd_rc_a, b=$ifd_rc_b)"
			[ "$ifd_rc_a" -ne 0 ] && printf 'ifdtool (a):\n%s\n' "$ifd_a" || true
			[ "$ifd_rc_b" -ne 0 ] && printf 'ifdtool (b):\n%s\n' "$ifd_b" || true
			inspection_failed=1
		else
			diff -u \
				<(printf '%s\n' "$ifd_a" | normalize_rom_path "$rom_a") \
				<(printf '%s\n' "$ifd_b" | normalize_rom_path "$rom_b") | head -120 || true
		fi
	fi
	if [ -n "$cbf" ]; then
		echo "-- cbfstool print (diff) --"
		cbf_a=""; cbf_b=""; cbf_rc_a=0; cbf_rc_b=0
		cbf_a=$("$cbf" "$rom_a" print 2>&1) || cbf_rc_a=$?
		cbf_b=$("$cbf" "$rom_b" print 2>&1) || cbf_rc_b=$?
		if [ "$cbf_rc_a" -ne 0 ] || [ "$cbf_rc_b" -ne 0 ]; then
			echo "cbfstool inspection failed (a=$cbf_rc_a, b=$cbf_rc_b)"
			[ "$cbf_rc_a" -ne 0 ] && printf 'cbfstool (a):\n%s\n' "$cbf_a" || true
			[ "$cbf_rc_b" -ne 0 ] && printf 'cbfstool (b):\n%s\n' "$cbf_b" || true
			inspection_failed=1
		else
			diff -u <(printf '%s\n' "$cbf_a") <(printf '%s\n' "$cbf_b") | head -120 || true
		fi
	fi
	[ -z "$ifd" ] && [ -z "$cbf" ] && echo "hint: build the board locally so host tools exist under build/<arch>/coreboot-*/util"
fi

if [ $rc -eq 0 ]; then
	echo "result: reproducible for compared ZIP contents"
else
	echo "result: NOT identical (see differences above)"
fi
[ "$inspection_failed" -eq 1 ] && echo "result: ROM inspection incomplete (see diagnostics above)"
exit $rc
