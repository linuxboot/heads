#!/bin/bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
test_root="$repo/.opal-test.$$"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root"

cat >"$test_root/functions.sh" <<'EOF'
STATUS_OK() { printf 'STATUS_OK: %s\n' "$*"; }
WARN() { printf 'WARN: %s\n' "$*" >&2; }
EOF

cat >"$test_root/gui_functions.sh" <<'EOF'
whiptail_error() { printf 'WHIPTAIL_ERROR\n' >&2; }
EOF

cat >"$test_root/prompt" <<'EOF'
#!/bin/bash
count_file="$OPAL_TEST_ROOT/prompt-count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s' "$count" >"$count_file"
touch "$OPAL_TEST_ROOT/prompt-called"
if [ "${PROMPT_CANCEL:-n}" = y ]; then
	exit 1
fi
if [ "${PROMPT_EMPTY:-n}" = y ]; then
	exit 5
fi
if [ "${PROMPT_ALWAYS_WRONG:-n}" = y ] ||
   { [ "${PROMPT_WRONG_FIRST:-n}" = y ] && [ "$count" -eq 1 ]; }; then
	printf '%s' wrong-password
else
	printf '%s' correct-password
fi
EOF
chmod +x "$test_root/prompt"

cat >"$test_root/backend" <<'EOF'
#!/bin/bash
set -u
printf '%s\n' "$*" >>"$OPAL_TEST_ROOT/backend-args"
case "${1:-}" in
scan)
	case "$SCENARIO" in
	none) ;;
	unlocked) printf '/dev/mock0 unlocked\n' ;;
	locked | wrong-first | always-wrong | backend-fail | s3-fail)
		if [ -e "$OPAL_TEST_ROOT/unlocked" ]; then
			printf '/dev/mock0 unlocked\n'
		else
			printf '/dev/mock0 locked\n'
		fi
		;;
	multiple)
		for dev in mock0 mock1; do
			if [ -e "$OPAL_TEST_ROOT/$dev-unlocked" ]; then
				printf '/dev/%s unlocked\n' "$dev"
			else
				printf '/dev/%s locked\n' "$dev"
			fi
		done
		;;
	malformed) printf '/dev/mock0 locked extra\n' ;;
	scan-fail) exit 1 ;;
	esac
	;;
status)
	name=${2##*/}
	if [ -e "$OPAL_TEST_ROOT/unlocked" ] ||
	   [ -e "$OPAL_TEST_ROOT/$name-unlocked" ]; then
		printf 'unlocked\n'
	else
		printf 'locked\n'
	fi
	;;
unlock)
	[ "${2:-}" = --s3-handoff ] || exit 4
	device=${3:-}
	[ "$#" -eq 3 ] || exit 1
	[ "$SCENARIO" != backend-fail ] || exit 1
	password=$(cat)
	case "$(tr '\0' ' ' </proc/$$/cmdline)" in
	*correct-password* | *wrong-password*) exit 1 ;;
	esac
	if env | grep -Eq 'correct-password|wrong-password'; then
		exit 1
	fi
	printf '%s\n' "$device" >>"$OPAL_TEST_ROOT/unlock-devices"
	if [ "$password" != correct-password ]; then
		unset password
		exit 3
	fi
	unset password
	[ "$SCENARIO" != s3-fail ] || exit 4
	if [ "$SCENARIO" = multiple ]; then
		touch "$OPAL_TEST_ROOT/${device##*/}-unlocked"
	else
		touch "$OPAL_TEST_ROOT/unlocked"
	fi
	;;
*) exit 64 ;;
esac
EOF
chmod +x "$test_root/backend"

run_case() {
	local scenario="$1"
	rm -f "$test_root"/{backend-args,prompt-count,prompt-called,unlocked,unlock-devices,mock0-unlocked,mock1-unlocked}
	OPAL_TEST_ROOT="$test_root" \
	SCENARIO="$scenario" \
	CONFIG_HEADS_OPAL_TOOL="$test_root/backend" \
	CONFIG_HEADS_OPAL_PROMPT="$test_root/prompt" \
	CONFIG_HEADS_OPAL_S3_HANDOFF=y \
	HEADS_OPAL_FUNCTIONS_SH="$test_root/functions.sh" \
	HEADS_OPAL_GUI_FUNCTIONS_SH="$test_root/gui_functions.sh" \
	PROMPT_WRONG_FIRST="${PROMPT_WRONG_FIRST:-n}" \
	PROMPT_ALWAYS_WRONG="${PROMPT_ALWAYS_WRONG:-n}" \
	PROMPT_CANCEL="${PROMPT_CANCEL:-n}" \
	PROMPT_EMPTY="${PROMPT_EMPTY:-n}" \
	"$repo/initrd/bin/heads-opal-unlock.sh"
}

run_case none
[ ! -e "$test_root/prompt-called" ]

run_case unlocked
[ ! -e "$test_root/prompt-called" ]

run_case locked
[ "$(cat "$test_root/prompt-count")" = 1 ]
grep -qx 'unlock --s3-handoff /dev/mock0' "$test_root/backend-args"

PROMPT_WRONG_FIRST=y run_case wrong-first
[ "$(cat "$test_root/prompt-count")" = 2 ]

if PROMPT_ALWAYS_WRONG=y run_case always-wrong; then
	exit 1
fi
[ "$(cat "$test_root/prompt-count")" = 3 ]

if PROMPT_CANCEL=y run_case locked; then
	exit 1
fi
[ "$(cat "$test_root/prompt-count")" = 1 ]

if PROMPT_EMPTY=y run_case locked; then
	exit 1
fi
[ "$(cat "$test_root/prompt-count")" = 3 ]

if run_case backend-fail; then
	exit 1
fi
[ "$(cat "$test_root/prompt-count")" = 1 ]

if run_case s3-fail; then
	exit 1
fi
if run_case scan-fail; then
	exit 1
fi
if run_case malformed; then
	exit 1
fi

run_case multiple
[ "$(wc -l <"$test_root/unlock-devices")" -eq 2 ]

opal_line=$(grep -n 'heads-opal-unlock.sh' "$repo/initrd/bin/gui-init.sh" | cut -d: -f1)
detect_line=$(grep -n '^if detect_boot_device' "$repo/initrd/bin/gui-init.sh" | cut -d: -f1)
[ "$opal_line" -lt "$detect_line" ]

tmpdir="$test_root/compiler-tmp"
mkdir -p "$tmpdir"
TMPDIR="$tmpdir" gcc -std=gnu11 -O2 -Wall -Wextra -Werror \
	-o "$test_root/test-heads-opal" "$repo/tests/opal/test_heads_opal.c"
"$test_root/test-heads-opal"

printf 'heads-opal shell tests: PASS\n'
