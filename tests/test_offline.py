#!/usr/bin/env python3
"""Offline single-player (master standard 12.9): the only networking code in the game is the Android OTA updater, which is gated off elsewhere, never awaited by the
menu or a run, and is not part of any desktop path. A static guard so a future change cannot quietly make the game need a connection."""
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
NET = re.compile(r"\b(HTTPRequest|HTTPClient|StreamPeerTLS|StreamPeerTCP|TCPServer|WebSocketPeer|PacketPeerUDP|UDPServer|ENetMultiplayerPeer|WebRTCPeerConnection)\b")
ALLOWED = {"scripts/boot/ota_updater.gd"}
fails = 0
for base in ("scripts", "characters", "scenes", "autoloads", "dungeon modules", "addons"):
    for dp, _dn, fn in os.walk(os.path.join(ROOT, base)):
        for f in fn:
            if not f.endswith((".gd", ".tscn", ".tres")):
                continue
            rel = os.path.relpath(os.path.join(dp, f), ROOT)
            if rel in ALLOWED:
                continue
            if NET.search(open(os.path.join(dp, f), encoding="utf-8", errors="replace").read()):
                fails += 1
                print(f"FAIL: {rel} uses a network class; single-player must work offline (only the OTA updater may)")

boot = open(os.path.join(ROOT, "scripts", "boot", "boot.gd"), encoding="utf-8").read()
# The updater starts only when OTA is enabled (the Android OTA feature, or an explicit developer hook outside release templates).
if not re.search(r"hooks_allowed\s*=\s*not OS\.has_feature\(\"template\"\)", boot):
    fails += 1
    print("FAIL: boot.gd no longer disables developer OTA hooks in export templates")
gate = open(os.path.join(ROOT, "scripts", "update_gate.gd"), encoding="utf-8").read()
if "ota_enabled" not in gate:
    fails += 1
    print("FAIL: update_gate.gd no longer checks ota_enabled before it checks for an update")
print(f"test_offline: {fails} failures")
sys.exit(1 if fails else 0)
