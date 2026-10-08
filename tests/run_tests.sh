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
STAGE_TIMES=()   # "<seconds> <label>" per stage, summarised at the end (docs/RELEASES.md "CI cost": measure before optimising)
LOG="$SCRATCH/last.log"
# TEST_JOBS=N (default 1 = strictly sequential, exactly as before) runs up to N Godot stages at the same time inside this one job. A hosted
# Linux runner has 4 vCPUs and one headless stage uses about one, so this cuts BILLED minutes (a job matrix would not). Every concurrent stage
# gets its own PURGATORY_SAVE_ROOT and log; results are printed in stage order and judged by the same rules (exit status, "SCRIPT ERROR").
TEST_JOBS="${TEST_JOBS:-1}"
case "$TEST_JOBS" in ''|*[!0-9]*|0) TEST_JOBS=1 ;; esac
PAR_N=0          # stages started in parallel mode
PAR_PRINTED=0    # stages whose result has been printed (strictly in start order)
PAR_LABELS=()
mkdir -p "$SCRATCH/par"
# _par_flush [all]: print the finished stages that come next in order (everything, waiting for it, with "all").
_par_flush() {
	local n code secs
	while [ "$PAR_PRINTED" -lt "$PAR_N" ]; do
		n=$((PAR_PRINTED + 1))
		if [ ! -f "$SCRATCH/par/$n.rc" ]; then [ "${1:-}" = "all" ] || return 0; wait -n 2>/dev/null || sleep 1; continue; fi
		read -r code secs < "$SCRATCH/par/$n.rc"
		echo "=== ${PAR_LABELS[$n]}"
		STAGE_TIMES+=("$secs ${PAR_LABELS[$n]}")
		sed 's/\x1b\[[0-9;]*m//g' "$SCRATCH/par/$n.log"
		if [ "$code" -ne 0 ]; then echo "!!! FAILED (exit $code): ${PAR_LABELS[$n]}"; rc=1; FAILED_STAGES+=("${PAR_LABELS[$n]} (exit $code)")
		elif grep -q 'SCRIPT ERROR' "$SCRATCH/par/$n.log"; then echo "!!! FAILED (script errors): ${PAR_LABELS[$n]}"; rc=1; FAILED_STAGES+=("${PAR_LABELS[$n]} (script errors)"); fi
		PAR_PRINTED=$n
	done
}
_par_start() {
	local label="$1"; shift
	while [ "$(jobs -rp | wc -l)" -ge "$TEST_JOBS" ]; do wait -n 2>/dev/null || sleep 1; done
	PAR_N=$((PAR_N + 1))
	local n=$PAR_N
	PAR_LABELS[$n]="$label"
	(
		export PURGATORY_SAVE_ROOT="$SCRATCH/par/save-$n/PurgetoryDungeon"
		t0=$SECONDS
		"$@" > "$SCRATCH/par/$n.log" 2>&1
		echo "$? $((SECONDS - t0))" > "$SCRATCH/par/$n.rc"
	) &
	_par_flush
}
# run <label> <cmd...>: runs a command, echoes output, fails on non-zero exit OR any "SCRIPT ERROR".
run() {
	local label="$1"; shift
	# TEST_FILTER (a regex) runs only the matching stages (a developer shortcut; CI always runs the full suite).
	if [ -n "${TEST_FILTER:-}" ] && ! echo "$label" | grep -Eq "$TEST_FILTER"; then return; fi
	if [ "$TEST_JOBS" -gt 1 ]; then _par_start "$label" "$@"; return; fi
	echo "=== $label"
	local t0=$SECONDS
	"$@" > "$LOG" 2>&1
	local code=$?
	STAGE_TIMES+=("$((SECONDS - t0)) $label")
	sed 's/\x1b\[[0-9;]*m//g' "$LOG"
	if [ "$code" -ne 0 ]; then echo "!!! FAILED (exit $code): $label"; rc=1; FAILED_STAGES+=("$label (exit $code)")
	elif grep -q 'SCRIPT ERROR' "$LOG"; then echo "!!! FAILED (script errors): $label"; rc=1; FAILED_STAGES+=("$label (script errors)"); fi
}
echo "=== release_tool check"
python3 tools/release_tool.py check || { echo "!!! FAILED: version consistency"; rc=1; }
echo "=== check_res_paths"
python3 tests/check_res_paths.py || { echo "!!! FAILED: res:// path check"; rc=1; }
echo "=== ota tools (tests/test_ota_tools.py)"
T_PY=$SECONDS
GODOT="$GODOT" python3 tests/test_ota_tools.py || { echo "!!! FAILED: OTA build tooling tests"; rc=1; }
STAGE_TIMES+=("$((SECONDS - T_PY)) python: tests/test_ota_tools.py (includes Godot payload builds)")
echo "=== android launcher icon (tests/test_android_icons.py)"
T_PY=$SECONDS
python3 tests/test_android_icons.py || { echo "!!! FAILED: Android icon checks"; rc=1; }
STAGE_TIMES+=("$((SECONDS - T_PY)) python: tests/test_android_icons.py")
echo "=== ota workflows (tests/test_ota_workflows.py)"
T_PY=$SECONDS
python3 tests/test_ota_workflows.py || { echo "!!! FAILED: OTA / CI workflow economics and safety tests"; rc=1; }
STAGE_TIMES+=("$((SECONDS - T_PY)) python: tests/test_ota_workflows.py")
# Refresh the import cache + global class registry (needed on a fresh clone).
echo "=== import"
T_IMPORT=$SECONDS
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
echo "--- import took $((SECONDS - T_IMPORT))s"
STAGE_TIMES+=("$((SECONDS - T_IMPORT)) godot --import (fresh clone)")
for scene in res://tests/validate_project.tscn res://tests/test_save_manager.tscn res://tests/test_fireball_pool.tscn res://tests/test_menu_scenes.tscn res://tests/test_pause_options.tscn res://tests/test_enemy_pooling.tscn res://tests/test_clock_buffs.tscn res://tests/test_run_lifecycle.tscn res://tests/test_audio_buses.tscn res://tests/test_pause_freeze.tscn res://tests/test_settings_controls.tscn res://tests/test_release_metadata.tscn res://tests/test_trap_fireball.tscn res://tests/test_misc_fixes.tscn res://tests/test_portal_completion.tscn res://tests/test_studio_splash.tscn res://tests/test_ui_brand.tscn res://tests/test_typography.tscn res://tests/test_ota_core.tscn res://tests/test_mage_aim.tscn res://tests/test_lighting_readability.tscn res://tests/test_enemy_assets.tscn res://tests/test_enemy_prewarm.tscn; do
	run "$scene" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . "$scene"
