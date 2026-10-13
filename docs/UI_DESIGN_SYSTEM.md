# Purgatory Dungeon — UI Design System

One interface language for the whole game: **dark dungeon + aged iron + warm firelight + restrained parchment.**
It must read as the same game on every screen — menus, Options, the Alchemist, the Codex, the HUD and the touch controls —
and be recognisable without the dungeon behind it.

Everything lives in code (`scripts/ui/`): **no image assets except two bundled fonts**, no shaders, no real-time blur,
no per-frame UI cost. Materials are tiny 9‑slice textures generated once at start‑up.

| File | Role |
|---|---|
| `scripts/ui/pui.gd` (`PUI`) | palette, spacing, type roles, procedural materials, the shared `Theme`, helpers |
| `scripts/ui/ui_theme.gd` (autoload `UiTheme`) | applies `PUI.theme()` to the root window — every scene inherits it |
| `scripts/ui/pui_bar.gd` (`PUIBar`) | HUD meter (health, cooldown) |
| `scripts/ui/pui_icon.gd` (`PUIIcon`) | draws an icon of the family |
| `scripts/touch/touch_icons.gd` (`TouchIcons`) | the icon family itself |
| `assets/fonts/` | Cinzel + Source Sans 3 (SIL OFL, licences included) |
| `tests/test_ui_brand.gd`, `tests/test_typography.gd` | the role → family map, glyph coverage, size floors and fit |
| `tools/ui_review.sh` | renders every screen / overlay (and, with `HUD=1`, the gameplay HUD) at phone and desktop shapes |
| `tools/ui_showcase.tscn` | every component on one screen (dev only; not shipped) |

## 1. Palette (semantic roles — never ad‑hoc colours)

| Role | Token | Value | Use |
|---|---|---|---|
| Void | `PUI.VOID` | `#0b0908` | behind full‑screen UI when no dungeon is visible |
| Dark surface | `PUI.IRON` / `IRON_DEEP` | `#1e1916` / `#15110f` | panels, button surfaces / inset (inputs, tracks) |
| Raised surface | `PUI.IRON_RAISED` / `IRON_HOVER` | `#2b241f` / `#372e27` | cards, tabs, interactive surfaces / hover lift |
| Border / divider | `PUI.EDGE` / `EDGE_BRASS` | `#4d4034` / `#85693a` | aged iron / dark brass (emphasis) |
| Primary text | `PUI.BONE` (`BONE_BRIGHT` on hover) | `#eadfc6` | warm bone — never pure white |
| Secondary text | `PUI.BONE_DIM` / `BONE_FAINT` | `#ab9f89` / `#6f6657` | secondary / disabled |
| **Accent** | `PUI.EMBER` / `EMBER_BRIGHT` / `EMBER_DEEP` | `#cf8a2e` / `#efae4d` / `#8a5a1d` | THE brand interaction colour: selection, focus, active tab, primary action, key values |
| Danger | `PUI.BLOOD` / `BLOOD_BRIGHT` | `#8c2a28` / `#e2685d` | only for danger: Hardcore warning, destructive actions, death, invalid |
| Positive | `PUI.MOSS` | `#7f9a58` | only where green has meaning (affordable/available). Never an accent |
| Parchment | `PUI.PARCHMENT` / `PARCHMENT_DK` / `INK` / `INK_DIM` | `#d3bf93` / `#b09665` / `#1a1008` / `#4a3a25` | lore/records paper and its ink |

| Key metals | `PUI.KEY_BRONZE` / `KEY_SILVER` / `KEY_GOLD` (`PUI.key_tint(metal)`) | `#b0723a` / `#b9c0c6` / `#e0b84a` | only to tint the "key" icon for bronze / silver / gold keys; never a UI accent |

Rules: one accent (ember). Selected, active, focused and primary all use it. No blue, no bright white outlines, no green call‑to‑action.
Colour is never the only signal: selected = amber edge **and** tinted fill; disabled = desaturated **and** dim text; danger = edge + wording.

## 2. Typography

Two families only, with one rule (full per-screen decisions and the glyph and sizing audits: `docs/TYPOGRAPHY_AUDIT.md`):

* **Cinzel = identity.** Titles, headings, card titles, **every button and tab**, names, important labels, HUD numbers and
  names, short prompts — any *short* text (about 3–4 words) where it stays legible.
