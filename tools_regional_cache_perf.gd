extends SceneTree

# Regional chunk cache perf harness.
# Captures deterministic prefetch/cache-hit metrics for the regional view workload.
#
# Usage:
#   godot --path . --script res://tools_regional_cache_perf.gd

const VariantCasts = preload("res://scripts/core/VariantCasts.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")
const RegionalChunkGenerator = preload("res://scripts/gameplay/RegionalChunkGenerator.gd")
const RegionalChunkCache = preload("res://scripts/gameplay/RegionalChunkCache.gd")

const WORLD_W: int = 275
const WORLD_H: int = 62
const REGION_SIZE: int = 96
const RENDER_W: int = 68 # VIEW_W(64) + 2*VIEW_PAD(2)
const RENDER_H: int = 34 # VIEW_H(30) + 2*VIEW_PAD(2)
const PREFETCH_MARGIN_CHUNKS: int = 1
const CHUNK_SIZE: int = 32
const MAX_CHUNKS: int = 256
const SAMPLE_STEPS: int = 220
const CASE_SEEDS: Array[int] = [1300716004, 7423911]

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

func _bench_seed(seed_value: int) -> Dictionary:
	var biomes: PackedInt32Array = _build_world_biomes(seed_value)
	if biomes.size() != WORLD_W * WORLD_H:
		return {"ok": false, "seed": seed_value, "error": "biomes_missing"}

	var chunk_gen = RegionalChunkGenerator.new()
	chunk_gen.configure(seed_value, WORLD_W, WORLD_H, biomes, REGION_SIZE)
	var cache = RegionalChunkCache.new()
	cache.configure(chunk_gen, CHUNK_SIZE, MAX_CHUNKS)

	var center_x: int = int((WORLD_W * REGION_SIZE) / 2)
	var center_y: int = int((WORLD_H * REGION_SIZE) / 2)
	var period_x: int = WORLD_W * REGION_SIZE
	var max_y: int = WORLD_H * REGION_SIZE - 1

	var prefetch_us_total: int = 0
	var sample_us_total: int = 0
	var generated_total: int = 0
	var cells_sampled: int = 0

	for step in range(SAMPLE_STEPS):
		var half_w: int = int(RENDER_W / 2)
		var half_h: int = int(RENDER_H / 2)
		var origin_x: int = center_x - half_w
		var origin_y: int = center_y - half_h

		var t0: int = Time.get_ticks_usec()
		generated_total += int(cache.prefetch_for_view(origin_x, origin_y, RENDER_W, RENDER_H, PREFETCH_MARGIN_CHUNKS))
		prefetch_us_total += Time.get_ticks_usec() - t0

		var t1: int = Time.get_ticks_usec()
		for sy in range(RENDER_H):
			for sx in range(RENDER_W):
				var gx: int = origin_x + sx
				var gy: int = origin_y + sy
				var cell: Dictionary = cache.get_cell(gx, gy)
				# Touch values so this mirrors render-loop lookup work.
				var _g: int = int(cell.get("ground", 0))
				var _b: int = int(cell.get("biome", 0))
				cells_sampled += 1
		sample_us_total += Time.get_ticks_usec() - t1

		# Deterministic camera drift path.
		center_x += 1
		if step % 48 == 0:
			var dy: int = 2 if int(step / 48) % 2 == 0 else -2
			center_y += dy
		center_x = posmod(center_x, period_x)
		center_y = clamp(center_y, 0, max_y)

	var stats: Dictionary = cache.get_stats()
	var hits: int = int(stats.get("cache_hits_total", 0))
	var misses: int = int(stats.get("cache_misses_total", 0))
	var lookups: int = hits + misses
	var hit_rate: float = (float(hits) / float(lookups) * 100.0) if lookups > 0 else 0.0
	var steps_f: float = float(max(1, SAMPLE_STEPS))
	var prefetch_total_ms: float = float(prefetch_us_total) / 1000.0
	var sample_total_ms: float = float(sample_us_total) / 1000.0

	return {
		"ok": true,
		"seed": seed_value,
		"steps": SAMPLE_STEPS,
		"cells_sampled": cells_sampled,
		"prefetch_generated_total": generated_total,
		"prefetch_total_ms": prefetch_total_ms,
		"prefetch_avg_ms": prefetch_total_ms / steps_f,
		"sample_total_ms": sample_total_ms,
		"sample_avg_ms": sample_total_ms / steps_f,
		"cache_hits_total": hits,
		"cache_misses_total": misses,
		"cache_hit_rate_pct": hit_rate,
		"chunks_cached_end": int(stats.get("chunks_cached", 0)),
		"max_chunks": int(stats.get("max_chunks", MAX_CHUNKS)),
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
		print("[REG-CACHE] seed:%d steps:%d cells:%d prefetch_avg_ms:%.3f sample_avg_ms:%.3f generated:%d hit_rate:%.2f%% hits:%d misses:%d cached:%d/%d" % [
			int(r.get("seed", 0)),
			int(r.get("steps", 0)),
			int(r.get("cells_sampled", 0)),
			float(r.get("prefetch_avg_ms", 0.0)),
			float(r.get("sample_avg_ms", 0.0)),
			int(r.get("prefetch_generated_total", 0)),
			float(r.get("cache_hit_rate_pct", 0.0)),
			int(r.get("cache_hits_total", 0)),
			int(r.get("cache_misses_total", 0)),
			int(r.get("chunks_cached_end", 0)),
			int(r.get("max_chunks", MAX_CHUNKS)),
		])

	if not failures.is_empty():
		for f in failures:
			push_error("[REG-CACHE] " + f)
		quit(1)
		return

	var agg_prefetch_avg_ms: float = 0.0
	var agg_sample_avg_ms: float = 0.0
	var agg_hits: int = 0
	var agg_misses: int = 0
	var agg_generated: int = 0
	for row in rows:
		agg_prefetch_avg_ms += float(row.get("prefetch_avg_ms", 0.0))
		agg_sample_avg_ms += float(row.get("sample_avg_ms", 0.0))
		agg_hits += int(row.get("cache_hits_total", 0))
		agg_misses += int(row.get("cache_misses_total", 0))
		agg_generated += int(row.get("prefetch_generated_total", 0))
	var n: float = float(max(1, rows.size()))
	var agg_rate: float = 0.0
	if (agg_hits + agg_misses) > 0:
		agg_rate = float(agg_hits) / float(agg_hits + agg_misses) * 100.0
	print("[REG-CACHE] aggregate seeds:%d prefetch_avg_ms:%.3f sample_avg_ms:%.3f hit_rate:%.2f%% hits:%d misses:%d generated:%d" % [
		int(rows.size()),
		agg_prefetch_avg_ms / n,
		agg_sample_avg_ms / n,
		agg_rate,
		agg_hits,
		agg_misses,
		agg_generated,
	])
	quit(0)
