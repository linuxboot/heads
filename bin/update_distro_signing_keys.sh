#! /usr/bin/env bash
# Update all distro signing keys in initrd/etc/distro/keys/.
# Auto-discovers and runs every script in bin/update_distro_signing_key/
# except helper.sh.  Adding a new distro only requires adding a new script
# in that directory — this meta script needs no changes.
#
# Exit codes:
#   0  — all keys up to date, no action needed
#   1  — one or more keys changed (review with git diff, then commit)
#   2  — one or more per-distro scripts failed (download/import error)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBDIR="$SCRIPT_DIR/update_distro_signing_key"

failed=()

for script in "$SUBDIR"/*.sh; do
	if ! "$script"; then
		failed+=("$(basename "$script")")
	fi
	echo ""
done

echo "========================================"

# Summarize git-changed key files
mapfile -t changed < <(git -C "$SCRIPT_DIR/.." diff --name-only -- initrd/etc/distro/keys/)

if [ ${#failed[@]} -gt 0 ]; then
	echo "FAILED: ${failed[*]}"
fi

if [ ${#changed[@]} -gt 0 ]; then
	echo "Keys that changed:"
	for f in "${changed[@]}"; do echo "  $f"; done
	echo ""
	echo "Commit all changes with:"
	echo "  git add initrd/etc/distro/keys/"
	echo "  git commit -s -S -m 'distro/keys: update distro signing keys'"
	[ ${#failed[@]} -gt 0 ] && exit 2
	exit 1
else
	echo "All keys are up to date."
	[ ${#failed[@]} -gt 0 ] && exit 2
	exit 0
fi
