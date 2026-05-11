#!/bin/bash
# ISO boot tool test harness
#
# Tests the actual Heads scripts generically:
#   - kexec-parse-boot.sh  parses any GRUB/syslinux config
#   - kexec-parse-bls.sh   parses BootLoaderSpec configs
#   - unpack_initramfs.sh  extracts any multi-segment initrd
#   - kexec-iso-init.sh    layered ISO boot flow
#
# Per-ISO expectations (all automated):
#   PARSES       - scanner finds >=1 boot entry
#   KERNEL_OK    - at least one entry's kernel path is a real file on the media
#                  (release ISOs include bonus/memtest entries; missing optional files OK)
#   INITRD_OK    - at least one entry with initrd has a real file (N/A if no initrd)
#   FS_COMPAT    - initrd has ext4 module or zero modules (built-in, e.g. Fedora)
#   LOOPBACK     - loopback.cfg classification: INLINE has menuentry,
#                  SOURCE names a file that exists; NONE is acceptable
#   VARS_OK      - at least one entry has no unresolved ${var} or $var remnants
#
# Usage:
#   ./run.sh                                          # mock trees only (fast)
#   ./run.sh --with-isos [<path>]                     # mock trees + ISOs in path
#   ./run.sh --with-isos --iso-dir <dir> [--single <f>]  # same with flags
#   ./run.sh --help                                   # show this help

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WITH_ISOS="n"
ISO_DIR=""
SINGLE_ISO=""

while [ $# -gt 0 ]; do
	case "$1" in
		--help|-h)
			cat <<'HELP'
Usage: ./run.sh [OPTIONS]

ISO boot tool test harness. Tests Heads scripts: kexec-parse-boot.sh,
kexec-parse-bls.sh, unpack_initramfs.sh, and kexec-iso-init.sh.

Options:
  --help, -h           Show this help message and exit
  --with-isos [<path>] Enable real ISO tests. <path> can be a directory
                       of *.iso files or a single .iso file.
  --iso-dir <dir>      Directory containing ISO files (alternative to
                       positional <path> in --with-isos)
  --single <file>      Test only one ISO file inside the ISO directory

Examples:
  ./run.sh                                    mock trees only
  ./run.sh --with-isos /path/to/isos           custom ISO directory
  ./run.sh --with-isos /path/to/foo.iso        single ISO file
  ./run.sh --with-isos --iso-dir /path --single foo.iso
HELP
			exit 0
			;;
		--with-isos)
			WITH_ISOS="y"
			shift
			if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
				ISO_DIR="$1"
				shift
			fi
			;;
		--iso-dir)
			shift; ISO_DIR="$1"; shift ;;
		--single)
			shift; SINGLE_ISO="$1"; shift ;;
		*)
			echo "Unknown option: $1"
			echo "Use --help for usage"
			exit 1
			;;
	esac
done

# No default — --with-isos requires an explicit path
if [ "$WITH_ISOS" = "y" ] && [ -z "$ISO_DIR" ]; then
	echo "ERROR: --with-isos requires a path (directory or .iso file)"
	echo "  ./run.sh --with-isos /path/to/isos"
	echo "  ./run.sh --with-isos /path/to/file.iso"
	exit 1
fi
if [ -f "$ISO_DIR" ]; then
	ISOS="$(dirname "$ISO_DIR")"
	SINGLE_ISO="${SINGLE_ISO:-$(basename "$ISO_DIR")}"
else
	ISOS="$ISO_DIR"
fi
TMPDIR="/tmp/iso_test_$$"
mkdir -p "$TMPDIR"

# Check required tools
MISSING=""
for tool in cpio cp sed xxd; do
	command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
	echo "ERROR: missing required tool(s):$MISSING"
	echo "  These are needed for generating mock initrds and running Heads scripts."
	[ "$WITH_ISOS" = "y" ] && command -v fuseiso >/dev/null 2>&1 || \
		[ "$WITH_ISOS" = "y" ] && echo "  Also need fuseiso for --with-isos (apt install fuseiso)"
	exit 1
fi
# fuseiso required for ISO tests, checked per-section
if [ "$WITH_ISOS" = "y" ] && ! command -v fuseiso >/dev/null 2>&1; then
	echo "ERROR: --with-isos requires fuseiso"
	echo "  Install: apt install fuseiso  (or your distro's equivalent)"
	exit 1
fi

PASS=0
FAIL=0
SKIP=0

