#!/usr/bin/env bash
# Dev utility: render the player-facing UI at PHONE (1496x672, touch) and DESKTOP (1920x1080) shapes into a folder,
# for visual review (typography, clipping, contrast). Needs xvfb; uses the software OpenGL path (no GPU).
#   tools/ui_review.sh <godot> <outdir> [frames]
# Renders: the front-end screens, the Options tabs, the pause menu, the virtual keyboard, the loading screen, the
# in-run overlays (buff cards, YOU DIED, run end, trap banners/status, chest / portal / globe prompts), the
# touch layer and the component showcase. HUD=1 additionally boots the real dungeon for the gameplay HUD of both
# classes (slow in software GL: minutes) via tools/hud_shot.gd.
# Then tile the PNGs with tools/contact_sheet.gd (see its header).
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
	shot keyboard        res://scenes/VirtualKeyboard.tscn     $mode
	shot showcase        res://tools/ui_showcase.tscn          $mode
	for tab in Video Gameplay Accessibility Controls; do
		[ "$mode" = phone ] && [ "$tab" = Controls ] && continue   # no remapping on a phone
		shot "options_$tab" res://tools/options_shot.tscn      $mode OPTIONS_TAB=$tab
	done
	shot options_pause   res://tools/options_shot.tscn         $mode OPTIONS_PAUSE=1
	for ovl in buff_common buff_rare buff_legendary buff_hud died runend chest chest_locked portal_hint portal_announce \
			traps status loading globe_curse globe_blessing; do
		shot "ovl_$ovl"  res://tools/overlay_preview.tscn      $mode OVERLAY=$ovl
	done
done
shot touch           res://tools/touch_preview.tscn            phone

if [ "${HUD:-0}" = 1 ]; then
	for cls in barbarian mage; do
		for mode in phone desktop; do
			if [ "$mode" = phone ]; then screen="1496x672x24"; res="1496x672"; touch="1"; else screen="1920x1080x24"; res="1920x1080"; touch=""; fi
			env PURGATORY_SAVE_ROOT="$SAVE" ${touch:+PURGATORY_FORCE_TOUCH=1} SHOT_CLASS=$cls \
				timeout 1500 xvfb-run -a -s "-screen 0 $screen" "$GODOT" --rendering-driver opengl3 --resolution "$res" --path . \
				--script tools/hud_shot.gd -- res://scenes/Purgatory_Dungeon_main_game_file.tscn "$OUT/hud_${cls}_${mode}" 2>&1 \
				| grep -E "SCRIPT ERROR|Parse Error" || true
		done
	done
fi
ls -1 "$OUT"
