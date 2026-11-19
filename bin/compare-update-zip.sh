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

  --extract DIR   Keep members in a fresh DIR/zipcmp.XXXXXX/<a|b> workspace
                  (for external inspection, e.g. ifdtool/cbfstool on the ROMs)
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
[ "$disassemble" -eq 1 ] && zip2=""
[ -f "$zip1" ] || { echo "not found: $zip1" >&2; exit 2; }
if [ -n "$zip2" ] && [ ! -f "$zip2" ]; then
	echo "not found: $zip2" >&2; exit 2
fi

# Always create a fresh workspace per run: a retained --extract directory is
# only a parent, never a set of member trees that an earlier run could mutate.
if [ -n "$extract_dir" ]; then
	mkdir -p -- "$extract_dir"
	tmp=$(mktemp -d -- "$extract_dir/zipcmp.XXXXXX")
else
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
fi
tmp=$(CDPATH= cd -- "$tmp" && pwd)
extract_abs=$tmp

# Each run gets a fresh workspace, so inputs can never be removed by a prior
# extraction and there is no overlap state to guard. Stage inputs under fixed
# names: Info-ZIP interprets brackets in an archive name as a pattern.
cp -- "$zip1" "$tmp/input1.zip"
if [ -n "$zip2" ]; then
	cp -- "$zip2" "$tmp/input2.zip"
fi

