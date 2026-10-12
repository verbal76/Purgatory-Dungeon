# Controller and keyboard glyphs: provenance and license

**Source.** The glyphs under `xbox/`, `ps5/`, `switch/` and `keyboard/` are a curated subset (147 files) of the Hot Attic Games studio glyph library, delivered by the
owner as `Source.zip` (sha256 `f6c75921b9d6ab2cb2b5249f547c7b7ba19e22da9f4f3b45693cf0912f25ded0`). `LIBRARY.json` lists, for every file, the member it came from and its own sha256. Re-run
`python3 tools/import_glyph_library.py <Source.zip>` to regenerate them.

**License: CC0 1.0 Universal, from the author's distribution page.** The owner supplied (2026-10-12) a screenshot of the library's distribution page ("Input Prompts"
pack by **JulioCacko**, published 2023-06-30, updated 2025-02-03; released on itch.io and FAB; "No generative AI was used"). It states: *"License: CC0 1.0 Universal. Free to
use in any project, commercial or non-commercial. No attribution required (but appreciated!)."* and lists **Asset license: Creative Commons Zero v1.0 Universal** (and
Code license: MIT). The archive itself contains no license file, and the screenshot image could not be stored in the repository by the session that recorded this notice, so:
keep a saved copy of that page (or the CC0 text) in `docs/licenses/` and note the page URL here when it is at hand. Evidence level: license stated by the author, seen by the
owner; not re-fetched from the source by us. Attribution is not required; crediting JulioCacko is a courtesy (done in `docs/THIRD_PARTY.md`).

**Derived.** `xbox/menu.png` and `xbox/view.png` are the library's own Menu and View glyphs, rendered from its sprite sheet (`XGamepad/Light/T_X_Light_Sprite.svg`) and
cropped; nothing is redrawn. The game no longer ships any hand-drawn glyph.

**Use in the game.** `scripts/controller_glyphs.gd` picks the family from the controller in use (or the Options > Controls override) and `scripts/glyph_prompt.gd`
shows the glyph in prompts. PlayStation shapes are also used for the Steam Deck's L1 / R1 / L2 / R2, which are the Deck's own labels.
