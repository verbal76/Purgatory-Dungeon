# Fonts (both SIL Open Font License 1.1 - free to bundle and ship)

| Role | Font | Files |
|---|---|---|
| Display (titles, headings, world-facing text) | Cinzel (Copyright 2020 The Cinzel Project Authors) | `Cinzel-SemiBold`, `Cinzel-Bold`, `Cinzel-Black` |
| Body / UI (buttons, settings, HUD, descriptions) | Source Sans 3 (Copyright 2010-2020 Adobe) | `SourceSans3-Regular`, `-SemiBold`, `-Bold` |

Obtained from the Fontsource npm packages (`@fontsource/cinzel`, `@fontsource/source-sans-3`, v5.3.0), Latin subset, WOFF2.
Licences: `OFL-Cinzel.txt`, `OFL-SourceSans3.txt`. The Latin subset has no arrows or check marks; the theme falls back to the
engine font for such glyphs, but UI should prefer drawn icons (see `scripts/touch/touch_icons.gd`).