cleanup() {
	mount | grep "$TMPDIR" | awk '{print $3}' | while read m; do
		fusermount -zu "$m" 2>/dev/null || true
	done
	rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT

TESTDATA="$TMPDIR/testdata"
generate_mock_trees() {
	local d="$TESTDATA"
	# bls-format: BLS entries via loader/entries/*.conf
	mkdir -p "$d/bls-format/boot/grub" "$d/bls-format/boot/loader/entries" && cat >"$d/bls-format/boot/grub/grub.cfg" <<'EOF'
set default="0"
set timeout=5
EOF
	cat >"$d/bls-format/boot/loader/entries/fedora-43.conf" <<'EOF'
title Fedora 43
linux /vmlinuz-6.12.0
initrd /initramfs-6.12.0.img
options quiet splash
EOF
	touch "$d/bls-format/vmlinuz-6.12.0" "$d/bls-format/initramfs-6.12.0.img"

	# dash-separator: GRUB with --- marker in append
	mkdir -p "$d/dash-separator/boot/grub" && cat >"$d/dash-separator/boot/grub/grub.cfg" <<'EOF'
menuentry "Test" {
    linux /boot/vmlinuz quiet splash --- nomodeset
    initrd /boot/initrd.img
}
EOF
	touch "$d/dash-separator/boot/vmlinuz" "$d/dash-separator/boot/initrd.img"

	# deep-path-grub: long store paths like NixOS
	mkdir -p "$d/deep-path-grub/boot/grub" "$d/deep-path-grub/boot" && cat >"$d/deep-path-grub/boot/grub/grub.cfg" <<'EOF'
menuentry "NixOS" {
    linux /boot//nix/store/hash-linux-6.12/bzImage
    initrd /boot//nix/store/hash-initrd/initrd
}
EOF
	cat >"$d/deep-path-grub/boot/grub/loopback.cfg" <<'EOF'
source /boot/grub/grub.cfg
EOF
	touch "$d/deep-path-grub/boot/vmlinuz" 2>/dev/null; mkdir -p "$d/deep-path-grub/boot/nix/store/hash-linux-6.12" "$d/deep-path-grub/boot/nix/store/hash-initrd" && touch "$d/deep-path-grub/boot/nix/store/hash-linux-6.12/bzImage" "$d/deep-path-grub/boot/nix/store/hash-initrd/initrd"

	# grub-vars: ${var} and $var references
	mkdir -p "$d/grub-vars/boot/grub" "$d/grub-vars/casper" && cat >"$d/grub-vars/boot/grub/loopback.cfg" <<'EOF'
menuentry "Ubuntu" {
    linux /casper/vmlinuz iso-scan/filename=${iso_path} quiet splash $isofile
    initrd /casper/initrd
}
EOF
	touch "$d/grub-vars/casper/vmlinuz" "$d/grub-vars/casper/initrd"

	# loopback-inline-vars: INLINE loopback.cfg with GRUB vars
	mkdir -p "$d/loopback-inline-vars/boot/grub" "$d/loopback-inline-vars/casper" && cat >"$d/loopback-inline-vars/boot/grub/loopback.cfg" <<'EOF'
menuentry "Try Ubuntu" {
    linux /casper/vmlinuz iso-scan/filename=${iso_path} quiet splash
    initrd /casper/initrd
}
menuentry "Safe mode" {
    linux /casper/vmlinuz nomodeset quiet splash
    initrd /casper/initrd
}
EOF
	touch "$d/loopback-inline-vars/casper/vmlinuz" "$d/loopback-inline-vars/casper/initrd"

	# loopback-source: SOURCE loopback.cfg
	mkdir -p "$d/loopback-source/boot/grub" "$d/loopback-source/live" && cat >"$d/loopback-source/boot/grub/loopback.cfg" <<'EOF'
source /boot/grub/grub.cfg
EOF
	cat >"$d/loopback-source/boot/grub/grub.cfg" <<'EOF'
menuentry "Debian Live" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd.img
}
menuentry "Failsafe" {
    linux /live/vmlinuz memtest noapic
    initrd /live/initrd.img
}
EOF
	touch "$d/loopback-source/live/vmlinuz" "$d/loopback-source/live/initrd.img"

	# loopback-source-grub2: SOURCE loopback.cfg under grub2/
	mkdir -p "$d/loopback-source-grub2/boot/grub2" "$d/loopback-source-grub2/images/pxeboot" && cat >"$d/loopback-source-grub2/boot/grub2/loopback.cfg" <<'EOF'
source /boot/grub2/grub.cfg
EOF
	cat >"$d/loopback-source-grub2/boot/grub2/grub.cfg" <<'EOF'
menuentry "Fedora Live" {
    linux /images/pxeboot/vmlinuz root=live:CDLABEL=quiet rhgb rd.live.image
    initrd /images/pxeboot/initrd.img
}
EOF
	touch "$d/loopback-source-grub2/images/pxeboot/vmlinuz" "$d/loopback-source-grub2/images/pxeboot/initrd.img"

	# no-loopback: grub.cfg without loopback.cfg
	mkdir -p "$d/no-loopback/boot/grub" "$d/no-loopback/casper" && cat >"$d/no-loopback/boot/grub/grub.cfg" <<'EOF'
menuentry "Ubuntu" {
    linux /casper/vmlinuz quiet splash
    initrd /casper/initrd
}
menuentry "Ubuntu safe" {
    linux /casper/vmlinuz nomodeset quiet splash
    initrd /casper/initrd
}
EOF
	touch "$d/no-loopback/casper/vmlinuz" "$d/no-loopback/casper/initrd"

	# syslinux-iso: syslinux LABEL entries
	mkdir -p "$d/syslinux-iso/boot/grub" "$d/syslinux-iso/isolinux" "$d/syslinux-iso/live" && cat >"$d/syslinux-iso/boot/grub/grub.cfg" <<'EOF'
menuentry "Debian Live" {
    linux /live/vmlinuz boot=live quiet
    initrd /live/initrd.img
}
EOF
	cat >"$d/syslinux-iso/isolinux/isolinux.cfg" <<'EOF'
default live
label live
    linux /live/vmlinuz
    initrd /live/initrd.img
    append boot=live quiet
EOF
	touch "$d/syslinux-iso/live/vmlinuz" "$d/syslinux-iso/live/initrd.img"

	# tab-indented: GRUB with TAB characters
	mkdir -p "$d/tab-indented/boot/grub" "$d/tab-indented/boot" && cat >"$d/tab-indented/boot/grub/grub.cfg" <<'EOF'
menuentry "Test" {
	linux	/boot/vmlinuz	quiet splash
	initrd	/boot/initrd.img
}
EOF
	touch "$d/tab-indented/boot/vmlinuz" "$d/tab-indented/boot/initrd.img"
}

