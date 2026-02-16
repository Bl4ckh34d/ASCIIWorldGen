extends RefCounted
class_name LocalAreaGenerator

const DungeonGenerator = preload("res://scripts/gameplay/DungeonGenerator.gd")

const HOUSE_MAP_W: int = 40
const HOUSE_MAP_H: int = 22

const _SERVICE_HOME: String = "home"
const _SERVICE_SHOP: String = "shop"
const _SERVICE_INN: String = "inn"
const _SERVICE_TEMPLE: String = "temple"
const _SERVICE_FACTION_HALL: String = "faction_hall"
const _SERVICE_TOWN_HALL: String = "town_hall"

const _DOOR_EAST: int = 0
const _DOOR_WEST: int = 1
const _DOOR_NORTH: int = 2
const _DOOR_SOUTH: int = 3

func dimensions_for_poi(poi_type: String) -> Vector2i:
	if String(poi_type) == "Dungeon":
		return Vector2i(160, 90)
	return Vector2i(HOUSE_MAP_W, HOUSE_MAP_H)

func generate_house(
	world_seed_hash: int,
	poi_id: String,
	w: int,
	h: int,
	is_shop: bool = false,
	service_type: String = ""
) -> Dictionary:
	return generate_house_layout(world_seed_hash, poi_id, w, h, is_shop, service_type)

