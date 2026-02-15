extends SceneTree

# Regional redraw perf harness.
# Benchmarks actual RegionalMap redraw paths (full vs incremental).
#
# Usage:
#   godot --path . --script res://tools_regional_redraw_perf.gd

const VariantCasts = preload("res://scripts/core/VariantCasts.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")
const RegionalMapScript = preload("res://scripts/gameplay/RegionalMap.gd")
const RegionalChunkGenerator = preload("res://scripts/gameplay/RegionalChunkGenerator.gd")
const RegionalChunkCache = preload("res://scripts/gameplay/RegionalChunkCache.gd")
const GpuMapView = preload("res://scripts/gameplay/rendering/GpuMapView.gd")

const WORLD_W: int = 275
const WORLD_H: int = 62
const REGION_SIZE: int = 96
const CHUNK_SIZE: int = 32
const MAX_CHUNKS: int = 256
const RENDER_W: int = 68 # VIEW_W(64) + 2*VIEW_PAD(2)
const RENDER_H: int = 34 # VIEW_H(30) + 2*VIEW_PAD(2)
const SAMPLE_STEPS: int = 220
const CASE_SEEDS: Array[int] = [1300716004, 7423911]

class DummyGpuRenderer:
	extends Control
	func set_world_data_1_override(_tex) -> void:
		pass
	func set_world_data_2_override(_tex) -> void:
		pass
	func set_cloud_texture_override(_tex) -> void:
		pass
	func set_solar_params(_day_of_year, _time_of_day) -> void:
		pass
	func set_fixed_lonlat(_enabled, _fixed_lon, _fixed_phi) -> void:
		pass
	func update_ascii_display(
		_a00 = null, _a01 = null, _a02 = null, _a03 = null, _a04 = null,
		_a05 = null, _a06 = null, _a07 = null, _a08 = null, _a09 = null,
		_a10 = null, _a11 = null, _a12 = null, _a13 = null, _a14 = null,
		_a15 = null, _a16 = null, _a17 = null, _a18 = null, _a19 = null,
		_a20 = null, _a21 = null, _a22 = null, _a23 = null, _a24 = null
	) -> void:
		pass

