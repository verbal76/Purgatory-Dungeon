#!/usr/bin/env bash
# Builds, signs and verifies one OTA update for one platform (docs/OTA.md). Called by .github/workflows/ota.yml.
#   usage: tools/ota/build_ota.sh --platform android|windows --base-ref <git ref/tag of the native build>
#                                 --godot <godot-binary> --seq <K> [options]
#   options:
#     --out DIR              bundle/channel directory (default build/ota; --self-test: build/ota-selftest, wiped first)
#     --key PEM              signing key (default $OTA_PRIVATE_KEY_PATH, i.e. what tools/ota/keys.sh exported)
#     --native-artifact PATH the shipped native build to compare base.pck against (strongly recommended):
#                              windows: the build folder / PurgatoryDungeon.exe / .pck / release zip
#                                       (the exe's sibling PurgatoryDungeon.pck is compared)
#                              android: the APK (files under assets/ are compared, see native_check.py)
#                            Its build_info.json is also reused so the patch never contains it.
#     --native-check MODE    fail (default) | warn: what a base.pck/native mismatch does
#     --accept-guarded WHY   allow guarded save/settings code in the update (recorded in the log)
#     --no-channel           stop after the bundle (the workflow merges channel.json once for both platforms)
#     --keep-temp            keep the temp worktrees (debugging)
#     --self-test            prove the whole chain without any published native build: HEAD is its own base plus a
#                            synthetic change to data/ota_probe.json (created in the temp worktree only), signed with a
#                            throwaway key, then verified. --base-ref/--seq/--key are not needed.
# Steps: temp worktrees of the base ref and of HEAD -> same import as CI (android: ETC2/ASTC import on, exactly as
#   tools/android/build_apk.sh) -> base.pck (`--export-pack <preset>`) -> tools/ota/classify.py base..HEAD (aborts when an
#   APK is required) -> optional native comparison -> `--export-patch <preset> payload.pck --patches base.pck` of HEAD ->
#   make_bundle.py -> channel.py merge -> verify_bundle.py (CI gate). Nothing is published or pushed by this script.
# Files that are generated per build, not committed (ota_trust.pem, build_info.json) are placed byte-identically in BOTH
# trees, so they are never part of the patch. Needs: git, python3, openssl, the Godot 4.6 binary (+ export templates).
set -euo pipefail

usage() { awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; }
die() { echo "build_ota: $*" >&2; exit 1; }

PLATFORM=""; BASE_REF=""; GODOT=""; SEQ=""; OUT=""; KEY=""; NATIVE=""
NATIVE_CHECK="fail"; ACCEPT=""; CHANNEL=1; KEEP=0; SELF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) PLATFORM="${2:?}"; shift 2 ;;
    --base-ref) BASE_REF="${2:?}"; shift 2 ;;
    --godot) GODOT="${2:?}"; shift 2 ;;
    --seq) SEQ="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --key) KEY="${2:?}"; shift 2 ;;
    --native-artifact) NATIVE="${2:?}"; shift 2 ;;
    --native-check) NATIVE_CHECK="${2:?}"; shift 2 ;;
    --accept-guarded) ACCEPT="${2:?}"; shift 2 ;;
    --no-channel) CHANNEL=0; shift ;;
    --keep-temp) KEEP=1; shift ;;
    --self-test) SELF=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument $1" ;;
  esac
done

case "$PLATFORM" in
  android) PRESET="Android" ;;
  windows) PRESET="Windows Desktop" ;;
  *) usage >&2; die "--platform must be android or windows" ;;
esac
[[ -x "$GODOT" || -n "$(command -v "$GODOT" 2>/dev/null)" ]] || die "--godot <binary> is required and must be executable"
[[ "$NATIVE_CHECK" == "fail" || "$NATIVE_CHECK" == "warn" ]] || die "--native-check must be fail or warn"
GODOT="$(command -v "$GODOT")"
cd "$(dirname "$0")/../.."
ROOT="$PWD"
OTA="$ROOT/tools/ota"

TMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/build-ota.XXXXXX")"
cleanup() {
  local rc=$?
  if [[ "$KEEP" == "1" ]]; then echo "build_ota: temp kept at $TMP"; return; fi
  for t in base head; do
    [[ -d "$TMP/$t" ]] && git -C "$ROOT" worktree remove --force "$TMP/$t" >/dev/null 2>&1 || true
  done
  git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
  rm -rf "$TMP"
  return $rc
}
trap cleanup EXIT

HEAD_SHA="$(git rev-parse --verify HEAD^{commit})"
if [[ "$SELF" == "1" ]]; then
  BASE_SHA="$HEAD_SHA"; SEQ="${SEQ:-1}"
  if [[ -z "$OUT" ]]; then OUT="build/ota-selftest"; rm -rf "$OUT"; fi   # the default location is disposable
  if [[ -e "$OUT" && -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then die "--out $OUT is not empty (self-test needs a fresh directory)"; fi
  if [[ -z "$KEY" ]]; then
    # never the real key: ignore $OTA_PRIVATE_KEY_PATH and the secret even when they are present in the environment
    echo "== self-test: throwaway signing key (never leaves $TMP)"
    env -u OTA_SIGNING_KEY_PEM_BASE64 -u OTA_PRIVATE_KEY_PATH OTA_KEY_DIR="$TMP/keys" bash "$OTA/keys.sh" "$TMP/ota_trust.pem" >/dev/null
    KEY="$TMP/keys/ota-signing.key"
  fi
else
  KEY="${KEY:-${OTA_PRIVATE_KEY_PATH:-}}"
  [[ -n "$BASE_REF" ]] || { usage >&2; die "--base-ref is required"; }
  [[ "$SEQ" =~ ^[1-9][0-9]*$ ]] || die "--seq <K> (positive integer) is required"
  BASE_SHA="$(git rev-parse --verify --quiet "$BASE_REF^{commit}")" || die "cannot resolve --base-ref $BASE_REF (fetch tags/history first)"
  [[ -n "$OUT" ]] || OUT="build/ota"
fi
[[ -n "$KEY" && -f "$KEY" ]] || die "no signing key (use --key or source tools/ota/keys.sh first)"
if [[ ! -f "$TMP/ota_trust.pem" ]]; then openssl pkey -in "$KEY" -pubout -out "$TMP/ota_trust.pem"; fi
if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  echo "build_ota: note: uncommitted changes in the checkout are ignored; the update is built from commit $HEAD_SHA"
fi

NATIVE_VERSION="$(git show "$BASE_SHA:VERSION" | tr -d '[:space:]')"
[[ "$NATIVE_VERSION" =~ ^[1-9][0-9]*$ ]] || die "VERSION at $BASE_SHA is not a positive integer"
ENGINE="$("$GODOT" --version | tr -d '[:space:]')"
echo "== OTA build: platform=$PLATFORM native=v$NATIVE_VERSION base=$BASE_SHA head=$HEAD_SHA seq=$SEQ"
echo "== engine $ENGINE"
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"

# ---- 1. classification (the same rules the client enforces again before mounting)
if [[ "$SELF" == "1" ]]; then
  echo "== classify: skipped for the self-test (HEAD..HEAD; the synthetic probe file is OTA-safe by construction)"
else
  echo "== classify $BASE_SHA..$HEAD_SHA"
  GUARD=()
  [[ -n "$ACCEPT" ]] && GUARD=(--accept-guarded "$ACCEPT")
  rc=0; python3 "$OTA/classify.py" "$BASE_SHA" "$HEAD_SHA" "${GUARD[@]}" || rc=$?
  if [[ $rc -eq 10 ]]; then die "the change set since v$NATIVE_VERSION needs a new APK/native build (listed above); it cannot ship over the air"; fi
  if [[ $rc -eq 11 ]]; then die "guarded save/settings code changed; rerun with --accept-guarded \"<reason>\" if the update stays readable by the previous code"; fi
  [[ $rc -eq 0 ]] || die "classification failed (exit $rc)"
fi

# ---- 2. temp worktrees
echo "== worktrees"
git worktree add --detach --quiet "$TMP/base" "$BASE_SHA"
git worktree add --detach --quiet "$TMP/head" "$HEAD_SHA"

# per-build generated files, identical in both trees
cp "$TMP/ota_trust.pem" "$TMP/base/ota_trust.pem"
cp "$TMP/ota_trust.pem" "$TMP/head/ota_trust.pem"
if [[ -n "$NATIVE" ]]; then
  python3 "$OTA/native_check.py" extract --platform "$PLATFORM" --native "$NATIVE" --path build_info.json --out "$TMP/build_info.json" \
    || die "could not read build_info.json from the native artifact $NATIVE"
else
  BT="$TMP/base/tools/release_tool.py"; [[ -f "$BT" ]] || BT="$ROOT/tools/release_tool.py"
  python3 "$BT" build-info "$TMP/build_info.json" --commit "$BASE_SHA" --run-id "ota-base" --release >/dev/null
  echo "build_ota: no --native-artifact: base.pck is built with a regenerated build_info.json (the shipped one is stamped per build)"
fi
cp "$TMP/build_info.json" "$TMP/base/build_info.json"
cp "$TMP/build_info.json" "$TMP/head/build_info.json"

if [[ "$SELF" == "1" ]]; then
  mkdir -p "$TMP/head/data"
  printf '{\n  "ota_self_test": true,\n  "head_commit": "%s"\n}\n' "$HEAD_SHA" > "$TMP/head/data/ota_probe.json"
  if [[ -f "$TMP/base/data/ota_probe.json" ]]; then echo "self-test: data/ota_probe.json exists in the tree -> expect op replace"; \
  else echo "self-test: data/ota_probe.json is new in the temp worktree -> expect op add"; fi
fi

enable_etc2_astc() {   # same edit as tools/android/build_apk.sh ("Android needs ETC2/ASTC textures")
  python3 - "$1/project.godot" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "import_etc2_astc" not in s:
    s = s.replace("[rendering]\n", "[rendering]\n\ntextures/vram_compression/import_etc2_astc=true", 1)
    open(p, "w", encoding="utf-8").write(s)
ok = "import_etc2_astc=true" in open(p, encoding="utf-8").read()
print("etc2_astc enabled" if ok else "FAILED to enable etc2_astc")
sys.exit(0 if ok else 1)
PY
}

import_tree() {   # $1 = tree
  if [[ "$PLATFORM" == "android" ]]; then enable_etc2_astc "$1" || die "could not enable ETC2/ASTC import in $1"; fi
  "$GODOT" --headless --path "$1" --import >/dev/null 2>&1 || true
  "$GODOT" --headless --path "$1" --import >/dev/null 2>&1 || true
}

# ---- 3. base.pck
echo "== import + export base.pck ($PRESET) from $BASE_SHA"
import_tree "$TMP/base"
"$GODOT" --headless --path "$TMP/base" --export-pack "$PRESET" "$TMP/base.pck" 2>&1 | tail -5
[[ -s "$TMP/base.pck" ]] || die "export of base.pck produced nothing (export templates installed? preset '$PRESET' present at the base commit?)"
python3 "$OTA/pck.py" verify "$TMP/base.pck" || die "base.pck failed its own integrity check"

# ---- 4. does base.pck equal the shipped native build?
if [[ -n "$NATIVE" ]]; then
  echo "== compare base.pck with the shipped native build"
  FLAGS=(); [[ "$NATIVE_CHECK" == "warn" ]] && FLAGS=(--warn-only)
  # Godot's importer is not byte-deterministic (see native_check.py), so import products only have to exist.
  python3 "$OTA/native_check.py" compare --platform "$PLATFORM" --base-pck "$TMP/base.pck" --native "$NATIVE" \
    --allow build_info.json --tolerate godot/imported/ --tolerate godot/exported/ --tolerate .godot/imported/ \
    --tolerate .godot/exported/ --tolerate godot/global_script_class_cache.cfg --tolerate .godot/global_script_class_cache.cfg \
    "${FLAGS[@]}" 2>&1 | tail -150 \
    || die "base.pck does not reproduce the shipped native build; an update built against it would not be safe"   # (pipefail)
else
  echo "build_ota: WARNING: --native-artifact not given; base.pck was NOT compared with the shipped native build"
fi

# ---- 5. patch of HEAD against base.pck
# Godot's importer is NOT byte-deterministic: two independent imports of the same commit differ in ~14% of the files
# (random scene-unique ids in imported .scn/.res and the exported scenes; measured 126 of 892, incl. a 166 MB model).
# Importing HEAD from scratch would therefore put every such file into the patch. Like the editor does, HEAD starts
# from the BASE import cache and only re-imports what really changed (md5 of the source decides), so the patch holds
# genuine changes only (+ the small, order-randomised global_script_class_cache.cfg).
echo "== import + export patch ($PRESET) of $HEAD_SHA against base.pck (HEAD seeded with the base import cache)"
for d in godot .godot; do
  if [[ -d "$TMP/base/$d" ]]; then rm -rf "$TMP/head/$d"; cp -a "$TMP/base/$d" "$TMP/head/$d"; fi
done
import_tree "$TMP/head"
"$GODOT" --headless --path "$TMP/head" --export-patch "$PRESET" "$TMP/payload.pck" --patches "$TMP/base.pck" 2>&1 | tail -5
[[ -s "$TMP/payload.pck" ]] || die "export-patch produced nothing (is there any shipped change since the base?)"
python3 "$OTA/pck.py" list "$TMP/payload.pck" --base "$TMP/base.pck" > "$TMP/payload.list"
head -40 "$TMP/payload.list"

# ---- 6. bundle, channel, gate
echo "== sign bundle"
GUARD=(); [[ -n "$ACCEPT" ]] && GUARD=(--accept-guarded "$ACCEPT")
BUNDLE="$(python3 "$OTA/make_bundle.py" --platform "$PLATFORM" --native-version "$NATIVE_VERSION" --base-commit "$BASE_SHA" \
  --engine "$ENGINE" --seq "$SEQ" --source-commit "$HEAD_SHA" --payload "$TMP/payload.pck" --base-pck "$TMP/base.pck" \
  --out "$OUT" --key "$KEY" "${GUARD[@]}")"
if [[ "$CHANNEL" == "1" ]]; then
  echo "== channel index"
  python3 "$OTA/channel.py" merge --out "$OUT" --key "$KEY"
fi
echo "== verify (CI gate)"
GATE=(--pubkey "$TMP/ota_trust.pem" --native-version "$NATIVE_VERSION" --platform "$PLATFORM" --base-commit "$BASE_SHA"
      --engine "$ENGINE" --base-pck "$PLATFORM=$TMP/base.pck")
[[ -n "$ACCEPT" ]] && GATE+=(--accept-guarded)
python3 "$OTA/verify_bundle.py" "$BUNDLE" "${GATE[@]}"
if [[ "$CHANNEL" == "1" ]]; then python3 "$OTA/verify_bundle.py" "$OUT" "${GATE[@]}"; fi

echo "== done: $BUNDLE"
ls -l "$BUNDLE"
echo "build_ota: base.pck sha256 $(sha256sum "$TMP/base.pck" | cut -d' ' -f1) (engineering metadata)"
if [[ "$SELF" == "1" ]]; then echo "build_ota: SELF-TEST PASSED (bundle is signed with a throwaway key and must not be published)"; fi
