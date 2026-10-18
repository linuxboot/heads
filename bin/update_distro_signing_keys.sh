#! /usr/bin/env bash
# Update all distro signing keys in initrd/etc/distro/keys/.
# Auto-discovers and runs every script in bin/update_distro_signing_key/
# except helper.sh.  Adding a new distro only requires adding a new script
# in that directory — this meta script needs no changes.
#
# Exit codes:
#   0  — all keys up to date, no action needed
#   1  — one or more keys are unwritten: a key that differs and was not
#        confirmed, or a script that failed
#   3  — a pinned fingerprint disagrees with the key upstream

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBDIR="$SCRIPT_DIR/update_distro_signing_key"

# A pin mismatch is its own class: it writes nothing and is not a write
# decision, so it must never read like an ordinary pending write.
not_written=()
mismatched=()

for script in "$SUBDIR"/*.sh; do
	rc=0
	"$script" || rc=$?
	case "$rc" in
	0) ;;
	3) mismatched+=("$(basename "$script")") ;;
	*) not_written+=("$(basename "$script")") ;;
	esac
	echo ""
done

echo "========================================"

# Every file this tool can leave dirty: the key files themselves, and the
# wrappers whose pin a rotated key would change.
mapfile -t changed < <(git -C "$SCRIPT_DIR/.." diff --name-only -- \
	initrd/etc/distro/keys/ bin/update_distro_signing_key/)

if [ ${#not_written[@]} -gt 0 ]; then
	echo "NOT WRITTEN: ${not_written[*]} — key differs and the write was not confirmed, or the script failed."
fi
if [ ${#mismatched[@]} -gt 0 ]; then
	echo "PIN MISMATCH: ${mismatched[*]} — the pinned fingerprint disagrees with upstream."
fi

if [ ${#changed[@]} -gt 0 ]; then
	echo "Files that changed:"
	for f in "${changed[@]}"; do echo "  $f"; done
	echo ""
	echo "Commit all changes with:"
	echo "  git add initrd/etc/distro/keys/ bin/update_distro_signing_key/"
	echo "  git commit -s -S -m 'distro/keys: update distro signing keys'"
elif [ ${#not_written[@]} -gt 0 ]; then
	# Nothing on disk changed, so the git-derived list above is empty even
	# though a key is known to differ from upstream.
	echo "No files were changed."
	echo "At least one key differs from upstream and was left untouched — see"
	echo "the output above for its fingerprint."
elif [ ${#mismatched[@]} -gt 0 ]; then
	echo "Nothing was written."
fi

if [ ${#mismatched[@]} -gt 0 ]; then
	echo ""
	echo "A pin mismatch is not a stale key: the tree can match the download"
	echo "perfectly while the wrapper still names a fingerprint the upstream key"
	echo "does not have. Confirm the real fingerprint out of band, then edit the"
	echo "pin line named above."
fi

# Never say "up to date" over a known-bad pin: a summary that contradicts the
# warning above it is worse than no summary, because it is what gets read.
overall=0
if [ ${#not_written[@]} -gt 0 ]; then overall=1; fi
if [ ${#mismatched[@]} -gt 0 ]; then overall=3; fi

if [ "$overall" -eq 0 ]; then
	echo "All keys are up to date."
fi
exit "$overall"
