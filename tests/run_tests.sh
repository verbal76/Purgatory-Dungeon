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
FAILED_STAGES=()
LOG="$SCRATCH/last.log"
# run <label> <cmd...>: runs a command, echoes output, fails on non-zero exit OR any "SCRIPT ERROR".
run() {
	local label="$1"; shift
	# TEST_FILTER (a regex) runs only the matching stages (used by the Android job for the mobile subset).
	if [ -n "${TEST_FILTER:-}" ] && ! echo "$label" | grep -Eq "$TEST_FILTER"; then return; fi
	echo "=== $label"
	"$@" > "$LOG" 2>&1
	local code=$?
	sed 's/\x1b\[[0-9;]*m//g' "$LOG"
	if [ "$code" -ne 0 ]; then echo "!!! FAILED (exit $code): $label"; rc=1; FAILED_STAGES+=("$label (exit $code)")
	elif grep -q 'SCRIPT ERROR' "$LOG"; then echo "!!! FAILED (script errors): $label"; rc=1; FAILED_STAGES+=("$label (script errors)"); fi
}
echo "=== release_tool check"
python3 tools/release_tool.py check || { echo "!!! FAILED: version consistency"; rc=1; }
echo "=== check_res_paths"
python3 tests/check_res_paths.py || { echo "!!! FAILED: res:// path check"; rc=1; }
echo "=== ota tools (tests/test_ota_tools.py)"
GODOT="$GODOT" python3 tests/test_ota_tools.py || { echo "!!! FAILED: OTA build tooling tests"; rc=1; }
# Refresh the import cache + global class registry (needed on a fresh clone).
echo "=== import"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
for scene in res://tests/validate_project.tscn res://tests/test_save_manager.tscn res://tests/test_fireball_pool.tscn res://tests/test_menu_scenes.tscn res://tests/test_pause_options.tscn res://tests/test_enemy_pooling.tscn res://tests/test_clock_buffs.tscn res://tests/test_run_lifecycle.tscn res://tests/test_audio_buses.tscn res://tests/test_pause_freeze.tscn res://tests/test_settings_controls.tscn res://tests/test_release_metadata.tscn res://tests/test_trap_fireball.tscn res://tests/test_misc_fixes.tscn res://tests/test_portal_completion.tscn res://tests/test_studio_splash.tscn res://tests/test_ui_brand.tscn res://tests/test_typography.tscn res://tests/test_ota_core.tscn res://tests/test_mage_aim.tscn res://tests/test_lighting_readability.tscn; do
	run "$scene" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . "$scene"
done
# Touch layer (Android): runs as a touch platform so the layer is built; the desktop bindings test runs
# WITHOUT it and proves keyboard / controller input is untouched.
for scene in res://tests/test_touch_controls.tscn res://tests/test_touch_art.tscn res://tests/test_twin_stick.tscn res://tests/test_mobile_ui.tscn res://tests/test_app_lifecycle.tscn res://tests/test_typography.tscn; do
	PURGATORY_FORCE_TOUCH=1 run "$scene" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . "$scene"
done
# Twin-stick (default scheme): the right stick and the ATTACK drag turn the real Barbarian and the real Mage.
for cls in barbarian mage; do
	TWIN_CLASS="$cls" PURGATORY_FORCE_TOUCH=1 run "res://tests/test_twin_stick.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_twin_stick.tscn
done
run "res://tests/test_input_desktop.tscn" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_input_desktop.tscn
for cls in barbarian mage; do
	SMOKE_CLASS="$cls" run "res://tests/test_gameplay_smoke.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_gameplay_smoke.tscn
done
for cls in barbarian mage; do
	BUFF_CLASS="$cls" run "res://tests/test_buffs.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_buffs.tscn
done
for seed in 11 5 2024; do
	CHEST_SEED="$seed" run "res://tests/test_chests.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_chests.tscn
done
# A new run cannot be swarmed by a red-barrier room before the first daily buff selection.
for seed in 11 5 2024; do
	LOCK_SEED="$seed" run "res://tests/test_room_lock_arming.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_room_lock_arming.tscn
done
for cls in barbarian mage; do
	PHYS_CLASS="$cls" run "res://tests/test_physics_queries.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_physics_queries.tscn
done
for seed in 11 5 2024; do
	PLACE_SEED="$seed" run "res://tests/test_placement.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_placement.tscn
done
# Generation never leaves a tiny dungeon (one case per process, same engine quirk as below).
for gcase in normal recover exhaust; do
	GROWTH_CASE="$gcase" run "res://tests/test_generation_growth.tscn ($gcase)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_generation_growth.tscn
done
# Generator stress sample (chests, Day-30 portal and guards, connectivity, enemy spawns). The full
# 1000-seed run is tests/stress_generation.sh; any failing seed reproduces with STRESS_SEED=<seed>.
for seed in 20001 20002 20003 20004 20005 20006; do
	STRESS_SEED="$seed" STRESS_FULL=1 run "res://tests/stress_generation.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/stress_generation.tscn
done
# Dungeon generation: one seed per process (several generate/free cycles in a
# single headless process can abort the engine; see docs/BASELINE.md).
for seed in 1 2 3 7 42 123 2024 98765; do
	GEN_TEST_SEEDS="$seed" run "res://tests/test_dungeon_generation.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_dungeon_generation.tscn
done
# Torches: every module has at least one and every torch is seated on a wall (one seed per process, as above).
for seed in 1 7 42; do
	TORCH_TEST_SEEDS="$seed" run "res://tests/test_torch_placement.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_torch_placement.tscn
done
if [ "${#FAILED_STAGES[@]}" -gt 0 ]; then
	echo "=== FAILED STAGES (${#FAILED_STAGES[@]}):"
	printf '  %s\n' "${FAILED_STAGES[@]}"
fi
exit $rc
