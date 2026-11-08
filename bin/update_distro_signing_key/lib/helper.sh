#! /usr/bin/env bash
# Shared helper: download, normalize, and update one distro signing key.
# Called by the per-distro wrapper scripts in bin/update_distro_signing_key/.
#
# Usage: helper.sh <label> <url> <uid> <key_relpath> <fpr> — <label> is a
# human-readable distro name for log output, <url> the raw key bundle, <uid>
# the GPG UID to export, <key_relpath> the repo-relative key file to update and
# <fpr> the primary key fingerprint the wrapper pins. The export keeps the
# primary key and its non-expired signing subkeys (export-minimal,
# export-clean, drop-subkey=expired -gt 0 || usage !~ s).
#
# stdout is one report block per key; progress and diagnostics go to stderr.
#
# Exit codes: 0 up to date or written after confirmation; 1 key differs and
# was not written; 2 download, import or export failed; 3 pin mismatch.

set -eo pipefail

die() { echo "ERROR: $*" >&2; exit 2; }

progress() { echo "[$LABEL] $*" >&2; }

[ $# -eq 5 ] || die "Usage: $(basename "$0") <label> <url> <uid> <key_relpath> <fpr>"

LABEL="$1"
KEY_URL="$2"
KEY_UID="$3"
KEY_RELPATH="$4"

# A pin that is not exactly 40 hex digits is fatal: a typo would mute the check.
FPR="$(printf '%s' "$5" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
[[ "$FPR" =~ ^[0-9A-F]{40}$ ]] || die "Fingerprint must be 40 hex digits, got: $5"

# 0 = the pin and the downloaded key agree; 1 = they disagree.
PIN_MISMATCH=0

# A pin mismatch outranks a plain 0, so 0 is never reported over a known-wrong pin.
finish() {
	local rc="${1:-0}"
	if [ "$rc" -eq 0 ] && [ "$PIN_MISMATCH" -eq 1 ]; then
		rc=3
	fi
	exit "$rc"
}

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_DIR="$(cd "$HELPER_DIR/.." && pwd)"

REPO_ROOT="$(git -C "$HELPER_DIR" rev-parse --show-toplevel)"
KEY_FILE="$REPO_ROOT/$KEY_RELPATH"
WRAPPER_RELPATH="${WRAPPER_DIR#"$REPO_ROOT"/}"

[ -f "$KEY_FILE" ] || die "Key file not found in repo: $KEY_RELPATH"

# Temporary GPG home, removed on exit, so a declined run stages nothing.
GPGHOME="$(mktemp -d --tmpdir "update-distro-key-XXXXXX")"
trap 'rm -rf -- "$GPGHOME"' EXIT

progress "downloading $KEY_URL"
wget -q "$KEY_URL" -O "$GPGHOME/raw.key" \
	|| die "[$LABEL] Failed to download key from $KEY_URL"

progress "importing into a temporary keyring"
gpg --homedir "$GPGHOME" --batch --import "$GPGHOME/raw.key" 2>/dev/null \
	|| die "[$LABEL] gpg --import failed"

progress "normalizing '$KEY_UID'"
gpg --homedir "$GPGHOME" --batch \
	--export --armor \
	--export-options export-minimal,export-clean \
	--export-filter 'drop-subkey=expired -gt 0 || usage !~ s' \
	"$KEY_UID" > "$GPGHOME/normalized.key" \
	|| die "[$LABEL] gpg --export failed"

[ -s "$GPGHOME/normalized.key" ] \
	|| die "[$LABEL] Exported key is empty — is '$KEY_UID' present in the downloaded keyring?"

# Format a bare fingerprint into the spaced groups-of-4 display form.
fpr_format() {
	awk '{
		out = ""; n = 0; len = length($0)
		for (i = 1; i <= len; i += 4) {
			n++
			out = out substr($0, i, 4)
			if (i + 4 <= len) out = out (n == 5 ? "  " : " ")
		}
		print out
	}'
}