* **Source Sans 3 = reading.** Sentences, descriptions, lore, settings notes, helper lines, footers, diagnostics, warnings that
  are sentences, text the player types, value fields (drop-downs, key bindings) and long numeric/status strings.

Cinzel's lowercase is small caps (smaller x-height) and its digit "1" resembles a capital I, so Cinzel is never used for
paragraphs, typed text or code-like strings, and never below 16 px (`PUI.MIN_DISPLAY_SIZE`).

Type roles (`PUI.ROLES`; sizes are phone sizes in 1280×720 virtual px, desktop ×0.86):

| Role | Face | Size | Colour | Label variation |
|---|---|---|---|---|
| Game title | Cinzel Black | 72 | bone | `GameTitle` |
| Screen title | Cinzel Bold | 42 | bone | `ScreenTitle` |
| Section heading | Cinzel SemiBold | 22 | ember | `SectionHeading` |
| Card title | Cinzel SemiBold | 26 | bone | `CardTitle` (`DangerTitle` in blood) |
| Button (all kinds, tabs) | Cinzel SemiBold | 24 | bone | (Button theme) |
| Primary button | Cinzel Bold | 28 | bright bone | `PrimaryButton` |
| Short label | Cinzel SemiBold | 22 | bone | `ShortLabel` — a setting's name, a stat line |
| Stat label | Cinzel SemiBold | 20 | dim bone | `StatLabel` — Runs 2, Barbarian · Slot 3, 1 / 2, a rarity tag |
| HUD value | Cinzel Bold | 24 | bone, dark outline | `HudValue` — numbers, short HUD/banner names |
| HUD label | Cinzel SemiBold | 20 | dim bone, dark outline | `HudLabel` — wallet rows, buff names |
| Body | Source Sans Regular | 22 | bone | (default Label) |
| Secondary body | Source Sans Regular | 20 | dim bone | `SecondaryLabel` |
| Metadata | Source Sans Regular | 18 | dim bone | `MetaLabel` |
| Field | Source Sans SemiBold | 22 | bone | `OptionButton`, `FieldButton` — a button that shows a value |
| Warning | Source Sans SemiBold | 22 | blood | `WarningLabel` |
| Small caption | Source Sans Regular | 16 | dim bone | `CaptionLabel` |

Choosing a role: *is it a name, a number, a heading or a button of a few words?* → a Cinzel role. *Is it a sentence, a
description, something typed, or a code-like string?* → a Source Sans role. In a settings row the **name** is `ShortLabel` and
the **note** under it is `MetaLabel`; on a card the **title** is `CardTitle` and the **description** is body.

**Glyph fallback is explicit** (`PUI.font()`): Cinzel → Source Sans 3 of the same weight → the engine font; Source Sans → the
engine font. Cinzel's subset has no arrows (↑ ↓ fall through to Source Sans); *no* bundled font has ← → ✓ ⚠ ☰ Ⓐ, so those are
never used as text — draw an icon (`PUIIcon`). The middle dot, em dash, en dash, ellipsis, multiplication sign and bullet are safe
everywhere. `tests/test_typography.gd` fails if any shipped string would show a missing-glyph box
(`PUI.missing_glyphs(font_key, text)` is the same check for one-off strings).

