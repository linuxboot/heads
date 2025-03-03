#! /usr/bin/env bash
set -eo pipefail

usage()
{
	cat <<USAGE_END
usage:
	$0 <coreboot-dir> <pkg-name> <pkgs-dir>
	$0 --help

	Downloads the source archive for <pkg-name> needed by coreboot's
	crossgcc toolchain.  The package version and digest are found in
	coreboot-dir.  The package is downloaded to <pkgs-dir>, then placed in
	the coreboot directory.

	Uses fetch_source_archive.sh, so mirrors are used and WGET can override
	the path to wget.
USAGE_END
}

if [ "$#" -lt 3 ]; then
	usage
	exit 1
fi

COREBOOT_DIR="$1"
PKG_NAME="$2"
PKGS_DIR="$(realpath "$3")" # Make sure it's an absolute path

# Get the result of a glob that should match a single thing, or die if it
# doesn't match exactly one thing.
single() {
	if [ "$#" -eq 1 ]; then
		if [ -f "$1" ]; then
			echo "$1"
		else
			echo "$1: no matches" >&2
			exit 1
		fi
	else
		echo "multiple unexpected matches for glob:" "$@" >&2
		exit 1
	fi
}

# Delete prefix and suffix from a value
delete_prefix_suffix() {
	local value prefix suffix
	value="$1"
	prefix="$2"
	suffix="$3"
	value="${value/#$prefix/}"
	value="${value/%$suffix/}"
	echo "$value"
}

# Find the checksum file for this package

# 'iasl' is special-cased.  Before coreboot 4.21, the archive was named
# 'acpica-unix2-<ver>', and the original sources for those archives are gone.
# Since coreboot 4.21, the archive is just named 'R<ver>.tar.gz', it lacks the
# package name.
# If we're fetching iasl, and this is an older release, look for the acpica
# archive.
if [ "$PKG_NAME" = iasl ] && [ -f "$COREBOOT_DIR/util/crossgcc/sum/"acpica-*.cksum ]; then
	PKG_NAME=acpica
fi
# Otherwise, keep 'iasl' to look for the newer archive.

# 'iasl' (4.21+) doesn't include the package name in the archive name, the
# archive is just the release name
if [ "$PKG_NAME" = "iasl" ]; then
	PKG_CKSUM_FILE="$(single "$COREBOOT_DIR/util/crossgcc/sum/"R*.cksum)"
else
	PKG_CKSUM_FILE="$(single "$COREBOOT_DIR/util/crossgcc/sum/$PKG_NAME-"*.cksum)"
fi

PKG_BASENAME="$(basename "$PKG_CKSUM_FILE" .cksum)"
# Get the base URL for the package.  This _is_ duplicated from coreboot's
# buildgcc script, but these don't change much, and when they do we usually want
# to use the newer source anyway for older versions of coreboot (e.g. Intel
# broke all the iasl links - coreboot 90753398).
case "$PKG_NAME" in
	gmp)
		PKG_BASEURL="https://ftpmirror.gnu.org/gmp/"
		;;
	mpfr)
		PKG_BASEURL="https://ftpmirror.gnu.org/mpfr/"
		;;
	mpc)
		PKG_BASEURL="https://ftpmirror.gnu.org/mpc/"
		;;
	gcc)
		PKG_BASEURL="https://ftpmirror.gnu.org/gcc/gcc-$(delete_prefix_suffix "$PKG_BASENAME" gcc- .tar.xz)/"
		;;
	binutils)
		PKG_BASEURL="https://ftpmirror.gnu.org/binutils/"
		;;
	nasm)
		PKG_BASEURL="https://www.nasm.us/pub/nasm/releasebuilds/$(delete_prefix_suffix "$PKG_BASENAME" nasm- .tar.bz2)/"
		;;
	iasl)
		PKG_BASEURL="https://github.com/acpica/acpica/archive/refs/tags/"
		;;
	acpica)
		# Original acpica sources are gone.  Most of the older releases
		# can be found here
		PKG_BASEURL="https://mirror.math.princeton.edu/pub/libreboot/misc/acpica/"
		# Version 20220331 (currently used by talos_2) isn't there, but
		# there is an old link from Intel that is still up.  This is
		# specific to this release.
		if [ "$PKG_BASENAME" = acpica-unix2-20220331.tar.gz ]; then
			PKG_BASEURL="https://downloadmirror.intel.com/774879/"
		fi
		;;
esac

PKG_DIGEST="$(cut -d' ' -f1 "$PKG_CKSUM_FILE")"

BIN_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Download to packages/<arch>
"$BIN_DIR/fetch_source_archive.sh" "$PKG_BASEURL$PKG_BASENAME" \
	"$PKGS_DIR/coreboot-crossgcc-$PKG_BASENAME" "$PKG_DIGEST"

# Copy to the tarballs directory so coreboot's toolchain build will use this
# archive
mkdir -p "$COREBOOT_DIR/util/crossgcc/tarballs"
(
	cd "$COREBOOT_DIR/util/crossgcc/tarballs"
	rm -f "$PKG_BASENAME"
	ln -s "$PKGS_DIR/coreboot-crossgcc-$PKG_BASENAME" "$PKG_BASENAME"
)
