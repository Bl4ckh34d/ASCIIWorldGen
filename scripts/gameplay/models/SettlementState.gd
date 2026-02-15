extends RefCounted
class_name SettlementStateModel

# Persistent settlement registry derived from civilization population fields.
# Settlements are outcomes, not inputs: extracted at coarse cadence (worldgen mode).

const CURRENT_VERSION: int = 1

var version: int = CURRENT_VERSION

# settlement_id -> Dictionary
# Settlement dict (v0):
# - id
# - world_x/world_y
# - level: "camp"|"village"|"city"
# - pop_est: float (from civ pop field)
# - founded_abs_day
# - home_state_id (from politics province ownership)
var settlements: Dictionary = {}

var last_extract_abs_day: int = -1
var extract_interval_days: int = 60

func reset_defaults() -> void:
	version = CURRENT_VERSION
	settlements.clear()
	last_extract_abs_day = -1
	extract_interval_days = 60

static func settlement_id_at(world_x: int, world_y: int) -> String:
	return "settlement|%d|%d" % [int(world_x), int(world_y)]

func upsert_settlement(settlement_id: String, patch: Dictionary) -> Dictionary:
	settlement_id = String(settlement_id)
	if settlement_id.is_empty():
		return {}
	var v: Variant = settlements.get(settlement_id, {})
	var st: Dictionary = {}
	if typeof(v) == TYPE_DICTIONARY:
		st = (v as Dictionary).duplicate(true)
	st["id"] = settlement_id
	for k in patch.keys():
		st[k] = patch[k]
	settlements[settlement_id] = st
	return st.duplicate(true)

func to_dict() -> Dictionary:
	return {
		"version": version,
		"settlements": settlements.duplicate(true),
		"last_extract_abs_day": last_extract_abs_day,
		"extract_interval_days": extract_interval_days,
	}

static func from_dict(data: Dictionary) -> SettlementStateModel:
	var out := SettlementStateModel.new()
	out.version = max(1, int(data.get("version", CURRENT_VERSION)))
	out.settlements = data.get("settlements", {}).duplicate(true)
	out.last_extract_abs_day = int(data.get("last_extract_abs_day", -1))
	out.extract_interval_days = max(1, int(data.get("extract_interval_days", 60)))
	return out
