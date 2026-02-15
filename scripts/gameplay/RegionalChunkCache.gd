extends RefCounted
class_name RegionalChunkCache

const RegionalChunkGenerator = preload("res://scripts/gameplay/RegionalChunkGenerator.gd")

var generator: RegionalChunkGenerator = null
var chunk_size: int = 32
var max_chunks: int = 256

var _tick: int = 0
var _chunks: Dictionary = {} # Vector2i -> { ground, obj, flags, last_used, chunk_size }
var _generated_total: int = 0
var _cache_hits_total: int = 0
var _cache_misses_total: int = 0
var _generated_last_prefetch: int = 0

func configure(gen: RegionalChunkGenerator, chunk_size_value: int = 32, max_chunks_value: int = 256) -> void:
	generator = gen
	chunk_size = max(8, chunk_size_value)
	max_chunks = max(16, max_chunks_value)
	_tick = 0
	_chunks.clear()
	_generated_total = 0
	_cache_hits_total = 0
	_cache_misses_total = 0
	_generated_last_prefetch = 0

func invalidate_all() -> void:
	# Called when generator parameters change (e.g., biome transition progress).
	_tick = 0
	_chunks.clear()
	_generated_last_prefetch = 0

func prefetch_for_view(origin_x: int, origin_y: int, view_w: int, view_h: int, margin_chunks: int = 1) -> int:
	if generator == null:
		return 0
	_tick += 1
	_generated_last_prefetch = 0
	var cs: int = max(8, chunk_size)
	var pad_cells: int = max(0, margin_chunks) * cs
	var width_cells: int = max(1, view_w)
	var height_cells: int = max(1, view_h)
	var min_x: int = origin_x - pad_cells
	var max_x: int = origin_x + width_cells - 1 + pad_cells
	var min_y: int = origin_y - pad_cells
	var max_y: int = origin_y + height_cells - 1 + pad_cells

	var max_world_y: int = max(0, int(generator.world_height) * int(generator.region_size) - 1)
	min_y = clamp(min_y, 0, max_world_y)
	max_y = clamp(max_y, 0, max_world_y)
	if min_y > max_y:
		return 0
	var cy0: int = int(min_y / cs)
	var cy1: int = int(max_y / cs)
	var x_ranges: Array = _wrapped_x_ranges(min_x, max_x)
	for xr in x_ranges:
		var rr: Vector2i = xr
		var cx0: int = int(rr.x / cs)
		var cx1: int = int(rr.y / cs)
		for cy in range(cy0, cy1 + 1):
			for cx in range(cx0, cx1 + 1):
				_generated_last_prefetch += _ensure_chunk(cx, cy)
	if _generated_last_prefetch > 0:
		_evict_if_needed()
	return _generated_last_prefetch