done
# Touch layer (Android): runs as a touch platform so the layer is built; the desktop bindings test runs
# WITHOUT it and proves keyboard / controller input is untouched.
for scene in res://tests/test_touch_controls.tscn res://tests/test_touch_art.tscn res://tests/test_attack_gesture.tscn res://tests/test_twin_stick.tscn res://tests/test_mobile_ui.tscn res://tests/test_app_lifecycle.tscn res://tests/test_typography.tscn; do
	PURGATORY_FORCE_TOUCH=1 run "$scene" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . "$scene"
done
# Options > About (status model, Check for updates through Boot, Copy diagnostics, developer tools), the main-menu footer
# (safe area, Exit above the version), no OTA/debug text over the menus, and the Alchemist's Lab "Main Menu" button.
# Desktop and phone.
for scene in res://tests/test_about.tscn res://tests/test_menu_footer.tscn; do
	run "$scene" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . "$scene"
	PURGATORY_FORCE_TOUCH=1 run "$scene (touch)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . "$scene"
done
# Twin-stick (default scheme): the right stick and the ATTACK drag turn the real Barbarian and the real Mage.
for cls in barbarian mage; do
	TWIN_CLASS="$cls" PURGATORY_FORCE_TOUCH=1 run "res://tests/test_twin_stick.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_twin_stick.tscn
