# Purgatory Dungeon — Typography audit

Decision (owner): the game should feel unmistakably like Purgatory Dungeon, so **Cinzel carries the identity** and
**Source Sans 3 carries the reading**. Exactly two families ship; nothing else is allowed.

* **Cinzel** — titles, headings, card titles, every button and tab, names, important labels, HUD names and numbers,
  short prompts: any *short* (up to about 3–4 words) piece of interface text where it stays legible.
* **Source Sans 3** — anything read as a sentence or scanned as data: lore, descriptions, explanations, settings notes,
  helper lines ("Need 1 more potion"), footers and version captions, diagnostics, warnings that are sentences, text the
  player types, value fields (drop-downs, key bindings), long numeric/status strings.

How the rule is enforced (design-system way, not per-label hacks): the type *roles* in `PUI.ROLES` carry the family;
theme variations and component themes (`Button`, `TabContainer`, …) pick it up. `tests/test_ui_brand.gd` asserts the
role → family map and the theme variations; `tests/test_typography.gd` asserts glyph coverage, size floors and fit.

## 1. Role → font (final)

| Role (`PUI.ROLES`) | Variation / component | Font | Size px (phone / desktop) | Why |
|---|---|---|---|---|
| `game_title` | `GameTitle` | Cinzel Black | 72 / 62 | the logo-class title |
| `screen_title` | `ScreenTitle` | Cinzel Bold | 42 / 36 | screen titles and headline banners |
| `section` | `SectionHeading` | Cinzel SemiBold | 22 / 19 | section headings, compass cardinals |
| `card_title` | `CardTitle` | Cinzel SemiBold | 26 / 22 | card, slot and alert names |
| `button` | `Button`, `NavButton`, `SelectorButton`, `DangerButton`, tabs | Cinzel SemiBold | 24 / 21 | **changed** from Source Sans: menu, navigation and actions are short and are the most seen text |
| `button_primary` | `PrimaryButton` | Cinzel Bold | 28 / 24 | the one main action |
| `label` | `ShortLabel` (`ParchmentLabel`) | Cinzel SemiBold | 22 / 19 | **new**: a setting's name, a stat line (Master Volume, Screen Shake) |
| `stat` | `StatLabel` (`ParchmentStat`) | Cinzel SemiBold, dim | 20 / 17 | **new**: quiet short lines (Runs 2, Barbarian · Slot 3, 1 / 2, rarity tag, Day 3) |
| `hud_value` | `HudValue` | Cinzel Bold | 24 / 21 | **changed**: HUD numbers and short names (lining figures read well; outlined) |
| `hud_label` | `HudLabel` | Cinzel SemiBold, dim | 20 / 17 | **changed**: wallet rows, ability caption, buff names |
| `body` | default `Label`, `RichTextLabel` | Source Sans Regular | 22 / 19 | reading text |
| `body_secondary` | `SecondaryLabel` | Source Sans Regular | 20 / 17 | explanations, prompts that are sentences |
| `metadata` | `MetaLabel` | Source Sans Regular | 18 / 15 | notes, column captions |
| `field` | `OptionButton`, `FieldButton` | Source Sans SemiBold | 22 / 19 | **new**: value fields (resolution, key bindings) |
| `warning` | `WarningLabel` | Source Sans SemiBold | 22 / 19 | warnings are sentences |
| `caption` | `CaptionLabel` | Source Sans Regular | 16 / 14 | version footer, helper notes |
| (theme) | `LineEdit`, `TextEdit`, `PopupMenu`, `ItemList`, `CheckBox`, tooltips | Source Sans | per theme | typed text keeps its case; menus list values |

Cinzel's lowercase is **small caps**: a Cinzel role is never rendered below **16 px** (`PUI.MIN_DISPLAY_SIZE`; every role
clears it on desktop, and is ≥ 20 px on phones). Source Sans keeps the old 14 px floor.

