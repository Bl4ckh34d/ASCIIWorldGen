# File: res://scripts/systems/HydroUpdateSystem.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")
const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

# Lightweight system to update flow/accumulation/rivers on a cadence.
# Adds a simple tiling scheduler to amortize updates over several ticks.

var generator: Object = null
var tiles_x: int = 4
var tiles_y: int = 4
var tiles_per_tick: int = 2
var _tile_cursor: int = 0
var _river_tex: Object = null
var river_threshold: float = 6.0
const RIVER_STAGE_BUFFER_NAME: String = "river_stage"
const CATCHUP_BOOST_DT1: float = 1.5
const CATCHUP_BOOST_DT2: float = 3.5
const RIVER_FREEZE_C: float = 0.5
const RIVER_THAW_C: float = 2.8

func cleanup() -> void:
	if _river_tex is Object:
		var tex_obj: Object = _river_tex as Object
		if tex_obj.has_method("cleanup"):
			tex_obj.call("cleanup")
		elif tex_obj.has_method("clear"):
			tex_obj.call("clear")
	_river_tex = null
	generator = null
	_tile_cursor = 0

func initialize(gen: Object) -> void:
	generator = gen
	_tile_cursor = 0
	_river_tex = load("res://scripts/systems/RiverTextureCompute.gd").new()

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	# Guard on world presence
	if world == null:
		return {}
	# If FlowCompute supports ROI, process K tiles this tick; else fallback to full refresh
	var w: int = generator.config.width
	var h: int = generator.config.height
	var total_tiles: int = max(1, tiles_x * tiles_y)
	# Keep hydrology work bounded; avoid explosive catch-up bursts.
	var catchup_boost: int = 0
	if dt_days >= CATCHUP_BOOST_DT1:
		catchup_boost = 1
	if dt_days >= CATCHUP_BOOST_DT2:
		catchup_boost = 2
	var ts: float = 1.0
	if world != null and "time_scale" in world:
		ts = max(1.0, float(world.time_scale))
	if ts >= 10000.0:
		catchup_boost += 1
	if ts >= 100000.0:
		catchup_boost += 1
	var k: int = min(total_tiles, max(1, tiles_per_tick + catchup_boost))
	var processed: int = 0
	var river_trace_any: bool = false
	var river_cycle_committed: bool = false
	# GPU-only: ensure compute objects exist
	var flow_compute: Object = generator.ensure_flow_compute() if "ensure_flow_compute" in generator else null
	var river_compute: Object = generator.ensure_river_compute() if "ensure_river_compute" in generator else null
	var river_freeze_compute: Object = generator.ensure_river_freeze_compute() if "ensure_river_freeze_compute" in generator else null
	var gpu_mgr: Object = generator.get_gpu_buffer_manager() if "get_gpu_buffer_manager" in generator else null
	if flow_compute == null or river_compute == null:
		return {}
	while processed < k:
		var cycle_start_now: bool = (_tile_cursor % total_tiles == 0)
		var tindex: int = _tile_cursor % total_tiles
		var tx: int = tindex % tiles_x
		var ty: int = int(floor(float(tindex) / float(max(1, tiles_x))))
		var tile_w: int = int(ceil(float(w) / float(max(1, tiles_x))))
		var tile_h: int = int(ceil(float(h) / float(max(1, tiles_y))))
		var x0: int = tx * tile_w
		var y0: int = ty * tile_h
		var x1: int = min(w, x0 + tile_w)
		var y1: int = min(h, y0 + tile_h)
		var roi := Rect2i(Vector2i(x0, y0), Vector2i(max(0, x1 - x0), max(0, y1 - y0)))
		# Recompute flow over ROI; then retrace rivers
		if "ensure_persistent_buffers" in generator:
			generator.ensure_persistent_buffers(false)
			var height_buf: RID = generator.get_persistent_buffer("height")
			var land_buf: RID = generator.get_persistent_buffer("is_land")
			var dir_buf: RID = generator.get_persistent_buffer("flow_dir")
			var acc_buf: RID = generator.get_persistent_buffer("flow_accum")
			var lake_buf: RID = generator.get_persistent_buffer("lake")
			var river_buf: RID = generator.get_persistent_buffer("river")
			var temp_buf: RID = generator.get_persistent_buffer("temperature")
			var biome_buf: RID = generator.get_persistent_buffer("biome_id")
			var river_stage_buf: RID = RID()
			if "ensure_gpu_storage_buffer" in generator:
				river_stage_buf = generator.ensure_gpu_storage_buffer(RIVER_STAGE_BUFFER_NAME, w * h * 4)
			if not river_stage_buf.is_valid():
				river_stage_buf = river_buf
			if height_buf.is_valid() and land_buf.is_valid() and dir_buf.is_valid() and acc_buf.is_valid() and lake_buf.is_valid() and river_buf.is_valid():
				flow_compute.compute_flow_gpu_buffers(w, h, height_buf, land_buf, true, dir_buf, acc_buf, roi, gpu_mgr)
				var thr: float = river_threshold
				if "last_river_seed_threshold" in generator:
					var last_thr := float(generator.last_river_seed_threshold)
					if last_thr > 0.0:
						thr = last_thr
				if "config" in generator:
					var cfg_thr := float(generator.config.river_threshold)
					if cfg_thr > 0.0:
						thr = max(thr, cfg_thr)
				# Build rivers in a staging buffer and publish only when the full tile cycle completes.
				var clear_now: bool = cycle_start_now
				river_compute.trace_rivers_gpu_buffers(w, h, land_buf, lake_buf, dir_buf, acc_buf, thr, 5, roi, river_stage_buf, clear_now)
				river_trace_any = true
				var cycle_end_now: bool = ((_tile_cursor + 1) % total_tiles == 0)
				if cycle_end_now and river_stage_buf.is_valid() and river_buf.is_valid():
					if river_freeze_compute != null and temp_buf.is_valid() and biome_buf.is_valid():
						river_freeze_compute.apply_gpu_buffers(
							w,
							h,
							river_stage_buf,
							land_buf,
							temp_buf,
							biome_buf,
							float(generator.config.temp_min_c),
							float(generator.config.temp_max_c),
							int(BiomeClassifier.Biome.GLACIER),
							RIVER_FREEZE_C,
							RIVER_THAW_C
						)
					if "dispatch_copy_u32" in generator:
						river_cycle_committed = VariantCastsUtil.to_bool(generator.dispatch_copy_u32(river_stage_buf, river_buf, w * h)) or river_cycle_committed
		processed += 1
		_tile_cursor = (_tile_cursor + 1) % total_tiles
	if river_cycle_committed and _river_tex:
		var river_buf_final: RID = generator.get_persistent_buffer("river")
		if river_buf_final.is_valid():
			var tex: Texture2D = _river_tex.update_from_buffer(w, h, river_buf_final)
			if tex and "set_river_texture_override" in generator:
				generator.set_river_texture_override(tex)
			elif "set_river_texture_override" in generator:
				generator.set_river_texture_override(null)
	var dirty := PackedStringArray(["flow"])
	if river_cycle_committed or (total_tiles <= 1 and river_trace_any):
		dirty.append("river")
	if "update_water_budget_and_sea_solver" in generator:
		var wb: Dictionary = generator.update_water_budget_and_sea_solver(dt_days, world)
		if VariantCastsUtil.to_bool(wb.get("sea_level_changed", false)):
			dirty.append("is_land")
			dirty.append("biome")
	return {
		"dirty_fields": dirty,
		"consumed_days": max(0.0, float(dt_days))
	}
