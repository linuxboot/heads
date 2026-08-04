#! /usr/bin/env bash
set -eo pipefail

# Pre-seed musl-cross-make's component tarballs into the packages directory
# so they are cached alongside all other module tarballs, picked up by
# Purism's package mirror sync, and available for CI cache layers.
#
# usage:
#	$0 <musl-cross-make-dir> <pkgs-dir>
#	$0 --help
#
# Reads component versions and archive names from the musl-cross-make
# source tree (Makefile defaults + hashes/*.sha1), then downloads each
# tarball via fetch_source_archive.sh.
# Uses fetch_source_archive.sh, so the Purism mirrors are used
# as fallback and WGET can override the path to wget.

usage() {
	cat <<USAGE_END
usage:
	$0 <musl-cross-make-dir> <pkgs-dir>
	$0 --help

Reads component versions and archive names from a musl-cross-make
source tree (Makefile defaults + hashes/*.sha1), then downloads each
tarball via fetch_source_archive.sh (primary -> Purism mirror fallback).

Uses fetch_source_archive.sh, so the Purism mirrors are used
as fallback and WGET can override the path to wget.
USAGE_END
}

if [ "$#" -lt 2 ]; then
	usage
	exit 1
fi

MCM_DIR="$(realpath "$1")"
PKGS_DIR="$(realpath "$2")"	# ensure absolute paths
BIN_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Find a glob pattern that matches exactly one file, failing with a
# distinct message for no matches vs. multiple matches.
single() {
	if [ "$#" -eq 1 ]; then
		if [ -f "$1" ]; then
			echo "$1"
			return 0
		fi
	else
		echo "multiple unexpected matches for glob:" "$@" >&2
		exit 1
	fi
	echo "$1: no matches" >&2
	exit 1
}

# Extract a variable from the musl-cross-make Makefile.
# Returns the value of KEY = <value>, or empty string if not found.
make_var() {
	grep -E "^$1[[:space:]]*=" "$MCM_DIR/Makefile" | head -1 \
		| sed "s/^$1[[:space:]]*=[[:space:]]*//"
}

# Resolve the archive name for a component from its hashes file.
# The hashes directory contains files named <prefix>-<version>.tar.*.sha1
# (glob tolerates both .tar.gz and .tar.xz suffixes).
# single() guarantees exactly one match; basename strips the .sha1 suffix
# to give the archive filename.
component_archive() {  # $1 = prefix (gcc, binutils, ...), $2 = version
	basename "$(single "$MCM_DIR/hashes/$1-$2.tar."*.sha1)" .sha1
}

# Download a tarball via fetch_source_archive.sh.
# Digests are SHA-1 (40 chars); fetch_source_archive.sh auto-detects that.
# fetch_source_archive.sh applies the Purism mirror fallback
# keyed on the basename of the destination file.
fetch() {  # $1 = url_base, $2 = filename, $3 = sha1_digest
	"$BIN_DIR/fetch_source_archive.sh" "$1$2" "$PKGS_DIR/$2" "$3"
}

# GNU component versions come from the musl-cross-make Makefile defaults
# and feed component_archive() to resolve the archive filenames.
V_BINUTILS=$(make_var BINUTILS_VER)
V_GCC=$(make_var GCC_VER)
V_GMP=$(make_var GMP_VER)
V_MPC=$(make_var MPC_VER)
V_MPFR=$(make_var MPFR_VER)
V_MUSL=$(make_var MUSL_VER)
V_LINUX=$(make_var LINUX_VER)

# SHA-1 digests are read from hashes/*.sha1 files (format: "digest filename").
# cut extracts the first field.  component_archive() maps version to filename.

# GNU tarballs: use mirrors.kernel.org directly.
# ftpmirror.gnu.org is a redirector that frequently returns 502.
GNU_BASE="https://mirrors.kernel.org/gnu"

# Fetch each component from its upstream source.
# binutils, gcc, gmp, mpc, mpfr come from GNU mirrors.
fetch "$GNU_BASE/binutils/"	"$(component_archive binutils "$V_BINUTILS")"	"$(cut -d' ' -f1 "$MCM_DIR/hashes/$(component_archive binutils "$V_BINUTILS").sha1")"
fetch "$GNU_BASE/gcc/gcc-$V_GCC/" "$(component_archive gcc "$V_GCC")"	"$(cut -d' ' -f1 "$MCM_DIR/hashes/$(component_archive gcc "$V_GCC").sha1")"
fetch "$GNU_BASE/gmp/"		"$(component_archive gmp "$V_GMP")"		"$(cut -d' ' -f1 "$MCM_DIR/hashes/$(component_archive gmp "$V_GMP").sha1")"
fetch "$GNU_BASE/mpc/"		"$(component_archive mpc "$V_MPC")"		"$(cut -d' ' -f1 "$MCM_DIR/hashes/$(component_archive mpc "$V_MPC").sha1")"
fetch "$GNU_BASE/mpfr/"		"$(component_archive mpfr "$V_MPFR")"		"$(cut -d' ' -f1 "$MCM_DIR/hashes/$(component_archive mpfr "$V_MPFR").sha1")"
# musl and Linux headers come from non-GNU hosts.
fetch "https://musl.libc.org/releases/"	"$(component_archive musl "$V_MUSL")"	"$(cut -d' ' -f1 "$MCM_DIR/hashes/$(component_archive musl "$V_MUSL").sha1")"
fetch "https://ftp.barfooze.de/pub/sabotage/tarballs/"	"$(component_archive linux "$V_LINUX")"	"$(cut -d' ' -f1 "$MCM_DIR/hashes/$(component_archive linux "$V_LINUX").sha1")"
