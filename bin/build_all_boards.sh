#!/usr/bin/env bash
#
# Build every board under boards/ through docker_repro.sh with USB disabled.
#
# Usage:
#   ./bin/build_all_boards.sh [BOARD_PATTERN]
#
# Without an argument, builds every board in boards/ (one per docker_repro.sh
# invocation, so a failure on one board does not abort the others).
#
# With BOARD_PATTERN (e.g. "x280" or "t480"), only boards whose directory name
# matches the pattern are built.
#
# Environment:
#   HEADS_DISABLE_USB=1   (forced) — disable USB passthrough inside the image
#   DRY_RUN=1             print commands instead of running them
#
# Every board's log is written to LOG_DIR (printed at start) so a developer
# can track the global log while the script is silent and inspect per-board
# failures afterwards.  LOG_DIR is kept on exit (not removed).
#
set -uo pipefail

interrupted=0
child_pid=""

# Separate INT/TERM traps: mark interrupted, report, and forward the signal to
# the active docker_repro.sh child (if any).  The main loop reaps the child
# before reporting the board's result.
trap 'interrupted=1; echo "Interrupted (INT), stopping build_all_boards." >&2; if [ -n "${child_pid:-}" ]; then kill -INT "$child_pid" 2>/dev/null || true; fi' INT
trap 'interrupted=1; echo "Interrupted (TERM), stopping build_all_boards." >&2; if [ -n "${child_pid:-}" ]; then kill -TERM "$child_pid" 2>/dev/null || true; fi' TERM

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

PATTERN="${1:-}"

HEADS_DISABLE_USB=1
export HEADS_DISABLE_USB

TS="$(date +%Y%m%d%H%M%S)"
LOG_DIR="build/logs/build_all_boards/$TS"
mkdir -p "$LOG_DIR" || exit 1

FAIL_LOG="$LOG_DIR/failed_boards.txt"
: >"$FAIL_LOG"

pass=0
fail=0
skip=0
selected=0
sync_warn=0
verified=0
unverified=0

echo "==========================================="
echo " build_all_boards: starting"
echo "   log dir: $LOG_DIR  (per-board logs + failed_boards.txt)"
echo "   pattern: ${PATTERN:-all boards}"
echo "==========================================="
echo

for board_dir in boards/*/; do
	board="$(basename "$board_dir")"
	board_config="${board_dir}${board}.config"
	[ -f "$board_config" ] || continue

	if [ -n "$PATTERN" ]; then
		case "$board" in
			*"$PATTERN"*) ;;
			*) skip=$((skip + 1)); continue ;;
		esac
	fi

	selected=$((selected + 1))
	log="${LOG_DIR}/${board}.log"
	echo "=== building $board ==="
	if [ "${DRY_RUN:-}" = "1" ]; then
		echo "HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=${board}"
		pass=$((pass + 1))
		continue
	fi

	# Snapshot config/ before this build so pre-existing uncommitted changes
	# are not attributed to the board built below.
	config_before="$(git --no-pager status --porcelain -- config/ 2>/dev/null || true)"

	build_status=0
	child_pid=""
	HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD="${board}" >"$log" 2>&1 &
	child_pid=$!
	wait "$child_pid" || build_status=$?
	# A signal trap interrupts wait before the child exits; the trap has
	# already signaled it, so reap it here before reporting the board.
	if [ "$interrupted" -ne 0 ]; then
		wait "$child_pid" 2>/dev/null || true
	fi
	child_pid=""
	if [ "$interrupted" -ne 0 ]; then
		echo "   INT  $board (interrupted, log: $log)"
		fail=$((fail + 1))
		echo "$board" >>"$FAIL_LOG"
		break
	fi
	if [ "$build_status" -ne 0 ]; then
		echo "   FAIL $board (log: $log)"
		echo "$board" >>"$FAIL_LOG"
		fail=$((fail + 1))
		continue
	fi
	sync_warned=0
	if grep -q 'WARN: config_sync failed' "$log"; then
		echo "   WARN $board: config_sync failed (see $log)"
		sync_warn=$((sync_warn + 1))
		sync_warned=1
	fi
	config_after="$(git --no-pager status --porcelain -- config/ 2>/dev/null || true)"
	config_changed=0
	if [ "$config_after" != "$config_before" ]; then
		config_changed=1
		echo "   WARN $board: config/ changed by build"
		# Show only entries this build changed (present after, absent before).
		printf '%s\n' "$config_after" | while IFS= read -r line; do
			[ -n "$line" ] || continue
			if ! printf '%s\n' "$config_before" | grep -Fxq -- "$line"; then
				echo "      ${line:3}"
			fi
		done
	fi
	if [ "$sync_warned" -ne 0 ]; then
		echo "   UNVERIFIED $board: config_sync warning (not counted as passed, log: $log)"
		unverified=$((unverified + 1))
	else
		echo "   OK   $board"
		pass=$((pass + 1))
		# Positive evidence: only a non-dry-run success with no sync warning
		# and no config/ change counts as verified.
		if [ "$config_changed" -eq 0 ]; then
			verified=$((verified + 1))
		fi
	fi
done

echo
echo "==========================================="
echo " build_all_boards: done"
echo "   log dir: $LOG_DIR"
echo "   selected: $selected"
echo "   passed: $pass"
echo "   verified: $verified"
echo "   unverified: $unverified"
echo "   failed: $fail"
echo "   skipped: $skip"
echo "   sync warnings: $sync_warn"
if [ "$fail" -gt 0 ]; then
	echo "   failed boards:"
	cat "$FAIL_LOG" | sed 's/^/      - /'
fi
echo "==========================================="

if [ "$selected" -eq 0 ]; then
	echo "No boards matched pattern: ${PATTERN:-<none>}" >&2
	exit 1
fi

echo
echo "==========================================="
echo " config/ after builds"
echo "==========================================="
config_status="$(git --no-pager status --porcelain -- config/ 2>/dev/null || true)"
if [ -n "$config_status" ]; then
	echo "These config files changed from the git-committed state:"
	printf '%s\n' "$config_status" | while IFS= read -r line; do
		[ -n "$line" ] || continue
		echo "   ${line:3} changed from the git-committed state"
	done
	echo
	git --no-pager diff -- config/ || true
	echo
	echo "Review and commit the regenerated config/ files with the change that caused them."
elif [ "${DRY_RUN:-}" = "1" ]; then
	echo "config/ not checked: DRY_RUN=1 ran no builds or config_sync."
elif [ "$verified" -eq "$selected" ]; then
	echo "config/ unchanged: committed configs match what linux and coreboot consumed."
else
	echo "config/ unchanged, but agreement is unverified: verified $verified/$selected board(s), unverified $unverified, $sync_warn config_sync warning(s), $fail failed build(s). See the per-board logs."
fi
echo "==========================================="

[ "$fail" -eq 0 ]