static func generate_house_layout(
	world_seed_hash: int,
	poi_id: String,
	w: int,
	h: int,
	is_shop: bool = false,
	service_type: String = ""
) -> Dictionary:
	w = max(24, int(w))
	h = max(16, int(h))
	var tiles := PackedByteArray()
	var objects := PackedByteArray()
	tiles.resize(w * h)
	objects.resize(w * h)
	tiles.fill(LocalAreaTiles.Tile.OUTSIDE)
	objects.fill(LocalAreaTiles.Obj.NONE)

	var seed_value: int = world_seed_hash if world_seed_hash != 0 else 1
	var key_root: String = "house_layout|%s" % String(poi_id)
	service_type = _normalize_house_service_type(service_type, is_shop)

	var bw_min: int = 18
	var bw_max: int = max(bw_min, min(27, w - 6))
	var bh_min: int = 10
	var bh_max: int = max(bh_min, min(15, h - 5))
	if service_type == _SERVICE_INN:
		bw_min = max(20, min(24, w - 8))
		bw_max = max(bw_min, min(30, w - 5))
		bh_min = max(11, min(13, h - 6))
		bh_max = max(bh_min, min(16, h - 4))
	elif service_type == _SERVICE_TOWN_HALL:
		bw_min = max(22, min(26, w - 8))
		bw_max = max(bw_min, min(31, w - 4))
		bh_min = max(11, min(13, h - 6))
		bh_max = max(bh_min, min(16, h - 4))

	var bw: int = DeterministicRng.randi_range(seed_value, key_root + "|bw", bw_min, bw_max)
	var bh: int = DeterministicRng.randi_range(seed_value, key_root + "|bh", bh_min, bh_max)

	var jx: int = DeterministicRng.randi_range(seed_value, key_root + "|jx", -2, 2)
	var jy: int = DeterministicRng.randi_range(seed_value, key_root + "|jy", -1, 1)
	var bx0_min: int = 2
	var by0_min: int = 2
	var bx0_max: int = max(bx0_min, w - bw - 2)
	var by0_max: int = max(by0_min, h - bh - 2)
	var bx0: int = clamp(int(floor(float(w - bw) * 0.5)) + jx, bx0_min, bx0_max)
	var by0: int = clamp(int(floor(float(h - bh) * 0.5)) + jy, by0_min, by0_max)
	var bx1: int = bx0 + bw - 1
	var by1: int = by0 + bh - 1

	for y in range(by0, by1 + 1):
		for x in range(bx0, bx1 + 1):
			var border: bool = (x == bx0 or x == bx1 or y == by0 or y == by1)
			_set_tile_s(tiles, w, h, x, y, LocalAreaTiles.Tile.WALL if border else LocalAreaTiles.Tile.FLOOR)

	var door_side: int = DeterministicRng.randi_range(seed_value, key_root + "|door_side", 0, 3)
	if service_type == _SERVICE_TOWN_HALL:
		var hall_roll: float = DeterministicRng.randf01(seed_value, key_root + "|hall_door")
		if hall_roll < 0.55:
			door_side = _DOOR_SOUTH
		elif hall_roll < 0.75:
			door_side = _DOOR_NORTH
	var door_x: int = bx1
	var door_y: int = int(round(float(by0 + by1) * 0.5))
	if door_side == _DOOR_EAST:
		door_x = bx1
		door_y = clamp(
			int(round(float(by0 + by1) * 0.5)) + DeterministicRng.randi_range(seed_value, key_root + "|door_y_e", -2, 2),
			by0 + 1,
			by1 - 1
		)
	elif door_side == _DOOR_WEST:
		door_x = bx0
		door_y = clamp(
			int(round(float(by0 + by1) * 0.5)) + DeterministicRng.randi_range(seed_value, key_root + "|door_y_w", -2, 2),
			by0 + 1,
			by1 - 1
		)
	elif door_side == _DOOR_NORTH:
		door_y = by0
		door_x = clamp(
			int(round(float(bx0 + bx1) * 0.5)) + DeterministicRng.randi_range(seed_value, key_root + "|door_x_n", -3, 3),
			bx0 + 1,
			bx1 - 1
		)
	else:
		door_y = by1
		door_x = clamp(
			int(round(float(bx0 + bx1) * 0.5)) + DeterministicRng.randi_range(seed_value, key_root + "|door_x_s", -3, 3),
			bx0 + 1,
			bx1 - 1
		)

	var anchor_x: int = door_x
	var anchor_y: int = door_y
	match door_side:
		_DOOR_EAST:
			anchor_x = door_x - 1
		_DOOR_WEST:
			anchor_x = door_x + 1
		_DOOR_NORTH:
			anchor_y = door_y + 1
		_DOOR_SOUTH:
			anchor_y = door_y - 1
	anchor_x = clamp(anchor_x, bx0 + 1, bx1 - 1)
	anchor_y = clamp(anchor_y, by0 + 1, by1 - 1)

	_set_tile_s(tiles, w, h, door_x, door_y, LocalAreaTiles.Tile.DOOR)
	_set_tile_s(tiles, w, h, anchor_x, anchor_y, LocalAreaTiles.Tile.FLOOR)

	var corridor_cells: Dictionary = {}
	var mid_x: int = clamp(
		int(round(float(bx0 + bx1) * 0.5)) + DeterministicRng.randi_range(seed_value, key_root + "|mid_x", -1, 1),
		bx0 + 2,
		bx1 - 2
	)
	var mid_y: int = clamp(
		int(round(float(by0 + by1) * 0.5)) + DeterministicRng.randi_range(seed_value, key_root + "|mid_y", -1, 1),
		by0 + 2,
		by1 - 2
	)
	if door_side == _DOOR_EAST or door_side == _DOOR_WEST:
		_carve_corridor_line_s(tiles, w, h, anchor_x, anchor_y, mid_x, anchor_y, corridor_cells)
		_carve_corridor_line_s(tiles, w, h, mid_x, by0 + 2, mid_x, by1 - 2, corridor_cells)
		var tail_x: int = bx0 + 2 if door_side == _DOOR_EAST else bx1 - 2
		_carve_corridor_line_s(tiles, w, h, mid_x, mid_y, tail_x, mid_y, corridor_cells)
	else:
		_carve_corridor_line_s(tiles, w, h, anchor_x, anchor_y, anchor_x, mid_y, corridor_cells)
		_carve_corridor_line_s(tiles, w, h, bx0 + 2, mid_y, bx1 - 2, mid_y, corridor_cells)
		var tail_y: int = by1 - 2 if door_side == _DOOR_NORTH else by0 + 2
		_carve_corridor_line_s(tiles, w, h, mid_x, mid_y, mid_x, tail_y, corridor_cells)

	var split_x_a: int = clamp(
		bx0 + int(round(float(bw) * 0.34)) + DeterministicRng.randi_range(seed_value, key_root + "|split_x_a", -1, 1),
		bx0 + 3,
		bx1 - 3
	)
	var split_x_b: int = -1
	if bw >= 23 and DeterministicRng.randf01(seed_value, key_root + "|split_x_b_on") < 0.42:
		split_x_b = clamp(
			bx0 + int(round(float(bw) * 0.68)) + DeterministicRng.randi_range(seed_value, key_root + "|split_x_b", -1, 1),
			split_x_a + 3,
			bx1 - 3
		)

	var split_y_a: int = clamp(
		by0 + int(round(float(bh) * 0.52)) + DeterministicRng.randi_range(seed_value, key_root + "|split_y_a", -1, 1),
		by0 + 3,
		by1 - 3
	)
	var split_y_b: int = -1
	if bh >= 13 and DeterministicRng.randf01(seed_value, key_root + "|split_y_b_on") < 0.32:
		split_y_b = clamp(
			by0 + int(round(float(bh) * 0.74)) + DeterministicRng.randi_range(seed_value, key_root + "|split_y_b", -1, 1),
			split_y_a + 2,
			by1 - 2
		)

	for yy in range(by0 + 1, by1):
		_set_tile_s(tiles, w, h, split_x_a, yy, LocalAreaTiles.Tile.WALL)
		if split_x_b >= 0:
			_set_tile_s(tiles, w, h, split_x_b, yy, LocalAreaTiles.Tile.WALL)
	for xx in range(bx0 + 1, bx1):
		_set_tile_s(tiles, w, h, xx, split_y_a, LocalAreaTiles.Tile.WALL)
		if split_y_b >= 0:
			_set_tile_s(tiles, w, h, xx, split_y_b, LocalAreaTiles.Tile.WALL)

	_open_random_wall_gaps_vertical_s(tiles, w, h, split_x_a, by0 + 2, by1 - 2, 2, seed_value, key_root + "|gap_v_a")
	if split_x_b >= 0:
		_open_random_wall_gaps_vertical_s(tiles, w, h, split_x_b, by0 + 2, by1 - 2, 1, seed_value, key_root + "|gap_v_b")
	_open_random_wall_gaps_horizontal_s(tiles, w, h, split_y_a, bx0 + 2, bx1 - 2, 2, seed_value, key_root + "|gap_h_a")
	if split_y_b >= 0:
		_open_random_wall_gaps_horizontal_s(tiles, w, h, split_y_b, bx0 + 2, bx1 - 2, 1, seed_value, key_root + "|gap_h_b")
	_restore_corridor_cells_s(tiles, corridor_cells)

	var left_x0: int = bx0 + 1
	var left_x1: int = max(left_x0, split_x_a - 1)
	var right_x0: int = split_x_a + 1
	var right_x1: int = max(right_x0, bx1 - 1)
	var top_y0: int = by0 + 1
	var top_y1: int = max(top_y0, split_y_a - 1)
	var bot_y0: int = split_y_a + 1
	var bot_y1: int = max(bot_y0, by1 - 1)

	var entry_candidates: Array[Vector2i] = _entry_side_candidates(anchor_x, anchor_y, door_side)
	if service_type == _SERVICE_SHOP:
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.TABLE, entry_candidates, right_x0, top_y0, right_x1, top_y1, seed_value, key_root + "|shop_counter")
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.HEARTH, [Vector2i(right_x1 - 1, bot_y1 - 1), Vector2i(right_x0 + 1, bot_y1 - 1)], right_x0, bot_y0, right_x1, bot_y1, seed_value, key_root + "|shop_hearth")
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.BED, [Vector2i(left_x0 + 1, top_y0 + 1), Vector2i(left_x0 + 1, bot_y0 + 1)], left_x0, top_y0, left_x1, bot_y1, seed_value, key_root + "|shop_bed")
	elif service_type == _SERVICE_INN:
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.TABLE, entry_candidates, left_x0, top_y0, right_x1, top_y1, seed_value, key_root + "|inn_desk")
		var beds_n: int = 2 + DeterministicRng.randi_range(seed_value, key_root + "|inn_beds", 0, 2)
		for bi in range(beds_n):
			_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.BED, [
				Vector2i(left_x0 + 1 + bi * 2, bot_y0 + 1),
				Vector2i(right_x0 + 1 + bi * 2, bot_y0 + 1),
				Vector2i(left_x0 + 1 + bi * 2, top_y0 + 1),
			], left_x0, top_y0, right_x1, bot_y1, seed_value, "%s|inn_bed_%d" % [key_root, bi])
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.HEARTH, [Vector2i(right_x1 - 1, bot_y1 - 1), Vector2i(left_x0 + 1, bot_y1 - 1)], left_x0, bot_y0, right_x1, bot_y1, seed_value, key_root + "|inn_hearth")
	elif service_type == _SERVICE_TEMPLE:
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.TABLE, [Vector2i(mid_x, top_y0 + 1), Vector2i(mid_x - 1, top_y0 + 1), Vector2i(mid_x + 1, top_y0 + 1)], left_x0, top_y0, right_x1, top_y1, seed_value, key_root + "|temple_altar")
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.HEARTH, [Vector2i(mid_x, bot_y1 - 1)], left_x0, bot_y0, right_x1, bot_y1, seed_value, key_root + "|temple_fire")
		if DeterministicRng.randf01(seed_value, key_root + "|temple_bed") < 0.45:
			_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.BED, [Vector2i(left_x0 + 1, bot_y0 + 1)], left_x0, bot_y0, left_x1, bot_y1, seed_value, key_root + "|temple_bedroll")
	elif service_type == _SERVICE_FACTION_HALL or service_type == _SERVICE_TOWN_HALL:
		var table_count: int = 2 if service_type == _SERVICE_FACTION_HALL else 3
		for ti in range(table_count):
			_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.TABLE, [
				Vector2i(mid_x - 2 + ti * 2, mid_y),
				Vector2i(mid_x - 2 + ti * 2, top_y0 + 2),
			], left_x0, top_y0, right_x1, bot_y1, seed_value, "%s|hall_table_%d" % [key_root, ti])
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.HEARTH, [Vector2i(right_x1 - 1, bot_y1 - 1)], left_x0, bot_y0, right_x1, bot_y1, seed_value, key_root + "|hall_hearth")
	else:
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.BED, [Vector2i(left_x0 + 1, top_y0 + 1), Vector2i(left_x0 + 2, top_y0 + 1)], left_x0, top_y0, left_x1, top_y1, seed_value, key_root + "|home_bed")
		if DeterministicRng.randf01(seed_value, key_root + "|home_second_bed") < 0.45:
			_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.BED, [Vector2i(left_x0 + 1, bot_y0 + 1), Vector2i(left_x1 - 1, bot_y0 + 1)], left_x0, bot_y0, left_x1, bot_y1, seed_value, key_root + "|home_second_bed")
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.TABLE, [Vector2i(right_x0 + 1, top_y0 + 1), Vector2i(right_x1 - 1, top_y0 + 1)], right_x0, top_y0, right_x1, top_y1, seed_value, key_root + "|home_table")
		_place_object_candidates_s(objects, tiles, w, h, LocalAreaTiles.Obj.HEARTH, [Vector2i(right_x0 + 1, bot_y1 - 1), Vector2i(right_x1 - 1, bot_y1 - 1)], right_x0, bot_y0, right_x1, bot_y1, seed_value, key_root + "|home_hearth")

	return {
		"w": w,
		"h": h,
		"tiles": tiles,
		"objects": objects,
		"door_pos": Vector2i(door_x, door_y),
		"door_side": door_side,
		"service_type": service_type,
		"boss_pos": Vector2i(-1, -1),
		"chest_pos": Vector2i(-1, -1),
		"anchor_x": anchor_x,
		"anchor_y": anchor_y,
		"extent_left": anchor_x,
		"extent_right": max(0, w - 1 - anchor_x),
		"extent_up": anchor_y,
		"extent_down": max(0, h - 1 - anchor_y),
	}

