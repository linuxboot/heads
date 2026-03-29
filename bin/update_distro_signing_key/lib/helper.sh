#! /usr/bin/env bash
# Shared helper: download, normalize, and update one distro signing key.
# Called by per-distro wrapper scripts in bin/update_distro_signing_key/.
#
# Usage: update_distro_signing_key_helper.sh <label> <url> <uid> <key_relpath>
#
#   <label>       Human-readable distro name, used in log output (e.g. "Tails")
#   <url>         URL to download the raw key bundle from
#   <uid>         GPG UID to select for export (email or full name string)
#   <key_relpath> Repo-relative path to the key file to update
#                 (e.g. initrd/etc/distro/keys/tails.key)
#
# Normalization applied:
#   --export-options export-minimal,export-clean
#   --export-filter  drop-subkey=expired -gt 0 || usage !~ s
#
# Only the primary key and non-expired signing subkeys are kept — no
# encryption, authentication, or expired subkeys.

set -eo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 4 ] || die "Usage: $(basename "$0") <label> <url> <uid> <key_relpath>"

LABEL="$1"
KEY_URL="$2"
KEY_UID="$3"
KEY_RELPATH="$4"

REPO_ROOT="$(git -C "$(cd "$(dirname "$0")" && pwd)" rev-parse --show-toplevel)"
KEY_FILE="$REPO_ROOT/$KEY_RELPATH"

[ -f "$KEY_FILE" ] || die "Key file not found in repo: $KEY_RELPATH"

# Temporary GPG home — cleaned up on exit
GPGHOME="$(mktemp -d --tmpdir "update-distro-key-XXXXXX")"
trap 'rm -rf -- "$GPGHOME"' EXIT

echo "[$LABEL] Downloading $KEY_URL ..."
wget -q "$KEY_URL" -O "$GPGHOME/raw.key" \
	|| die "[$LABEL] Failed to download key from $KEY_URL"

echo "[$LABEL] Importing key into temporary keyring ..."
gpg --homedir "$GPGHOME" --batch --import "$GPGHOME/raw.key" 2>/dev/null \
	|| die "[$LABEL] gpg --import failed"

echo "[$LABEL] Exporting normalized key for '$KEY_UID' ..."
gpg --homedir "$GPGHOME" --batch \
	--export --armor \
	--export-options export-minimal,export-clean \
	--export-filter 'drop-subkey=expired -gt 0 || usage !~ s' \
	"$KEY_UID" > "$GPGHOME/normalized.key" \
	|| die "[$LABEL] gpg --export failed"

[ -s "$GPGHOME/normalized.key" ] \
	|| die "[$LABEL] Exported key is empty — is '$KEY_UID' present in the downloaded keyring?"

cp "$GPGHOME/normalized.key" "$KEY_FILE"
echo "[$LABEL] Written to $KEY_RELPATH"

# Report primary key expiry; warn (in color) if expiring within 365 days
WARN_DAYS=365
WARN_SECS=$(( WARN_DAYS * 86400 ))
NOW="$(date +%s)"
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
echo ""
gpg --homedir "$GPGHOME" --batch --list-keys --with-colons "$KEY_UID" 2>/dev/null \
	| awk -F: -v label="$LABEL" -v now="$NOW" -v warn_secs="$WARN_SECS" \
	      -v red="$RED" -v yellow="$YELLOW" -v nc="$NC" '
		/^pub:/ {
			expiry = $7
			if (expiry != "") {
				cmd = "date -d @" expiry " +%Y-%m-%d"
				cmd | getline expdate
				close(cmd)
				days_left = int((expiry - now) / 86400)
				if (expiry <= now) {
					print red "WARNING: [" label "] Primary key EXPIRED on " expdate " -- update immediately!" nc
				} else if ((expiry - now) <= warn_secs) {
					print yellow "WARNING: [" label "] Primary key expires " expdate " (" days_left " days) -- update soon!" nc
				} else {
					print "[" label "] Primary key expires " expdate " (" days_left " days)"
				}
			} else {
				print "[" label "] Primary key: no expiry"
			}
		}
	'

# Report change status via git
if git -C "$REPO_ROOT" diff --quiet -- "$KEY_RELPATH"; then
	echo "[$LABEL] No change — key is identical to the committed version."
else
	echo ""
	echo "[$LABEL] Key has CHANGED since the last committed version:"
	echo ""
	git -C "$REPO_ROOT" diff --stat -- "$KEY_RELPATH"
	echo ""
	echo "Review the diff with:"
	echo "  git diff -- $KEY_RELPATH"
	echo ""
	echo "If the change is expected, commit it with:"
	echo "  git add $KEY_RELPATH"
	echo "  git commit -s -S -m 'distro/keys: update $LABEL signing key'"
fi