# Locate a host-built coreboot utility (ifdtool/cbfstool) in the local build
# tree. For a ZIP under build/<arch>/<board>/ the coreboot utilities live under
# build/<arch>/coreboot-*/util (the same host tools pointed to by the Makefile),
# so search the ZIP's arch directory first, then fall back to the whole build/.
# Only coreboot build outputs are trusted: candidates under the physical
# extraction root are filtered out so a crafted archive can never supply an
# executable that is run here.
trusted_tool_file() {
	local f=$1 d
	[ -f "$f" ] && [ ! -L "$f" ] || return 1
	d=$(dirname -- "$f")
	while [ "$d" != / ] && [ "$d" != . ]; do
		[ ! -L "$d" ] || return 1
		case "$d" in "$extract_abs"/*) return 1 ;; esac
		d=$(dirname -- "$d")
	done
	return 0
}

find_tool() {
	local name=$1 arch="" board="" root d c b f
	local -a roots boards
	case "$zip1" in
		*/build/*/*/*|build/*/*/*) board=$(echo "$zip1" | sed -n 's#.*build/[^/]*/\([^/]*\)/.*#\1#p') ;;
	esac
	case "$zip1" in
		*/build/*/*|build/*/*) arch=$(echo "$zip1" | sed -n 's#.*build/\([^/]*\)/.*#\1#p') ;;
	esac
	root=$(CDPATH= cd -- build 2>/dev/null && pwd -P) || return 1
	# Enumerate direct coreboot-* children of known arch dirs only. No recursive
	# wildcard search: an extraction tree retained under build/ must never be
	# able to supply an executable for --rom-tools.
	if [ "$arch" = ppc64 ]; then
		roots=("$root/ppc64" "$root/x86")
	else
		roots=("$root/x86" "$root/ppc64")
	fi
	for d in "${roots[@]}"; do
		[ -d "$d" ] && [ ! -L "$d" ] || continue
		for c in "$d"/coreboot-*; do
			[ -d "$c" ] && [ ! -L "$c" ] || continue
			# Some tools are built in the board output directory, flat or
			# under its util/ subdirectory. If the ZIP path does not name a
			# board, probe the direct (non-symlink) board-output children of
			# this coreboot build, never extraction trees.
			boards=()
			if [ -n "$board" ]; then
				boards=("$board")
			else
				for b in "$c"/*; do
					[ -d "$b" ] && [ ! -L "$b" ] || continue
					[ "$(basename "$b")" = util ] && continue
					case "$b" in "$extract_abs"/*) continue ;; esac
					boards+=("$(basename "$b")")
				done
			fi
			for b in "${boards[@]}"; do
				[ -d "$c/$b" ] && [ ! -L "$c/$b" ] || continue
				for f in "$c/$b/$name" "$c/$b/util/$name/$name"; do
					trusted_tool_file "$f" && [ -x "$f" ] && { echo "$f"; return 0; }
				done
			done
			for f in "$c/util/$name/$name" "$c/util/$name"; do
				trusted_tool_file "$f" && [ -x "$f" ] && { echo "$f"; return 0; }
			done
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

# Pick the single ROM in one extracted tree, independent of member names.
select_rom() {
	local dir=$1 f n=0 out=""
	while IFS= read -r -d '' f; do
		n=$((n + 1))
		out=$f
	done < <(find "$dir" -type f -name '*.rom' -print0 2>/dev/null)
	[ "$n" -le 1 ] || { echo "multiple ROMs in $dir; skipping ROM tools" >&2; return 1; }
	[ "$n" -eq 1 ] && printf '%s' "$out"
	return 0
}

# Print archive details and checksums/modes/mtimes for every member, then
# extract members into the given directory for byte-level comparison.
inspect() {
	local z=$1 out=$2 label=$3
	mkdir -p "$out"
	echo "== archive: $label"
	printf '%s  %s\n' "$(sha256sum "$z" | cut -d' ' -f1)" "$label"
	echo "-- listing --"
	{ unzip -lv "$z" || unzip -l "$z"; } 2>/dev/null | grep -v '^Archive:' || true
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

inspect "$tmp/input1.zip" "$tmp/a" "$zip1"
[ -n "$extract_dir" ] && echo "extracted: $tmp/a"

if [ "$disassemble" -eq 1 ] || [ -z "$zip2" ]; then
	[ -z "$zip2" ] && [ "$rom_tools" -eq 1 ] && echo "note: --rom-tools compares two ROMs; provide a second ZIP"
	exit 0
fi

echo
inspect "$tmp/input2.zip" "$tmp/b" "$zip2"
[ -n "$extract_dir" ] && echo "extracted: $tmp/b"

echo
echo "== comparison: $zip1 vs $zip2 =="
cmp_rc=0
cmp -s "$tmp/input1.zip" "$tmp/input2.zip" || cmp_rc=$?
if [ "$cmp_rc" -eq 0 ]; then
	echo "zip: identical"
	rc=0
elif [ "$cmp_rc" -eq 1 ]; then
	echo "zip: different"
	cmp -l "$zip1" "$zip2" | head -20 || true
	rc=1
else
	echo "zip: comparison error (cmp exit $cmp_rc)" >&2
	rc=1
fi

# Compare every member present in either archive. For manifest files, also
# compare the sorted hash-entry lines so an empty sorted diff reveals an
# ordering-only difference in otherwise identical content.
while IFS= read -r -d '' m; do
	ma="$tmp/a/$m"; mb="$tmp/b/$m"
	if [ ! -f "$ma" ]; then echo "member only in second: $m"; rc=1; continue; fi
	if [ ! -f "$mb" ]; then echo "member only in first: $m"; rc=1; continue; fi
	member_cmp_rc=0
	cmp -s "$ma" "$mb" || member_cmp_rc=$?
	if [ "$member_cmp_rc" -eq 0 ]; then
		echo "member identical: $m"
	elif [ "$member_cmp_rc" -eq 1 ]; then
		echo "member different: $m"
		diff -u "$ma" "$mb" | head -80 || true
		case "$(basename "$m")" in
			hashes.txt|sizes.txt)
				if [ "$(basename "$m")" = sizes.txt ]; then
					entry='^[[:space:]]*[0-9][0-9]*:'
				else
					entry='^[\\]\?[0-9a-f]\{64\}  '
				fi
				echo "-- sorted entry diff (header/order-only differences excluded) --"
				diff -u \
					<(grep "$entry" "$ma" | LC_ALL=C sort) \
					<(grep "$entry" "$mb" | LC_ALL=C sort) | head -80 || true
				;;
		esac
		rc=1
	else
		echo "member comparison error (cmp exit $member_cmp_rc): $m" >&2
		rc=1
	fi
done < <( (cd "$tmp/a" && find . -type f -print0; cd "$tmp/b" && find . -type f -print0) 2>/dev/null | LC_ALL=C sort -zu )

# Optionally diff ROM structure with host-built coreboot tools from the local
# build tree to attribute content differences to flash regions or CBFS entries.
inspection_failed=0
rom_a=$(select_rom "$tmp/a") || rom_a=""
rom_b=$(select_rom "$tmp/b") || rom_b=""
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