Glyph fallback chain (explicit, built once in `PUI.font()`): **Cinzel → Source Sans 3 (same weight) → engine font**.
Source Sans → engine font. Cinzel's subset has no arrows (↑↓ come from Source Sans); no bundled font has ← → ✓ ⚠ ☰ Ⓐ, so
those are **forbidden in text** (drawn icons instead; `test_typography` fails if one appears in a shipped string).
Cinzel's digit "1" resembles a capital I, so code-like strings with digits (key bindings, resolutions) stay in Source Sans.

## 2. Audit by screen: current → decided

"Before" = the rebrand state this work started from (Cinzel only on titles/section/card/primary).

### Front-end

| Screen / element | Before | Decided | Why |
|---|---|---|---|
| Main menu: title "Purgatory", "Dungeon" | Cinzel Black / SemiBold | unchanged | identity |
| Main menu: New Character (primary) | Cinzel Bold | unchanged | |
| Main menu: Load Character, Alchemist Lab, Codex, Options, Quit | Source Sans | **Cinzel SemiBold** | short navigation = identity |
| Main menu: version footer | Source Sans caption | unchanged | footer, long string |
| Main menu: "All 10 slots full" popup title / body / buttons | Cinzel / Source Sans / Source Sans | Cinzel / Source Sans / **Cinzel** | sentence stays body |
| Character select: title, Name / Class / Difficulty headings, card title | Cinzel | unchanged | |
| Character select: Barbarian, Mage, Easy, Medium, Hardcore (selector) | Source Sans | **Cinzel** | short choices |
| Character select: Start Run (primary), Back, Load Character, Randomize Seed | primary Cinzel, rest Source Sans | all Cinzel | |
| Character select: slot indicator ("Creating Character in Slot 1") | Source Sans meta | unchanged | sentence |
| Character select: warning "Enter a name first!", Hardcore hint | Source Sans warning | unchanged | sentences |
| Character select: name field, seed field, placeholders | Source Sans | unchanged | typed text keeps case |
| Character select: stats block (Runs / Deaths / Perks…) | Source Sans | unchanged | dense multi-line data |
| Character select: dev toggles (CheckBox text), note | Source Sans | unchanged | dev-only; note is a sentence |
| Profiles: title, slot-action title | Cinzel | unchanged | |
| Profiles: slot name (CardTitle) | Cinzel | unchanged | trimmed with an ellipsis if > the card |
| Profiles: "Empty slot" | Source Sans secondary | **Cinzel dim (`StatLabel`)** | short name |
| Profiles: "Corrupted save" | Source Sans warning | **Cinzel blood (`DangerTitle`)** | short name; danger by colour **and** wording |
| Profiles: "Class · Slot N", "Runs N", "Deaths N" | Source Sans meta | **Cinzel dim (`StatLabel`)** | short stat lines |
| Profiles: "Slot N · tap to create…", "can be cleared" | Source Sans meta | unchanged | helper sentences |
| Profiles: Load / Delete / Cancel / Yes / No buttons | Source Sans | **Cinzel** | |
| Profiles: "Delete this character? This cannot be undone." | Source Sans | unchanged | sentence |
| Virtual keyboard: keys (letters, digits, Space, Back, Clear, OK, Cancel) | Source Sans | **Cinzel** | keys are upper-case; Cinzel caps = same letterforms; commands are short |
| Virtual keyboard: input display | Source Sans | unchanged | typed text keeps case |
| Loading: "Loading the dungeon" + dots | Cinzel Bold | unchanged | reviewed by the owner |

### Options and Pause