# Use the real Heads scripts under /tmp/ so all relative paths resolve.
# Heads scripts source . /etc/functions.sh and . /etc/gui_functions.sh;
# we copy them to /tmp/heads/etc/ and patch the scripts to match.
HEADSTMP="$TMPDIR/heads"
mkdir -p "$HEADSTMP/etc" "$HEADSTMP/bin"
cp "$SCRIPT_DIR/../../initrd/etc/functions.sh" "$HEADSTMP/etc/"
cp "$SCRIPT_DIR/../../initrd/etc/gui_functions.sh" "$HEADSTMP/etc/"

# Set up /tmp/heads/bin/ scripts with corrected source paths
setup_host_script() {
	local script="$1" out="$2"
	sed "s|\. /etc/functions\.sh|. $HEADSTMP/etc/functions.sh|; s|\. /etc/gui_functions\.sh|. $HEADSTMP/etc/gui_functions.sh|" "$script" >"$out"
	chmod +x "$out"
	echo "$out"
}

PARSER=$(setup_host_script "$SCRIPT_DIR/../../initrd/bin/kexec-parse-boot.sh" "$HEADSTMP/bin/kexec-parse-boot.sh")
BLS_PARSER=$(setup_host_script "$SCRIPT_DIR/../../initrd/bin/kexec-parse-bls.sh" "$HEADSTMP/bin/kexec-parse-bls.sh")
UNPACKER=$(setup_host_script "$SCRIPT_DIR/../../initrd/bin/unpack_initramfs.sh" "$HEADSTMP/bin/unpack_initramfs.sh")
SELECTOR=$(setup_host_script "$SCRIPT_DIR/../../initrd/bin/kexec-select-boot.sh" "$HEADSTMP/bin/kexec-select-boot.sh")

# Extract boot_marker() and fmt_boot_target() as a sourceable snippet.
# These are the Heads formatting functions that determine how entries
# appear in the boot menu — the test harness must use the exact same code.
FORMAT_HELPERS="$HEADSTMP/bin/_format_helpers.sh"
{
	echo ". $HEADSTMP/etc/functions.sh"
	sed -n '/^boot_marker()/,/^}/p' "$SCRIPT_DIR/../../initrd/bin/kexec-select-boot.sh"
	sed -n '/^# Format kernel\/initrd/,/^}/p' "$SCRIPT_DIR/../../initrd/bin/kexec-select-boot.sh" | tail -n +2
} > "$FORMAT_HELPERS"

# Parse a pipe-delimited entry line into global vars
parse_entry() {
	local entry="$1"
	entry_name=$(echo "$entry" | cut -d'|' -f1)
	entry_type=$(echo "$entry" | cut -d'|' -f2)
	local rest
	rest=$(echo "$entry" | cut -d'|' -f3-)
	entry_kernel=""; entry_initrd=""; entry_append=""
	local old_ifs="$IFS"; IFS='|'
	for part in $rest; do
		case "$part" in
			kernel*) entry_kernel="${part#kernel }" ;;
			initrd*) entry_initrd="${part#initrd }" ;;
			append*) entry_append="${part#append }" ;;
		esac
	done
	IFS="$old_ifs"
}

# Check if entry has unresolved GRUB variables ($var or ${var})
has_unresolved_vars() {
	echo "$entry_kernel $entry_initrd $entry_append" | grep -qE '\$\{?[a-zA-Z_][a-zA-Z0-9_]*\}?'
}

