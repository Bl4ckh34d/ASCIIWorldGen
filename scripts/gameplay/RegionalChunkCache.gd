extends RefCounted


var generator: RegionalChunkGenerator = null
var chunk_size: int = 32
var max_chunks: int = 256
var prefetch_generate_budget_chunks: int = 4
var prefetch_time_budget_us: int = 2000

var _tick: int = 0
var _chunks: Dictionary = {} # Vector2i -> { ground, obj, flags, last_used, chunk_size }
var _generated_total: int = 0
var _cache_hits_total: int = 0
var _cache_misses_total: int = 0
var _generated_last_prefetch: int = 0
var _requested_last_prefetch: int = 0
var _get_cell_hits_total: int = 0
var _get_cell_misses_total: int = 0
var _prefetch_calls_total: int = 0
var _prefetch_generated_total: int = 0
var _prefetch_requested_total: int = 0
var _prefetch_us_last: int = 0
var _prefetch_us_total: int = 0
var _prefetch_us_max: int = 0
var _chunk_gen_us_last: int = 0
var _chunk_gen_us_total: int = 0
var _chunk_gen_us_max: int = 0
var _chunks_evicted_total: int = 0
var _seam_checks_total: int = 0
var _seam_anomalies_total: int = 0
var _seam_delta_accum: float = 0.0
var _seam_delta_max: float = 0.0

func configure(gen: RegionalChunkGenerator, chunk_size_value: int = 32, max_chunks_value: int = 256) -> void:
	generator = gen
	chunk_size = max(8, chunk_size_value)
	max_chunks = max(16, max_chunks_value)
	prefetch_generate_budget_chunks = max(1, int(prefetch_generate_budget_chunks))
	prefetch_time_budget_us = max(250, int(prefetch_time_budget_us))
	_tick = 0
	_chunks.clear()
	_generated_total = 0
	_cache_hits_total = 0
	_cache_misses_total = 0
	_generated_last_prefetch = 0
	_requested_last_prefetch = 0
	_get_cell_hits_total = 0
	_get_cell_misses_total = 0
	_prefetch_calls_total = 0
	_prefetch_generated_total = 0
	_prefetch_requested_total = 0
	_prefetch_us_last = 0
	_prefetch_us_total = 0
	_prefetch_us_max = 0
	_chunk_gen_us_last = 0
	_chunk_gen_us_total = 0
	_chunk_gen_us_max = 0
	_chunks_evicted_total = 0
	_seam_checks_total = 0
	_seam_anomalies_total = 0
	_seam_delta_accum = 0.0
	_seam_delta_max = 0.0

func invalidate_all() -> void:
	# Called when generator parameters change (e.g., biome transition progress).
	_tick = 0
	_chunks.clear()
	_generated_last_prefetch = 0
	_requested_last_prefetch = 0
	_prefetch_us_last = 0

