#!/usr/bin/env bash
# Builds the OTA patch payload for one native baseline (docs/OTA.md sections 3-4). NO signing and no publishing here:
# the output is a patch pack + files.json that tools/ota_make_manifest.gd turns into a manifest.
#   usage: tools/ota_build_payload.sh --godot <godot-binary> --base-sha <native baseline commit> --out DIR [options]
#          tools/ota_build_payload.sh --godot <godot-binary> --self-test [--out DIR]
#   options:
#     --head-sha REF         the commit the update is built from (default HEAD; pinned to its full 40-hex SHA)
#     --out DIR              output directory (must be empty or absent; --self-test: build/ota-selftest, wiped first)
#     --native-artifact PATH the SHIPPED native build to compare base.pck against (strongly recommended, required by CI):
#                              android: the APK (files under assets/ are compared, see tools/ota/native_check.py)
#                              windows: the build folder / PurgatoryDungeon.exe / .pck / release zip
#                            Its build_info.json (commit, runtime_id, runtime_fingerprint ...) is reused byte for byte in
#                            both trees, so it can never be part of the patch.
#     --native-platform P    android | windows (default: guessed from the artifact name; android without one)
#     --native-check MODE    fail (default) | warn: what a base.pck/native mismatch does
#     --preset NAME          export preset (default "Android"; the local end-to-end test uses "Windows Desktop" so the
#                            baseline pack can run on a desktop)
#     --accept-guarded WHY   allow guarded save/settings code in the update (recorded in the report)
#     --emit-base            also copy base.pck to the output directory (the end-to-end driver runs the game from it)
#     --keep-temp            keep the temp worktrees (writes build_env.json into the output directory)
#     --self-test            prove the whole chain without any published native build: HEAD is its own baseline plus a
#                            synthetic change to data/ota_probe.json (created in the temp worktree only). --base-sha is
#                            not needed. Never publishable (its build identity is synthetic when the tree has no runtime).
#   output (in --out): payload.pck, files.json ([{"path","op"}] from the independent PCK parser), payload_report.json,
#     classify.json, build_info.json (the baseline identity), [base.pck], [build_env.json]
#   exit status: 0 ok, 10 the change set needs a new APK, 11 guarded code without --accept-guarded, 1 any other refusal
# Steps: pin commits -> classify base..head (ota/boundary.json at the base) -> temp worktrees of both -> same import as
#   tools/android/build_apk.sh (Android: ETC2/ASTC on) -> base.pck (`--export-pack`) -> optional comparison with the
#   shipped native build -> HEAD seeded with the BASE import cache (Godot's importer is not byte-deterministic) ->
#   `--export-patch <preset> payload.pck --patches base.pck` -> tools/ota/payload_check.py (protected paths, size limits,
#   files[]). Needs: git, python3, the Godot 4.6 binary (+ export templates for the preset).
set -euo pipefail

usage() { awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; }
die() { echo "ota_build_payload: $*" >&2; exit "${DIE_CODE:-1}"; }

GODOT=""; BASE_REF=""; HEAD_REF="HEAD"; OUT=""; NATIVE=""; NPLAT=""; NATIVE_CHECK="fail"; PRESET="Android"
ACCEPT=""; EMIT_BASE=0; KEEP=0; SELF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --godot) GODOT="${2:?}"; shift 2 ;;
    --base-sha) BASE_REF="${2:?}"; shift 2 ;;
    --head-sha) HEAD_REF="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --native-artifact) NATIVE="${2:?}"; shift 2 ;;
    --native-platform) NPLAT="${2:?}"; shift 2 ;;
    --native-check) NATIVE_CHECK="${2:?}"; shift 2 ;;
    --preset) PRESET="${2:?}"; shift 2 ;;
    --accept-guarded) ACCEPT="${2:?}"; shift 2 ;;
    --emit-base) EMIT_BASE=1; shift ;;
    --keep-temp) KEEP=1; shift ;;
    --self-test) SELF=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument $1" ;;
  esac
