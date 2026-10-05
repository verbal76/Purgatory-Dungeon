# ==============================================================================
# File Name: ota_runtime.gd
# Path: res://scripts/ota/ota_runtime.gd
#
# Description:
#   What the OTA client did THIS launch, as plain static fields, so diagnostics (BuildInfo, the main menu
#   footer, the startup log) can read it without depending on autoload order or node lookups.
# ==============================================================================
class_name OtaRuntime
extends RefCounted

static var enabled: bool = false
static var disabled_reason: String = ""      # why OTA is off (dev build, --no-ota, no trust anchor ...)
static var active_seq: int = 0               # update mounted this launch; 0 = the native build
static var active_source_commit: String = ""
static var active_payload_id: String = ""    # sha256 of the signed manifest, short form in the UI
static var confirmed: bool = false           # the mounted update has been confirmed healthy this launch
static var boot_attempts: int = 0
static var rolled_back_seq: int = 0          # an update that was rejected / crash-looped at this launch
static var rolled_back_reason: String = ""
static var pending_seq: int = 0              # staged update waiting for a restart
static var known_good_seq: int = 0
static var channel_configured: bool = false
static var last_check_utc: int = 0
static var last_error: String = ""


static func reset() -> void:
	enabled = false
	disabled_reason = ""
	active_seq = 0
	active_source_commit = ""
	active_payload_id = ""
	confirmed = false
	boot_attempts = 0
	rolled_back_seq = 0
	rolled_back_reason = ""
	pending_seq = 0
	known_good_seq = 0
	channel_configured = false
	last_check_utc = 0
	last_error = ""