func generate_dungeon(world_seed_hash: int, poi_id: String, w: int, h: int) -> Dictionary:
	var gen := DungeonGenerator.new()
	var out: Dictionary = gen.generate(world_seed_hash, poi_id, w, h)
	if typeof(out) != TYPE_DICTIONARY:
		return {}
	return out

static func _normalize_house_service_type(service_type: String, is_shop: bool) -> String:
	var out: String = String(service_type).to_lower().strip_edges()
	if out == "guild" or out == "faction":
		out = _SERVICE_FACTION_HALL
	if out.is_empty():
		out = _SERVICE_SHOP if is_shop else _SERVICE_HOME
	if out != _SERVICE_HOME and out != _SERVICE_SHOP and out != _SERVICE_INN and out != _SERVICE_TEMPLE and out != _SERVICE_FACTION_HALL and out != _SERVICE_TOWN_HALL:
		out = _SERVICE_HOME
	return out

static func _entry_side_candidates(anchor_x: int, anchor_y: int, door_side: int) -> Array[Vector2i]:
	match door_side:
		_DOOR_EAST:
			return [
				Vector2i(anchor_x - 1, anchor_y),
				Vector2i(anchor_x - 2, anchor_y),
				Vector2i(anchor_x - 1, anchor_y - 1),
				Vector2i(anchor_x - 1, anchor_y + 1),
			]
		_DOOR_WEST:
			return [
				Vector2i(anchor_x + 1, anchor_y),
				Vector2i(anchor_x + 2, anchor_y),
				Vector2i(anchor_x + 1, anchor_y - 1),
				Vector2i(anchor_x + 1, anchor_y + 1),
			]
		_DOOR_NORTH:
			return [
				Vector2i(anchor_x, anchor_y + 1),
				Vector2i(anchor_x - 1, anchor_y + 1),
				Vector2i(anchor_x + 1, anchor_y + 1),
				Vector2i(anchor_x, anchor_y + 2),
			]
		_:
			return [
				Vector2i(anchor_x, anchor_y - 1),
				Vector2i(anchor_x - 1, anchor_y - 1),
				Vector2i(anchor_x + 1, anchor_y - 1),
				Vector2i(anchor_x, anchor_y - 2),
			]

