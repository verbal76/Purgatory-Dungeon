#!/usr/bin/env bash
# Provides the Android release signing key for CI and exports the Godot environment variables.
#
# Order of preference:
#   1. GitHub Actions secrets (ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS):
#      the owner-controlled option; use it as soon as the owner adds the secrets.
#   2. A stored key: the private DRAFT release "Android signing key (do not delete)" in this repository
#      (assets android-release.p12 + android-release.pw; a draft is visible only to people with write
#      access and is never published or marked Latest).
#   3. First run only: generate a new 4096-bit key, then store it as (2).
# The key is NEVER printed, committed, put in release notes or uploaded as a build artifact; the
# password is masked in logs. Only the certificate SHA-256 fingerprint (public information) is shown.
#
# usage (must be SOURCED so the exports reach the next steps):  source tools/android/signing.sh
set -euo pipefail

KS_DIR="${RUNNER_TEMP:-/tmp}/android-signing"
mkdir -p "$KS_DIR"
KS="$KS_DIR/release.p12"
ALIAS="purgatorydungeon"
STORE_TITLE="Android signing key (do not delete)"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"

if [[ -n "${ANDROID_KEYSTORE_BASE64:-}" ]]; then
  echo "signing: using the keystore from Actions secrets"
  echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$KS"
  PW="${ANDROID_KEYSTORE_PASSWORD:?ANDROID_KEYSTORE_PASSWORD secret missing}"
  ALIAS="${ANDROID_KEY_ALIAS:-$ALIAS}"
else
  REL_ID="$(gh api "repos/$REPO/releases?per_page=100" --jq "[.[]|select(.draft and .name==\"$STORE_TITLE\")][0].id // empty")"
  if [[ -n "$REL_ID" ]]; then
    echo "signing: using the stored key (draft release $REL_ID)"
    for pair in "android-release.p12:$KS" "android-release.pw:$KS_DIR/release.pw"; do
      name="${pair%%:*}"; dest="${pair#*:}"
      aid="$(gh api "repos/$REPO/releases/$REL_ID" --jq "[.assets[]|select(.label==\"$name\" or .name==\"$name\" or .name==\"${name#android-}\")][0].id // empty")"
      [[ -n "$aid" ]] || { echo "stored key is incomplete: asset $name missing"; exit 1; }
      gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$aid" > "$dest"
    done
    PW="$(cat "$KS_DIR/release.pw")"
  else
    echo "signing: no stored key yet - generating the Android signing identity for this app line"
    PW="$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-40)"
    echo "::add-mask::$PW"
    keytool -genkeypair -keystore "$KS" -storetype PKCS12 -storepass "$PW" -keypass "$PW" \
      -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 36500 \
      -dname "CN=Hot Attic Games, O=Hot Attic Games, C=US" >/dev/null 2>&1
    printf '%s' "$PW" > "$KS_DIR/release.pw"
    gh release create "android-signing-key" --draft --repo "$REPO" --title "$STORE_TITLE" \
      --notes "Private, never published. Holds the Android app signing key for Purgatory Dungeon so every build can update the previous one. Deleting this draft makes future APKs impossible to install over the old ones. Move the key into Actions secrets (ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS) at any time; secrets take precedence." \
      "$KS#android-release.p12" "$KS_DIR/release.pw#android-release.pw" >/dev/null
    echo "signing: new key stored in a private draft release"
  fi
fi
echo "::add-mask::$PW"
FP="$(keytool -list -v -keystore "$KS" -storepass "$PW" -alias "$ALIAS" 2>/dev/null | sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | head -1 | tr -d ':' | tr 'A-F' 'a-f')"
[[ -n "$FP" ]] || { echo "could not read the signing certificate"; exit 1; }
echo "signing certificate SHA-256: $FP"
export ANDROID_CERT_SHA256="$FP"
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KS"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$ALIAS"
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$PW"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "ANDROID_CERT_SHA256=$FP"
    echo "GODOT_ANDROID_KEYSTORE_RELEASE_PATH=$KS"
    echo "GODOT_ANDROID_KEYSTORE_RELEASE_USER=$ALIAS"
    echo "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=$PW"
  } >> "$GITHUB_ENV"
fi
