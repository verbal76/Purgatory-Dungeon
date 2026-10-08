# ==============================================================================
# File Name: save_schema.gd
# Path: res://scripts/save_schema.gd
#
# Description:
#   GAME LAYER (docs/OTA.md section 9). The version of the persisted save/profile data this game
#   writes and the oldest version it can still read. The native OTA client records SAVE_SCHEMA on the
#   device when a package becomes healthy, and refuses to activate an OTA whose manifest
#   [min_save_schema, save_schema] range does not contain the schema recorded on the device (this
#   protects rollbacks past a deliberate migration).
#
#   Bump SAVE_SCHEMA only together with a real, tested save migration, and only in a change that
#   also decides what MIN_SAVE_SCHEMA must be. Save formats are unchanged in v7.
# ==============================================================================
extends RefCounted

## Schema of the data this build writes.
const SAVE_SCHEMA := 1
## Oldest schema this build can still read.
const MIN_SAVE_SCHEMA := 1
