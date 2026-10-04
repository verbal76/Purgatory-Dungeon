#!/usr/bin/env bash
# Publishes "Purgatory Dungeon v<N>" as a GitHub Release from an already-built artifact.
# Used by .github/workflows/ci.yml (tag builds and "promote an existing build" dispatches).
#
# usage: publish_release.sh <version> <source_sha> <artifact_dir> <ci_run_id> <make_latest:true|false> [extra_notes_file]
#   artifact_dir must contain PurgatoryDungeon.exe, PurgatoryDungeon.pck (and BUILD_INFO.txt).
# It never overwrites: if release or tag v<N> already exists the script fails.
set -euo pipefail

V="$1"; SHA="$2"; DIR="$3"; RUN="$4"; LATEST="$5"; EXTRA="${6:-}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
PRODUCT="Purgatory Dungeon"
TAG="v${V}"
ZIPNAME="Purgatory-Dungeon-v${V}-Windows.zip"

[[ "$V" =~ ^[1-9][0-9]*$ ]] || { echo "version must be a positive integer, got '$V'"; exit 1; }
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "source sha must be a full 40-char commit, got '$SHA'"; exit 1; }
test -s "$DIR/PurgatoryDungeon.exe" && test -s "$DIR/PurgatoryDungeon.pck" \
  || { echo "artifact directory $DIR is missing the exe/pck"; ls -la "$DIR"; exit 1; }

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists - a version number identifies exactly one delivered build. Refusing."; exit 1
fi
# (authenticated check: an unauthenticated git ls-remote cannot see tags of a private repo)
if gh api "repos/${REPO}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
  echo "Tag $TAG already exists. Refusing to reuse a version number."; exit 1
fi

# The artifact's own build record must agree with the commit we are about to tag.
if [[ -f "$DIR/BUILD_INFO.txt" ]]; then
  BUILT_SHA="$(sed -n 's/^source_sha=//p' "$DIR/BUILD_INFO.txt" | head -1)"
  if [[ -n "$BUILT_SHA" && "$BUILT_SHA" != "$SHA" ]]; then
    echo "BUILD_INFO source_sha ($BUILT_SHA) != requested source ($SHA). Refusing."; exit 1
  fi
fi

STAGE="$(mktemp -d)"; PKG="$STAGE/Purgatory-Dungeon-v${V}"; mkdir -p "$PKG"
cp "$DIR/PurgatoryDungeon.exe" "$DIR/PurgatoryDungeon.pck" "$PKG/"
[[ -f "$DIR/BUILD_INFO.txt" ]] && cp "$DIR/BUILD_INFO.txt" "$PKG/"
cat > "$PKG/VERSION.txt" <<VER
${PRODUCT} v${V}
Platform: Windows (x86-64)
Install: extract ALL files into one folder, keep PurgatoryDungeon.exe and PurgatoryDungeon.pck
together, then run PurgatoryDungeon.exe.
Saves: Documents\\PurgetoryDungeon\\ (unchanged from earlier builds).
Source commit: ${SHA}
VER
( cd "$STAGE" && zip -q -r "$ZIPNAME" "Purgatory-Dungeon-v${V}" )
mv "$STAGE/$ZIPNAME" "./$ZIPNAME"

EXE_SHA="$(sha256sum "$PKG/PurgatoryDungeon.exe" | cut -d' ' -f1)"
PCK_SHA="$(sha256sum "$PKG/PurgatoryDungeon.pck" | cut -d' ' -f1)"
ZIP_SHA="$(sha256sum "./$ZIPNAME" | cut -d' ' -f1)"
GODOT_LINE="$(sed -n 's/^godot=//p' "$DIR/BUILD_INFO.txt" 2>/dev/null | head -1)"

NOTES="$STAGE/notes.md"
{
  echo "# ${PRODUCT} v${V}"
  echo
  echo "**Windows:** \`${ZIPNAME}\`"
  echo
  echo "**Install:** extract the whole zip into a new folder (keep \`PurgatoryDungeon.exe\` and \`PurgatoryDungeon.pck\` together) and run \`PurgatoryDungeon.exe\`."
  echo
  if [[ -n "$EXTRA" && -s "$EXTRA" ]]; then cat "$EXTRA"; echo; fi
  echo "---"
  echo "### Technical details (engineering only)"
  echo "- Source commit: \`${SHA}\`"
  echo "- Built by CI run: https://github.com/${REPO}/actions/runs/${RUN}"
  echo "- Engine: ${GODOT_LINE:-Godot 4.6}"
  echo "- Android: not built for this release"
  echo "- SHA-256 \`PurgatoryDungeon.exe\`: \`${EXE_SHA}\`"
  echo "- SHA-256 \`PurgatoryDungeon.pck\`: \`${PCK_SHA}\`"
  echo "- SHA-256 \`${ZIPNAME}\`: \`${ZIP_SHA}\`"
  echo "- Release convention: docs/RELEASES.md"
} > "$NOTES"

gh release create "$TAG" "./$ZIPNAME" --repo "$REPO" --target "$SHA" \
  --title "${PRODUCT} v${V}" --notes-file "$NOTES" --latest="$LATEST"
gh release view "$TAG" --repo "$REPO" --json name,tagName,url,assets \
  --jq '{title:.name, tag:.tagName, url:.url, assets:[.assets[]|{name,size}]}'
echo "Latest release is now: $(gh api "repos/${REPO}/releases/latest" --jq '.name')"
