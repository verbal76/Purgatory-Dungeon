#!/usr/bin/env bash
# Runs the headless validation suite. Usage: tests/run_tests.sh [path-to-godot]
# Godot 4.6 is expected (see project.godot). Saves/settings are redirected to a
# scratch directory via PURGATORY_SAVE_ROOT so real player data is never touched.
set -u
GODOT="${1:-${GODOT:-godot}}"
cd "$(dirname "$0")/.."
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export PURGATORY_SAVE_ROOT="$SCRATCH/PurgetoryDungeon"
rc=0
LOG="$SCRATCH/last.log"
# run <label> <cmd...>: runs a command, echoes output, fails on non-zero exit OR any "SCRIPT ERROR".
run() {
	local label="$1"; shift
	echo "=== $label"
	"$@" > "$LOG" 2>&1
	local code=$?
	sed 's/\x1b\[[0-9;]*m//g' "$LOG"
	if [ "$code" -ne 0 ]; then echo "!!! FAILED (exit $code): $label"; rc=1
	elif grep -q 'SCRIPT ERROR' "$LOG"; then echo "!!! FAILED (script errors): $label"; rc=1; fi
}
# Refresh the import cache + global class registry (needed on a fresh clone).
echo "=== import"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
for scene in res://tests/validate_project.tscn res://tests/test_save_manager.tscn res://tests/test_fireball_pool.tscn res://tests/test_menu_scenes.tscn; do
	run "$scene" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . "$scene"
done
for cls in barbarian mage; do
	SMOKE_CLASS="$cls" run "res://tests/test_gameplay_smoke.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_gameplay_smoke.tscn
done
# Dungeon generation: one seed per process (several generate/free cycles in a
# single headless process can abort the engine; see docs/BASELINE.md).
for seed in 1 2 3 7 42 123 2024 98765; do
	GEN_TEST_SEEDS="$seed" run "res://tests/test_dungeon_generation.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_dungeon_generation.tscn
done
exit $rc
