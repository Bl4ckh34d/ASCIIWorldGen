extends RefCounted

# Deterministic procedural dungeon generator with a guaranteed solvable "golden path"
# from entrance to boss. The generator is purely CPU-side but produces GPU-renderable
# marker grids (tiles/objects) that the LocalAreaScene packs for the GPU renderer.

const DeterministicRng = preload("res://scripts/gameplay/DeterministicRng.gd")

const TILE_WALL: int = 0
const TILE_FLOOR: int = 1
const TILE_DOOR: int = 2

const OBJ_NONE: int = 0
const OBJ_BOSS: int = 1
const OBJ_MAIN_CHEST: int = 2

const _INF: int = 1 << 30

func generate(world_seed_hash: int, poi_id: String, w: int, h: int) -> Dictionary:
	w = max(24, int(w))
	h = max(16, int(h))

	var tiles := PackedByteArray()
	var objects := PackedByteArray()
	tiles.resize(w * h)
	objects.resize(w * h)
	tiles.fill(TILE_WALL)
	objects.fill(OBJ_NONE)

	var mid_y: int = int(h / 2)
	var door_pos := Vector2i(w - 2, mid_y)
	_set_tile(tiles, w, h, door_pos.x, door_pos.y, TILE_DOOR)

	# Entrance room.
	_carve_room(tiles, w, h, w - 18, mid_y - 7, w - 4, mid_y + 7)
	_set_tile(tiles, w, h, door_pos.x - 1, door_pos.y, TILE_FLOOR)

	# Boss room placement: far away to the left; seeded for determinism.
	var seed_root: String = "dun|" + poi_id
	var boss_cx: int = DeterministicRng.randi_range(world_seed_hash, seed_root + "|boss_cx", 3, max(3, int(w / 4)))
	var boss_cy: int = DeterministicRng.randi_range(world_seed_hash, seed_root + "|boss_cy", 3, h - 4)
	var boss_rw: int = DeterministicRng.randi_range(world_seed_hash, seed_root + "|boss_rw", 10, 16)
	var boss_rh: int = DeterministicRng.randi_range(world_seed_hash, seed_root + "|boss_rh", 8, 12)
	var boss_room := Rect2i(
		Vector2i(clamp(boss_cx - int(boss_rw / 2), 1, w - 2), clamp(boss_cy - int(boss_rh / 2), 1, h - 2)),
		Vector2i(boss_rw, boss_rh)
	)
	boss_room.size.x = clamp(boss_room.size.x, 6, w - boss_room.position.x - 1)
	boss_room.size.y = clamp(boss_room.size.y, 6, h - boss_room.position.y - 1)
	var br_x0: int = boss_room.position.x
	var br_y0: int = boss_room.position.y
	var br_x1: int = boss_room.position.x + boss_room.size.x - 1
	var br_y1: int = boss_room.position.y + boss_room.size.y - 1
	_carve_room(tiles, w, h, br_x0, br_y0, br_x1, br_y1)

	var start := Vector2i(door_pos.x - 1, door_pos.y)
	var goal := Vector2i(clamp(boss_room.position.x + int(boss_room.size.x / 2), 1, w - 2), clamp(boss_room.position.y + int(boss_room.size.y / 2), 1, h - 2))

	# Golden path: A* on a seeded "cost field" to create organic corridors.
	var golden_path: Array[Vector2i] = _astar_carve_path(world_seed_hash, seed_root + "|gold", w, h, start, goal)
	if golden_path.is_empty():
		golden_path = _fallback_l_path(start, goal)
	for p in golden_path:
		_set_tile(tiles, w, h, p.x, p.y, TILE_FLOOR)

	# Extra branches and side rooms for complexity.
	var area: int = w * h
	var branch_count: int = clamp(int(floor(float(area) / 900.0)), 12, 34)
	var side_room_count: int = clamp(int(floor(float(area) / 700.0)), 18, 52)
	_add_branches(world_seed_hash, seed_root, tiles, w, h, golden_path, branch_count)
	_add_side_rooms(world_seed_hash, seed_root, tiles, w, h, golden_path, side_room_count)

	# Boss + chest placement.
	var boss_pos := goal
	var chest_pos := _pick_chest_near(world_seed_hash, seed_root, tiles, w, h, boss_pos)
	# Objects are placed by caller depending on cleared/open state.
	objects[_idx(w, boss_pos.x, boss_pos.y)] = OBJ_BOSS
	objects[_idx(w, chest_pos.x, chest_pos.y)] = OBJ_MAIN_CHEST

	return {
		"w": w,
		"h": h,
		"tiles": tiles,
		"objects": objects,
		"door_pos": door_pos,
		"boss_pos": boss_pos,
		"chest_pos": chest_pos,
	}

func _idx(w: int, x: int, y: int) -> int:
	return x + y * w