func invalidate_for_world_tiles(
	changed_tiles: Array,
	region_size_cells: int,
	world_width_tiles: int,
	world_height_tiles: int,
	pad_cells: int = 0
) -> int:
	if _chunks.is_empty():
		return 0
	var rs: int = max(1, int(region_size_cells))
	var ww_tiles: int = max(1, int(world_width_tiles))
	var wh_tiles: int = max(1, int(world_height_tiles))
	var max_world_y: int = max(0, wh_tiles * rs - 1)
	var pad: int = max(0, int(pad_cells))
	var dirty_rects: Array = []
	var seen_rects: Dictionary = {}
	for tv in changed_tiles:
		if typeof(tv) != TYPE_VECTOR2I:
			continue
		var wt: Vector2i = tv as Vector2i
		var tx: int = posmod(wt.x, ww_tiles)
		var ty: int = clamp(wt.y, 0, wh_tiles - 1)
		var rx0_raw: int = tx * rs - pad
		var rx1_raw: int = tx * rs + rs - 1 + pad
		var ry0: int = clamp(ty * rs - pad, 0, max_world_y)
		var ry1: int = clamp(ty * rs + rs - 1 + pad, 0, max_world_y)
		if ry1 < ry0:
			continue
		for xv in _wrapped_x_ranges(rx0_raw, rx1_raw):
			if typeof(xv) != TYPE_VECTOR2I:
				continue
			var xr: Vector2i = xv as Vector2i
			var key: String = "%d,%d|%d,%d" % [xr.x, xr.y, ry0, ry1]
			if seen_rects.has(key):
				continue
			seen_rects[key] = true
			dirty_rects.append(Rect2i(xr.x, ry0, xr.y - xr.x + 1, ry1 - ry0 + 1))
	if dirty_rects.is_empty():
		return 0
	var remove_keys: Array = []
	var cs: int = max(8, chunk_size)
	for kv in _chunks.keys():
		if typeof(kv) != TYPE_VECTOR2I:
			continue
		var ck: Vector2i = kv as Vector2i
		var cx0: int = ck.x * cs
		var cx1: int = cx0 + cs - 1
		var cy0: int = ck.y * cs
		var cy1: int = cy0 + cs - 1
		for rv in dirty_rects:
			if typeof(rv) != TYPE_RECT2I:
				continue
			var rect: Rect2i = rv as Rect2i
			var rx0: int = rect.position.x
			var ry0i: int = rect.position.y
			var rx1: int = rect.position.x + rect.size.x - 1
			var ry1i: int = rect.position.y + rect.size.y - 1
			if _rect_intersects(cx0, cx1, cy0, cy1, rx0, rx1, ry0i, ry1i):
				remove_keys.append(ck)
				break
	for ck_rm in remove_keys:
		_chunks.erase(ck_rm)
	var removed: int = remove_keys.size()
	if removed > 0:
		_chunks_evicted_total += removed
		_generated_last_prefetch = 0
		_requested_last_prefetch = 0
		_prefetch_us_last = 0
	return removed

