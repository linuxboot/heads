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
if [ "${PROMPT_FAIL_AFTER_OUTPUT:-n}" = y ]; then
	printf '%s' correct-password
	exit 1
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
	locked | wrong-first | always-wrong | backend-fail | s3-pre-fail | s3-fail | relock-fail)
		if [ -e "$OPAL_TEST_ROOT/unlocked" ]; then
			printf '/dev/mock0 unlocked\n'
		else
			printf '/dev/mock0 locked\n'
		fi
		;;
	multiple-later-fail)
		for dev in mock0 mock1; do
			if [ -e "$OPAL_TEST_ROOT/$dev-unlocked" ]; then
				printf '/dev/%s unlocked\n' "$dev"
			else
				printf '/dev/%s locked\n' "$dev"
			fi
		done
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
	device=${2:-}
	[ "$#" -eq 2 ] || exit 1
	[ "$SCENARIO" != backend-fail ] || exit 1
	[ "$SCENARIO" != relock-fail ] || exit 1
	[ "$SCENARIO" != s3-pre-fail ] || exit 4
	[ ! -e "$OPAL_TEST_ROOT/password" ] || exit 1
	if [ "$SCENARIO" = multiple-later-fail ] && [ "$device" = /dev/mock1 ]; then
		exit 1
	fi
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
	if [ "$SCENARIO" = multiple ] || [ "$SCENARIO" = multiple-later-fail ]; then
		touch "$OPAL_TEST_ROOT/${device##*/}-unlocked"
	else
		touch "$OPAL_TEST_ROOT/unlocked"
	fi
	[ "$SCENARIO" != s3-fail ] || exit 5
	;;
lock)
	device=${2:-}
	[ "$#" -eq 2 ] || exit 1
	[ ! -e "$OPAL_TEST_ROOT/password" ] || exit 1
	printf '%s\n' "$device" >>"$OPAL_TEST_ROOT/lock-devices"
	password=$(cat)
	[ "$password" = correct-password ] || exit 3
	unset password
	[ "$SCENARIO" != relock-fail ] || exit 1
	rm -f "$OPAL_TEST_ROOT/unlocked" \
		"$OPAL_TEST_ROOT/${device##*/}-unlocked"
	;;
*) exit 64 ;;
esac
EOF
chmod +x "$test_root/backend"

run_case() {
	local scenario="$1"
	rm -f "$test_root"/{backend-args,prompt-count,prompt-called,unlocked,unlock-devices,lock-devices,mock0-unlocked,mock1-unlocked}
	OPAL_TEST_ROOT="$test_root" \
	SCENARIO="$scenario" \
	PROMPT_WRONG_FIRST="${PROMPT_WRONG_FIRST:-n}" \
	PROMPT_ALWAYS_WRONG="${PROMPT_ALWAYS_WRONG:-n}" \
	PROMPT_CANCEL="${PROMPT_CANCEL:-n}" \
	PROMPT_EMPTY="${PROMPT_EMPTY:-n}" \
	PROMPT_FAIL_AFTER_OUTPUT="${PROMPT_FAIL_AFTER_OUTPUT:-n}" \
	"$repo/initrd/bin/heads-opal-unlock.sh" --test-fixture "$test_root"
}

run_case none
[ ! -e "$test_root/prompt-called" ]

run_case unlocked
[ ! -e "$test_root/prompt-called" ]

run_case locked
[ "$(cat "$test_root/prompt-count")" = 1 ]
grep -qx 'unlock /dev/mock0' "$test_root/backend-args"

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
[ ! -e "$test_root/password" ]

if PROMPT_FAIL_AFTER_OUTPUT=y run_case locked; then
	exit 1
fi
[ ! -e "$test_root/unlock-devices" ]
[ ! -e "$test_root/password" ]

if run_case backend-fail; then
	exit 1
fi
[ "$(cat "$test_root/prompt-count")" = 1 ]

set +e
run_case relock-fail
[ "$?" -eq 2 ] || exit 1
set -e

if run_case s3-pre-fail; then
	exit 1
fi
[ ! -e "$test_root/unlocked" ]
if run_case s3-fail; then
	exit 1
fi
grep -qx '/dev/mock0' "$test_root/lock-devices"
[ ! -e "$test_root/unlocked" ]
if run_case scan-fail; then
	exit 1
fi
if run_case malformed; then
	exit 1
fi

run_case multiple
[ "$(wc -l <"$test_root/unlock-devices")" -eq 2 ]

if run_case multiple-later-fail; then
	exit 1
fi
grep -qx '/dev/mock0' "$test_root/lock-devices"
[ ! -e "$test_root/mock0-unlocked" ]

opal_line=$(grep -n '/bin/heads-opal-unlock.sh' "$repo/initrd/init" | cut -d: -f1)
bootscript_line=$(grep -n '^if \[ ! -x ' "$repo/initrd/init" | cut -d: -f1)
[ "$opal_line" -lt "$bootscript_line" ]
grep -q '^if \[ -x /bin/heads-opal \]' "$repo/initrd/init"
grep -q 'heads-opal-unlock.sh' "$repo/initrd/bin/gui-init.sh" && exit 1

tmpdir="$test_root/compiler-tmp"
mkdir -p "$tmpdir"
TMPDIR="$tmpdir" gcc -std=gnu11 -O2 -Wall -Wextra -Werror \
	-o "$test_root/test-heads-opal" "$repo/tests/opal/test_heads_opal.c"
"$test_root/test-heads-opal"

printf 'heads-opal shell tests: PASS\n'
