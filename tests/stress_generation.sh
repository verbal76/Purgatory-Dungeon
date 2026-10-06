#!/usr/bin/env bash
# Generator stress run: many seeds, one process each (several generate/free cycles in one headless
# process can abort the engine), checked and summarised. Usage:
#   tests/stress_generation.sh <godot> <first_seed> <last_seed> [attempts] [full(0|1)] [jobs]
# attempts = max_layout_attempts (1 shows the raw single-layout failure rate; omit for the game's).
# STRESS_W1=<n> in the environment sets the dead-end room weight (adverse generation tests).
# Every non-OK seed is listed so it can be reproduced:
#   STRESS_SEED=<seed> godot --headless --path . res://tests/stress_generation.tscn
GODOT="${1:?godot binary}"; FIRST="${2:?first seed}"; LAST="${3:?last seed}"
ATTEMPTS="${4:-}"; FULL="${5:-0}"; JOBS="${6:-3}"
cd "$(dirname "$0")/.."
OUT="$(mktemp)"
export GODOT ATTEMPTS FULL STRESS_W1
seq "$FIRST" "$LAST" | xargs -P "$JOBS" -I{} sh -c '
	d=$(mktemp -d)
	PURGATORY_SAVE_ROOT="$d/PurgetoryDungeon" STRESS_SEED={} STRESS_ATTEMPTS="$ATTEMPTS" STRESS_FULL="$FULL" STRESS_W1="$STRESS_W1" \
		timeout 180 "$GODOT" --headless --path . res://tests/stress_generation.tscn 2>&1 | grep "^STRESS" || echo "STRESS seed={} ok=False attempts=0 rooms=0 spawns=0 dead_end_rooms=0 chests=0 portal_ok=-1 history=- problems=crash_or_timeout"
	rm -rf "$d"' > "$OUT"
python3 - "$OUT" <<'PY'
import re, sys, collections
rows = [l.strip() for l in open(sys.argv[1]) if l.startswith("STRESS")]
def field(l, k):
    m = re.search(k + r"=(\S+)", l); return m.group(1) if m else ""
n = len(rows)
bad = [l for l in rows if field(l, "ok").lower() != "true"]
attempts = collections.Counter(int(field(l, "attempts") or 0) for l in rows)
rooms = [int(field(l, "rooms") or 0) for l in rows]
firstfail = [l for l in rows if int(field(l, "attempts") or 0) > 1]
print(f"seeds run: {n}   OK: {n - len(bad)}   not OK: {len(bad)}")
print("layout attempts needed (attempts: seeds):", dict(sorted(attempts.items())))
print(f"seeds that needed regeneration: {len(firstfail)}")
if rooms: print(f"rooms min/avg/max: {min(rooms)}/{sum(rooms)/len(rooms):.1f}/{max(rooms)}")
for k in ("spawns", "dead_end_rooms", "chests"):
    v = [int(field(l, k) or 0) for l in rows]
    if v: print(f"{k} min/avg/max: {min(v)}/{sum(v)/len(v):.1f}/{max(v)}")
for l in firstfail[:20]: print("  REGEN:", field(l, "seed"), field(l, "history"))
for l in bad: print("  FAILED seed", field(l, "seed"), "->", field(l, "problems"), "history", field(l, "history"))
sys.exit(1 if bad else 0)
PY
