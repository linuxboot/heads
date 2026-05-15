# Common functions for blob download/processing scripts.
# Source this file from individual blob scripts.
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"

# Verify sha256sum for a file.  Exit with error on mismatch.
chk_sha256sum() {
	local sha256_hash="$1"
	local filename="$2"
	echo "$sha256_hash" "$filename" "$(pwd)"
	sha256sum "$filename"
	if ! echo "${sha256_hash} ${filename}" | sha256sum --check; then
		echo "ERROR: SHA256 checksum for ${filename} doesn't match."
		exit 1
	fi
}

# Check that output files exist and match expected hashes.
# Each arg is "<hash> <path>" (hash optionally followed by filename).
# Returns 0 if all files exist AND hashes match.
# Prints which files are missing and which have mismatched hashes.
check_outputs() {
	local all_ok=y
	local pair hash path
	for pair in "$@"; do
		pair="$(echo "$pair" | tr -s ' ')"
		hash="${pair%% *}"
		path="${pair#* }"
		echo -n "CHECKING: ${path}... "
		if [[ ! -f "$path" ]]; then
			echo "MISSING"
			all_ok=
		elif echo "${hash} ${path}" | sha256sum --check >/dev/null 2>&1; then
			echo "OK"
		else
			echo "HASH MISMATCH"
			all_ok=
		fi
	done
	if [[ -n "$all_ok" ]]; then
		return 0
	fi
	return 1
}
