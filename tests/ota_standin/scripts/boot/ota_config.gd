extends RefCounted
## STAND-IN for scripts/boot/ota_config.gd (see tests/ota_standin/project.godot). Same constants and runtime_id()
## contract as the real native layer (docs/OTA.md section 3).

const RUNTIME_REVISION := 1
const CHANNEL := "dev"
const REPO := "standin/updates"
const BOOTSTRAP_VERSION := 1
const PUBLIC_KEY_PEM := ""


static func runtime_id(platform: String) -> String:
	var v: Dictionary = Engine.get_version_info()
	return "%s-godot-%d.%d.%d-r%d" % [platform, v["major"], v["minor"], v["patch"], RUNTIME_REVISION]


static func channel_tag(ch: String) -> String:
	return "ota-channel-" + ch


static func release_url(tag: String, asset: String) -> String:
	return "https://github.com/%s/releases/download/%s/%s" % [REPO, tag, asset]


static func pointer_url(ch: String) -> String:
	return release_url(channel_tag(ch), "latest.json")
