# ==============================================================================
# File Name: ota_core.gd
# Path: res://scripts/ota/ota_core.gd
#
# Description:
#   The OTA client's decision logic as static functions over injected inputs (so tests can drive every path
#   with a fake mounter): which stored update to mount at launch, what to do when one fails, when one counts
#   as healthy, and which channel entry to download. ota_boot.gd / ota_updater.gd are thin autoload shells
#   around this. See docs/OTA.md "Failure and rollback behaviour".
# ==============================================================================
class_name OtaCore
extends RefCounted


## Static so tests can call it directly. Mounts at most one update. Returns
## {active_seq, active_source_commit, active_payload_id, boot_attempts, rolled_back_seq,
##  rolled_back_reason, known_good, pending}.
static func boot(root_dir: String, identity: Dictionary, public_pem: String, mounter: Callable, save_root: String) -> Dictionary:
	var out: Dictionary = {"active_seq": 0, "active_source_commit": "", "active_payload_id": "", "boot_attempts": 0,
			"rolled_back_seq": 0, "rolled_back_reason": "", "known_good": 0, "pending": 0}
	DirAccess.make_dir_recursive_absolute(root_dir)
	OtaStore.clean_staging(root_dir)
	var st: Dictionary = OtaStore.load_state(root_dir)

	var order: Array = []
	for s in [int(st["pending"]), int(st["active"]), int(st["known_good"])]:
		if s > 0 and not order.has(s):
			order.append(s)

	for seq in order:
		var failed: Array = st["failed"]
		var revoked: Array = st["revoked"]
		if revoked.has(seq):
			_drop(root_dir, st, seq, "revoked by the channel", out, false)
			continue
		if failed.has(seq):
			_drop(root_dir, st, seq, "previously failed", out, false)
			continue
		var why: String = OtaVerify.verify_slot(root_dir, seq, identity, public_pem)
		if why != "":
			# A slot built for an older native build is simply obsolete (new APK installed): delete, don't quarantine.
			var obsolete: bool = why.begins_with("built for")
			_drop(root_dir, st, seq, why, out, obsolete)
			continue
		var confirmed: bool = seq == int(st["known_good"])
		var attempts: int = int(st["boot_attempts"]) if seq == int(st["active"]) else 0
		if not confirmed and attempts >= OtaConst.MAX_BOOT_ATTEMPTS:
			_drop(root_dir, st, seq, "crash loop (%d launches without reaching a healthy menu)" % attempts, out, false)
			continue
		if seq == int(st["pending"]) and seq != int(st["active"]):
			OtaStore.backup_saves(root_dir, seq, save_root)
			attempts = 0
		# Persist the attempt BEFORE mounting: a crash while loading must still count.
		st["active"] = seq
		if int(st["pending"]) == seq:
			st["pending"] = 0
		st["boot_attempts"] = 0 if confirmed else attempts + 1
		OtaStore.save_state(root_dir, st)
		var pck: String = OtaStore.slot_dir(root_dir, seq).path_join("payload.pck")
		if not bool(mounter.call(pck)):
			_drop(root_dir, st, seq, "mount failed", out, false)
			continue
		var m: Dictionary = OtaVerify.slot_manifest(root_dir, seq)
		out["active_seq"] = seq
		out["active_source_commit"] = str(m.get("source_commit", ""))
		out["active_payload_id"] = OtaVerify.manifest_id(OtaStore.read_bytes(OtaStore.slot_dir(root_dir, seq).path_join("manifest.json")))
		out["boot_attempts"] = int(st["boot_attempts"])
		break

	if int(out["active_seq"]) == 0:
		st["active"] = 0
		st["boot_attempts"] = 0
	out["known_good"] = int(st["known_good"])
	out["pending"] = int(st["pending"])
	OtaStore.prune_slots(root_dir, [int(st["known_good"]), int(st["active"]), int(st["pending"])])
	OtaStore.save_state(root_dir, st)
	return out


