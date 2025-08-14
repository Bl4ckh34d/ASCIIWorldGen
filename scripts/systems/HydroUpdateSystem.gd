# File: res://scripts/systems/HydroUpdateSystem.gd
extends RefCounted

# Lightweight system to update flow/accumulation/rivers on a cadence.
# Adds a simple tiling scheduler to amortize updates over several ticks.

var generator: Object = null
var tiles_x: int = 4
var tiles_y: int = 4
var tiles_per_tick: int = 2
var _tile_cursor: int = 0

func initialize(gen: Object) -> void:
	generator = gen
	_tile_cursor = 0

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
		# Recompute flow over ROI; then retrace rivers fully for now
		var fc_out: Dictionary = generator._flow_compute.compute_flow(w, h, generator.last_height, generator.last_is_land, true, roi)
		if fc_out.size() > 0:
			generator.last_flow_dir = fc_out.get("flow_dir", generator.last_flow_dir)
			generator.last_flow_accum = fc_out.get("flow_accum", generator.last_flow_accum)
			# Retrace rivers fully for now (cheap enough)
			if generator._river_compute == null:
				generator._river_compute = load("res://scripts/systems/RiverCompute.gd").new()
			var forced := PackedInt32Array()
			var rivers: PackedByteArray = generator._river_compute.trace_rivers(w, h, generator.last_is_land, generator.last_lake, generator.last_flow_dir, generator.last_flow_accum, 0.97, 5, forced)
			if rivers.size() == w * h:
				generator.last_river = rivers
		processed += 1
		_tile_cursor = (_tile_cursor + 1) % total_tiles
	return {"dirty_fields": PackedStringArray(["flow", "river"]) }


