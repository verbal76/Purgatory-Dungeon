#!/usr/bin/env bash
# Provides the OTA signing key for CI (mirrors tools/android/signing.sh) and writes the PUBLIC half to a file.
# The matching public key is the device-side trust anchor: PUBLIC_KEY_PEM in scripts/boot/ota_config.gd (compiled into the APK;
# tools/ota/publish_gates.py key-match refuses to sign when the two differ). Nothing is written into the build.
#
# Order of preference:
#   1. GitHub Actions secret OTA_SIGNING_KEY_PEM_BASE64 (base64 of an RSA-3072+ private key PEM): the
#      owner-controlled option; use it as soon as the owner adds the secret.
#   2. OTA_KEY_DIR (a directory holding ota-signing.key): local override used by the tests and for offline
#      use. When it is set, GitHub is never contacted. If the key is missing it is generated there once.
#   3. The private DRAFT release "OTA signing key (do not delete)" in this repository (asset ota-signing.key;
#      a draft is visible only to people with write access and is never published or marked Latest).
#   4. First run only (full mode, not --no-create): generate `openssl genrsa 3072` and store it as (3).
# The private key is NEVER printed, committed, put in release notes, workflow summaries or uploaded as an
# artifact. Only the SHA-256 fingerprint of the public key (public information) is shown.
#
# usage (SOURCE it so the exports reach the next steps; running it also works, minus the exports):
#   source tools/ota/keys.sh <public-out.pem>                full: ensure the key exists, export
#                                                            OTA_PRIVATE_KEY_PATH and OTA_TRUST_FINGERPRINT
#   source tools/ota/keys.sh --public-only <public-out.pem>  fetch/derive the public key only (build jobs); never
#                                                            creates a key, never exports a private path, and
#                                                            removes any private copy it had to download
#   --no-create   (full mode) fail instead of generating when no key exists yet
#   env OTA_KEYS_NO_CREATE=1 is the same as --no-create (used by jobs that must never write to the repository)
#
# Idempotent: a second call reuses the stored key. RACES: two jobs that find no key at the same moment could
# each generate one. Creation is therefore serialised by a DEDICATED FIRST JOB with
# `concurrency: {group: ota-signing-key, cancel-in-progress: false}` that every other job `needs:`; all other
# jobs use --public-only or --no-create and so can never create. As a second line of defence, if several
# drafts with the title exist, every consumer uses the one with the LOWEST release id, and a creator that finds
# it is not the lowest deletes its own copy and uses the winner's key (see _ota_gh_ensure below).
# The local OTA_KEY_DIR store is race-safe by itself (atomic hard-link publication of the generated file).
set -euo pipefail

_ota_bits() {   # RSA private key size in bits, or empty if the file is not an RSA private key
  openssl rsa -in "$1" -noout -text 2>/dev/null | sed -n 's/^Private-Key: (\([0-9]*\) bit.*/\1/p' | head -1
}

_ota_check_key() {   # $1 = key file, $2 = where it came from (no key material is ever echoed)
  local bits; bits="$(_ota_bits "$1")"
  if [[ -z "$bits" ]]; then echo "ota keys: the key from $2 is not an RSA private key PEM" >&2; return 1; fi
  if (( bits < 3072 )); then echo "ota keys: the key from $2 is RSA-$bits; OTA requires RSA-3072 or larger" >&2; return 1; fi
}

_ota_gen() {   # $1 = destination file (mode 600)
  ( umask 077; openssl genrsa -out "$1" 3072 >/dev/null 2>&1 )
  chmod 600 "$1"
}

# GitHub draft-release store ---------------------------------------------------------------------------
_OTA_TITLE="OTA signing key (do not delete)"

_ota_gh_release_id() {   # lowest id among drafts with the title (empty if none)
  gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
    --jq "[.[]|select(.draft and .name==\"$_OTA_TITLE\")|.id]|min // empty"
}

_ota_gh_download() {   # $1 = release id, $2 = destination; retries while the creator is still uploading
  local id="$1" dest="$2" aid="" i
  for i in 1 2 3 4 5 6; do
    aid="$(gh api "repos/$GITHUB_REPOSITORY/releases/$id" --jq '[.assets[]|select(.label=="ota-signing.key" or .name=="ota-signing.key")][0].id // empty')"
    [[ -n "$aid" ]] && break
    sleep 5
  done
  [[ -n "$aid" ]] || { echo "ota keys: the stored key release $id has no ota-signing.key asset" >&2; return 1; }
  ( umask 077; gh api -H "Accept: application/octet-stream" "repos/$GITHUB_REPOSITORY/releases/assets/$aid" > "$dest" )
  chmod 600 "$dest"
}