func prefetch_for_view(
	origin_x: int,
	origin_y: int,
	view_w: int,
	view_h: int,
	margin_chunks: int = 1,
	max_generate_chunks: int = -1,
	time_budget_us_override: int = -1
) -> int:
	if generator == null:
		return 0
	var t0_us: int = Time.get_ticks_usec()
	_prefetch_calls_total += 1
	_tick += 1
	_generated_last_prefetch = 0
	_requested_last_prefetch = 0
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
	var chunk_keys: Array = _collect_prefetch_chunk_keys(min_x, max_x, min_y, max_y, cs)
	_requested_last_prefetch = chunk_keys.size()
	if _requested_last_prefetch <= 0:
		_prefetch_us_last = Time.get_ticks_usec() - t0_us
		_prefetch_us_total += _prefetch_us_last
		_prefetch_us_max = max(_prefetch_us_max, _prefetch_us_last)
		return 0

	var center_gx: int = _normalize_global_coords(origin_x + int(floor(float(width_cells) * 0.5)), origin_y).x
	var center_gy: int = clamp(origin_y + int(floor(float(height_cells) * 0.5)), 0, max_world_y)
	var center_cx: int = _floor_div_int(center_gx, cs)
	var center_cy: int = _floor_div_int(center_gy, cs)
	_sort_chunk_keys_by_proximity(chunk_keys, center_cx, center_cy)

	var gen_budget: int = max_generate_chunks if max_generate_chunks >= 0 else int(prefetch_generate_budget_chunks)
	var time_budget: int = time_budget_us_override if time_budget_us_override >= 0 else int(prefetch_time_budget_us)
	gen_budget = max(0, gen_budget)
	time_budget = max(0, time_budget)
	var generated_now: int = 0
	for kv in chunk_keys:
		if generated_now >= gen_budget:
			break
		if time_budget > 0 and (Time.get_ticks_usec() - t0_us) >= time_budget:
			break
		if typeof(kv) != TYPE_VECTOR2I:
			continue
		var ck: Vector2i = kv as Vector2i
		if _chunks.has(ck):
			var cached_chunk: Dictionary = _chunks.get(ck, {})
			cached_chunk["last_used"] = _tick
			_chunks[ck] = cached_chunk
			continue
		generated_now += _ensure_chunk(ck.x, ck.y)
	_generated_last_prefetch = generated_now
	_prefetch_requested_total += _requested_last_prefetch
	_prefetch_generated_total += _generated_last_prefetch
	_prefetch_us_last = Time.get_ticks_usec() - t0_us
	_prefetch_us_total += _prefetch_us_last
	_prefetch_us_max = max(_prefetch_us_max, _prefetch_us_last)
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
	var cx: int = _floor_div_int(gx, cs)
	var cy: int = _floor_div_int(gy, cs)
	var key := Vector2i(cx, cy)
	var had_chunk: bool = _chunks.has(key)
	_ensure_chunk(cx, cy)
	if had_chunk:
		_get_cell_hits_total += 1
	else:
		_get_cell_misses_total += 1
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
	var lookup_total: int = _cache_hits_total + _cache_misses_total
	var lookup_hit_ratio: float = (float(_cache_hits_total) / float(lookup_total)) if lookup_total > 0 else 0.0
	var cell_lookup_total: int = _get_cell_hits_total + _get_cell_misses_total
	var cell_hit_ratio: float = (float(_get_cell_hits_total) / float(cell_lookup_total)) if cell_lookup_total > 0 else 0.0
	var prefetch_avg_us: float = float(_prefetch_us_total) / float(_prefetch_calls_total) if _prefetch_calls_total > 0 else 0.0
	var chunk_gen_avg_us: float = float(_chunk_gen_us_total) / float(_cache_misses_total) if _cache_misses_total > 0 else 0.0
	var seam_avg_step: float = _seam_delta_accum / float(_seam_checks_total) if _seam_checks_total > 0 else 0.0
	var seam_anomaly_ratio: float = float(_seam_anomalies_total) / float(_seam_checks_total) if _seam_checks_total > 0 else 0.0
	return {
		"chunks_cached": _chunks.size(),
		"chunk_size": chunk_size,
		"max_chunks": max_chunks,
		"cache_hits_total": _cache_hits_total,
		"cache_misses_total": _cache_misses_total,
		"cache_lookups_total": lookup_total,
		"cache_hit_ratio": lookup_hit_ratio,
		"get_cell_hits_total": _get_cell_hits_total,
		"get_cell_misses_total": _get_cell_misses_total,
		"get_cell_lookups_total": cell_lookup_total,
		"get_cell_hit_ratio": cell_hit_ratio,
		"chunks_generated_total": _generated_total,
		"chunks_generated_last_prefetch": _generated_last_prefetch,
		"chunks_requested_last_prefetch": _requested_last_prefetch,
		"prefetch_calls_total": _prefetch_calls_total,
		"prefetch_requested_total": _prefetch_requested_total,
		"prefetch_generated_total": _prefetch_generated_total,
		"prefetch_us_last": _prefetch_us_last,
		"prefetch_ms_last": float(_prefetch_us_last) / 1000.0,
		"prefetch_us_avg": prefetch_avg_us,
		"prefetch_ms_avg": prefetch_avg_us / 1000.0,
		"prefetch_us_max": _prefetch_us_max,
		"prefetch_ms_max": float(_prefetch_us_max) / 1000.0,
		"chunk_gen_us_last": _chunk_gen_us_last,
		"chunk_gen_ms_last": float(_chunk_gen_us_last) / 1000.0,
		"chunk_gen_us_avg": chunk_gen_avg_us,
		"chunk_gen_ms_avg": chunk_gen_avg_us / 1000.0,
		"chunk_gen_us_max": _chunk_gen_us_max,
		"chunk_gen_ms_max": float(_chunk_gen_us_max) / 1000.0,
		"prefetch_budget_chunks": prefetch_generate_budget_chunks,
		"prefetch_budget_us": prefetch_time_budget_us,
		"chunks_evicted_total": _chunks_evicted_total,
		"seam_checks_total": _seam_checks_total,
		"seam_anomalies_total": _seam_anomalies_total,
		"seam_anomaly_ratio": seam_anomaly_ratio,
		"seam_step_avg": seam_avg_step,
		"seam_step_max": _seam_delta_max,
	}