| Element | Before | Decided | Why |
|---|---|---|---|
| Options title, section headings | Cinzel | unchanged | |
| Tabs (Sound, Video, Gameplay, Accessibility, Controls) | Source Sans | **Cinzel SemiBold** | navigation; all five fit one row at 1920 and 1602 |
| Row labels (Master Volume, Screen Shake, Enemy Speed…) | Source Sans | **Cinzel SemiBold (`ShortLabel`)** via `SettingsRows.row` | settings *names* are short labels |
| Value read-outs (100%) | Source Sans bold | **Cinzel Bold (`HudValue`)** | numbers |
| On / Off state, section note ("Takes effect next run"), hints, "The game always runs full-screen…" | Source Sans | unchanged | status / descriptions / sentences |
| Display Mode / Resolution drop-downs, pop-up lists | Source Sans | unchanged (`OptionButton`) | value fields; "1920 x 1080  (Desktop)" is a numeric string |
| Key-binding buttons ("W", "LMB", "Pad Axis1-") | Source Sans | **Source Sans (`FieldButton`)** | would otherwise inherit Cinzel from `Button`; digit 1 ≈ I |
| Quick-reference table, column captions | Source Sans | unchanged | reference data |
| Back / Reset Controls to Default | Source Sans | **Cinzel** | |
| Touch Controls sliders / "Show performance readout" rows | Source Sans | label **Cinzel** (row), hint Source Sans | same row component |
| Pause: title, Resume (primary), Options, Exit to Main Menu (danger) | mixed | all Cinzel | |
| Pause: Master/Music/SFX Volume, Display Mode, Resolution labels | Source Sans | **Cinzel (`ShortLabel`)** | same names as Options |

### Alchemist's Lab and Codex

| Element | Before | Decided | Why |
|---|---|---|---|
| Title, perk names, "Level N" / "Locked" | Cinzel | unchanged | |
| Perk effect line ("Dome Radius +10%"), "Need 1 more potion", "Requires 5 runs" | Source Sans | unchanged | descriptions / helper lines |
| Trade N Potion / Locked (primary), Load Character, Start Another Run | Cinzel Bold / Source Sans | all Cinzel | |
| Potions Stashed + count | Source Sans | **Cinzel** (`HudLabel` / `HudValue`) | short label + number |
| Pager "1 / 2" | Source Sans | **Cinzel dim (`StatLabel`)** | short counter |
| Codex: title, "Entry N", "Entry N — sealed" | Cinzel | unchanged | |
| Codex: lore, progress ("1 / 27 entries revealed"), sealed note | Source Sans | unchanged | reading |
| Codex: empty-state message ("Complete your first run…") | Cinzel (as card title) | **Source Sans** | it is a sentence |
| Codex: "The codex is complete." | Cinzel | unchanged | short heading |

### In-run

| Element | Before | Decided | Why |
|---|---|---|---|
| HUD health "77 / 150", kills, day "Day 1 / 30", wallet counts | Source Sans bold | **Cinzel Bold** | numbers; box widths measured (`HudVitals`, `COMPASS_W`) |
| HUD ability caption (Charging…, Rapid attack 3.2s, Cooldown 5s) | Source Sans | **Cinzel dim** | ≤ 4 tokens; width verified |
| HUD wallet names (Potions, Bronze key…) | Source Sans | **Cinzel dim** | short labels |
| Heading plate (N, NE, …) | Source Sans | **Cinzel Bold**; plate 56 → 72 px | widest heading + margins measured |
| Minimap cardinals N E S W | Cinzel | unchanged | intercardinals (NE…) stay metadata Source Sans |
| HUD buff list: name — timer | Source Sans | **Cinzel** | name is short; description line stays Source Sans caption |
| Trap status panel (bottom centre) | Source Sans warning | unchanged | status strings with durations |
| Trap banners: name + duration | Source Sans bold | **Cinzel Bold** | names / numbers |
| Buff roulette: "Choose Your Fate", card title | Cinzel | unchanged | |
| Buff roulette: rarity tag, "Day N" | Source Sans | **Cinzel dim (`StatLabel`)** | short tags; rarity is also colour |
| Buff roulette: description, tradeoff | Source Sans | unchanged | descriptions / sentences |
| Buff roulette: "TAP to stop" / "Press Enter to stop" | Cinzel / Source Sans | unchanged | action word vs. instruction sentence |
| YOU DIED | Cinzel Black | unchanged | |
| YOU DIED prompts ("Press X to start a new run") | Source Sans | unchanged | instructions with key glyphs |
| YOU DIED touch exits | Source Sans / primary | all Cinzel | buttons |
| Run end: title | Cinzel Bold | unchanged | headline |
| Run end: flavour, option descriptions | Source Sans | unchanged | reading |
| Run end: buttons | Source Sans / primary | all Cinzel | |
| Chest prompt "[E] Use Bronze Key" | Source Sans bold | **Cinzel Bold**, 1.25× | short prompt; small caps are set larger over the world |
| Chest "Locked — come back with a Bronze Key" | Source Sans bold | **Source Sans warning** | a sentence |
| Portal hint "N enemies remain — clear…" | Source Sans warning | unchanged | sentence |
| Portal announce "Day 30 — an exit has appeared…" | Cinzel Bold | unchanged | one-line headline (wraps to two) |
| Globe alert "Potent Curse Sensed" / "Vitality Surge (+25)" | Cinzel | unchanged, 1.3× | name; larger over the world |