func _in_bounds(w: int, h: int, x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < w and y < h

func _get_tile(tiles: PackedByteArray, w: int, h: int, x: int, y: int) -> int:
	if not _in_bounds(w, h, x, y):
		return TILE_WALL
	var i: int = _idx(w, x, y)
	if i < 0 or i >= tiles.size():
		return TILE_WALL
	return int(tiles[i])

func _set_tile(tiles: PackedByteArray, w: int, h: int, x: int, y: int, v: int) -> void:
	if not _in_bounds(w, h, x, y):
		return
	var i: int = _idx(w, x, y)
	if i < 0 or i >= tiles.size():
		return
	tiles[i] = int(v)

func _carve_room(tiles: PackedByteArray, w: int, h: int, x0: int, y0: int, x1: int, y1: int) -> void:
	var ax0: int = clamp(int(x0), 1, w - 2)
	var ay0: int = clamp(int(y0), 1, h - 2)
	var ax1: int = clamp(int(x1), 1, w - 2)
	var ay1: int = clamp(int(y1), 1, h - 2)
	for y in range(min(ay0, ay1), max(ay0, ay1) + 1):
		for x in range(min(ax0, ax1), max(ax0, ax1) + 1):
			_set_tile(tiles, w, h, x, y, TILE_FLOOR)

func _fallback_l_path(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x: int = start.x
	var y: int = start.y
	out.append(Vector2i(x, y))
	while x != goal.x:
		x += 1 if goal.x > x else -1
		out.append(Vector2i(x, y))
	while y != goal.y:
		y += 1 if goal.y > y else -1
		out.append(Vector2i(x, y))
	return out

func _cell_cost(world_seed_hash: int, seed_key: String, x: int, y: int) -> int:
	# 1..5 cost; seeded per-cell for determinism.
	var r: float = DeterministicRng.randf01(world_seed_hash, "%s|c|%d|%d" % [seed_key, x, y])
	return 1 + int(floor(r * 5.0))

func _astar_carve_path(world_seed_hash: int, seed_key: String, w: int, h: int, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	if start == goal:
		return [start]
	if not _in_bounds(w, h, start.x, start.y) or not _in_bounds(w, h, goal.x, goal.y):
		return []

	var start_id: int = _idx(w, start.x, start.y)
	var goal_id: int = _idx(w, goal.x, goal.y)

	var open: Array[int] = [start_id]
	var open_set: Dictionary = {start_id: true}
	var came_from: Dictionary = {}
	var g_score: Dictionary = {start_id: 0}
	var f_score: Dictionary = {start_id: _manhattan(start.x, start.y, goal.x, goal.y)}
	var closed: Dictionary = {}
	var iters: int = 0
	var max_iters: int = max(4096, w * h * 4)
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

	while not open.is_empty() and iters < max_iters:
		iters += 1
		var best_idx: int = 0
		var current_id: int = int(open[0])
		var best_f: int = int(f_score.get(current_id, _INF))
		for j in range(1, open.size()):
			var cand_id: int = int(open[j])
			var cand_f: int = int(f_score.get(cand_id, _INF))
			if cand_f < best_f:
				best_f = cand_f
				current_id = cand_id
				best_idx = j
		open.remove_at(best_idx)
		open_set.erase(current_id)

		if current_id == goal_id:
			return _reconstruct_path(w, came_from, current_id, start_id)

		closed[current_id] = true
		var cx: int = int(current_id % w)
		var cy: int = int(current_id / w)
		for d in dirs:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if not _in_bounds(w, h, nx, ny):
				continue
			var nid: int = _idx(w, nx, ny)
			if closed.has(nid):
				continue
			var step_cost: int = _cell_cost(world_seed_hash, seed_key, nx, ny)
			var tentative_g: int = int(g_score.get(current_id, _INF)) + step_cost
			if tentative_g >= int(g_score.get(nid, _INF)):
				continue
			came_from[nid] = current_id
			g_score[nid] = tentative_g
			f_score[nid] = tentative_g + _manhattan(nx, ny, goal.x, goal.y)
			if not open_set.has(nid):
				open.append(nid)
				open_set[nid] = true
	return []

func _reconstruct_path(w: int, came_from: Dictionary, current_id: int, start_id: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var cur: int = int(current_id)
	var safety: int = 0
	while true:
		out.append(Vector2i(int(cur % w), int(cur / w)))
		if cur == start_id:
			break
		if not came_from.has(cur):
			return []
		cur = int(came_from[cur])
		safety += 1
		if safety > w * 2048:
			return []
	out.reverse()
	return out

func _manhattan(ax: int, ay: int, bx: int, by: int) -> int:
	return abs(ax - bx) + abs(ay - by)

func _add_branches(world_seed_hash: int, seed_root: String, tiles: PackedByteArray, w: int, h: int, golden_path: Array[Vector2i], branch_count: int) -> void:
	if golden_path.is_empty():
		return
	var min_len: int = clamp(int(floor(float(min(w, h)) * 0.18)), 10, 26)
	var max_len: int = clamp(int(floor(float(max(w, h)) * 0.50)), 24, 80)
	for i in range(max(0, int(branch_count))):
		var pi: int = DeterministicRng.randi_range(world_seed_hash, "%s|br|i=%d|pi" % [seed_root, i], 0, golden_path.size() - 1)
		var p: Vector2i = golden_path[pi]
		var len: int = DeterministicRng.randi_range(world_seed_hash, "%s|br|i=%d|len" % [seed_root, i], min_len, max_len)
		var x: int = p.x
		var y: int = p.y
		for s in range(len):
			_set_tile(tiles, w, h, x, y, TILE_FLOOR)
			var rr: float = DeterministicRng.randf01(world_seed_hash, "%s|br|i=%d|s=%d|r" % [seed_root, i, s])
			var d: Vector2i = Vector2i(0, 0)
			if rr < 0.40:
				d = Vector2i(-1, 0)
			elif rr < 0.55:
				d = Vector2i(0, -1)
			elif rr < 0.70:
				d = Vector2i(0, 1)
			else:
				d = Vector2i(1, 0)
			var nx: int = clamp(x + d.x, 1, w - 2)
			var ny: int = clamp(y + d.y, 1, h - 2)
			x = nx
			y = ny
			# Occasionally carve a small pocket room off the corridor.
			if (s % 11) == 0:
				var rw: int = DeterministicRng.randi_range(world_seed_hash, "%s|br|i=%d|s=%d|rw" % [seed_root, i, s], 4, 8)
				var rh: int = DeterministicRng.randi_range(world_seed_hash, "%s|br|i=%d|s=%d|rh" % [seed_root, i, s], 3, 6)
				_carve_room(tiles, w, h, x - int(rw / 2), y - int(rh / 2), x + int(rw / 2), y + int(rh / 2))

func _add_side_rooms(world_seed_hash: int, seed_root: String, tiles: PackedByteArray, w: int, h: int, golden_path: Array[Vector2i], room_count: int) -> void:
	if golden_path.is_empty():
		return
	for i in range(int(room_count)):
		var rw: int = DeterministicRng.randi_range(world_seed_hash, "%s|rm|i=%d|w" % [seed_root, i], 6, 14)
		var rh: int = DeterministicRng.randi_range(world_seed_hash, "%s|rm|i=%d|h" % [seed_root, i], 5, 11)
		var cx: int = DeterministicRng.randi_range(world_seed_hash, "%s|rm|i=%d|cx" % [seed_root, i], 2 + int(rw / 2), w - 3 - int(rw / 2))
		var cy: int = DeterministicRng.randi_range(world_seed_hash, "%s|rm|i=%d|cy" % [seed_root, i], 2 + int(rh / 2), h - 3 - int(rh / 2))
		var x0: int = cx - int(rw / 2)
		var y0: int = cy - int(rh / 2)
		var x1: int = x0 + rw - 1
		var y1: int = y0 + rh - 1
		if _room_overlaps(tiles, w, h, x0 - 1, y0 - 1, x1 + 1, y1 + 1):
			continue
		_carve_room(tiles, w, h, x0, y0, x1, y1)
		# Connect to the golden path via a short corridor to a random path cell.
		var pi: int = DeterministicRng.randi_range(world_seed_hash, "%s|rm|i=%d|pi" % [seed_root, i], 0, golden_path.size() - 1)
		var anchor: Vector2i = golden_path[pi]
		_carve_corridor(tiles, w, h, Vector2i(cx, cy), anchor, world_seed_hash, "%s|rm|i=%d|con" % [seed_root, i])

func _room_overlaps(tiles: PackedByteArray, w: int, h: int, x0: int, y0: int, x1: int, y1: int) -> bool:
	var ax0: int = clamp(int(x0), 1, w - 2)
	var ay0: int = clamp(int(y0), 1, h - 2)
	var ax1: int = clamp(int(x1), 1, w - 2)
	var ay1: int = clamp(int(y1), 1, h - 2)
	for y in range(min(ay0, ay1), max(ay0, ay1) + 1):
		for x in range(min(ax0, ax1), max(ax0, ax1) + 1):
			if _get_tile(tiles, w, h, x, y) == TILE_FLOOR:
				return true
	return false

func _carve_corridor(tiles: PackedByteArray, w: int, h: int, start: Vector2i, goal: Vector2i, world_seed_hash: int, seed_key: String) -> void:
	var path: Array[Vector2i] = _astar_carve_path(world_seed_hash, seed_key, w, h, start, goal)
	if path.is_empty():
		path = _fallback_l_path(start, goal)
	for p in path:
		_set_tile(tiles, w, h, p.x, p.y, TILE_FLOOR)

func _pick_chest_near(world_seed_hash: int, seed_root: String, tiles: PackedByteArray, w: int, h: int, boss_pos: Vector2i) -> Vector2i:
	var options: Array[Vector2i] = []
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if dx == 0 and dy == 0:
				continue
			var x: int = boss_pos.x + dx
			var y: int = boss_pos.y + dy
			if not _in_bounds(w, h, x, y):
				continue
			if _get_tile(tiles, w, h, x, y) != TILE_FLOOR:
				continue
			options.append(Vector2i(x, y))
	if options.is_empty():
		return boss_pos
	var i: int = DeterministicRng.randi_range(world_seed_hash, "%s|chest_i" % seed_root, 0, options.size() - 1)
	return options[i]
