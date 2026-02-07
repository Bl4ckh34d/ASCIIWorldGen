# File: res://scripts/systems/RainErosionSystem.gd
extends RefCounted

const DistanceTransformCompute = preload("res://scripts/systems/DistanceTransformCompute.gd")
const ContinentalShelfCompute = preload("res://scripts/systems/ContinentalShelfCompute.gd")

# Runtime rainfall-driven erosion.
# Erosion strength is derived from moisture (humidity/rain proxy) and flow concentration.

var generator: Object = null
var _step_counter: int = 0
var _dt_compute: Object = null
var _shelf_compute: Object = null

const _MAX_DT_DAYS: float = 6.0
const _BASE_EROSION_PER_DAY: float = 0.000045
const _MAX_EROSION_PER_DAY: float = 0.0009
const _MOUNTAIN_START_ABOVE_SEA: float = 0.04
const _HEIGHT_MIN: float = -1.0
const _HEIGHT_MAX: float = 2.0
const _NOISE_SPAN: float = 0.36
const _NOISE_BASE: float = 0.82
const _EPS: float = 1e-8

func initialize(gen: Object) -> void:
	generator = gen
	_step_counter = 0
	if _dt_compute == null:
		_dt_compute = DistanceTransformCompute.new()
	if _shelf_compute == null:
		_shelf_compute = ContinentalShelfCompute.new()

func tick(dt_days: float, _world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	var w: int = int(generator.config.width)
	var h: int = int(generator.config.height)
	var size: int = w * h
	if size <= 0:
		return {}
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)

	var heights: PackedFloat32Array = _read_f32_buffer("height", size, generator.last_height)
	var moisture: PackedFloat32Array = _read_f32_buffer("moisture", size, generator.last_moisture)
	var flow_accum: PackedFloat32Array = _read_f32_buffer("flow_accum", size, generator.last_flow_accum)
	var is_land: PackedByteArray = _read_u32_mask_buffer("is_land", size, generator.last_is_land)
	var lake_mask: PackedByteArray = _read_u32_mask_buffer("lake", size, generator.last_lake)
	if heights.size() != size or is_land.size() != size:
		return {}
	if moisture.size() != size:
		moisture.resize(size)
		moisture.fill(0.5)
	if flow_accum.size() != size:
		flow_accum.resize(size)
		flow_accum.fill(0.0)
	if lake_mask.size() != size:
		lake_mask.resize(size)
		lake_mask.fill(0)

	var dt_eff: float = clamp(float(dt_days), 0.0, _MAX_DT_DAYS)
	if dt_eff <= 0.0:
		return {}

	var flow_max: float = _max_land_value(flow_accum, is_land)
	var flow_denom: float = log(max(1.000001, 1.0 + flow_max * 3.0))
	if flow_denom <= _EPS:
		flow_denom = 1.0

	var delta := PackedFloat32Array()
	delta.resize(size)
	delta.fill(0.0)

	var sea_level: float = float(generator.config.sea_level)
	var changed_cells: int = 0
	var land_changed_cells: int = 0

	_step_counter += 1
	var step_seed: int = int(generator.config.rng_seed) ^ (_step_counter * 1013904223)

	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if is_land[i] == 0:
				continue
			if lake_mask[i] != 0:
				continue

			var h0: float = heights[i]
			var above_sea: float = h0 - sea_level
			if above_sea <= -0.005:
				continue

			var best_drop: float = 0.0
			var target_i: int = -1
			var slope_energy: float = 0.0
			var slope_samples: int = 0

			for oy in range(-1, 2):
				for ox in range(-1, 2):
					if ox == 0 and oy == 0:
						continue
					var ny: int = y + oy
					if ny < 0 or ny >= h:
						continue
					var nx: int = (x + ox + w) % w
					var ni: int = nx + ny * w
					var dh: float = h0 - heights[ni]
					if dh > best_drop:
						best_drop = dh
						target_i = ni
					slope_energy += abs(dh)
					slope_samples += 1

			if target_i < 0 or best_drop <= 0.0:
				continue

			var avg_slope: float = slope_energy / float(max(1, slope_samples))
			var slope_drive: float = clamp((best_drop * 0.74 + avg_slope * 0.26 - 0.0007) / 0.06, 0.0, 1.0)
			if slope_drive <= 0.0:
				continue

			var moist: float = clamp(moisture[i], 0.0, 1.0)
			var flow: float = max(0.0, flow_accum[i])
			var flow_drive: float = clamp(log(1.0 + flow * 3.0) / flow_denom, 0.0, 1.0)
			var rain_drive: float = clamp(moist * 0.75 + flow_drive * 0.25, 0.0, 1.0)
			if rain_drive <= 0.02:
				continue

			var mountain_drive: float = 0.6 + 1.4 * clamp((above_sea - _MOUNTAIN_START_ABOVE_SEA) / 0.55, 0.0, 1.0)
			var shape_noise: float = _NOISE_BASE + _NOISE_SPAN * _hash01(i ^ step_seed)

			var erode: float = dt_eff * _BASE_EROSION_PER_DAY * rain_drive * slope_drive * mountain_drive * shape_noise
			var erode_cap: float = min(_MAX_EROSION_PER_DAY * dt_eff, best_drop * 0.42)
			erode = min(erode, erode_cap)
			if erode <= _EPS:
				continue

			delta[i] -= erode

			# Deposit some sediment downslope. Remaining sediment is treated as suspended load.
			if is_land[target_i] != 0:
				var deposit_factor: float = clamp(0.14 + (1.0 - slope_drive) * 0.46, 0.10, 0.65)
				delta[target_i] += erode * deposit_factor

	for ii in range(size):
		var old_h: float = heights[ii]
		var new_h: float = clamp(old_h + delta[ii], _HEIGHT_MIN, _HEIGHT_MAX)
		if abs(new_h - old_h) > _EPS:
			changed_cells += 1
		heights[ii] = new_h

	if changed_cells <= 0:
		return {}

	var new_land := PackedByteArray()
	new_land.resize(size)
	var ocean_count: int = 0
	for li in range(size):
		var lv: int = 1 if heights[li] > sea_level else 0
		new_land[li] = lv
		if lv == 0:
			ocean_count += 1
		if lv != is_land[li]:
			land_changed_cells += 1

	generator.last_height = heights
	generator.last_height_final = heights
	if "update_persistent_buffer" in generator:
		generator.update_persistent_buffer("height", heights.to_byte_array())

	generator.last_is_land = new_land
	generator.last_ocean_fraction = float(ocean_count) / float(max(1, size))
	if "update_persistent_buffer" in generator and "_pack_bytes_to_u32" in generator:
		generator.update_persistent_buffer("is_land", generator._pack_bytes_to_u32(new_land).to_byte_array())

	var dirty := PackedStringArray()
	dirty.append("height")
	dirty.append("is_land")

	if land_changed_cells > 0:
		_recompute_coastal_fields(w, h, heights, new_land)
		dirty.append("shelf")

	return {"dirty_fields": dirty, "consumed_dt": true}