### Touch layer and diagnostics (owned by the touch work; recorded here for completeness)

| Element | Now | Decision | Status |
|---|---|---|---|
| Touch button captions (OPEN, USE…) — `touch_button.gd` `PUI.font("body_semi")` | Source Sans | **Cinzel SemiBold**, ≥ 16 px | one-line change left to the touch owner (see report) |
| Touch button badge (potion count) — `PUI.font("body_bold")` | Source Sans bold | Cinzel Bold | same patch |
| Touch onboarding hints ("Tap to attack - hold to charge") | Source Sans | **stay Source Sans** | sentences |
| Performance overlay ("58 fps \| low 1%: 41 \| …") | default Label (Source Sans) | **stay Source Sans** | diagnostics |

## 3. Glyph audit

Scan: every string literal in `scripts/`, `autoloads/` and `scenes/` (comments, `print`/`push_*`/`assert` lines and the OTA
internals excluded), `data/buffs.json`, `data/globe_effects.json`, `data/codex_lore.txt`, the role samples, and the whole
printable ASCII range — 3,990 strings. Non-ASCII characters actually in shipped UI text: **— (U+2014)** and **· (U+00B7)**;
the codex also uses **…**. All are drawn by Cinzel itself.

| Glyph | Cinzel | Source Sans | Engine font | Result |
|---|---|---|---|---|
| ASCII 33–126 | yes | yes | yes | fine |
| — – · × … • ’ “ ” | yes | yes | yes | fine |
| ↑ ↓ | no | yes | no | via fallback |
| ← → ✓ ✔ ✕ ⚠ ☰ Ⓐ | no | no | no | **forbidden in text** (icons instead; asserted) |

Nothing shipped used a forbidden glyph. Functional symbols are therefore never replaced by a broken Cinzel glyph.

## 4. Sizing audit

* Cinzel is wider (≈ 12–18 %) and its lowercase is small caps. Role sizes were chosen so that every Cinzel role renders at
  ≥ 16 px on desktop (0.86 scale) and ≥ 20 px on phones; touch minimums (labels ≥ 22, buttons ≥ 26) are applied on top by
  `MobileUi` and still hold.
* `test_typography` lays out the real screens at 1920×1080 and at the phone canvas (1602×720) and asserts: no label is
  trimmed, no button is narrower than its text + margins, nothing leaves the screen (scroll areas: horizontally), the five
  Options tabs fit one row, the health read-out box fits "1000 / 1000", the ability caption fits beside its bar and the
  heading plate fits the widest heading ("NW").
* Adjusted: `COMPASS_W` 56 → 72; the health read-out box is measured from the font instead of a fixed 120 px; world-space
  prompts/alerts (chest, globe) are set one step larger than the role size.
* Judgement calls only a device can confirm: legibility of 17 px small caps (desktop HUD labels) in a bright room and of the
  20 px dim HUD captions over a very bright wall.
