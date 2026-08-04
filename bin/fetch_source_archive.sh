#! /usr/bin/env bash
set -eo pipefail

# Mirror URLs, make sure these end in slashes.
BACKUP_MIRRORS=(
	https://storage.puri.sm/heads-packages/
	https://storage.puri.st/heads-packages/
)

usage()
{
	cat <<USAGE_END
usage:
	$0 <url> <file> <digest>
	$0 --help

	Downloads <url> to <file>, falling back to package mirrors if the
	primary source is not available or does match the expected digest.  The
	digest can be a SHA-256 (preferred) or SHA-1 digest.

	Uses wget, export WGET to override the path to wget.
USAGE_END
}

if [ "$#" -lt 2 ]; then
	usage
	exit 1
fi

URL="$1"
FILE="$2"
DIGEST="$3"

TMP_FILE="$2.tmp"

WGET="${WGET:-wget}"

case "$(echo -n "$DIGEST" | wc -c)" in
	64)
		SHASUM=sha256sum
		;;
	40)
		# coreboot crossgcc archives have SHA-1 digests from coreboot
		SHASUM=sha1sum
		;;
	*)
		echo "Unknown digest for $FILE: $DIGEST" >&2
		exit 1
		;;
esac

download() {
	local download_url
	download_url="$1"
	# --timeout=30: bail fast on hung downloads (default 900s)
	# --tries=3:     retry transient failures
	# -4:            prefer IPv4, avoid IPv6 stalls (issue #2086)
	if ! "$WGET" -O "$TMP_FILE" \
		--timeout=30 --tries=3 -4 \
		"$download_url"; then
		echo "Failed to download $download_url" >&2
	elif ! echo "$DIGEST $TMP_FILE" | "$SHASUM" --check -; then
		echo "File from $download_url does not match expected digest" >&2
	else
		mv "$TMP_FILE" "$FILE"	# Matches, keep this file
		return 0
	fi
	rm -f "$TMP_FILE"	# Wasn't downloaded or failed check
	return 1
}

# If the file exists already and the digest is correct, use the cached copy.
if [ -f "$FILE" ] && (echo "$DIGEST $FILE" | "$SHASUM" --check -); then
	echo "$(date -Iseconds) CACHED file=$(basename "$FILE")" \
		>>"${MIRROR_LOG:-build/mirror_fallbacks.log}"
	echo "File $FILE is already cached" >&2
	exit 0
fi

rm -f "$FILE" "$TMP_FILE"

# Try the primary source
if download "$URL"; then
	echo "$(date -Iseconds) PRIMARY file=$(basename "$FILE") url=$URL" \
		>>"${MIRROR_LOG:-build/mirror_fallbacks.log}"
	echo "Downloaded from primary: $URL" >&2
	exit 0
fi

# Log mirror fallback for developer awareness
MIRROR_LOG="${MIRROR_LOG:-build/mirror_fallbacks.log}"
mkdir -p "$(dirname "$MIRROR_LOG")"
echo "$(date -Iseconds) MIRROR_FALLBACK file=$(basename "$FILE") primary=$URL" >>"$MIRROR_LOG"

# Shuffle the mirrors so we try each equally
readarray -t BACKUP_MIRRORS < <(shuf -e "${BACKUP_MIRRORS[@]}")

# The mirrors use our archive names, which may differ from the primary source
# (e.g. musl-cross-make archives are just <hash>.tar.gz, makes more sense to use
# musl-cross-<hash>.tar.gz).  This also means mirrors can be seeded directly
# from the packages/<arch>/ directories.
archive="$(basename "$FILE")"
echo "Try mirrors for $archive" >&2

for mirror in "${BACKUP_MIRRORS[@]}"; do
	if download "$mirror$archive"; then
		echo "$(date -Iseconds) MIRROR_USED mirror=$mirror$archive" >>"$MIRROR_LOG"
		exit 0
	fi
done

# All mirrors failed
exit 1