static func _drop(root_dir: String, st: Dictionary, seq: int, reason: String, out: Dictionary, delete_only: bool) -> void:
	var failed: Array = st["failed"]
	if not failed.has(seq):
		failed.append(seq)
	st["failed"] = failed
	if int(st["active"]) == seq:
		st["active"] = 0
		st["boot_attempts"] = 0
	if int(st["pending"]) == seq:
		st["pending"] = 0
	if int(st["known_good"]) == seq:
		st["known_good"] = 0
	if delete_only:
		OtaStore.remove_tree(OtaStore.slot_dir(root_dir, seq))
	else:
		OtaStore.quarantine(root_dir, seq, reason)
	OtaStore.note(st, "update %d dropped: %s" % [seq, reason])
	st["last_error"] = "update %d: %s" % [seq, reason]
	if int(out["rolled_back_seq"]) == 0:
		out["rolled_back_seq"] = seq
		out["rolled_back_reason"] = reason
	OtaStore.save_state(root_dir, st)
	push_warning("OTA: update %d not used (%s); continuing without it" % [seq, reason])


static func apply_result(r: Dictionary) -> void:
	OtaRuntime.active_seq = int(r["active_seq"])
	OtaRuntime.active_source_commit = str(r["active_source_commit"])
	OtaRuntime.active_payload_id = str(r["active_payload_id"])
	OtaRuntime.boot_attempts = int(r["boot_attempts"])
	OtaRuntime.rolled_back_seq = int(r["rolled_back_seq"])
	OtaRuntime.rolled_back_reason = str(r["rolled_back_reason"])
	OtaRuntime.known_good_seq = int(r["known_good"])
	OtaRuntime.pending_seq = int(r["pending"])
	OtaRuntime.confirmed = OtaRuntime.active_seq > 0 and OtaRuntime.active_seq == OtaRuntime.known_good_seq


## Marks the update that is running as healthy: it becomes the rollback target and older slots are removed.
static func confirm_health(root_dir: String) -> void:
	if OtaRuntime.active_seq <= 0 or OtaRuntime.confirmed:
		return
	var st: Dictionary = OtaStore.load_state(root_dir)
	if int(st["active"]) != OtaRuntime.active_seq:
		return
	st["known_good"] = OtaRuntime.active_seq
	st["boot_attempts"] = 0
	OtaStore.note(st, "update %d confirmed healthy" % OtaRuntime.active_seq)
	OtaStore.save_state(root_dir, st)
	OtaStore.prune_slots(root_dir, [int(st["known_good"]), int(st["pending"])])
	OtaRuntime.known_good_seq = OtaRuntime.active_seq
	OtaRuntime.confirmed = true


## Pure planning step (unit-tested): given a verified channel document, the identity and the state, which
## entry should be downloaded? Returns {} when there is nothing to do. Also returns the revoked list for this build.
static func plan(channel: Dictionary, identity: Dictionary, st: Dictionary) -> Dictionary:
	var result: Dictionary = {"entry": {}, "revoked": [], "generation": int(channel.get("generation", 0))}
	if int(channel.get("format", -1)) != OtaConst.FORMAT or str(channel.get("product", "")) != OtaConst.PRODUCT:
		result["error"] = "channel document has an unknown format"
		return result
	if int(channel.get("generation", 0)) < int(st["generation"]):
		result["error"] = "channel generation went backwards (replayed index ignored)"
		return result
	var revoked: Array = []
	var rv: Variant = channel.get("revoked", [])
	if rv is Array:
		for r in rv:
			if r is Dictionary and _same_build(r, identity):
				revoked.append(int(r.get("seq", 0)))
	result["revoked"] = revoked
	var have: int = maxi(int(st["active"]), maxi(int(st["pending"]), int(st["known_good"])))
	var best: Dictionary = {}
	var ups: Variant = channel.get("updates", [])
	if ups is Array:
		for u in ups:
			if not (u is Dictionary) or not _same_build(u, identity):
				continue
			var seq: int = int(u.get("seq", 0))
			if seq <= have or revoked.has(seq) or (st["revoked"] as Array).has(seq) or (st["failed"] as Array).has(seq):
				continue
			if best.is_empty() or seq > int(best.get("seq", 0)):
				best = u
	result["entry"] = best
	return result


static func _same_build(d: Dictionary, identity: Dictionary) -> bool:
	return int(d.get("native_version", -1)) == int(identity.get("native_version", -2)) \
			and str(d.get("platform", "")) == str(identity.get("platform", "?")) \
			and str(d.get("base_commit", "")) == str(identity.get("base_commit", ""))