Hierarchy comes from face, size, weight and colour — not from ALL CAPS or bold everywhere. (Cinzel's lowercase is small caps by design; use sentence/title case in source text.)
Parchment contexts use the same roles in ink: `ParchmentTitle`, `ParchmentHeading`, `ParchmentCardTitle`, `ParchmentLabel`, `ParchmentStat`, `ParchmentBody`, `ParchmentMeta`, `ParchmentRich`.

## 3. Components (theme type variations)

Set `control.theme_type_variation = &"Name"` in a scene, or use `PUI.button(text, kind)`, `PUI.panel(kind)`, `PUI.label(text, variation)`.

**Buttons** (all: blackened iron body, raised edge, bone label)

| State | Look |
|---|---|
| normal | iron, muted edge |
| hover / focus | lifted iron, brass edge; focus adds a bright ember ring |
| pressed | darker, 2 px tactile depression, ember inner glow, ember label |
| disabled | desaturated iron, faint label |
| `Button` (secondary) | the default (Cinzel SemiBold) |
| `PrimaryButton` | ember/brass edge, warm glow rising from the base, Cinzel Bold label, 64 px min height — **Start Run, Trade, the one main action** |
| `FieldButton` | the plain button in the body face — for a button that shows a **value** (key bindings). Applied automatically to plain buttons in a `SettingsRows.row` |
| `SelectorButton` | segmented choice (class, difficulty): toggled‑on = ember edge + amber‑tinted fill + ember label. Use `toggle_mode` + `ButtonGroup` |
| `NavButton` | Back / Next / pagers — quieter, same family |
| `DangerButton` | blood edge — destructive actions only |

**Panels** — `PanelContainer`/`Panel` default = **Surface** (blackened iron). Variations: `CardPanel` (raised: slots, upgrade cards), `ParchmentPanel`, `VeilPanel` (translucent, over the visible dungeon), `InsetPanel` (recessed).
**Tabs** (`TabContainer`/`TabBar`): Cinzel SemiBold; unselected iron, selected = ember edge + glow + ember label.
**Sliders** (`HSlider`): iron track, ember fill, brass‑ringed bone thumb. Give them ≥ 44 px height for touch.
**Check boxes / toggles** (`CheckBox`, `CheckButton`): iron square, ember tick.
**Text input** (`LineEdit`): inset iron, ember edge on focus, ember caret.
**Scroll bars**, **option buttons / pop‑ups**, **tooltips**, **dialogs (`AcceptDialog`)**, **item lists**: all in the theme.
**Divider**: `PUI.divider()` / `BrassDivider` — a thin brass line.
**Rarity ramp** (buff cards, pickups — `PUI.rarity_card(r)`, `PUI.rarity_edge(r)`, `PUI.rarity_text(r)`): a restrained ramp built only from the palette, never a rainbow.

| Rarity | Card edge | Tag text | Base glow |
|---|---|---|---|
| common | `BONE_FAINT` | `BONE_DIM` | none |
| rare | `EDGE_BRASS` | `EMBER` | none |
| epic | `EMBER` | `EMBER_BRIGHT` | faint ember |
| legendary | `EMBER_BRIGHT` | `EMBER_BRIGHT` | strong ember |
| cursed | `BLOOD` | `BLOOD_BRIGHT` | faint blood |

Rarity is always also written as a text tag ("Common", "Rare", "Legendary"), never colour alone.
**HUD meter**: `PUIBar.make(size, colour)` — iron frame, lit fill, recent‑loss trail.

## 4. Backgrounds

* **World menus** (the dungeon is visible: main menu, character select): keep the dungeon; add `PUI.background("veil")` (light darkening + vignette) and put content on `VeilPanel` only where needed. No giant panels.
* **System screens** (Options, Profiles): `PUI.background("void")` — near‑black with a faint warm vignette — and iron panels. Never a grey floating rectangle.
* **Parchment** is reserved for things that are conceptually paper: the **Codex** and the **Alchemist's ledger**. It is a *surface*, not a second brand: on parchment, text uses the ink roles but **controls stay iron/brass**, headings stay Cinzel, the accent stays ember, borders and spacing are unchanged.

## 5. Spacing

Multiples of 4: `S1=4 S2=8 S3=12 S4=16 S5=24 S6=32 S7=48`. Screen margin 48, panel padding 20, card gap 16, section gap 24, button height 56 (64 primary; 72 on phones via `MobileUi`), icon–text gap 12. Touch targets ≥ 56 (72 on phones). Respect safe areas; nothing is hard‑coded to one phone.

## 6. Icons

One family (`TouchIcons`): a filled **bone** silhouette, **ember** detail, a single stroke weight (`r × 0.09`), drawn in code. Kinds: attack, kick, slide, block, burst, use, map, pause, potion, key, hourglass, blade, chevron_left, chevron_right.
Use `PUIIcon.make(kind, px, tint)`. No emoji, no font glyphs (no bundled font has arrows/ticks/⚠), no mixed icon styles.

## 7. HUD and touch controls

* HUD elements are small, material‑backed (outline text or a thin iron plate) — never large opaque boxes; the dungeon stays dominant. Health = `PUIBar` + `HudValue`; counters = icon + `HudValue`; labels = `HudLabel` (both Cinzel; their boxes are measured from the font, `HudKit.COMPASS_W`, `HudVitals`).
* In‑run layout (`scripts/ui/hud_kit.gd`, `HudKit`): **top‑left cluster** = health bar + value (`HudVitals`, shared by Barbarian and Mage), then kills (blade icon + "Kills: N") with the heading letter on a small iron plate (`GameplayCompassLabel`) right‑aligned with the bar. **Top‑right** = day counter (hourglass + `HudValue`). **Wallet** = potion / bronze / silver / gold key rows (icon + `HudLabel` + `HudValue`, key icons tinted with `PUI.key_tint`, zero count dims the row): bottom‑right on desktop, top‑right under the day counter on phones. **Trap statuses** = `HudStatusPanel` (small veil plate, warning role, bottom centre). The map overlay keeps its dark iron ground with a thin brass frame, Cinzel compass letters (north in ember), bone player arrow, ember portal diamond and blood enemy dots, all with a dark rim.
* **In-run overlays and prompts** (buff roulette, YOU DIED, run end, trap banners, chest/portal hints, globe alerts): full-screen moments sit on `PUI.background("veil"|"void")` with a `VeilPanel`/`CardPanel` where a panel is needed; titles are `ScreenTitle` (the death title is `GameTitle` in `BLOOD_BRIGHT`), explanations `SecondaryLabel`/`MetaLabel` (sentences stay Source Sans), short tags `StatLabel`, exits are the unified buttons (one `PrimaryButton`). Prompts over the world are outline text (`HudValue` for short action prompts, set a step larger because small caps read smaller; `WarningLabel` for sentences) or a thin translucent iron plate (trap banners, blood edge) — never opaque boxes. Hostile/blocked = blood, positive/active = ember, everything else bone. Key prompts take their glyph from `InputManager.glyph()`; no ☰/Ⓐ/⚠ font glyphs. `tools/overlay_preview.tscn` renders each of them in isolation (`OVERLAY=died|buff_rare|runend|traps|…`).
* Touch controls are physical round controls (docs/ANDROID.md "Button anatomy and baked art"), art-directed by `docs/art/PD_Mobile_Control_Art_Reference.png`: a soft cached drop shadow, a chunky segmented aged-bronze rim (PUI.EDGE_BRASS family), a recessed dark cracked-slate face (IRON / IRON_DEEP) with an inner bevel, and chunky faceted icons (steel, bronze, bone, red gem for the flask) with strong small-scale silhouettes. The rim, face and icons are baked offline by `tools/make_control_art.gd` into `assets/touch/` per state (default, pressed = ember-lit rim and glow with the face pushed in, cooldown = cool desaturated, disabled = dark grey); meaning-carrying pieces (charge fill, flask cooldown and count, USE caption in Cinzel, drag ring) stay code-drawn on top. Attack is the dominant control (about 1.8x the others, four diamond studs); slide (chevrons), kick, block, burst and USE share one family at smaller size; Pause / Map are quieter code-drawn members. The sticks share the rim/inset language. No shaders, no blur, no animation.

## 8. Accessibility and performance

Contrast (measured, WCAG): bone on iron 11.5–14:1, dim bone 5.9–7.2:1, ember (bright) on iron 7.9–9.7:1, danger text 4.6–5.7:1, ink on parchment 10.4:1, dim ink 6.1:1. Selected/disabled/danger are never colour‑only. Focus is always visible. Text ≥ 16 px (body ≥ 20 on phones; Cinzel ≥ 16 px on desktop and ≥ 20 px on phones because its lowercase is small caps). No blur, no continuous UI animation; the materials are generated once (≈ 40 small textures).

## 9. Adding UI

1. Pick the role (title/section/body/…) and the component (button kind, panel kind) — do not invent colours or sizes.
2. Use a theme variation or the `PUI` helpers. If something needs a new look, add it to `pui.gd` and this document.
3. UI built in code under a `CanvasLayer` does **not** inherit the root theme (Godot stops the lookup at the layer): give the top-level Control `PUI.adopt(control)`; children inherit it. (Direct children of a scene's root Control are fine.)
4. Check it in `tools/ui_showcase.tscn` and with `tools/ui_shot.gd` at phone shape and desktop shape.