# Verify parsed entries against filesystem
# Returns: "TOTAL_K KERNEL INITRD VARS" where KERNEL/INITRD/VARS = OK/FAIL/N/A
verify_entries() {
	local bootdir="$1" entries_file="$2"
	local total
	total=$(wc -l < "$entries_file" 2>/dev/null || echo 0)

	[ "$total" -eq 0 ] && { echo "0 FAIL N/A FAIL"; return; }

	local k_ok=0 i_ok=0 i_entries=0 v_ok=0
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		parse_entry "$entry"

		# KERNEL_OK
		[ -n "$entry_kernel" ] && [ -f "$bootdir/${entry_kernel#/}" ] && k_ok=$((k_ok+1))

		# INITRD_OK
		if [ -n "$entry_initrd" ]; then
			i_entries=$((i_entries+1))
			local all_ok=true
			for ip in $(echo "$entry_initrd" | tr ',' ' '); do
				[ -f "$bootdir/${ip#/}" ] || all_ok=false
			done
			$all_ok && i_ok=$((i_ok+1))
		fi

		# VARS_OK
		has_unresolved_vars || v_ok=$((v_ok+1))
	done < "$entries_file"

	local k="FAIL" i="N/A" v="FAIL"
	[ "$k_ok" -gt 0 ] && k="OK"
	[ "$i_entries" -gt 0 ] && [ "$i_ok" -gt 0 ] && i="OK"
	[ "$v_ok" -gt 0 ] && v="OK"
	echo "$total $k $i $v"
}

# Classify loopback.cfg: NONE / INLINE / SOURCE / OTHER
# Returns classification and validates SOURCE file exists
classify_loopback() {
	local mnt="$1"
	for lb in "boot/grub/loopback.cfg" "boot/grub2/loopback.cfg"; do
		[ -f "$mnt/$lb" ] || continue
		local content
		content=$(cat "$mnt/$lb")
		if echo "$content" | grep -q 'menuentry'; then
			echo "INLINE"
		elif echo "$content" | grep -q '^source '; then
			local src_file
			src_file=$(echo "$content" | grep '^source ' | sed 's/^source //' | head -1)
			if [ -n "$src_file" ] && [ -f "$mnt/$src_file" ]; then
				echo "SOURCE"
			else
				echo "SOURCE(MISSING:$src_file)"
			fi
		else
			echo "OTHER"
		fi
		return
	done
	echo "NONE"
}

# Check initrd fs compatibility from parsed boot entries.
# Uses generic kmod lookup matching kexec-iso-init.sh's initrd_fs_type_to_kmod().
# @param fstype  filesystem type to check for (default ext4)
# Also prints per-initrd detail: path, .ko count, and [OK]/[!] status.
# Returns: OK / MOD / N/A summary for test counting.
#   OK  = at least one initrd has the needed module (as .ko or builtin)
#   MOD = no initrd has it, but some have modules
#   N/A = no initrd found
check_fs_compat() {
	local mnt="$1" entries_file="$2" fstype="${3:-ext4}"
	local initrd_paths="" initrd="" kmod
	kmod=$(fstype_to_kmod "$fstype")

	# Collect all unique initrd paths from parsed boot entries
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		local f4 path
		f4=$(echo "$entry" | cut -d\| -f4)
		case "$f4" in
			initrd\ *) path="${f4#initrd }"; [ -f "$mnt/$path" ] && case " $initrd_paths " in *" $path "*) ;; *) initrd_paths="$initrd_paths $path" ;; esac ;;
		esac
	done < "$entries_file"
	[ -z "$initrd_paths" ] && echo "N/A" && return

	local best="N/A"
	echo "    Initrds:" >&2
	for p in $initrd_paths; do
		initrd="$mnt/$p"
		local unpack_dir
		unpack_dir=$(mktemp -p "$TMPDIR" -d)
		"$UNPACKER" "$initrd" "$unpack_dir" 2>/dev/null || true

		local ko_count mod_status
		ko_count=$(find "$unpack_dir" -name "*.ko*" -type f 2>/dev/null | wc -l)
		if [ "$ko_count" -eq 0 ]; then
			mod_status=""  # no modules → can't verify, no marker
		elif find "$unpack_dir" -name "*.ko*" 2>/dev/null | grep -q "${kmod}" 2>/dev/null; then
			mod_status="[OK]"
			[ "$best" = "N/A" ] && best="OK"
		elif grep -q "${kmod}" "$unpack_dir/lib/modules/"*/modules.builtin 2>/dev/null; then
			mod_status="[OK]"
			[ "$best" = "N/A" ] && best="OK"
		else
			mod_status="[!]"
			[ "$best" != "OK" ] && best="MOD"
		fi
		printf "      %-50s %5d .ko  %s\n" "${p:0:50}" "$ko_count" "$mod_status" >&2
		rm -rf "$unpack_dir" 2>/dev/null || true
	done

	echo "$best"
}

# Print a table row for an ISO/test tree
# Usage: print_row "label" "entries" "kernel" "initrd" "fs_compat" "loopback" "vars"
print_row() {
	printf "%-55s %-7s %-6s %-6s %-8s %-10s %s\n" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# Check a single initrd for ext4 module support (with cache)
# Reports: [OK] if ext4.ko found in initrd, or no modules (built-in heuristic)
#         [!]  if initrd has modules but no ext4.ko
#         empty if no initrd in entry
# NOTE: ext4 is almost always built into the kernel, not in the initrd.
# [!] does NOT mean boot will fail — it means we can't verify from initrd alone.
# Map blkid fstype to kernel module name (must match initrd_fs_type_to_kmod()
# in kexec-iso-init.sh).  vfat/msdos use "fat", everything else matches the fstype.
fstype_to_kmod() {
	case "$1" in
	vfat|msdos)	echo "fat" ;;
	*)		echo "$1" ;;
	esac
}

