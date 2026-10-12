#!/usr/bin/env bash
# Fast LOCAL checks before pushing (no Godot, no network, about 15 s). GitHub runs nothing for a draft PR (docs/COMPLIANCE_AUDIT.md), so this is the
# cheap gate that stands in for it; the full suite is `tests/run_tests.sh <godot>`.  Usage: tools/preflight.sh [base-ref]   (default: origin/<branch> or HEAD~1)
set -u
cd "$(dirname "$0")/.."
BASE="${1:-$(git rev-parse --verify -q '@{upstream}' || git rev-parse HEAD~1)}"
rc=0
step() { echo "=== $1"; shift; "$@" || { echo "!!! FAILED: $*"; rc=1; }; }
step "version consistency"            python3 tools/release_tool.py check
step "native runtime fingerprint"     python3 tools/ota_runtime.py --check
step "OTA classification vs $BASE"    python3 tools/ota/classify.py "$BASE" HEAD
step "base is on the release line"    python3 tools/source_audit.py base-check
step "res:// paths"                   python3 tests/check_res_paths.py
step "build tool"                     python3 tests/test_build_tool.py
step "workflow safety"                python3 tests/test_ota_workflows.py
step "source of truth"                python3 tests/test_source_of_truth.py
step "licence inventory"              python3 tests/test_licenses.py
step "offline guard"                  python3 tests/test_offline.py
step "git: no unstaged or untracked source left behind" bash -c 'test -z "$(git status --porcelain)"'
[ "$rc" -eq 0 ] && echo "preflight OK ($(git rev-parse --short HEAD))" || echo "preflight FAILED"
exit $rc