done

[[ -n "$GODOT" && ( -x "$GODOT" || -n "$(command -v "$GODOT" 2>/dev/null)" ) ]] || die "--godot <binary> is required and must be executable"
[[ "$NATIVE_CHECK" == "fail" || "$NATIVE_CHECK" == "warn" ]] || die "--native-check must be fail or warn"
GODOT="$(command -v "$GODOT")"
cd "$(dirname "$0")/.."
ROOT="$PWD"
OTA="$ROOT/tools/ota"

TMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ota-payload.XXXXXX")"
cleanup() {
  local rc=$?
  if [[ "$KEEP" == "1" ]]; then echo "ota_build_payload: temp kept at $TMP"; return $rc; fi
  for t in base head; do
    [[ -d "$TMP/$t" ]] && git -C "$ROOT" worktree remove --force "$TMP/$t" >/dev/null 2>&1 || true
  done
  git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
  rm -rf "$TMP"
  return $rc
}
trap cleanup EXIT

HEAD_SHA="$(git rev-parse --verify --quiet "$HEAD_REF^{commit}")" || die "cannot resolve --head-sha $HEAD_REF to a commit"
if [[ "$SELF" == "1" ]]; then
  [[ -z "$BASE_REF" ]] || die "--self-test uses HEAD as its own baseline; do not pass --base-sha"
  BASE_SHA="$HEAD_SHA"
  if [[ -z "$OUT" ]]; then OUT="build/ota-selftest"; rm -rf "$OUT"; fi   # the default location is disposable
else
  [[ -n "$BASE_REF" ]] || { usage >&2; die "--base-sha is required (the native baseline's source commit)"; }
  BASE_SHA="$(git rev-parse --verify --quiet "$BASE_REF^{commit}")" || die "cannot resolve --base-sha $BASE_REF (fetch the history first)"
  [[ -n "$OUT" ]] || die "--out DIR is required"
fi
if [[ -e "$OUT" && -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then die "--out $OUT is not empty (use a fresh directory)"; fi
if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  echo "ota_build_payload: note: uncommitted changes in the checkout are ignored; the update is built from commit $HEAD_SHA"
fi

NATIVE_VERSION="$(git show "$BASE_SHA:VERSION" | tr -d '[:space:]')"
[[ "$NATIVE_VERSION" =~ ^[1-9][0-9]*$ ]] || die "VERSION at $BASE_SHA is not a positive integer"
ENGINE="$("$GODOT" --version | tr -d '[:space:]')"
WANT_ENGINE="$(python3 "$ROOT/tools/ota_runtime.py" --engine)" || die "cannot read the engine version from ota/boundary.json / ci.yml"
[[ "$ENGINE" == "$WANT_ENGINE".stable* ]] || die "engine mismatch: the project pins Godot $WANT_ENGINE (GODOT_RELEASE) but --godot reports $ENGINE"
echo "== OTA payload: preset=$PRESET native=v$NATIVE_VERSION base=$BASE_SHA head=$HEAD_SHA engine=$ENGINE self_test=$SELF"
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"

# ---- 1. classification (the boundary at the base: a head commit cannot weaken its own gate)
if [[ "$SELF" == "1" ]]; then
  echo "== classify: skipped for the self-test (HEAD..HEAD; the synthetic probe file is OTA-safe by construction)"
  printf '{"result": "self_test", "exit_code": 0}\n' > "$OUT/classify.json"
else
  echo "== classify $BASE_SHA..$HEAD_SHA"
  GUARD=(); [[ -n "$ACCEPT" ]] && GUARD=(--accept-guarded "$ACCEPT")
  python3 "$OTA/classify.py" "$BASE_SHA" "$HEAD_SHA" --json "${GUARD[@]}" > "$OUT/classify.json" || true
  rc=0; python3 "$OTA/classify.py" "$BASE_SHA" "$HEAD_SHA" "${GUARD[@]}" || rc=$?
  if [[ $rc -eq 10 ]]; then DIE_CODE=10 die "the change set since the native baseline needs a new APK/native build (listed above); it cannot ship over the air"; fi
  if [[ $rc -eq 11 ]]; then DIE_CODE=11 die "guarded save/settings code changed; rerun with --accept-guarded \"<reason>\" if the update stays readable by the previous code"; fi
  [[ $rc -eq 0 ]] || die "classification failed (exit $rc)"
fi

# ---- 2. temp worktrees
echo "== worktrees"
git worktree add --detach --quiet "$TMP/base" "$BASE_SHA"
git worktree add --detach --quiet "$TMP/head" "$HEAD_SHA"

# ---- 3. the baseline identity (build_info.json), identical in both trees
if [[ -z "$NPLAT" ]]; then
  case "$NATIVE" in *.apk|"") NPLAT="android" ;; *) NPLAT="windows" ;; esac