done
# ATTACK gesture (tap / hold = one attack, drag = look, nothing stays pressed): the real Barbarian and the real Mage.
for cls in barbarian mage; do
	ATTACK_CLASS="$cls" PURGATORY_FORCE_TOUCH=1 run "res://tests/test_attack_gesture.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_attack_gesture.tscn
done
run "res://tests/test_input_desktop.tscn" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_input_desktop.tscn
for cls in barbarian mage; do
	SMOKE_CLASS="$cls" run "res://tests/test_gameplay_smoke.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_gameplay_smoke.tscn
done
for cls in barbarian mage; do
	BUFF_CLASS="$cls" run "res://tests/test_buffs.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_buffs.tscn
done
# Reversed View lasts exactly as long as Intoxicated and can never stay stuck (expiry, pause, death, fresh run).
for cls in barbarian mage; do
	REVERSE_CLASS="$cls" run "res://tests/test_reversed_view.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_reversed_view.tscn
done
# Repulse (jump / Slide input): radial push of every enemy around the player, protected window, cool-down.
for cls in barbarian mage; do
	REPULSE_CLASS="$cls" run "res://tests/test_repulse.tscn ($cls)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_repulse.tscn
done
# The opening keeps a growing share of the population near the player (far off-screen sleepers are recycled).
run "res://tests/test_enemy_opening.tscn" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_enemy_opening.tscn
# Starting health: Barbarian 200, Mage 135 (v8.2).
run "res://tests/test_starting_health.tscn" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_starting_health.tscn
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
# Threaded dungeon scene load (no frozen menu while a run starts).
run "res://tests/test_dungeon_entry.tscn" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_dungeon_entry.tscn
# Staged dungeon entry: the sliced generation equals the synchronous one; the player's neighbourhood is complete at hand-over.
for seed in 7 42; do
	ENTRY_TEST_SEED="$seed" run "res://tests/test_entry_staging.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_entry_staging.tscn
done
# Torches: every module has at least one and every torch is seated on a wall (one seed per process, as above).
for seed in 1 7 42; do
	TORCH_TEST_SEEDS="$seed" run "res://tests/test_torch_placement.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_torch_placement.tscn
done
# Render cost: torch light budget (cap, hysteresis, fade, dimming hand-over), batched flames, opaque modules.
for seed in 7 42; do
	LIGHT_TEST_SEED="$seed" run "res://tests/test_light_budget.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_light_budget.tscn
done
# Rooms outside the useful area cost no rendering work: distance culling (render nodes only).
for seed in 7 42; do
	VIS_TEST_SEED="$seed" run "res://tests/test_module_visibility.tscn (seed $seed)" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_module_visibility.tscn
done
# ... and in the real main scene with the real minimap (map key shows every room, closing hides them again).
run "res://tests/test_module_visibility_main.tscn" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_module_visibility_main.tscn
# Floor seams: no gap or lip in the floor of any module scene or at any doorway of six generated dungeons.
run "res://tests/test_floor_seams.tscn" timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path . res://tests/test_floor_seams.tscn
_par_flush all
echo "=== stage timing: ${#STAGE_TIMES[@]} Godot stages, $(printf '%s\n' ${STAGE_TIMES[@]+"${STAGE_TIMES[@]}"} | awk '{s+=$1} END {print s+0}')s in stages, $SECONDS s total; slowest 12:"
printf '%s\n' ${STAGE_TIMES[@]+"${STAGE_TIMES[@]}"} | sort -rn | head -12 | sed 's/^/  /'
if [ "${#FAILED_STAGES[@]}" -gt 0 ]; then
	echo "=== FAILED STAGES (${#FAILED_STAGES[@]}):"
	printf '  %s\n' "${FAILED_STAGES[@]}"
fi
exit $rc
