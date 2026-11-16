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

	log="${LOG_DIR}/${board}.log"
	echo "=== building $board ==="
	if [ "${DRY_RUN:-}" = "1" ]; then
		echo "HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=${board}"
		echo "HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=${board} config_sync"
		pass=$((pass + 1))
		continue
	fi

	if HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD="${board}" >"$log" 2>&1; then
		if HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD="${board}" config_sync >>"$log" 2>&1; then
			echo "   OK   $board"
			pass=$((pass + 1))
		else
			echo "   FAIL $board config_sync (log: $log)"
			echo "$board" >>"$FAIL_LOG"
			fail=$((fail + 1))
		fi
	else
		echo "   FAIL $board (log: $log)"
		echo "$board" >>"$FAIL_LOG"
		fail=$((fail + 1))
	fi
done

echo
echo "==========================================="
echo " build_all_boards: done"
echo "   log dir: $LOG_DIR"
echo "   passed: $pass"
echo "   failed: $fail"
echo "   skipped: $skip"
if [ "$fail" -gt 0 ]; then
	echo "   failed boards:"
	cat "$FAIL_LOG" | sed 's/^/      - /'
fi
echo "==========================================="

echo
echo "==========================================="
echo " config/ after explicit config_sync"
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
else
	echo "config/ unchanged: committed configs match what linux and coreboot consumed."
fi
echo "==========================================="

[ "$fail" -eq 0 ]
