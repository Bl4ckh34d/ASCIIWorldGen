# File: res://scripts/systems/HydroUpdateSystem.gd
extends RefCounted

# Lightweight system to update flow/accumulation/rivers on a cadence.
# Adds a simple tiling scheduler to amortize updates over several ticks.

var generator: Object = null
var tiles_x: int = 4
var tiles_y: int = 4
var tiles_per_tick: int = 2
var _tile_cursor: int = 0
var _river_tex: Object = null
var river_threshold: float = 4.0

func initialize(gen: Object) -> void:
	generator = gen
	_tile_cursor = 0
	_river_tex = load("res://scripts/systems/RiverTextureCompute.gd").new()

func tick(_dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	# Guard on world presence
	if world == null:
		return {}
	# If FlowCompute supports ROI, process K tiles this tick; else fallback to full refresh
	var w: int = generator.config.width
	var h: int = generator.config.height
	var total_tiles: int = max(1, tiles_x * tiles_y)
	var k: int = max(1, tiles_per_tick)
	var processed: int = 0
	# GPU-only: ensure compute objects exist
	if generator._flow_compute == null:
		generator._flow_compute = load("res://scripts/systems/FlowCompute.gd").new()
	if generator._river_compute == null:
		generator._river_compute = load("res://scripts/systems/RiverCompute.gd").new()
	var use_gpu_only: bool = ("config" in generator and generator.config.use_gpu_all)
	while processed < k:
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
		if use_gpu_only:
			if "ensure_persistent_buffers" in generator:
				generator.ensure_persistent_buffers(false)
			var height_buf: RID = generator.get_persistent_buffer("height")
			var land_buf: RID = generator.get_persistent_buffer("is_land")
			var dir_buf: RID = generator.get_persistent_buffer("flow_dir")
			var acc_buf: RID = generator.get_persistent_buffer("flow_accum")
			var lake_buf: RID = generator.get_persistent_buffer("lake")
			var river_buf: RID = generator.get_persistent_buffer("river")
			if height_buf.is_valid() and land_buf.is_valid() and dir_buf.is_valid() and acc_buf.is_valid() and lake_buf.is_valid() and river_buf.is_valid():
				generator._flow_compute.compute_flow_gpu_buffers(w, h, height_buf, land_buf, true, dir_buf, acc_buf, roi, generator._gpu_buffer_manager)
				var thr: float = river_threshold
				if "last_river_seed_threshold" in generator:
					var last_thr := float(generator.last_river_seed_threshold)
					if last_thr > 0.0:
						thr = last_thr
				if "config" in generator:
					var cfg_thr := float(generator.config.river_threshold)
					if cfg_thr > 0.0:
						thr = max(thr, cfg_thr)
				generator._river_compute.trace_rivers_gpu_buffers(w, h, land_buf, lake_buf, dir_buf, acc_buf, thr, 5, roi, river_buf)
				if _river_tex:
					var tex: Texture2D = _river_tex.update_from_buffer(w, h, river_buf)
					if tex and "set_river_texture_override" in generator:
						generator.set_river_texture_override(tex)
		else:
			var fc_out: Dictionary = generator._flow_compute.compute_flow(w, h, generator.last_height, generator.last_is_land, true, roi)
			if fc_out.size() > 0:
				generator.last_flow_dir = fc_out.get("flow_dir", generator.last_flow_dir)
				generator.last_flow_accum = fc_out.get("flow_accum", generator.last_flow_accum)
				# Retrace rivers fully for now (cheap enough)
				var forced := PackedInt32Array()
				var thr2: float = river_threshold
				if "last_river_seed_threshold" in generator:
					var last_thr2 := float(generator.last_river_seed_threshold)
					if last_thr2 > 0.0:
						thr2 = last_thr2
				if "config" in generator:
					var cfg_thr2 := float(generator.config.river_threshold)
					if cfg_thr2 > 0.0:
						thr2 = max(thr2, cfg_thr2)
				var rivers: PackedByteArray = generator._river_compute.trace_rivers_roi(w, h, generator.last_is_land, generator.last_lake, generator.last_flow_dir, generator.last_flow_accum, thr2, 5, roi, forced)
				if rivers.size() == w * h:
					generator.last_river = rivers
		processed += 1
		_tile_cursor = (_tile_cursor + 1) % total_tiles
	return {"dirty_fields": PackedStringArray(["flow", "river"]) }
