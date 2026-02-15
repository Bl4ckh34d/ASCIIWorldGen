extends RefCounted
class_name PoliticsStateModel

# Politics state: states/provinces, treaties, wars, and border changes.
# Scaffolding only; simulation rules come in later milestones.

const CURRENT_VERSION: int = 1

var version: int = CURRENT_VERSION

# Province grid (coarse political units) measured in world-map tiles.
# Keep this coarse so politics is state/province-level, not per-meter/per-tile.
var province_size_world_tiles: int = 8

# Derived grid dims (optional cache; can be recomputed from world size).
var province_grid_w: int = 0
var province_grid_h: int = 0

# state_id -> Dictionary (name, capital, gov, tech/epoch affinity, etc.)
var states: Dictionary = {}

# province_id -> Dictionary (owner_state_id, population, unrest, economy refs, adjacency, etc.)
var provinces: Dictionary = {}

# Array[Dictionary] treaties/alliances
var treaties: Array = []

# Array[Dictionary] active wars/conflicts
var wars: Array = []

# Coarse political events (worldgen/debug feed).
var event_log: Array = []
var last_event_abs_day: int = -1

var last_tick_abs_day: int = -1

func reset_defaults() -> void:
	version = CURRENT_VERSION
	province_size_world_tiles = 8
	province_grid_w = 0
	province_grid_h = 0
	states.clear()
	provinces.clear()
	treaties.clear()
	wars.clear()
	event_log.clear()
	last_event_abs_day = -1
	last_tick_abs_day = -1

func province_coords_for_world_tile(world_x: int, world_y: int) -> Vector2i:
	var s: int = max(1, int(province_size_world_tiles))
	return Vector2i(int(floor(float(int(world_x)) / float(s))), int(floor(float(int(world_y)) / float(s))))

func province_id_at(world_x: int, world_y: int) -> String:
	var p: Vector2i = province_coords_for_world_tile(world_x, world_y)
	return "province|%d|%d" % [int(p.x), int(p.y)]

func state_id_for_province_coords(px: int, py: int) -> String:
	# v0 deterministic grouping: each state owns a block of provinces.
	const STATE_BLOCK_SIZE_PROVINCES: int = 4
	var sx: int = int(floor(float(int(px)) / float(STATE_BLOCK_SIZE_PROVINCES)))
	var sy: int = int(floor(float(int(py)) / float(STATE_BLOCK_SIZE_PROVINCES)))
	return "state|%d|%d" % [sx, sy]

func ensure_state(state_id: String, patch: Dictionary = {}) -> Dictionary:
	state_id = String(state_id)
	if state_id.is_empty():
		return {}
	var v: Variant = states.get(state_id, {})
	var st: Dictionary = {}
	if typeof(v) == TYPE_DICTIONARY:
		st = (v as Dictionary).duplicate(true)
	st["id"] = state_id
	for k in patch.keys():
		st[k] = patch[k]
	states[state_id] = st
	return st.duplicate(true)

func ensure_province(province_id: String, patch: Dictionary = {}) -> Dictionary:
	province_id = String(province_id)
	if province_id.is_empty():
		return {}
	var v: Variant = provinces.get(province_id, {})
	var pv: Dictionary = {}
	if typeof(v) == TYPE_DICTIONARY:
		pv = (v as Dictionary).duplicate(true)
	pv["id"] = province_id
	for k in patch.keys():
		pv[k] = patch[k]
	provinces[province_id] = pv
	return pv.duplicate(true)

func to_dict() -> Dictionary:
	return {
		"version": version,
		"province_size_world_tiles": province_size_world_tiles,
		"province_grid_w": province_grid_w,
		"province_grid_h": province_grid_h,
		"states": states.duplicate(true),
		"provinces": provinces.duplicate(true),
		"treaties": treaties.duplicate(true),
		"wars": wars.duplicate(true),
		"event_log": event_log.duplicate(true),
		"last_event_abs_day": last_event_abs_day,
		"last_tick_abs_day": last_tick_abs_day,
	}

static func from_dict(data: Dictionary) -> PoliticsStateModel:
	var out := PoliticsStateModel.new()
	out.version = max(1, int(data.get("version", CURRENT_VERSION)))
	out.province_size_world_tiles = max(1, int(data.get("province_size_world_tiles", 8)))
	out.province_grid_w = max(0, int(data.get("province_grid_w", 0)))
	out.province_grid_h = max(0, int(data.get("province_grid_h", 0)))
	out.states = data.get("states", {}).duplicate(true)
	out.provinces = data.get("provinces", {}).duplicate(true)
	out.treaties = data.get("treaties", []).duplicate(true)
	out.wars = data.get("wars", []).duplicate(true)
	out.event_log = data.get("event_log", []).duplicate(true)
	out.last_event_abs_day = int(data.get("last_event_abs_day", -1))
	out.last_tick_abs_day = int(data.get("last_tick_abs_day", -1))
	return out