func _read_f32_buffer(name: String, size: int, fallback: PackedFloat32Array) -> PackedFloat32Array:
	if generator == null:
		return fallback
	var out := PackedFloat32Array()
	if "read_persistent_buffer" in generator:
		var bytes: PackedByteArray = generator.read_persistent_buffer(name)
		if bytes.size() > 0:
			out = bytes.to_float32_array()
	if out.size() == size:
		return out
	if fallback.size() == size:
		return fallback.duplicate()
	out.resize(size)
	out.fill(0.0)
	return out

func _read_u32_mask_buffer(name: String, size: int, fallback: PackedByteArray) -> PackedByteArray:
	if generator == null:
		return fallback
	var out := PackedByteArray()
	if "read_persistent_buffer" in generator:
		var bytes: PackedByteArray = generator.read_persistent_buffer(name)
		if bytes.size() > 0:
			var vals: PackedInt32Array = bytes.to_int32_array()
			if vals.size() == size:
				out.resize(size)
				for i in range(size):
					out[i] = 1 if vals[i] != 0 else 0
	if out.size() == size:
		return out
	if fallback.size() == size:
		return fallback.duplicate()
	out.resize(size)
	out.fill(0)
	return out

func _max_land_value(values: PackedFloat32Array, is_land: PackedByteArray) -> float:
	var max_v: float = 0.0
	var size: int = min(values.size(), is_land.size())
	for i in range(size):
		if is_land[i] == 0:
			continue
		if values[i] > max_v:
			max_v = values[i]
	return max_v

func _hash01(n: int) -> float:
	var x: int = n
	x = (x ^ 61) ^ (x >> 16)
	x *= 9
	x = x ^ (x >> 4)
	x *= 0x27d4eb2d
	x = x ^ (x >> 15)
	var p: int = x & 0x7fffffff
	return float(p) / 2147483647.0

func _recompute_coastal_fields(w: int, h: int, heights: PackedFloat32Array, is_land: PackedByteArray) -> void:
	if generator == null:
		return
	var size: int = w * h
	if _dt_compute == null:
		_dt_compute = DistanceTransformCompute.new()
	if _shelf_compute == null:
		_shelf_compute = ContinentalShelfCompute.new()

	var water_dist: PackedFloat32Array = _dt_compute.ocean_distance_to_land(w, h, is_land, true)
	if water_dist.size() == size:
		generator.last_water_distance = water_dist
		generator.last_distance_to_coast = water_dist
		if "update_persistent_buffer" in generator:
			generator.update_persistent_buffer("distance", water_dist.to_byte_array())

	var shore_noise := PackedFloat32Array()
	if "_feature_noise_cache" in generator and generator._feature_noise_cache != null and generator._feature_noise_cache.shore_noise_field.size() == size:
		shore_noise = generator._feature_noise_cache.shore_noise_field
	else:
		shore_noise.resize(size)
		shore_noise.fill(0.5)

	var dist_for_shelf: PackedFloat32Array = water_dist
	if dist_for_shelf.size() != size:
		dist_for_shelf = generator.last_water_distance
	var out_shelf: Dictionary = _shelf_compute.compute(
		w,
		h,
		heights,
		is_land,
		float(generator.config.sea_level),
		dist_for_shelf,
		shore_noise,
		float(generator.config.shallow_threshold),
		float(generator.config.shore_band),
		true,
		float(generator.config.noise_x_scale)
	)
	if out_shelf.is_empty():
		return

	generator.last_turquoise_water = out_shelf.get("turquoise_water", generator.last_turquoise_water)
	generator.last_beach = out_shelf.get("beach", generator.last_beach)
	generator.last_turquoise_strength = out_shelf.get("turquoise_strength", generator.last_turquoise_strength)
	if "update_persistent_buffer" in generator and "_pack_bytes_to_u32" in generator:
		generator.update_persistent_buffer("beach", generator._pack_bytes_to_u32(generator.last_beach).to_byte_array())