func set_prefetch_budget(max_generate_chunks: int, budget_time_us: int) -> void:
	prefetch_generate_budget_chunks = max(0, int(max_generate_chunks))
	prefetch_time_budget_us = max(0, int(budget_time_us))

func _collect_prefetch_chunk_keys(min_x: int, max_x: int, min_y: int, max_y: int, cs: int) -> Array:
	var out: Array = []
	var cy0: int = _floor_div_int(min_y, cs)
	var cy1: int = _floor_div_int(max_y, cs)
	var x_ranges: Array = _wrapped_x_ranges(min_x, max_x)
	var seen: Dictionary = {}
	for xr in x_ranges:
		var rr: Vector2i = xr
		var cx0: int = _floor_div_int(rr.x, cs)
		var cx1: int = _floor_div_int(rr.y, cs)
		for cy in range(cy0, cy1 + 1):
			for cx in range(cx0, cx1 + 1):
				var key := Vector2i(cx, cy)
				if seen.has(key):
					continue
				seen[key] = true
				out.append(key)
	return out

func _sort_chunk_keys_by_proximity(keys: Array, center_cx: int, center_cy: int) -> void:
	if keys.size() <= 1:
		return
	var period_x_chunks: int = max(1, int(ceil(float(max(1, int(generator.world_width) * int(generator.region_size))) / float(max(1, chunk_size)))))
	var ordered: Array = []
	for kv in keys:
		if typeof(kv) != TYPE_VECTOR2I:
			continue
		var ck: Vector2i = kv as Vector2i
		var inserted: bool = false
		for i in range(ordered.size()):
			var ov: Variant = ordered[i]
			if typeof(ov) != TYPE_VECTOR2I:
				continue
			var ok: Vector2i = ov as Vector2i
			if _chunk_key_less(ck, ok, center_cx, center_cy, period_x_chunks):
				ordered.insert(i, ck)
				inserted = true
				break
		if not inserted:
			ordered.append(ck)
	keys.clear()
	keys.append_array(ordered)

func _floor_div_int(value: int, divisor: int) -> int:
	var d: int = max(1, int(divisor))
	return int(floor(float(value) / float(d)))

func _chunk_key_less(a: Vector2i, b: Vector2i, center_cx: int, center_cy: int, period_x_chunks: int) -> bool:
	var dax: int = abs(a.x - center_cx)
	dax = min(dax, max(0, period_x_chunks - dax))
	var dbx: int = abs(b.x - center_cx)
	dbx = min(dbx, max(0, period_x_chunks - dbx))
	var da: int = dax + abs(a.y - center_cy)
	var db: int = dbx + abs(b.y - center_cy)
	if da == db:
		if a.y == b.y:
			return a.x < b.x
		return a.y < b.y
	return da < db

func _rect_intersects(
	ax0: int,
	ax1: int,
	ay0: int,
	ay1: int,
	bx0: int,
	bx1: int,
	by0: int,
	by1: int
) -> bool:
	return not (ax1 < bx0 or bx1 < ax0 or ay1 < by0 or by1 < ay0)

func _ensure_chunk(cx: int, cy: int) -> int:
	var key := Vector2i(cx, cy)
	var chunk: Dictionary = _chunks.get(key, {})
	if chunk.is_empty():
		_cache_misses_total += 1
		var t0_us: int = Time.get_ticks_usec()
		chunk = generator.generate_chunk(cx, cy, chunk_size)
		_chunk_gen_us_last = Time.get_ticks_usec() - t0_us
		_chunk_gen_us_total += _chunk_gen_us_last
		_chunk_gen_us_max = max(_chunk_gen_us_max, _chunk_gen_us_last)
		chunk["last_used"] = _tick
		_chunks[key] = chunk
		_generated_total += 1
		_collect_seam_metrics_for_chunk(cx, cy, chunk)
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
		_chunks_evicted_total += 1