fi
if [[ -n "$NATIVE" ]]; then
  python3 "$OTA/native_check.py" extract --platform "$NPLAT" --native "$NATIVE" --path build_info.json --out "$TMP/build_info.json" \
    || die "could not read build_info.json from the native artifact $NATIVE"
else
  echo "ota_build_payload: no --native-artifact: base.pck is built with a regenerated build_info.json (the shipped one is stamped per build)"
  IDENT="$TMP/ident.json"
  if python3 "$TMP/base/tools/ota_runtime.py" --print --json > "$IDENT" 2>"$TMP/ident.err"; then
    :
  elif [[ "$SELF" == "1" ]]; then
    echo "ota_build_payload: self-test: the tree has no native runtime yet ($(tr '\n' ' ' < "$TMP/ident.err")); using a SYNTHETIC identity"
    printf '{"runtime_id": "android-godot-4.6.0-r1", "runtime_fingerprint": "%s", "ota_channel": "dev"}\n' "$(printf 'self-test' | sha256sum | cut -d' ' -f1)" > "$IDENT"
  else
    die "cannot compute the baseline's runtime identity: $(cat "$TMP/ident.err")"
  fi
  idv() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$IDENT" "$1"; }
  BT="$TMP/base/tools/release_tool.py"
  grep -q -- "--runtime-fingerprint" "$BT" || die "the baseline's release_tool.py predates the runtime identity (cannot bake it)"
  python3 "$BT" build-info "$TMP/build_info.json" --commit "$BASE_SHA" --run-id "ota-base" --release \
    --runtime-id "$(idv runtime_id)" --runtime-fingerprint "$(idv runtime_fingerprint)" --ota-channel "$(idv ota_channel)" >/dev/null
fi
cp "$TMP/build_info.json" "$TMP/base/build_info.json"
cp "$TMP/build_info.json" "$TMP/head/build_info.json"
cp "$TMP/build_info.json" "$OUT/build_info.json"

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
  if [[ "$PRESET" == "Android" ]]; then enable_etc2_astc "$1" || die "could not enable ETC2/ASTC import in $1"; fi
  "$GODOT" --headless --path "$1" --import >/dev/null 2>&1 || true
  "$GODOT" --headless --path "$1" --import >/dev/null 2>&1 || true
}

# ---- 4. base.pck
echo "== import + export base.pck ($PRESET) from $BASE_SHA"
import_tree "$TMP/base"
"$GODOT" --headless --path "$TMP/base" --export-pack "$PRESET" "$TMP/base.pck" 2>&1 | tail -5
[[ -s "$TMP/base.pck" ]] || die "export of base.pck produced nothing (export templates installed? preset '$PRESET' present at the base commit?)"
python3 "$OTA/pck.py" verify "$TMP/base.pck" || die "base.pck failed its own integrity check"

