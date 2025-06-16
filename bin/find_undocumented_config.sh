#! /usr/bin/env bash

set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# By default, just show the variables.  Invoke with --show-files to show where
# each undocumented variable appears (up to 3 occurrences)
SHOW_FILES=
if [ "$1" = --show-files ]; then
	SHOW_FILES=y
fi

# Don't search the entire repo, we only want config variables used by Heads:
# - config and patches contain lots of CONFIG_ variables from other projects,
#   ignore them
# - build/crossgcc/packages are all build outputs and will also contain lots of
#   other projects, ignore them
# - modules files are mostly relevant (many do define CONFIG_ variables to
#   tweak the module), but a few have several variables actually from the
#   project being configured, not used by Heads.  Exclude specific files only
#
# boards, initrd, Makefile, and modules cover all Heads variables pretty well
# without introducing many false positives.
GREP_VARS=(-EroIh '\bCONFIG_[A-Za-z0-9_]+')
EXCLUDE_MODULES="
flashrom
flashprog
coreboot
"
ALL_VARS="$(grep "${GREP_VARS[@]}" boards initrd Makefile)"
ALL_VARS+="$(grep --exclude-from=<(echo "${EXCLUDE_MODULES[@]}") "${GREP_VARS[@]}" modules)"

ALL_VARS="$(echo "$ALL_VARS" | sort | uniq)"

# Check each variable to see if it's already documented
while IFS= read -r var; do
	if ! grep -Eq "\b$var\b" doc/config.md; then
		if [ "$SHOW_FILES" = y ]; then
			echo
			echo "$var"
			grep -r "$var" boards initrd Makefile modules | head -3 || true
		else
			echo "$var"
		fi
	fi
done < <(echo "$ALL_VARS")
