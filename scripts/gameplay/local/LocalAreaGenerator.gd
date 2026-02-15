extends RefCounted
class_name LocalAreaGenerator

const LocalAreaTiles = preload("res://scripts/gameplay/local/LocalAreaTiles.gd")
const DungeonGenerator = preload("res://scripts/gameplay/DungeonGenerator.gd")

func dimensions_for_poi(poi_type: String) -> Vector2i:
	if String(poi_type) == "Dungeon":
		return Vector2i(160, 90)
	return Vector2i(40, 22)

func generate_house(_world_seed_hash: int, _poi_id: String, w: int, h: int) -> Dictionary:
	w = max(12, int(w))
	h = max(10, int(h))
	var tiles := PackedByteArray()
	var objects := PackedByteArray()
	tiles.resize(w * h)
	objects.resize(w * h)
	tiles.fill(LocalAreaTiles.Tile.WALL)
	objects.fill(LocalAreaTiles.Obj.NONE)

	_carve_room(tiles, w, h, 2, 2, w - 3, h - 3)
	var door_pos := Vector2i(w - 2, int(h / 2))
	_set_tile(tiles, w, h, door_pos.x, door_pos.y, LocalAreaTiles.Tile.DOOR)

	# Baseline lived-in furniture set for houses.
	_set_object(objects, w, h, 4, 4, LocalAreaTiles.Obj.BED)
	_set_object(objects, w, h, 6, 6, LocalAreaTiles.Obj.TABLE)
	_set_object(objects, w, h, 5, h - 5, LocalAreaTiles.Obj.HEARTH)

	return {
		"w": w,
		"h": h,
		"tiles": tiles,
		"objects": objects,
		"door_pos": door_pos,
		"boss_pos": Vector2i(-1, -1),
		"chest_pos": Vector2i(-1, -1),
	}

func generate_dungeon(world_seed_hash: int, poi_id: String, w: int, h: int) -> Dictionary:
	var gen := DungeonGenerator.new()
	var out: Dictionary = gen.generate(world_seed_hash, poi_id, w, h)
	if typeof(out) != TYPE_DICTIONARY:
		return {}
	return out

func _in_bounds(w: int, h: int, x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < w and y < h

func _idx(w: int, x: int, y: int) -> int:
	return x + y * w

func _set_tile(tiles: PackedByteArray, w: int, h: int, x: int, y: int, v: int) -> void:
	if not _in_bounds(w, h, x, y):
		return
	var i: int = _idx(w, x, y)
	if i < 0 or i >= tiles.size():
		return
	tiles[i] = int(v)

func _set_object(objects: PackedByteArray, w: int, h: int, x: int, y: int, v: int) -> void:
	if not _in_bounds(w, h, x, y):
		return
	var i: int = _idx(w, x, y)
	if i < 0 or i >= objects.size():
		return
	objects[i] = int(v)

func _carve_room(tiles: PackedByteArray, w: int, h: int, x0: int, y0: int, x1: int, y1: int) -> void:
	var ax0: int = clamp(int(x0), 1, w - 2)
	var ay0: int = clamp(int(y0), 1, h - 2)
	var ax1: int = clamp(int(x1), 1, w - 2)
	var ay1: int = clamp(int(y1), 1, h - 2)
	for y in range(min(ay0, ay1), max(ay0, ay1) + 1):
		for x in range(min(ax0, ax1), max(ax0, ax1) + 1):
			_set_tile(tiles, w, h, x, y, LocalAreaTiles.Tile.FLOOR)