ESC=$'\033'; GRN="${ESC}[0;32m"; YLW="${ESC}[1;33m"; RST="${ESC}[0m"
# Check single initrd for a kernel module matching the given fstype (default: ext4).
# Returns [OK] if module found as .ko or in modules.builtin, [!] if initrd has
# modules but not the needed one, empty if no initrd or no modules (can't verify).
check_single_initrd() {
	local path="$1"
	local fstype="${2:-ext4}"
	[ -f "$path" ] || { echo ""; return; }
	local cache_key
	cache_key=$(echo "$path$fstype" | tr '/' '_' | tr -d ' ')
	[ -n "$cache_key" ] && [ -f "$TMPDIR/initrd_cache_$cache_key" ] && { cat "$TMPDIR/initrd_cache_$cache_key"; return; }
	local ud
	ud=$(mktemp -p "$TMPDIR" -d)
	"$UNPACKER" "$path" "$ud" 2>/dev/null || true
	local result="" kmod
	kmod=$(fstype_to_kmod "$fstype")
	local ha
	ha=$(find "$ud" -name "*.ko*" -type f 2>/dev/null | head -1)
	if [ -z "$ha" ]; then
		result=""  # no modules → can't verify, no marker
	elif find "$ud" -name "*.ko*" 2>/dev/null | grep -q "${kmod}" 2>/dev/null; then
		result="${GRN}[OK]${RST}"
	elif grep -q "${kmod}" "$ud/lib/modules/"*/modules.builtin 2>/dev/null; then
		result="${GRN}[OK]${RST}"
	else
		result="${YLW}[!]${RST}"
	fi
	rm -rf "$ud" 2>/dev/null
	[ -n "$cache_key" ] && [ -n "$result" ] && echo "$result" > "$TMPDIR/initrd_cache_$cache_key"
	[ -n "$result" ] && echo "$result" || echo ""
}

# Process an ISO or mock tree: parse entries, verify, classify loopback, check fs compat
# Returns: "TOTAL KERNEL INITRD VARS" (space-separated, without trailing newline issues)
process_media() {
	local label="$1" bootdir="$2" entries_file="$3"
	local result_file="$TMPDIR/${label}_result.txt"

	# Parse entries
	: > "$entries_file"
	while IFS= read -r cfg; do
		[ -f "$cfg" ] || continue
		case "$cfg" in *EFI*|*efi*|*x86_64-efi*) continue ;; esac
		"$PARSER" "$bootdir" "$cfg" >>"$entries_file" 2>/dev/null || true
	done < <(find "$bootdir" -name '*.cfg' -type f 2>/dev/null)

	# BLS fallback
	blsdir="$bootdir/boot/loader/entries"
	if [ ! -s "$entries_file" ] && [ -d "$blsdir" ]; then
		ref_cfg=$(find "$bootdir" -name 'grub.cfg' -type f | head -1)
		[ -n "$ref_cfg" ] && "$BLS_PARSER" "$bootdir" "$ref_cfg" "$blsdir" >>"$entries_file" 2>/dev/null || true
	fi

	# Verify entries
	local result
	result=$(verify_entries "$bootdir" "$entries_file")
	echo "$result" > "$result_file"
}

echo "============================================================"
echo "  ISO BOOT TEST HARNESS"
echo "============================================================"
echo ""

# ============================================================================
# SECTION 1: Mock tree parser verification
# ============================================================================
generate_mock_trees
echo "=== SECTION 1: Mock tree parser verification ==="
echo ""

print_row "Mock tree" "Entries" "Kernel" "Initrd" "Vars" "Loopback" ""
print_row "-------" "-------" "------" "------" "----" "--------" "---"

