extends RefCounted
class_name EconomyStateModel

# Economy state is persisted and ticked in the background (global, downscaled).
# Detailed simulation comes later; this is scaffolding for data + determinism + save/load.

const CURRENT_VERSION: int = 1

var version: int = CURRENT_VERSION

# settlement_id -> Dictionary
# Settlement dict (v0 shape, may evolve):
# - id, name
# - world_x/world_y (macro location)
# - population
# - production/consumption/stockpile/prices (commodity_key -> float)
# - scarcity (commodity_key -> float)
var settlements: Dictionary = {}

# route list (future): Array[Dictionary] edges between settlements
var routes: Array = []

# Absolute day index of last processed tick (prevents re-sim on load).
var last_tick_abs_day: int = -1

func reset_defaults() -> void:
	version = CURRENT_VERSION
	settlements.clear()
	routes.clear()
	last_tick_abs_day = -1

static func settlement_id_for_tile(world_x: int, world_y: int) -> String:
	return "settlement|%d|%d" % [int(world_x), int(world_y)]

func ensure_settlement(settlement_id: String, patch: Dictionary = {}) -> Dictionary:
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
		"routes": routes.duplicate(true),
		"last_tick_abs_day": last_tick_abs_day,
	}

static func from_dict(data: Dictionary) -> EconomyStateModel:
	var out := EconomyStateModel.new()
	out.version = max(1, int(data.get("version", CURRENT_VERSION)))
	out.settlements = data.get("settlements", {}).duplicate(true)
	out.routes = data.get("routes", []).duplicate(true)
	out.last_tick_abs_day = int(data.get("last_tick_abs_day", -1))
	return out