# ---- 5. does base.pck equal the shipped native build?
NATIVE_STATE="not-compared"
if [[ -n "$NATIVE" ]]; then
  echo "== compare base.pck with the shipped native build"
  FLAGS=(); [[ "$NATIVE_CHECK" == "warn" ]] && FLAGS=(--warn-only)
  # Godot's importer is not byte-deterministic (see native_check.py), so import products only have to exist.
  python3 "$OTA/native_check.py" compare --platform "$NPLAT" --base-pck "$TMP/base.pck" --native "$NATIVE" \
    --allow build_info.json --tolerate godot/imported/ --tolerate godot/exported/ --tolerate .godot/imported/ \
    --tolerate .godot/exported/ --tolerate godot/global_script_class_cache.cfg --tolerate .godot/global_script_class_cache.cfg \
    "${FLAGS[@]}" 2>&1 | tail -150 \
    || die "base.pck does not reproduce the shipped native build; an update built against it would not be safe"   # (pipefail)
  NATIVE_STATE="compared"; [[ "$NATIVE_CHECK" == "warn" ]] && NATIVE_STATE="compared-warn-only"
else
  echo "ota_build_payload: WARNING: --native-artifact not given; base.pck was NOT compared with the shipped native build"
fi

# ---- 6. patch of HEAD against base.pck
# Godot's importer is NOT byte-deterministic: two independent imports of the same commit differ in ~14% of the files
# (random scene-unique ids in imported .scn/.res and the exported scenes; measured: 126 of 892, incl. a 166 MB model).
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

# ---- 7. independent check + files[]
echo "== check the payload with the independent PCK reader"
BOUNDARY="$TMP/base/ota/boundary.json"; [[ -f "$BOUNDARY" ]] || BOUNDARY="$ROOT/ota/boundary.json"
GUARD=(); [[ -n "$ACCEPT" ]] && GUARD=(--accept-guarded "$ACCEPT")
python3 "$OTA/payload_check.py" "$TMP/payload.pck" --base "$TMP/base.pck" --boundary "$BOUNDARY" \
  --files-out "$OUT/files.json" --report-out "$TMP/check_report.json" "${GUARD[@]}" || die "the payload was refused (see above)"
# (listed to a file first: `list | head -60` under `set -o pipefail` killed the whole step with exit 141 (SIGPIPE) as soon as a payload
# had more than 60 entries; a failing reader must still fail the step)
python3 "$OTA/pck.py" list "$TMP/payload.pck" --base "$TMP/base.pck" > "$TMP/payload_list.txt" || die "the PCK reader could not list the payload"
head -60 "$TMP/payload_list.txt"

cp "$TMP/payload.pck" "$OUT/payload.pck"
[[ "$EMIT_BASE" == "1" ]] && cp "$TMP/base.pck" "$OUT/base.pck"
python3 - "$TMP/check_report.json" "$OUT/payload_report.json" <<PY
import json, sys
r = json.load(open(sys.argv[1]))
r.update({"head_sha": "$HEAD_SHA", "base_source_sha": "$BASE_SHA", "preset": "$PRESET", "engine_build": "$ENGINE",
          "native_version": int("$NATIVE_VERSION"), "native_comparison": "$NATIVE_STATE", "self_test": $SELF == 1,
          "base_pck_sha256": "$(sha256sum "$TMP/base.pck" | cut -d' ' -f1)"})
open(sys.argv[2], "w").write(json.dumps(r, indent=2, sort_keys=True) + "\n")
PY
if [[ "$KEEP" == "1" ]]; then
  printf '{"tmp": "%s", "base_pck": "%s", "head_tree": "%s", "base_tree": "%s", "preset": "%s"}\n' \
    "$TMP" "$TMP/base.pck" "$TMP/head" "$TMP/base" "$PRESET" > "$OUT/build_env.json"
fi

echo "== done: $OUT"
ls -l "$OUT"
echo "ota_build_payload: base.pck sha256 $(sha256sum "$TMP/base.pck" | cut -d' ' -f1) (engineering metadata)"
if [[ "$SELF" == "1" ]]; then echo "ota_build_payload: SELF-TEST PASSED (never publishable: HEAD is its own baseline plus a synthetic probe)"; fi