static func _in_bounds_s(w: int, h: int, x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < w and y < h

static func _idx_s(w: int, x: int, y: int) -> int:
	return x + y * w

static func _set_tile_s(tiles: PackedByteArray, w: int, h: int, x: int, y: int, v: int) -> void:
	if not _in_bounds_s(w, h, x, y):
		return
	var i: int = _idx_s(w, x, y)
	if i < 0 or i >= tiles.size():
		return
	tiles[i] = int(v)

static func _set_object_s(objects: PackedByteArray, w: int, h: int, x: int, y: int, v: int) -> void:
	if not _in_bounds_s(w, h, x, y):
		return
	var i: int = _idx_s(w, x, y)
	if i < 0 or i >= objects.size():
		return
	objects[i] = int(v)

static func _carve_corridor_line_s(
	tiles: PackedByteArray,
	w: int,
	h: int,
	x0: int,
	y0: int,
	x1: int,
	y1: int,
	corridor_cells: Dictionary
) -> void:
	var cx: int = x0
	var cy: int = y0
	_carve_corridor_cell_s(tiles, w, h, cx, cy, corridor_cells)
	var safety: int = 0
	while (cx != x1 or cy != y1) and safety < 512:
		safety += 1
		if cx < x1:
			cx += 1
		elif cx > x1:
			cx -= 1
		elif cy < y1:
			cy += 1
		elif cy > y1:
			cy -= 1
		_carve_corridor_cell_s(tiles, w, h, cx, cy, corridor_cells)

static func _carve_corridor_cell_s(tiles: PackedByteArray, w: int, h: int, x: int, y: int, corridor_cells: Dictionary) -> void:
	if not _in_bounds_s(w, h, x, y):
		return
	var i: int = _idx_s(w, x, y)
	if i < 0 or i >= tiles.size():
		return
	tiles[i] = int(LocalAreaTiles.Tile.FLOOR)
	corridor_cells[i] = true

static func _restore_corridor_cells_s(tiles: PackedByteArray, corridor_cells: Dictionary) -> void:
	for kv in corridor_cells.keys():
		var i: int = int(kv)
		if i < 0 or i >= tiles.size():
			continue
		tiles[i] = int(LocalAreaTiles.Tile.FLOOR)

static func _open_random_wall_gaps_vertical_s(
	tiles: PackedByteArray,
	w: int,
	h: int,
	wall_x: int,
	y0: int,
	y1: int,
	gap_count: int,
	seed_value: int,
	key: String
) -> void:
	if gap_count <= 0:
		return
	y0 = max(1, y0)
	y1 = min(h - 2, y1)
	if y1 < y0:
		return
	for i in range(gap_count):
		var gy: int = DeterministicRng.randi_range(seed_value, "%s|i=%d" % [key, i], y0, y1)
		_set_tile_s(tiles, w, h, wall_x, gy, LocalAreaTiles.Tile.FLOOR)

static func _open_random_wall_gaps_horizontal_s(
	tiles: PackedByteArray,
	w: int,
	h: int,
	wall_y: int,
	x0: int,
	x1: int,
	gap_count: int,
	seed_value: int,
	key: String
) -> void:
	if gap_count <= 0:
		return
	x0 = max(1, x0)
	x1 = min(w - 2, x1)
	if x1 < x0:
		return
	for i in range(gap_count):
		var gx: int = DeterministicRng.randi_range(seed_value, "%s|i=%d" % [key, i], x0, x1)
		_set_tile_s(tiles, w, h, gx, wall_y, LocalAreaTiles.Tile.FLOOR)

static func _try_place_object_s(objects: PackedByteArray, tiles: PackedByteArray, w: int, h: int, x: int, y: int, obj_id: int) -> bool:
	if not _in_bounds_s(w, h, x, y):
		return false
	var i: int = _idx_s(w, x, y)
	if i < 0 or i >= tiles.size() or i >= objects.size():
		return false
	if int(tiles[i]) != int(LocalAreaTiles.Tile.FLOOR):
		return false
	if int(objects[i]) != int(LocalAreaTiles.Obj.NONE):
		return false
	objects[i] = int(obj_id)
	return true

static func _place_object_candidates_s(
	objects: PackedByteArray,
	tiles: PackedByteArray,
	w: int,
	h: int,
	obj_id: int,
	candidates: Array,
	x0: int,
	y0: int,
	x1: int,
	y1: int,
	seed_value: int,
	key: String
) -> void:
	for cv in candidates:
		if typeof(cv) != TYPE_VECTOR2I:
			continue
		var c: Vector2i = cv
		if _try_place_object_s(objects, tiles, w, h, c.x, c.y, obj_id):
			return
	var ax0: int = min(x0, x1)
	var ay0: int = min(y0, y1)
	var ax1: int = max(x0, x1)
	var ay1: int = max(y0, y1)
	if ax0 < 1 or ay0 < 1:
		return
	if ax1 >= w - 1 or ay1 >= h - 1:
		return
	for t in range(48):
		var rx: int = DeterministicRng.randi_range(seed_value, "%s|x|t=%d" % [key, t], ax0, ax1)
		var ry: int = DeterministicRng.randi_range(seed_value, "%s|y|t=%d" % [key, t], ay0, ay1)
		if _try_place_object_s(objects, tiles, w, h, rx, ry, obj_id):
			return