func _percentile_ms(samples: Array[float], q: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var t: float = clamp(q, 0.0, 1.0)
	var idx: int = int(round(t * float(sorted.size() - 1)))
	idx = clamp(idx, 0, sorted.size() - 1)
	return float(sorted[idx])

func _cleanup_worldgen(gen: Object) -> void:
	if gen == null:
		return
	if gen.has_method("cleanup"):
		gen.call("cleanup")
	elif gen.has_method("clear"):
		gen.call("clear")

func _build_world_biomes(seed_value: int) -> PackedInt32Array:
	var gen = WorldGenerator.new()
	gen.apply_config({
		"seed": str(seed_value),
		"width": WORLD_W,
		"height": WORLD_H,
	})
	var land_mask: PackedByteArray = gen.generate()
	if land_mask.is_empty():
		_cleanup_worldgen(gen)
		return PackedInt32Array()
	var out: PackedInt32Array = gen.last_biomes.duplicate()
	_cleanup_worldgen(gen)
	return out

func _movement_delta(step_idx: int) -> Vector2i:
	# Deterministic path using mostly horizontal 1-cell moves plus periodic vertical shifts.
	if step_idx > 0 and step_idx % 64 == 0:
		var dy_sign: int = 1 if (int(step_idx / 64) % 2 == 0) else -1
		return Vector2i(0, dy_sign)
	if step_idx > 0 and step_idx % 37 == 0:
		var diag_y: int = 1 if (int(step_idx / 37) % 2 == 0) else -1
		return Vector2i(1, diag_y)
	return Vector2i(1, 0)

func _build_centers(start_x: int, start_y: int, steps: int) -> Array[Vector2i]:
	var centers: Array[Vector2i] = []
	var cx: int = start_x
	var cy: int = start_y
	var period_x: int = WORLD_W * REGION_SIZE
	var max_y: int = WORLD_H * REGION_SIZE - 1
	for i in range(max(1, steps)):
		centers.append(Vector2i(cx, cy))
		var d: Vector2i = _movement_delta(i)
		cx = posmod(cx + d.x, period_x)
		cy = clamp(cy + d.y, 0, max_y)
	return centers

func _build_regional_map(seed_value: int, biomes: PackedInt32Array):
	var map = RegionalMapScript.new()
	map.world_width = WORLD_W
	map.world_height = WORLD_H
	map.world_seed_hash = seed_value
	map.world_biome_ids = biomes
	map.world_tile_x = int(WORLD_W / 2)
	map.world_tile_y = int(WORLD_H / 2)
	map.local_x = int(REGION_SIZE / 2)
	map.local_y = int(REGION_SIZE / 2)
	map._chunk_gen = RegionalChunkGenerator.new()
	map._chunk_gen.configure(seed_value, WORLD_W, WORLD_H, biomes, REGION_SIZE)
	map._chunk_cache = RegionalChunkCache.new()
	map._chunk_cache.configure(map._chunk_gen, CHUNK_SIZE, MAX_CHUNKS)
	map._field_cache_valid = false
	map._gpu_view = GpuMapView.new()
	map._gpu_view.configure("bench_%d" % seed_value, RENDER_W, RENDER_H, seed_value)
	map.gpu_map = DummyGpuRenderer.new()
	map.add_child(map.gpu_map)
	return map

func _bench_mode(seed_value: int, biomes: PackedInt32Array, centers: Array[Vector2i], mode: String) -> Dictionary:
	var map = _build_regional_map(seed_value, biomes)
	var redraw_us_total: int = 0
	var fresh_cells_total: int = 0
	var reused_cells_total: int = 0
	var incremental_steps: int = 0
	var full_steps: int = 0
	var fallback_steps: int = 0
	var redraw_ms_samples: Array[float] = []
	var gpu_upload_ms_samples: Array[float] = []
	var gpu_upload_partial_steps: int = 0
	var gpu_upload_full_steps: int = 0
	var ok: bool = true
	var mode_name: String = mode.strip_edges().to_lower()

	for i in range(centers.size()):
		var c: Vector2i = centers[i]
		map._center_gx = c.x
		map._center_gy = c.y
		map._player_gx = float(c.x) + 0.5
		map._player_gy = float(c.y) + 0.5
		var t0: int = Time.get_ticks_usec()
		if mode_name == "incremental":
			if i == 0:
				map._render_view_full()
			else:
				var prev: Vector2i = centers[i - 1]
				if not map._render_view_incremental(prev.x, prev.y):
					fallback_steps += 1
					map._render_view_full()
		else:
			map._render_view_full()
		redraw_us_total += Time.get_ticks_usec() - t0
		var rs: Dictionary = map.get_last_redraw_stats()
		var rendered_mode: String = String(rs.get("mode", ""))
		if rendered_mode == "incremental":
			incremental_steps += 1
		elif rendered_mode == "full":
			full_steps += 1
		else:
			ok = false
		fresh_cells_total += int(rs.get("fresh_cells", 0))
		reused_cells_total += int(rs.get("reused_cells", 0))
		redraw_ms_samples.append(float(rs.get("redraw_ms", 0.0)))
		gpu_upload_ms_samples.append(float(rs.get("gpu_upload_ms", 0.0)))
		var gpu_upload_mode: String = String(rs.get("gpu_upload_mode", ""))
		if gpu_upload_mode == "partial":
			gpu_upload_partial_steps += 1
		elif gpu_upload_mode == "full":
			gpu_upload_full_steps += 1

	var cache_stats: Dictionary = map._chunk_cache.get_stats()
	var hits: int = int(cache_stats.get("cache_hits_total", 0))
	var misses: int = int(cache_stats.get("cache_misses_total", 0))
	var lookups: int = hits + misses
	var hit_rate: float = (100.0 * float(hits) / float(lookups)) if lookups > 0 else 0.0
	var n_steps: int = max(1, centers.size())
	var redraw_total_ms: float = float(redraw_us_total) / 1000.0

	if map._gpu_view != null and "cleanup" in map._gpu_view:
		map._gpu_view.cleanup()
	map._gpu_view = null
	if map.gpu_map != null:
		if map.gpu_map.get_parent() == map:
			map.remove_child(map.gpu_map)
		map.gpu_map.free()
		map.gpu_map = null
	map.free()
	return {
		"ok": ok,
		"mode": mode_name,
		"steps": centers.size(),
		"redraw_total_ms": redraw_total_ms,
		"redraw_avg_ms": redraw_total_ms / float(n_steps),
		"redraw_p50_ms": _percentile_ms(redraw_ms_samples, 0.50),
		"redraw_p95_ms": _percentile_ms(redraw_ms_samples, 0.95),
		"redraw_p99_ms": _percentile_ms(redraw_ms_samples, 0.99),
		"fresh_cells_total": fresh_cells_total,
		"fresh_cells_avg": float(fresh_cells_total) / float(n_steps),
		"reused_cells_total": reused_cells_total,
		"reused_cells_avg": float(reused_cells_total) / float(n_steps),
		"gpu_upload_p50_ms": _percentile_ms(gpu_upload_ms_samples, 0.50),
		"gpu_upload_p95_ms": _percentile_ms(gpu_upload_ms_samples, 0.95),
		"gpu_upload_partial_steps": gpu_upload_partial_steps,
		"gpu_upload_full_steps": gpu_upload_full_steps,
		"incremental_steps": incremental_steps,
		"full_steps": full_steps,
		"fallback_steps": fallback_steps,
		"cache_hits_total": hits,
		"cache_misses_total": misses,
		"cache_hit_rate_pct": hit_rate,
		"chunks_cached_end": int(cache_stats.get("chunks_cached", 0)),
		"chunks_generated_total": int(cache_stats.get("chunks_generated_total", 0)),
	}

func _bench_seed(seed_value: int) -> Dictionary:
	var biomes: PackedInt32Array = _build_world_biomes(seed_value)
	if biomes.size() != WORLD_W * WORLD_H:
		return {"ok": false, "seed": seed_value, "error": "biomes_missing"}
	var start_x: int = int((WORLD_W * REGION_SIZE) / 2)
	var start_y: int = int((WORLD_H * REGION_SIZE) / 2)
	var centers: Array[Vector2i] = _build_centers(start_x, start_y, SAMPLE_STEPS)
	var full_stats: Dictionary = _bench_mode(seed_value, biomes, centers, "full")
	var inc_stats: Dictionary = _bench_mode(seed_value, biomes, centers, "incremental")
	if not VariantCasts.to_bool(full_stats.get("ok", false)):
		return {"ok": false, "seed": seed_value, "error": "full_mode_failed"}
	if not VariantCasts.to_bool(inc_stats.get("ok", false)):
		return {"ok": false, "seed": seed_value, "error": "incremental_mode_failed"}
	var full_avg_ms: float = float(full_stats.get("redraw_avg_ms", 0.0))
	var inc_avg_ms: float = float(inc_stats.get("redraw_avg_ms", 0.0))
	var speedup: float = full_avg_ms / max(0.0001, inc_avg_ms)
	var full_fresh_total: int = int(full_stats.get("fresh_cells_total", 0))
	var inc_fresh_total: int = int(inc_stats.get("fresh_cells_total", 0))
	var fresh_reduction_pct: float = 0.0
	if full_fresh_total > 0:
		fresh_reduction_pct = 100.0 * (1.0 - (float(inc_fresh_total) / float(full_fresh_total)))
	return {
		"ok": true,
		"seed": seed_value,
		"steps": SAMPLE_STEPS,
		"full": full_stats,
		"incremental": inc_stats,
		"speedup": speedup,
		"fresh_reduction_pct": fresh_reduction_pct,
	}

func _init() -> void:
	var failures: PackedStringArray = PackedStringArray()
	var rows: Array[Dictionary] = []
	for seed_value in CASE_SEEDS:
		var r: Dictionary = _bench_seed(seed_value)
		if not VariantCasts.to_bool(r.get("ok", false)):
			failures.append("seed %d: %s" % [seed_value, String(r.get("error", "unknown"))])
			continue
		rows.append(r)
		var full_stats: Dictionary = r.get("full", {})
		var inc_stats: Dictionary = r.get("incremental", {})
		print("[REG-REDRAW] seed:%d steps:%d full_avg_ms:%.3f inc_avg_ms:%.3f speedup:%.2fx fresh_reduction:%.2f%% inc_fresh_avg:%.1f inc_reused_avg:%.1f inc_p95:%.3fms inc_upload_p95:%.3fms inc_upload_partial:%d/%d inc_fallback:%d hit_rate_full:%.2f%% hit_rate_inc:%.2f%%" % [
			int(r.get("seed", 0)),
			int(r.get("steps", 0)),
			float(full_stats.get("redraw_avg_ms", 0.0)),
			float(inc_stats.get("redraw_avg_ms", 0.0)),
			float(r.get("speedup", 0.0)),
			float(r.get("fresh_reduction_pct", 0.0)),
			float(inc_stats.get("fresh_cells_avg", 0.0)),
			float(inc_stats.get("reused_cells_avg", 0.0)),
			float(inc_stats.get("redraw_p95_ms", 0.0)),
			float(inc_stats.get("gpu_upload_p95_ms", 0.0)),
			int(inc_stats.get("gpu_upload_partial_steps", 0)),
			int(inc_stats.get("steps", 0)),
			int(inc_stats.get("fallback_steps", 0)),
			float(full_stats.get("cache_hit_rate_pct", 0.0)),
			float(inc_stats.get("cache_hit_rate_pct", 0.0)),
		])

	if not failures.is_empty():
		for f in failures:
			push_error("[REG-REDRAW] " + f)
		quit(1)
		return

	var agg_full_avg_ms: float = 0.0
	var agg_inc_avg_ms: float = 0.0
	var agg_speedup: float = 0.0
	var agg_fresh_reduction: float = 0.0
	var agg_fallbacks: int = 0
	var agg_inc_fresh_avg: float = 0.0
	var agg_inc_reused_avg: float = 0.0
	var agg_inc_p95_ms: float = 0.0
	var agg_inc_upload_p95_ms: float = 0.0
	var agg_inc_upload_partial: int = 0
	var agg_inc_steps: int = 0
	for row in rows:
		var full_stats: Dictionary = row.get("full", {})
		var inc_stats: Dictionary = row.get("incremental", {})
		agg_full_avg_ms += float(full_stats.get("redraw_avg_ms", 0.0))
		agg_inc_avg_ms += float(inc_stats.get("redraw_avg_ms", 0.0))
		agg_speedup += float(row.get("speedup", 0.0))
		agg_fresh_reduction += float(row.get("fresh_reduction_pct", 0.0))
		agg_fallbacks += int(inc_stats.get("fallback_steps", 0))
		agg_inc_fresh_avg += float(inc_stats.get("fresh_cells_avg", 0.0))
		agg_inc_reused_avg += float(inc_stats.get("reused_cells_avg", 0.0))
		agg_inc_p95_ms += float(inc_stats.get("redraw_p95_ms", 0.0))
		agg_inc_upload_p95_ms += float(inc_stats.get("gpu_upload_p95_ms", 0.0))
		agg_inc_upload_partial += int(inc_stats.get("gpu_upload_partial_steps", 0))
		agg_inc_steps += int(inc_stats.get("steps", 0))
	var n: float = float(max(1, rows.size()))
	print("[REG-REDRAW] aggregate seeds:%d full_avg_ms:%.3f inc_avg_ms:%.3f speedup:%.2fx fresh_reduction:%.2f%% inc_fresh_avg:%.1f inc_reused_avg:%.1f inc_p95:%.3fms inc_upload_p95:%.3fms inc_upload_partial:%d/%d total_fallback:%d" % [
		int(rows.size()),
		agg_full_avg_ms / n,
		agg_inc_avg_ms / n,
		agg_speedup / n,
		agg_fresh_reduction / n,
		agg_inc_fresh_avg / n,
		agg_inc_reused_avg / n,
		agg_inc_p95_ms / n,
		agg_inc_upload_p95_ms / n,
		agg_inc_upload_partial,
		agg_inc_steps,
		agg_fallbacks,
	])
	quit(0)
