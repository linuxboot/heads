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
setsid_bin="$(command -v setsid 2>/dev/null || true)"

# A background command started without job control inherits SIGINT ignored, so
# forwarding INT to the direct child cannot stop it or its descendants.  When
# setsid is available the child is launched under `setsid --wait`, making it a
# new session/process-group leader; both traps then TERM the whole group.
# Without setsid, fall back to signaling the child directly.
forward_signal() {
	# $1 = signal used only by the no-setsid fallback (INT or TERM).
	[ -n "${child_pid:-}" ] || return 0
	if [ -n "${setsid_bin:-}" ]; then
		# The group may not exist yet if the signal arrived after the child
		# PID was assigned but before setsid created the new session.  Fall
		# back to terminating the direct child in that race.
		if ! kill -TERM -- "-$child_pid" 2>/dev/null; then
			kill -TERM "$child_pid" 2>/dev/null || true
		fi
	else
		kill "-${1:-TERM}" "$child_pid" 2>/dev/null || true
	fi
}

# Separate INT/TERM traps: mark interrupted, report, and forward the signal to
# the active docker_repro.sh child's process group (if any).  The main loop
# reaps the process-group leader before reporting the board's result.
trap 'interrupted=1; echo "Interrupted (INT), stopping build_all_boards." >&2; forward_signal INT' INT
trap 'interrupted=1; echo "Interrupted (TERM), stopping build_all_boards." >&2; forward_signal TERM' TERM

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

	# A signal may arrive while the previous child is being reaped, after its
	# PID was cleared.  Stop before starting another board and count it as
	# not verified so the batch exits non-zero.
	if [ "$interrupted" -ne 0 ]; then
		echo "   INT  $board (interrupted before start, not run)"
		echo "$board" >>"$FAIL_LOG"
		fail=$((fail + 1))
		break
	fi

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
	if [ -n "$setsid_bin" ]; then
		# setsid --wait: the child leads a fresh session/process group, so the
		# traps can TERM the whole group; --wait propagates the exit status
		# even when setsid has to fork.
		"$setsid_bin" --wait env HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD="${board}" >"$log" 2>&1 &
	else
		HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD="${board}" >"$log" 2>&1 &
	fi
	child_pid=$!
	# If a signal arrived before child_pid was assigned, the trap had no PID
	# to forward to; signal the child now before waiting on it.
	if [ "$interrupted" -ne 0 ]; then
		forward_signal TERM
	fi
	wait "$child_pid" || build_status=$?
	# A signal trap interrupts wait before the child exits; the trap has
	# already TERM'd the process group, so reap the process-group leader
	# here before reporting the board.
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
	# Both a failed and a skipped sync leave the build unverified; count at
	# most one sync warning per board (elif) and never fail the script for it.
	sync_warned=0
	if grep -q 'WARN: config_sync failed' "$log"; then
		echo "   WARN $board: config_sync failed (see $log)"
		sync_warn=$((sync_warn + 1))
		sync_warned=1
	elif grep -q 'config_sync skipped' "$log"; then
		echo "   WARN $board: config_sync skipped (see $log)"
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

# A signal received between boards can leave a remaining board unstarted (counted
# as failed above) or a child-only interruption race; require a clean, uninterrupted
# batch before reporting success.
if [ "$interrupted" -ne 0 ]; then
	echo "build_all_boards: interrupted; batch incomplete (selected=$selected, passed=$pass, failed=$fail)." >&2
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

[ "$fail" -eq 0 ] && [ "$interrupted" -eq 0 ]