func _collect_seam_metrics_for_chunk(cx: int, cy: int, chunk: Dictionary) -> void:
	var left_key := Vector2i(cx - 1, cy)
	if _chunks.has(left_key):
		var left_chunk: Variant = _chunks.get(left_key, {})
		if typeof(left_chunk) == TYPE_DICTIONARY:
			_accumulate_vertical_seam(left_chunk as Dictionary, chunk)
	var up_key := Vector2i(cx, cy - 1)
	if _chunks.has(up_key):
		var up_chunk: Variant = _chunks.get(up_key, {})
		if typeof(up_chunk) == TYPE_DICTIONARY:
			_accumulate_horizontal_seam(up_chunk as Dictionary, chunk)

func _accumulate_vertical_seam(left_chunk: Dictionary, right_chunk: Dictionary) -> void:
	var hl: PackedFloat32Array = left_chunk.get("height_raw", PackedFloat32Array())
	var hr: PackedFloat32Array = right_chunk.get("height_raw", PackedFloat32Array())
	var cs_l: int = int(left_chunk.get("chunk_size", chunk_size))
	var cs_r: int = int(right_chunk.get("chunk_size", chunk_size))
	if cs_l <= 1 or cs_r <= 1:
		return
	var rows: int = min(cs_l, cs_r)
	if hl.size() != cs_l * cs_l or hr.size() != cs_r * cs_r:
		return
	for y in range(rows):
		var idx_l_edge: int = (cs_l - 1) + y * cs_l
		var idx_l_inner: int = (cs_l - 2) + y * cs_l
		var idx_r_edge: int = y * cs_r
		var idx_r_inner: int = 1 + y * cs_r
		var seam_step: float = abs(float(hr[idx_r_edge]) - float(hl[idx_l_edge]))
		var local_l: float = abs(float(hl[idx_l_edge]) - float(hl[idx_l_inner]))
		var local_r: float = abs(float(hr[idx_r_inner]) - float(hr[idx_r_edge]))
		_record_seam_step(seam_step, local_l, local_r)

func _accumulate_horizontal_seam(top_chunk: Dictionary, bottom_chunk: Dictionary) -> void:
	var ht: PackedFloat32Array = top_chunk.get("height_raw", PackedFloat32Array())
	var hb: PackedFloat32Array = bottom_chunk.get("height_raw", PackedFloat32Array())
	var cs_t: int = int(top_chunk.get("chunk_size", chunk_size))
	var cs_b: int = int(bottom_chunk.get("chunk_size", chunk_size))
	if cs_t <= 1 or cs_b <= 1:
		return
	var cols: int = min(cs_t, cs_b)
	if ht.size() != cs_t * cs_t or hb.size() != cs_b * cs_b:
		return
	for x in range(cols):
		var idx_t_edge: int = x + (cs_t - 1) * cs_t
		var idx_t_inner: int = x + (cs_t - 2) * cs_t
		var idx_b_edge: int = x
		var idx_b_inner: int = x + cs_b
		var seam_step: float = abs(float(hb[idx_b_edge]) - float(ht[idx_t_edge]))
		var local_t: float = abs(float(ht[idx_t_edge]) - float(ht[idx_t_inner]))
		var local_b: float = abs(float(hb[idx_b_inner]) - float(hb[idx_b_edge]))
		_record_seam_step(seam_step, local_t, local_b)

func _record_seam_step(seam_step: float, local_a: float, local_b: float) -> void:
	_seam_checks_total += 1
	_seam_delta_accum += seam_step
	_seam_delta_max = max(_seam_delta_max, seam_step)
	var local_baseline: float = max(0.01, (local_a + local_b) * 0.5)
	# Detect abrupt seam jumps that are much larger than surrounding local gradients.
	if seam_step > local_baseline * 2.80 + 0.06:
		_seam_anomalies_total += 1
