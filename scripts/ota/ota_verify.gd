# ==============================================================================
# File Name: ota_verify.gd
# Path: res://scripts/ota/ota_verify.gd
#
# Description:
#   Full verification of a stored update slot (slots/<seq>/{manifest.json, manifest.sig, payload.pck}).
#   Used at download time and again at EVERY boot, because files on a phone can be damaged between launches.
#   The result is "" (verified) or the reason it was rejected. Nothing is mounted by this class.
# ==============================================================================
class_name OtaVerify
extends RefCounted


static func manifest_id(manifest_bytes: PackedByteArray) -> String:
	return OtaCrypto.sha256_bytes(manifest_bytes)


## Verifies manifest signature, compatibility, update number and payload size + SHA-256.
static func verify_slot(root_dir: String, seq: int, identity: Dictionary, public_pem: String) -> String:
	var dir_path: String = OtaStore.slot_dir(root_dir, seq)
	var mbytes: PackedByteArray = OtaStore.read_bytes(dir_path.path_join("manifest.json"))
	var sig: String = FileAccess.get_file_as_string(dir_path.path_join("manifest.sig")) \
			if FileAccess.file_exists(dir_path.path_join("manifest.sig")) else ""
	if mbytes.is_empty():
		return "manifest missing"
	if not OtaCrypto.verify(mbytes, sig, public_pem):
		return "manifest signature invalid"
	var m: Dictionary = OtaManifest.parse(mbytes)
	var why: String = OtaManifest.check(m, identity)
	if why != "":
		return why
	if int(m.get("payload_seq", 0)) != seq:
		return "slot number does not match the manifest"
	var payload: Dictionary = m["payload"]
	var pck: String = dir_path.path_join("payload.pck")
	if not FileAccess.file_exists(pck):
		return "payload missing"
	var f := FileAccess.open(pck, FileAccess.READ)
	if f == null:
		return "payload unreadable"
	var size: int = f.get_length()
	f.close()
	if size != int(payload.get("size", -1)):
		return "payload size mismatch (%d vs %d)" % [size, int(payload.get("size", -1))]
	if OtaCrypto.sha256_file(pck) != str(payload.get("sha256", "")):
		return "payload hash mismatch"
	return ""


## Reads a verified slot's manifest (call only after verify_slot returned "").
static func slot_manifest(root_dir: String, seq: int) -> Dictionary:
	return OtaManifest.parse(OtaStore.read_bytes(OtaStore.slot_dir(root_dir, seq).path_join("manifest.json")))