_ota_gh_ensure() {   # $1 = destination key file, $2 = may_create (1/0); prints the source on stdout's last line
  local dest="$1" may_create="$2" id mine nonce winner
  id="$(_ota_gh_release_id)"
  if [[ -n "$id" ]]; then
    _ota_gh_download "$id" "$dest" || return 1
    echo "release"; return 0
  fi
  if [[ "$may_create" != "1" ]]; then
    echo "ota keys: no OTA signing key exists yet. It is created once by the dedicated first job (concurrency group ota-signing-key) or by adding the OTA_SIGNING_KEY_PEM_BASE64 secret; this job is not allowed to create it." >&2
    return 1
  fi
  _ota_gen "$dest"
  nonce="$(openssl rand -hex 16)"
  gh release create "ota-signing-key" --draft --latest=false --repo "$GITHUB_REPOSITORY" --title "$_OTA_TITLE" \
    --notes "Private, never published. Holds the OTA update signing key for Purgatory Dungeon; the matching public key is compiled into every APK (scripts/boot/ota_config.gd). Deleting this draft makes every already-installed build ignore all future updates until a new APK ships. Move the key into the Actions secret OTA_SIGNING_KEY_PEM_BASE64 at any time; the secret takes precedence. (creation nonce $nonce)" \
    "$dest#ota-signing.key" >/dev/null
  # Race check: lowest release id wins; a loser removes its own draft and adopts the winner's key.
  mine="$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq "[.[]|select(.draft and .name==\"$_OTA_TITLE\" and ((.body // \"\")|contains(\"$nonce\")))|.id][0] // empty")"
  winner="$(_ota_gh_release_id)"
  if [[ -n "$mine" && -n "$winner" && "$mine" != "$winner" ]]; then
    echo "ota keys: another job created the key first; discarding mine and using theirs" >&2
    gh api -X DELETE "repos/$GITHUB_REPOSITORY/releases/$mine" >/dev/null
    _ota_gh_download "$winner" "$dest" || return 1
    echo "release"; return 0
  fi
  echo "generated"
}

_ota_keys() {
  local mode=full out="" no_create="${OTA_KEYS_NO_CREATE:-}" arg
  while [[ $# -gt 0 ]]; do
    arg="$1"; shift
    case "$arg" in
      --public-only) mode=public ;;
      --no-create) no_create=1 ;;
      -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; return 0 ;;
      -*) echo "ota keys: unknown option $arg" >&2; return 2 ;;
      *) out="$arg" ;;
    esac
  done
  if [[ -z "$out" ]]; then echo "usage: source tools/ota/keys.sh [--public-only] [--no-create] <public-out.pem>" >&2; return 2; fi
  { set +x; } 2>/dev/null   # never let xtrace echo the secret

  local work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ota-signing"
  ( umask 077; mkdir -p "$work" )
  local key="$work/ota-signing.key" src="" may_create=1 private_is_copy=1
  [[ "$mode" == "public" || -n "$no_create" ]] && may_create=0

  if [[ -n "${OTA_SIGNING_KEY_PEM_BASE64:-}" ]]; then
    ( umask 077; printf '%s' "$OTA_SIGNING_KEY_PEM_BASE64" | base64 -d > "$key" 2>/dev/null ) || true
    chmod 600 "$key"
    _ota_check_key "$key" "the OTA_SIGNING_KEY_PEM_BASE64 secret" || { rm -f "$key"; return 1; }
    src="secret"
  elif [[ -n "${OTA_KEY_DIR:-}" ]]; then
    private_is_copy=0
    ( umask 077; mkdir -p "$OTA_KEY_DIR" )
    key="$OTA_KEY_DIR/ota-signing.key"
    if [[ ! -s "$key" ]]; then
      if [[ "$may_create" != "1" ]]; then echo "ota keys: no key in OTA_KEY_DIR ($OTA_KEY_DIR) and creation is not allowed here" >&2; return 1; fi
      local tmp; tmp="$(mktemp "$OTA_KEY_DIR/.gen.XXXXXX")"
      _ota_gen "$tmp"
      # atomic publication: hard-linking fails if another process won the race; then its key is used
      if ln "$tmp" "$key" 2>/dev/null; then src="generated"; else src="dir"; fi
      rm -f "$tmp"
    else
      src="dir"
    fi
    _ota_check_key "$key" "OTA_KEY_DIR" || return 1
  elif [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    src="$(_ota_gh_ensure "$key" "$may_create" | tail -1)"
    [[ -s "$key" ]] || return 1
    _ota_check_key "$key" "the stored key release" || return 1
  else
    echo "ota keys: no key source. Set OTA_SIGNING_KEY_PEM_BASE64, or OTA_KEY_DIR, or run in GitHub Actions (GITHUB_REPOSITORY)." >&2
    return 1
  fi

  openssl pkey -in "$key" -pubout -out "$out" || { echo "ota keys: could not derive the public key" >&2; return 1; }
  chmod 644 "$out"
  local fp; fp="$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | cut -d' ' -f1)"
  echo "ota keys: source=$src, trust key (public) written to $out, SHA-256 $fp"

  if [[ "$mode" == "public" ]]; then
    [[ "$private_is_copy" == "1" ]] && { shred -u "$key" 2>/dev/null || rm -f "$key"; }
    export OTA_TRUST_FINGERPRINT="$fp"
    [[ -n "${GITHUB_ENV:-}" ]] && echo "OTA_TRUST_FINGERPRINT=$fp" >> "$GITHUB_ENV"
    return 0
  fi
  export OTA_PRIVATE_KEY_PATH="$key"
  export OTA_TRUST_FINGERPRINT="$fp"
  export OTA_KEY_SOURCE="$src"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    { echo "OTA_PRIVATE_KEY_PATH=$key"; echo "OTA_TRUST_FINGERPRINT=$fp"; echo "OTA_KEY_SOURCE=$src"; } >> "$GITHUB_ENV"
  fi
  echo "ota keys: private key available at $OTA_PRIVATE_KEY_PATH (path only; contents are never printed)"
}

_ota_keys "$@"