for testdir in "$TESTDATA"/*/; do
	testname=$(basename "$testdir")
	[ -d "$testdir" ] || continue

	lb=$(classify_loopback "$testdir")
	entries_file="$TMPDIR/${testname}_entries.txt"
	result_file="$TMPDIR/${testname}_result.txt"
	process_media "$testname" "$testdir" "$entries_file"

	read -r total k_val i_val v_val < "$result_file"

	# PARSES
	[ "$total" -gt 0 ] && PASS=$((PASS+1)) || { echo "  FAIL: $testname: no boot entries parsed"; FAIL=$((FAIL+1)); }
	# KERNEL ok
	[ "$k_val" = "OK" ] && PASS=$((PASS+1)) || { [ "$k_val" != "N/A" ] && { echo "  FAIL: $testname: no entry has a reachable kernel file"; FAIL=$((FAIL+1)); }; }
	# INITRD ok
	[ "$i_val" = "OK" ] && PASS=$((PASS+1)) || { [ "$i_val" != "N/A" ] && { echo "  FAIL: $testname: no entry has a reachable initrd file"; FAIL=$((FAIL+1)); }; }
	# VARS ok
	[ "$v_val" = "OK" ] && PASS=$((PASS+1)) || { [ "$v_val" != "N/A" ] && { echo "  FAIL: $testname: all entries have unresolved GRUB variables"; FAIL=$((FAIL+1)); }; }

	print_row "$testname" "$total" "$k_val" "$i_val" "$v_val" "$lb" ""
done

echo ""
echo "  Mock tree summary: parsers handle tabs, --- markers, GRUB vars, BLS, syslinux"
echo ""

# ============================================================================
# SECTION 2: unpack_initramfs.sh — generic multi-segment initrd unpacking
# ============================================================================
echo "=== SECTION 2: unpack_initramfs.sh ==="
echo ""

# Create minimal mock initrds to verify unpacker works
mk_initrd() {
	local name="$1" ; shift
	local dest="$TMPDIR/${name}_initrd.cpio"
	local root="$TMPDIR/${name}_initrd_root"
	rm -rf "$root" "$dest" 2>/dev/null
	mkdir -p "$root"
	for f in "$@"; do
		mkdir -p "$(dirname "$root/$f")"
		echo "content" > "$root/$f"
	done
	(cd "$root" && find . -type f | cpio -o -H newc --quiet 2>/dev/null) > "$dest"
	echo "$dest"
}

# Test 1: simple initrd (single file, no subdirs)
simple=$(mk_initrd "simple" "init")

# Test 2: initrd with kernel modules (deep subdirs, no directory entries in cpio)
withmods=$(mk_initrd "withmods" \
	"lib/modules/6.1.0/kernel/fs/ext4/ext4.ko" \
	"lib/modules/6.1.0/kernel/fs/fat/fat.ko" \
	"lib/modules/6.1.0/kernel/drivers/usb/usb-storage.ko" \
	"init")

# Test 3: multi-segment initrd (simulated by concatenating two cpio archives)
seg1=$(mk_initrd "seg1" "early/init")
seg2=$(mk_initrd "seg2" "main/init" "main/modules.ko")
multi="$TMPDIR/multi_initrd.cpio"
cat "$seg1" "$seg2" > "$multi"

unpack_and_count() {
	local initrd="$1" label="$2" expected_min="${3:-1}"
	local dest="$TMPDIR/unpack_$$"
	mkdir -p "$dest"
	"$UNPACKER" "$initrd" "$dest" 2>/dev/null || true
	local count
	count=$(find "$dest" -type f 2>/dev/null | wc -l)
	rm -rf "$dest" 2>/dev/null || true
	[ "$count" -ge "$expected_min" ] && echo "  PASS: $label ($count files)" && PASS=$((PASS+1)) || \
		{ echo "  FAIL: $label (expected >=$expected_min, got $count)"; FAIL=$((FAIL+1)); }
}

unpack_and_count "$simple" "simple initrd"
unpack_and_count "$withmods" "initrd with kernel modules" 3
unpack_and_count "$multi" "multi-segment initrd" 3

# Verify module detection in unpacked initrd
dest="$TMPDIR/mod_check_$$"
mkdir -p "$dest"
"$UNPACKER" "$withmods" "$dest" 2>/dev/null || true
for mod in ext4 fat; do
	if find "$dest" -name "*.ko*" 2>/dev/null | grep -q "$mod"; then
		echo "  PASS: module $mod found"
		PASS=$((PASS+1))
	else
		echo "  FAIL: module $mod not found"
		FAIL=$((FAIL+1))
	fi
done
rm -rf "$dest" 2>/dev/null || true

# Test: no kernel modules (minimal initrd) -> should produce no marker (can't verify)
nomods=$(mk_initrd "nomods" "init" "bin/systemd" "etc/fstab")
echo ""
echo "  Initrd detail:"
check_and_report_initrd() {
	local path="$1" label="$2" fstype="${3:-ext4}"
	local ud="$TMPDIR/initrd_detail_$$"
	mkdir -p "$ud"
	"$UNPACKER" "$path" "$ud" 2>/dev/null || true
	local kcount kmod result
	kcount=$(find "$ud" -name "*.ko*" -type f 2>/dev/null | wc -l)
	kmod=$(fstype_to_kmod "$fstype")
	if [ "$kcount" -eq 0 ]; then
		result=""
	elif find "$ud" -name "*.ko*" 2>/dev/null | grep -q "${kmod}" 2>/dev/null; then
		result="[OK]"
	elif grep -q "${kmod}" "$ud/lib/modules/"*/modules.builtin 2>/dev/null; then
		result="[OK]"
	else
		result="[!]"
	fi
	printf "    %-35s %5d .ko  %s\n" "$label" "$kcount" "$result"
	rm -rf "$ud" 2>/dev/null || true
}
check_and_report_initrd "$simple" "simple initrd (no modules)"
check_and_report_initrd "$withmods" "with ext4/fat modules" "ext4"
check_and_report_initrd "$withmods" "with modules, check btrfs" "btrfs"
check_and_report_initrd "$multi" "multi-segment initrd" "ext4"
check_and_report_initrd "$nomods" "no modules (minimal)" "ext4"
echo "  Legend: [OK]=module found  [!]=modules present but not needed one  (blank)=no modules can't verify"
echo ""

