# Fonts (both SIL Open Font License 1.1 - free to bundle and ship)

| Role | Font | Files |
|---|---|---|
| Identity (titles, headings, card titles, every button and tab, names, short labels, HUD numbers and names, short prompts) | Cinzel (Copyright 2020 The Cinzel Project Authors) | `Cinzel-SemiBold`, `Cinzel-Bold`, `Cinzel-Black` |
| Reading (sentences, descriptions, lore, notes, footers, diagnostics, typed text, value fields) | Source Sans 3 (Copyright 2010-2020 Adobe) | `SourceSans3-Regular`, `-SemiBold`, `-Bold` |

Exactly two families ship. Which text uses which is decided by the type roles in `scripts/ui/pui.gd` (`PUI.ROLES`) and
documented in `docs/UI_DESIGN_SYSTEM.md` section 2 and `docs/TYPOGRAPHY_AUDIT.md`.

Obtained from the Fontsource npm packages (`@fontsource/cinzel`, `@fontsource/source-sans-3`, v5.3.0), Latin subset, WOFF2.
Licences: `OFL-Cinzel.txt`, `OFL-SourceSans3.txt`.

Glyph coverage (the Latin subsets are small): Cinzel has ASCII, the em/en dash, middle dot, bullet, ellipsis,
multiplication sign and curly quotes, but no arrows. `PUI.font()` therefore builds an explicit fallback chain,
**Cinzel -> Source Sans 3 (same weight) -> engine font**, so the up/down arrows come from Source Sans. No bundled font has
left/right arrows, check marks, the warning sign, hamburger or circled letters: never put those in text, draw an icon
(`scripts/touch/touch_icons.gd`, `PUIIcon`). `tests/test_typography.gd` fails when a shipped string needs a glyph no font
in the chain can draw.

Cinzel's lowercase is small caps and its digit 1 looks like a capital I: it is used only for short text, never below
16 px, and never for code-like strings (key bindings, resolutions) or text the player types.

No further Cinzel weights are bundled: SemiBold / Bold / Black cover every role. Only add a weight when a role uses it.
