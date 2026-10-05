#!/usr/bin/env bash
# Builds and qualifies the Android APK exactly the way CI does.
#   usage: tools/android/build_apk.sh <godot-binary> [out.apk]
# Needs: JDK 17 (JAVA_HOME_17_X64 or JAVA_HOME), the Android SDK (ANDROID_HOME), the Godot Android export
# templates installed (android_source.zip, android_release.apk, android_debug.apk), the release signing
# environment from tools/android/signing.sh, and build_info.json already written.
set -euo pipefail

GODOT="${1:?godot binary}"
OUT="${2:-build/android/Purgatory-Dungeon-Android.apk}"
cd "$(dirname "$0")/../.."

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -d "$SDK" ]] || { echo "ANDROID_HOME is not set / does not exist"; exit 1; }
JDK="${JAVA_HOME_17_X64:-${JAVA_HOME:-}}"
[[ -d "$JDK" ]] || { echo "JDK 17 not found (JAVA_HOME_17_X64 / JAVA_HOME)"; exit 1; }
VERSION="$(cat VERSION)"
TPL="$HOME/.local/share/godot/export_templates/4.6.stable"
for f in android_source.zip android_release.apk android_debug.apk; do
  [[ -s "$TPL/$f" ]] || { echo "export template $f missing in $TPL"; exit 1; }
done
: "${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:?run tools/android/signing.sh first}"

echo "== Android SDK components"
SDKMANAGER="$(ls "$SDK"/cmdline-tools/*/bin/sdkmanager | tail -1)"
yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
"$SDKMANAGER" "platform-tools" "platforms;android-36" "build-tools;35.0.1" >/dev/null

echo "== Godot editor settings (SDK + JDK paths)"
mkdir -p "$HOME/.config/godot"
cat > "$HOME/.config/godot/editor_settings-4.6.tres" <<TRES
[gd_resource type="EditorSettings" format=3]

[resource]
export/android/android_sdk_path = "$SDK"
export/android/java_sdk_path = "$JDK"
TRES

echo "== Gradle build template (from the official 4.6 templates) with compile/target API 36"
rm -rf android/build
mkdir -p android/build
unzip -q "$TPL/android_source.zip" -d android/build
printf "%s" "$(cat "$TPL/version.txt" 2>/dev/null || echo 4.6.stable)" > android/.build_version
touch android/build/.gdignore
# The template targets API 35; qualify against API 36. (AGP warns that it was tested up to 35: suppressed.)
sed -i "s/compileSdk         : 35/compileSdk         : 36/" android/build/config.gradle
grep -q "compileSdk         : 36" android/build/config.gradle || { echo "could not set compileSdk 36"; exit 1; }
echo "android.suppressUnsupportedCompileSdk=36" >> android/build/gradle.properties

echo "== Android needs ETC2/ASTC textures (Windows keeps S3TC/BPTC only)"
python3 - <<'PY'
import re
p = "project.godot"
s = open(p, encoding="utf-8").read()
if "import_etc2_astc" not in s:
    s = s.replace("[rendering]\n", "[rendering]\n\ntextures/vram_compression/import_etc2_astc=true", 1)
    open(p, "w", encoding="utf-8").write(s)
print("etc2_astc enabled" if "import_etc2_astc=true" in open(p, encoding="utf-8").read() else "FAILED to enable etc2_astc")
PY

echo "== Import (ETC2/ASTC)"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

echo "== Export Android (release, gradle)"
mkdir -p "$(dirname "$OUT")"
"$GODOT" --headless --path . --export-release "Android" "$OUT" 2>&1 | tail -60
test -s "$OUT" || { echo "export produced no APK"; exit 1; }

echo "== Qualify the APK"
FLAGS=()
if [[ "${GITHUB_REF:-}" == refs/tags/v* || "${GITHUB_REF:-}" == refs/heads/release/v* ]]; then
  FLAGS+=(--release --require-logo --sha "${SOURCE_SHA:-}")
fi
[[ -n "${ANDROID_CERT_SHA256:-}" ]] && FLAGS+=(--expect-cert "$ANDROID_CERT_SHA256")
python3 tools/verify_apk.py "$OUT" --version "$VERSION" "${FLAGS[@]}"
