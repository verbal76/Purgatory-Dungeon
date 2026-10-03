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
# Refresh the import cache + global class registry (needed on a fresh clone).
echo "=== import"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
for scene in res://tests/validate_project.tscn res://tests/test_save_manager.tscn res://tests/test_fireball_pool.tscn res://tests/test_gameplay_smoke.tscn; do
	echo "=== $scene"
	timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . "$scene" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
	[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "!!! FAILED: $scene"; rc=1; }
done
# Dungeon generation: one seed per process (several generate/free cycles in a
# single headless process can abort the engine; see docs/BASELINE.md).
for seed in 1 2 3 7 42 123 2024 98765; do
	echo "=== res://tests/test_dungeon_generation.tscn (seed $seed)"
	GEN_TEST_SEEDS="$seed" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_dungeon_generation.tscn 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
	[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "!!! FAILED: dungeon generation seed $seed"; rc=1; }
done
exit $rc
