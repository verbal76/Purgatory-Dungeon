# ==============================================================================
# File Name: ota_protected.gd
# Path: res://scripts/boot/ota_protected.gd
#
# Description:
#   NATIVE LAYER. The paths an OTA payload may never contain (docs/OTA.md sections 3 and 4).
#   This is a constant MIRROR of "payload_protected" in ota/boundary.json (the single
#   machine-readable definition); a test keeps the two identical. The client re-checks every
#   manifest's files[] against it before it will download or mount anything.
#
#   Matching is case-sensitive on a root-relative path with '/' separators (no res://, no
#   leading ./; one leading "godot/" pack prefix is also removed): EXACT = whole path,
#   PREFIXES = begins with, SUFFIXES = ends with. A pack entry is checked by its raw name and
#   by its source name (x.gd.remap and x.gdc both stand for x.gd).
# ==============================================================================
extends RefCounted

const EXACT: Array[String] = [
	".godot/extension_list.cfg",
	"VERSION",
	"build_info.json",
	"export_presets.cfg",
	"godot/extension_list.cfg",
	"project.binary",
	"project.godot",
]
const PREFIXES: Array[String] = [
	"android/",
	"ota/",
	"scripts/boot/",
]
const SUFFIXES: Array[String] = [
	".dll",
	".dylib",
	".gdextension",
	".so",
]
const PACK_PREFIX := "godot/"


## Root-relative form used for matching: no res://, no leading "./" or "/", backslashes as '/'.
static func normalize(path: String) -> String:
	var p: String = path.replace("\\", "/")
	if p.begins_with("res://"):
		p = p.substr(6)
	while p.begins_with("./"):
		p = p.substr(2)
	while p.begins_with("/"):
		p = p.substr(1)
	return p


## The source name a pack entry stands for ("a.gdc" and "a.gd.remap" -> "a.gd", "b.tscn.remap" -> "b.tscn").
static func source_name(path: String) -> String:
	if path.ends_with(".gd.remap"):
		return path.trim_suffix(".remap")
	if path.ends_with(".gdc") or path.ends_with(".gde"):
		return path.get_basename() + ".gd"
	if path.ends_with(".remap"):
		return path.trim_suffix(".remap")
	return path


static func _hit(p: String) -> bool:
	if p in EXACT:
		return true
	for pre in PREFIXES:
		if p.begins_with(pre):
			return true
	for suf in SUFFIXES:
		if p.ends_with(suf):
			return true
	return false


## True when `path` (as written in a manifest files[] entry or a pack listing) is payload-protected.
static func is_protected(path: String) -> bool:
	var p: String = normalize(path)
	var candidates: Array[String] = [p, source_name(p)]
	if p.begins_with(PACK_PREFIX):
		var q: String = p.substr(PACK_PREFIX.length())
		candidates.append(q)
		candidates.append(source_name(q))
	for c in candidates:
		if _hit(c):
			return true
	return false


## True for a path that could escape the pack or is not a plain relative file path.
static func is_unsafe(path: String) -> bool:
	if path.is_empty() or path.length() > 512:
		return true
	var p: String = path.replace("\\", "/")
	if p.begins_with("/") or p.contains(":"):
		return true
	for i in p.length():
		if p.unicode_at(i) < 32:
			return true
	for part in p.split("/"):
		if part == ".." or part == "":
			return true
	return false