func get_cell(gx: int, gy: int) -> Dictionary:
	if generator == null:
		return {"ground": 0, "obj": 0, "flags": 0, "poi_type": "", "poi_id": ""}
	var p: Vector2i = _normalize_global_coords(gx, gy)
	gx = p.x
	gy = p.y
	_tick += 1
	var cs: int = chunk_size
	var cx: int = int(gx / cs)
	var cy: int = int(gy / cs)
	_ensure_chunk(cx, cy)
	var key := Vector2i(cx, cy)
	var chunk: Dictionary = _chunks.get(key, {})
	if _chunks.size() > max_chunks:
		_evict_if_needed()

	var lx: int = gx - cx * cs
	var ly: int = gy - cy * cs
	# Defensive clamp in case caller passed coords near clamp boundaries.
	lx = clamp(lx, 0, cs - 1)
	ly = clamp(ly, 0, cs - 1)
	var idx: int = lx + ly * cs
	var ground: PackedByteArray = chunk.get("ground", PackedByteArray())
	var obj: PackedByteArray = chunk.get("obj", PackedByteArray())
	var flags: PackedByteArray = chunk.get("flags", PackedByteArray())
	var height_raw: PackedFloat32Array = chunk.get("height_raw", PackedFloat32Array())
	var biome: PackedInt32Array = chunk.get("biome", PackedInt32Array())
	if idx < 0 or idx >= ground.size() or idx >= obj.size() or idx >= flags.size():
		return {"ground": 0, "obj": 0, "flags": 0, "poi_type": "", "poi_id": ""}
	var poi_type: String = ""
	var poi_id: String = ""
	var poi_cells: Variant = chunk.get("poi_cells", {})
	if typeof(poi_cells) == TYPE_DICTIONARY:
		var poi_map: Dictionary = poi_cells as Dictionary
		if poi_map.has(idx):
			var pv: Variant = poi_map.get(idx, {})
			if typeof(pv) == TYPE_DICTIONARY:
				var pd: Dictionary = pv as Dictionary
				poi_type = String(pd.get("type", ""))
				poi_id = String(pd.get("id", ""))
	return {
		"ground": int(ground[idx]),
		"obj": int(obj[idx]),
		"flags": int(flags[idx]),
		"height_raw": float(height_raw[idx]) if idx >= 0 and idx < height_raw.size() else 0.0,
		"biome": int(biome[idx]) if idx >= 0 and idx < biome.size() else 7,
		"poi_type": poi_type,
		"poi_id": poi_id,
	}

func get_stats() -> Dictionary:
	return {
		"chunks_cached": _chunks.size(),
		"chunk_size": chunk_size,
		"max_chunks": max_chunks,
		"cache_hits_total": _cache_hits_total,
		"cache_misses_total": _cache_misses_total,
		"chunks_generated_total": _generated_total,
		"chunks_generated_last_prefetch": _generated_last_prefetch,
	}

func _ensure_chunk(cx: int, cy: int) -> int:
	var key := Vector2i(cx, cy)
	var chunk: Dictionary = _chunks.get(key, {})
	if chunk.is_empty():
		_cache_misses_total += 1
		chunk = generator.generate_chunk(cx, cy, chunk_size)
		chunk["last_used"] = _tick
		_chunks[key] = chunk
		_generated_total += 1
		return 1
	_cache_hits_total += 1
	chunk["last_used"] = _tick
	_chunks[key] = chunk
	return 0

func _normalize_global_coords(gx: int, gy: int) -> Vector2i:
	if generator == null:
		return Vector2i(gx, gy)
	var period_x: int = max(1, int(generator.world_width) * int(generator.region_size))
	var max_y: int = max(0, int(generator.world_height) * int(generator.region_size) - 1)
	return Vector2i(posmod(gx, period_x), clamp(gy, 0, max_y))

func _wrapped_x_ranges(min_x: int, max_x: int) -> Array:
	var out: Array = []
	if generator == null:
		out.append(Vector2i(min_x, max_x))
		return out
	var period_x: int = max(1, int(generator.world_width) * int(generator.region_size))
	var span: int = max_x - min_x + 1
	if span >= period_x:
		out.append(Vector2i(0, period_x - 1))
		return out
	var a: int = posmod(min_x, period_x)
	var b: int = posmod(max_x, period_x)
	if a <= b:
		out.append(Vector2i(a, b))
	else:
		out.append(Vector2i(a, period_x - 1))
		out.append(Vector2i(0, b))
	return out

func _evict_if_needed() -> void:
	if _chunks.size() <= max_chunks:
		return
	# Simple LRU eviction: drop the least recently used chunks until under budget.
	while _chunks.size() > max_chunks:
		var oldest_key: Variant = null
		var oldest_tick: int = 2147483647
		for k in _chunks.keys():
			var chunk: Dictionary = _chunks[k]
			var used: int = int(chunk.get("last_used", 0))
			if used < oldest_tick:
				oldest_tick = used
				oldest_key = k
		if oldest_key == null:
			break
		_chunks.erase(oldest_key)
