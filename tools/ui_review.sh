#!/usr/bin/env bash
# Dev utility: render the static UI screens at PHONE (1496x672, touch) and DESKTOP (1920x1080) shapes into a folder,
# for visual review. Needs xvfb; uses the software OpenGL path (no GPU).
#   tools/ui_review.sh <godot> <outdir> [frames]
set -u
GODOT="${1:?godot binary}"
OUT="${2:?output dir}"
FRAMES="${3:-70}"
cd "$(dirname "$0")/.."
mkdir -p "$OUT"
SAVE="$(mktemp -d)"
trap 'rm -rf "$SAVE"' EXIT

shot() {  # shot <label> <scene> <phone|desktop> [extra env as VAR=val ...]
	local label="$1" scene="$2" mode="$3"; shift 3
	local screen res touch=""
	local noscale=""
	if [ "$mode" = phone ]; then screen="1496x672x24"; res="1496x672"; touch="1"; else screen="1920x1080x24"; res="1920x1080"; noscale="1"; fi
	env PURGATORY_SAVE_ROOT="$SAVE" ${touch:+PURGATORY_FORCE_TOUCH=1} ${noscale:+SHOT_NOSCALE=1} "$@" \
		timeout 120 xvfb-run -a -s "-screen 0 $screen" "$GODOT" --rendering-driver opengl3 --resolution "$res" --path . \
		--script tools/ui_shot.gd -- "$scene" "$OUT/${label}_${mode}.png" "$FRAMES" 2>&1 | grep -E "SCRIPT ERROR|Parse Error" || true
}

for mode in phone desktop; do
	shot main_menu       res://scenes/MainMenu.tscn            $mode
	shot character       res://scenes/CharacterSelection.tscn  $mode
	shot profiles        res://scenes/ProfileScreen.tscn       $mode
	shot options         res://scenes/OptionsScreen.tscn       $mode
	shot alchemist       res://scenes/AlchemistStore.tscn      $mode
	shot codex           res://scenes/CodexScreen.tscn         $mode
	shot pause           res://scenes/pause_menu_function.tscn $mode SHOT_CALL=open_menu@30
done
ls -1 "$OUT"