dest="$TMPDIR/nomods_check_$$"
mkdir -p "$dest"
"$UNPACKER" "$nomods" "$dest" 2>/dev/null || true
ko_count=$(find "$dest" -name "*.ko*" -type f 2>/dev/null | wc -l)
if [ "$ko_count" -eq 0 ]; then
	echo "  PASS: no-modules initrd ($ko_count .ko files) -> no marker (can't verify)"
	PASS=$((PASS+1))
else
	echo "  FAIL: no-modules initrd unexpectedly has $ko_count .ko files"
	FAIL=$((FAIL+1))
fi
rm -rf "$dest" 2>/dev/null || true

echo ""

# ============================================================================
# SECTION 3: Real ISO matrix with active verification
# ============================================================================
echo "=== SECTION 3: Real ISO verification ==="
echo ""

if [ "$WITH_ISOS" = "y" ]; then
	print_row "ISO" "Entries" "Kernel" "Initrd" "FS_Compat" "Loopback" "Vars"
	print_row "---" "-------" "------" "------" "---------" "--------" "----"

	for iso in "$ISOS"/*.iso; do
		[ -f "$iso" ] || continue
		iso_name=$(basename "$iso")
		[ -n "$SINGLE_ISO" ] && [ "$iso_name" != "$SINGLE_ISO" ] && continue
		mnt="$TMPDIR/mnt_$$_$RANDOM"
		mkdir -p "$mnt"
		if ! fuseiso -n "$iso" "$mnt" 2>/dev/null; then
			printf "%-55s %s\n" "$iso_name" "MOUNTFAIL"
			echo "  FAIL: $iso_name: fuseiso mount failed"
			FAIL=$((FAIL+1))
			rmdir "$mnt" 2>/dev/null || true
			continue
		fi

		entries_file="$TMPDIR/${iso_name}_entries.txt"
		result_file="$TMPDIR/${iso_name}_result.txt"
		process_media "$iso_name" "$mnt" "$entries_file"
		read -r total k_val i_val v_val < "$result_file"

		# PARSES + KERNEL + INITRD + VARS
		[ "$total" -gt 0 ] && PASS=$((PASS+1)) || { echo "  FAIL: $iso_name: no boot entries parsed"; FAIL=$((FAIL+1)); }
		[ "$k_val" = "OK" ] && PASS=$((PASS+1)) || { [ "$k_val" != "N/A" ] && { echo "  FAIL: $iso_name: no entry has a reachable kernel file"; FAIL=$((FAIL+1)); }; }
		[ "$i_val" = "OK" ] && PASS=$((PASS+1)) || { [ "$i_val" != "N/A" ] && { echo "  FAIL: $iso_name: no entry has a reachable initrd file"; FAIL=$((FAIL+1)); }; }
		[ "$v_val" = "OK" ] && PASS=$((PASS+1)) || { [ "$v_val" != "N/A" ] && { echo "  FAIL: $iso_name: all entries have unresolved GRUB variables"; FAIL=$((FAIL+1)); }; }

		lb=$(classify_loopback "$mnt")
		if echo "$lb" | grep -q "MISSING"; then
			echo "  FAIL: $iso_name: loopback.cfg source directive targets missing file"
			FAIL=$((FAIL+1))
		elif [ "$lb" != "OTHER" ]; then
			PASS=$((PASS+1))
		else
			echo "  FAIL: $iso_name: loopback.cfg has unrecognized format"
			FAIL=$((FAIL+1))
		fi

		fs=$(check_fs_compat "$mnt" "$entries_file" 2>/dev/null)
		if [ "$fs" = "OK" ] || [ "$fs" = "N/A" ] || [ "$fs" = "MOD" ]; then
			PASS=$((PASS+1))
		else
			echo "  FAIL: $iso_name: initrd fs compatibility check returned: $fs"
			FAIL=$((FAIL+1))
		fi

		print_row "$iso_name" "$total" "$k_val" "$i_val" "$fs" "$lb" "$v_val"

		fusermount -zu "$mnt" 2>/dev/null || true
		rmdir "$mnt" 2>/dev/null || true
	done
	echo ""
	echo "  FS_Compat: OK=module found as .ko or builtin; MOD=modules present but not the needed one; N/A=no initrd found; (blank)=no modules, can't verify"
	echo "  Loopback legend:  NONE=no loopback.cfg; INLINE=menuentry in loopback.cfg; SOURCE=source directive to another file"
	echo "  Samsung_SSD and Qubes dir are non-OS ISOs and may show unexpected results"
	echo ""
else
	echo "  SKIP: real ISO tests (use --with-isos <path> to enable)"
	SKIP=$((SKIP+1))
fi

# ============================================================================
# SECTION 4: Boot entries as the user sees them (per-ISO menu display)
# ============================================================================
echo "=== SECTION 4: Boot entries (user-facing menu) ==="
echo ""

if [ "$WITH_ISOS" = "y" ]; then
	for iso in "$ISOS"/*.iso; do
		[ -f "$iso" ] || continue
		iso_name=$(basename "$iso")
		[ -n "$SINGLE_ISO" ] && [ "$iso_name" != "$SINGLE_ISO" ] && continue
		mnt="$TMPDIR/mnt_s4_$$_$RANDOM"
		mkdir -p "$mnt"
		fuseiso -n "$iso" "$mnt" 2>/dev/null || { rmdir "$mnt" 2>/dev/null; continue; }

		entries_file="$TMPDIR/s4_${iso_name}_entries.txt"
		: > "$entries_file"
		while IFS= read -r cfg; do
			[ -f "$cfg" ] || continue
			case "$cfg" in *EFI*|*efi*|*x86_64-efi*) continue ;; esac
			"$PARSER" "$mnt" "$cfg" >>"$entries_file" 2>/dev/null || true
		done < <(find "$mnt" -name '*.cfg' -type f 2>/dev/null)

		if [ -s "$entries_file" ]; then
			echo "  $iso_name"
			echo "    Menu:"
			sed 's/|append \([^|]*\)---[^|]*/|append \1/g' "$entries_file" | sort -t\| -k1 -u > "$entries_file.sorted"

			# Write /tmp/kexec_initrd_compat.txt in the format Heads boot_marker() expects
			compat_file="/tmp/kexec_initrd_compat.txt"
			kmod=$(fstype_to_kmod "${CHECK_FSTYPE:-ext4}")
			: > "$compat_file"
			while IFS= read -r entry; do
				[ -z "$entry" ] && continue
				ef4=$(echo "$entry" | cut -d\| -f4)
				case "$ef4" in
					initrd\ *) rp="${ef4#initrd }"
						[ -f "$mnt/$rp" ] || continue
						grep -q "^${rp#/} " "$compat_file" 2>/dev/null && continue
						ud=$(mktemp -p "$TMPDIR" -d)
						"$UNPACKER" "$mnt/$rp" "$ud" 2>/dev/null || true
						ha=$(find "$ud" -name "*.ko*" -type f 2>/dev/null | head -1)
						if [ -z "$ha" ]; then
							:  # no modules → can't verify, no marker
						elif find "$ud" -name "*.ko*" 2>/dev/null | grep -q "${kmod}" 2>/dev/null; then
							echo "${rp#/} [OK]" >> "$compat_file"
						elif grep -q "${kmod}" "$ud/lib/modules/"*/modules.builtin 2>/dev/null; then
							echo "${rp#/} [OK]" >> "$compat_file"
						else
							echo "${rp#/} [!]" >> "$compat_file"
						fi
						rm -rf "$ud" 2>/dev/null
						;;
				esac
			done < "$entries_file.sorted"

			# Source the Heads formatting functions from the sourceable snippet
			. "$FORMAT_HELPERS"

			n=0
			while IFS= read -r entry; do
				[ -z "$entry" ] && continue
				n=$((n+1))
				name=$(echo "$entry" | cut -d\| -f1)
				kernel=$(echo "$entry" | cut -d\| -f3 | sed 's/^kernel //')
				f4=$(echo "$entry" | cut -d\| -f4)
				initrd=""; params=""
				case "$f4" in
					initrd\ *) initrd="${f4#initrd }"; params=$(echo "$entry" | cut -d\| -f5 | sed 's/append //' | xargs) ;;
					append*) params=$(echo "$f4" | sed 's/^append //' | xargs) ;;
					*) ;;
				esac
				gui_menu="n"
				m=$(boot_marker)
				t=$(fmt_boot_target)
				if [ -n "$m" ]; then
					printf '    %d. %s %s %s %s\n' "$n" "$m" "$name" "${params:+($params)}" "$t"
				else
					printf '    %d. %s %s %s\n' "$n" "$name" "${params:+($params)}" "$t"
				fi
			done < "$entries_file.sorted"

			echo "    Confirmation:"
			n=0
			while IFS= read -r entry; do
				[ -z "$entry" ] && continue
				n=$((n+1))
				en=$(echo "$entry" | cut -d\| -f1)
				ek=$(echo "$entry" | cut -d\| -f3 | sed 's/^kernel //')
				ef4=$(echo "$entry" | cut -d\| -f4)
				ei=""; ep=""
				case "$ef4" in
					initrd*) ei="${ef4#initrd }"; ep=$(echo "$entry" | cut -d\| -f5 | sed 's/^append //' | xargs) ;;
					append*) ep=$(echo "$ef4" | sed 's/^append //' | xargs) ;;
					*) ;;
				esac
				echo "    $n. $en"
				echo "       Kernel: $ek"
				echo "       Initrd: ${ei:--}"
				echo "       Params: ${ep:--}"
			done < "$entries_file.sorted"
			rm -f "$entries_file.sorted"
			echo ""
		fi

		fusermount -zu "$mnt" 2>/dev/null || true
		rmdir "$mnt" 2>/dev/null || true
	done
else
	echo "  (available with --with-isos)"
	echo ""
fi

echo "============================================================"
echo "  RESULTS: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================================"
[ "$FAIL" -eq 0 ]