# Primary key fingerprint of an armored key file, unformatted; empty on any
# failure, never fatal — reporting is advisory, not a gate. Reads the
# normalized export, not the raw download: the raw download is never written.
fpr_of() {
	local out n
	out="$(gpg --homedir "$GPGHOME" --show-keys --with-colons "$1" 2>/dev/null || true)"
	n="$(printf '%s\n' "$out" | awk -F: '/^pub:/ { n++ } END { print n + 0 }')"
	if [ "$n" -gt 1 ]; then
		# Only the first is compared, so a multi-primary file could
		# otherwise report a clean pin.
		echo "WARNING: [$LABEL] $(basename "$1") lists $n primary keys;" \
			"comparing only the first. Verify the key by hand." >&2
	fi
	printf '%s\n' "$out" | awk -F: '/^fpr:/ { print $10; exit }' \
		| tr -d '[:space:]'
}

# Name the wrapper that owns this key and the line to edit. HARD INVARIANT —
# READ-ONLY: the pin is the maintainer's decision, so this never writes a
# wrapper.
fpr_edit_hint() {
	local wrappers rel line raw norm n
	local lineno=0 keyline=0 best="" bestvar=""

	wrappers="$(grep -l -F -e "$KEY_RELPATH" "$WRAPPER_DIR"/*.sh 2>/dev/null || true)"
	n="$(printf '%s\n' "$wrappers" | awk 'NF { n++ } END { print n + 0 }')"
	if [ "$n" -ne 1 ]; then
		echo "  Could not identify which wrapper owns $KEY_RELPATH: $n scripts"
		echo "  in $WRAPPER_DIR reference it. Set the fingerprint by hand."
		printf '%s\n' "$wrappers" | awk 'NF { print "      " $0 }'
		return 0
	fi
	rel="$WRAPPER_RELPATH/${wrappers##*/}"

	# The wrappers disagree on the variable name, so match the real assignment
	# by value. A pin belongs to this key only if it sits at or before the line
	# naming the key path, so find that line first.
	keyline="$(grep -n -F -e "$KEY_RELPATH" "$wrappers" | head -1 | cut -d: -f1)"
	keyline="${keyline:-1}"
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$(( lineno + 1 ))
		[[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"[[:space:]]*$ ]] || continue
		raw="${BASH_REMATCH[2]}"
		norm="$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
		[ "$norm" = "$FPR" ] || continue
		if [ "$lineno" -le "$keyline" ]; then
			best="$lineno"; bestvar="${BASH_REMATCH[1]}"
		fi
	done < "$wrappers"

	if [ -z "$best" ]; then
		echo "  Could not identify the line to edit: $rel has no pin assignment"
		echo "  worth $FPR for $KEY_RELPATH. Set the fingerprint by hand."
		return 0
	fi

	echo "  Edit $rel line $best to hold the new fingerprint:"
	printf '    %s="%s"\n' "$bestvar" "$ACTUAL_FPR"
}

ACTUAL_FPR="$(fpr_of "$GPGHOME/normalized.key")"
PIN_CHECKED=no
if [ -n "$ACTUAL_FPR" ]; then
	PIN_CHECKED=yes
	[ "$FPR" = "$ACTUAL_FPR" ] || PIN_MISMATCH=1
fi

# The pin is checked on EVERY run, and a mismatch is fatal here: before the
# tree comparison and before any prompt, so a denied key is never writable.
if [ "$PIN_MISMATCH" -eq 1 ]; then
	echo "[$LABEL]"
	printf '  %-8s %s\n' "pinned:" "$(printf '%s' "$FPR" | fpr_format)"
	printf '  %-8s %s\n' "actual:" "$(printf '%s' "$ACTUAL_FPR" | fpr_format)"
	echo ""
	echo "  PIN MISMATCH — the pin is not this key's, so nothing was compared or"
	echo "  written. Confirm out of band that $LABEL's key really is"
	echo "  $(printf '%s' "$ACTUAL_FPR" | fpr_format), then edit the pin."
	echo ""
	fpr_edit_hint
	echo ""
	finish
fi

if cmp -s -- "$GPGHOME/normalized.key" "$KEY_FILE"; then
	STATUS="no change"
else
	STATUS="KEY HAS CHANGED — differs from the committed key"
fi

# awk interprets \033 in a string literal; never print these via shell printf.
expiry_line() {
	local warn_days warn_secs now out
	local red='\033[0;31m' yellow='\033[0;33m' nc='\033[0m'
	warn_days=365
	warn_secs=$(( warn_days * 86400 ))
	now="$(date +%s)"
	out="$(gpg --homedir "$GPGHOME" --batch --list-keys --with-colons "$KEY_UID" 2>/dev/null \
		| awk -F: -v now="$now" -v warn_secs="$warn_secs" \
		      -v red="$red" -v yellow="$yellow" -v nc="$nc" '
		/^pub:/ {
			expiry = $7
			if (expiry == "") {
				print "no expiry"
			} else {
				cmd = "date -d @" expiry " +%Y-%m-%d"
				cmd | getline expdate
				close(cmd)
				days_left = int((expiry - now) / 86400)
				if (expiry <= now) {
					print expdate " (" days_left " days)" red "  EXPIRED -- update immediately!" nc
				} else if ((expiry - now) <= warn_secs) {
					print expdate " (" days_left " days)" yellow "  expires soon!" nc
				} else {
					print expdate " (" days_left " days)"
				}
			}
			exit
		}' || true)"
	[ -n "$out" ] || out="unknown"
	printf '%s' "$out"
}

echo "[$LABEL]"
printf '  %-8s %s\n' "pinned:" "$(printf '%s' "$FPR" | fpr_format)"
# No colour on the verdict: printf's %s does not interpret a backslash escape
# in its ARGUMENT, so it would reach a pipe as literal characters.
if [ "$PIN_CHECKED" = yes ]; then
	printf '  %-8s %s  ok\n' "actual:" "$(printf '%s' "$ACTUAL_FPR" | fpr_format)"
else
	printf '  %-8s %s  PIN NOT CHECKED\n' "actual:" \
		"(fingerprint unreadable)"
fi
printf '  %-8s %s\n' "expires:" "$(expiry_line)"
printf '  %-8s %s\n' "status:" "$STATUS"

if [ "$PIN_CHECKED" = no ]; then
	echo "  WARNING: the downloaded key's fingerprint could not be read, so the"
	echo "    pin was NOT checked. Review the key by hand."
fi

# Compare first; touch the tree only after the reviewer says yes.
if [ "$STATUS" = "no change" ]; then
	finish 0
fi

# Same basename on both sides so git reports "in-tree.key => downloaded.key".
mkdir -p "$GPGHOME/compare"
cp -- "$KEY_FILE" "$GPGHOME/compare/in-tree.key"
cp -- "$GPGHOME/normalized.key" "$GPGHOME/compare/downloaded.key"
echo ""
echo "  The download differs from the committed key:"
echo ""
git --no-pager -c color.ui=false diff --no-index --stat -- \
	"$GPGHOME/compare/in-tree.key" "$GPGHOME/compare/downloaded.key" \
	2>/dev/null || true
echo ""

echo "  The download is staged in a temporary directory removed on exit."
echo "  After accepting, review and commit it with:"
echo "    git diff -- $KEY_RELPATH && git add $KEY_RELPATH"
echo "    git commit -s -S -m 'distro/keys: update $LABEL signing key'"

echo ""
if ! { [ -t 0 ] && [ -t 1 ]; }; then
	echo "  (no terminal to answer: under a pipe or in CI there is nobody here)"
	echo "  ERROR: $KEY_RELPATH differs and there is no terminal to confirm the"
	echo "    write. Nothing was written — re-run interactively, or accept by hand."
	finish 1
fi

echo "  Write the new key to $KEY_RELPATH? [y/N] "

ANSWER=""
# An unreadable or empty answer is a declined write, and must not abort on set -e.
read -r ANSWER <&0 || ANSWER=""
case "$ANSWER" in
[yY]|[yY][eE][sS]) ;;
*)
	echo ""
	echo "  Declined — $KEY_RELPATH left untouched."
	finish 1
	;;
esac

cp -- "$GPGHOME/normalized.key" "$KEY_FILE"
echo ""
echo "  Written to $KEY_RELPATH"
finish 0
