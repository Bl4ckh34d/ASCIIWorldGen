extends RefCounted
class_name WorldFlagsStateModel

var discovered_pois: Dictionary = {}
var cleared_pois: Dictionary = {}
var poi_instances: Dictionary = {} # poi_id -> Dictionary of persistent flags (boss_defeated, opened_chests, etc)
var visited_world_tiles: Dictionary = {} # "x,y" -> true
var battles_won: int = 0
var battles_fled: int = 0
var battles_lost: int = 0

func reset_defaults() -> void:
	discovered_pois.clear()
	cleared_pois.clear()
	poi_instances.clear()
	visited_world_tiles.clear()
	battles_won = 0
	battles_fled = 0
	battles_lost = 0

func register_poi_discovery(poi_data: Dictionary) -> void:
	var poi_id: String = String(poi_data.get("id", ""))
	if poi_id.is_empty():
		return
	if not discovered_pois.has(poi_id):
		discovered_pois[poi_id] = poi_data.duplicate(true)

func mark_poi_cleared(poi_id: String) -> void:
	if poi_id.is_empty():
		return
	cleared_pois[poi_id] = true

func is_poi_cleared(poi_id: String) -> bool:
	return bool(cleared_pois.get(poi_id, false))

func apply_poi_instance_patch(poi_id: String, patch: Dictionary) -> void:
	if poi_id.is_empty() or patch.is_empty():
		return
	var st: Dictionary = poi_instances.get(poi_id, {})
	if typeof(st) != TYPE_DICTIONARY:
		st = {}
	else:
		st = st.duplicate(true)
	for k in patch.keys():
		st[k] = patch[k]
	poi_instances[poi_id] = st

func get_poi_instance_state(poi_id: String) -> Dictionary:
	if poi_id.is_empty():
		return {}
	var st: Variant = poi_instances.get(poi_id, {})
	if typeof(st) != TYPE_DICTIONARY:
		return {}
	return (st as Dictionary).duplicate(true)

func is_poi_boss_defeated(poi_id: String) -> bool:
	var st: Dictionary = get_poi_instance_state(poi_id)
	return bool(st.get("boss_defeated", false))

func mark_world_tile_visited(world_x: int, world_y: int) -> void:
	var k: String = "%d,%d" % [world_x, world_y]
	visited_world_tiles[k] = true

func is_world_tile_visited(world_x: int, world_y: int) -> bool:
	var k: String = "%d,%d" % [world_x, world_y]
	return bool(visited_world_tiles.get(k, false))

func register_battle_result(result_data: Dictionary) -> void:
	if bool(result_data.get("victory", false)):
		battles_won += 1
	elif bool(result_data.get("escaped", false)):
		battles_fled += 1
	else:
		battles_lost += 1

func to_dict() -> Dictionary:
	return {
		"discovered_pois": discovered_pois.duplicate(true),
		"cleared_pois": cleared_pois.duplicate(true),
		"poi_instances": poi_instances.duplicate(true),
		"visited_world_tiles": visited_world_tiles.duplicate(true),
		"battles_won": battles_won,
		"battles_fled": battles_fled,
		"battles_lost": battles_lost,
	}

static func from_dict(data: Dictionary) -> WorldFlagsStateModel:
	var out := WorldFlagsStateModel.new()
	out.discovered_pois = data.get("discovered_pois", {}).duplicate(true)
	out.cleared_pois = data.get("cleared_pois", {}).duplicate(true)
	out.poi_instances = data.get("poi_instances", {}).duplicate(true)
	out.visited_world_tiles = data.get("visited_world_tiles", {}).duplicate(true)
	out.battles_won = max(0, int(data.get("battles_won", 0)))
	out.battles_fled = max(0, int(data.get("battles_fled", 0)))
	out.battles_lost = max(0, int(data.get("battles_lost", 0)))
	return out

func summary_lines() -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("POIs Discovered: %d" % discovered_pois.size())
	lines.append("POIs Cleared: %d" % cleared_pois.size())
	lines.append("World Tiles Visited: %d" % visited_world_tiles.size())
	lines.append("Battles Won: %d" % battles_won)
	lines.append("Battles Fled: %d" % battles_fled)
	lines.append("Battles Lost: %d" % battles_lost)
	return lines
