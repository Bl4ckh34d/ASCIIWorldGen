# File: res://scripts/systems/PlateSystem.gd
extends RefCounted

# Prototype plate tectonics: Voronoi plates with wrap-X, per-plate velocities, and
# small boundary uplift/subsidence. Updates the height field incrementally.

const DistanceTransformCompute = preload("res://scripts/systems/DistanceTransformCompute.gd")
const ContinentalShelfCompute = preload("res://scripts/systems/ContinentalShelfCompute.gd")
const PlateUpdateCompute = preload("res://scripts/systems/PlateUpdateCompute.gd")

var generator: Object = null

# Configuration
var num_plates: int = 12
var uplift_rate_per_day: float = 0.002  # normalized height units per day at convergent boundaries
var ridge_rate_per_day: float = 0.0008  # divergent ridges (lower than convergent)
var subsidence_rate_per_day: float = 0.001 # divergent central trough
var transform_roughness_per_day: float = 0.0004
var boundary_band_cells: int = 1

# State
var plate_site_x: PackedInt32Array = PackedInt32Array()
var plate_site_y: PackedInt32Array = PackedInt32Array()
var plate_vel_u: PackedFloat32Array = PackedFloat32Array() # per-plate
var plate_vel_v: PackedFloat32Array = PackedFloat32Array() # per-plate
var cell_plate_id: PackedInt32Array = PackedInt32Array()
var boundary_mask: PackedByteArray = PackedByteArray()

var _dtc: Object = null
var _shelf: Object = null
var _noise: FastNoiseLite
var _gpu_update: Object = null

func initialize(gen: Object) -> void:
	generator = gen
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.02
	if "config" in generator:
		_noise.seed = int(generator.config.rng_seed) ^ 0x517A
	_build_plates()
	_dtc = DistanceTransformCompute.new()
	_shelf = ContinentalShelfCompute.new()

func tick(dt_days: float, _world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	var w: int = generator.config.width
	var h: int = generator.config.height
	if w * h <= 0:
		return {}
	# Refresh boundary mask lazily if dims changed
	if cell_plate_id.size() != w * h:
		_build_plates()
	# Prefer GPU update if pipeline available
	if _gpu_update == null:
		_gpu_update = PlateUpdateCompute.new()
	var updated: PackedFloat32Array
	updated = _gpu_update.apply(
		w, h,
		generator.last_height,
		cell_plate_id,
		boundary_mask,
		plate_vel_u,
		plate_vel_v,
		dt_days,
		{
			"uplift_rate_per_day": uplift_rate_per_day,
			"ridge_rate_per_day": ridge_rate_per_day,
			"transform_roughness_per_day": transform_roughness_per_day,
		},
		boundary_band_cells,
		float(Time.get_ticks_msec() % 100000) / 100000.0
	)
	if updated.size() == w * h:
		generator.last_height = updated
		generator.last_height_final = updated
	else:
		# Fallback CPU path
		_update_boundary_uplift(dt_days, w, h)
	# Expose boundary mask to generator for volcanism coupling
	var boundary_count = 0
	if "_plates_boundary_mask_i32" in generator:
		# build Int32 mask from ByteArray boundary_mask
		var mask_i32 := PackedInt32Array(); mask_i32.resize(w * h)
		for m in range(w * h): 
			var val = (1 if boundary_mask[m] != 0 else 0)
			mask_i32[m] = val
			if val == 1: boundary_count += 1
		generator._plates_boundary_mask_i32 = mask_i32
		# Store boundary count for other systems to use
		if "tectonic_stats" not in generator:
			generator.tectonic_stats = {}
		generator.tectonic_stats["boundary_cells"] = boundary_count
		generator.tectonic_stats["total_plates"] = num_plates
	_recompute_land_and_shelf(w, h)
	return {"dirty_fields": PackedStringArray(["height", "is_land", "shelf"]), "boundary_count": boundary_count}

func _build_plates() -> void:
	if generator == null:
		return
	var w: int = generator.config.width
	var h: int = generator.config.height
	var size: int = max(0, w * h)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(generator.config.rng_seed) ^ 0xC1A0
	var n: int = clamp(num_plates, 2, 128)
	plate_site_x.resize(n)
	plate_site_y.resize(n)
	plate_vel_u.resize(n)
	plate_vel_v.resize(n)
	for p in range(n):
		plate_site_x[p] = rng.randi_range(0, max(0, w - 1))
		plate_site_y[p] = rng.randi_range(0, max(0, h - 1))
		var lat: float = abs(float(plate_site_y[p]) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
		var u: float = (rng.randf() * 2.0 - 1.0)
		var v: float = (rng.randf() * 2.0 - 1.0) * 0.3
		if lat < 0.3:
			u -= 0.7
		elif lat < 0.7:
			u += 0.5
		else:
			u -= 0.4
		plate_vel_u[p] = u
		plate_vel_v[p] = v
	cell_plate_id.resize(size)
	boundary_mask.resize(size)
	for i in range(size):
		cell_plate_id[i] = 0
		boundary_mask[i] = 0
	# GPU Voronoi + boundary mask
	if _gpu_update == null:
		_gpu_update = PlateUpdateCompute.new()
	var built: Dictionary = _gpu_update.build_voronoi_and_boundary(w, h, plate_site_x, plate_site_y)
	if not built.is_empty():
		var pid: PackedInt32Array = built.get("plate_id", PackedInt32Array())
		var bnd: PackedInt32Array = built.get("boundary_mask", PackedInt32Array())
		if pid.size() == size:
			cell_plate_id = pid
		if bnd.size() == size:
			boundary_mask.resize(size)
			for k in range(size):
				boundary_mask[k] = (1 if bnd[k] != 0 else 0)

func _update_boundary_uplift(dt_days: float, w: int, h: int) -> void:
	var size: int = w * h
	if generator.last_height.size() != size:
		return
	var heights: PackedFloat32Array = generator.last_height
	# Adjust along boundary band
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if boundary_mask[i] == 0:
				continue
			var pid: int = cell_plate_id[i]
			# Look at one neighbor of different plate to get boundary normal approx
			var found: bool = false
			var nx_sel: int = x
			var ny_sel: int = y
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if abs(dx) + abs(dy) != 1: continue
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0: nx = w - 1
					elif nx >= w: nx = 0
					if ny < 0 or ny >= h: continue
					var j: int = nx + ny * w
					if cell_plate_id[j] != pid:
						nx_sel = nx
						ny_sel = ny
						found = true
						break
				if found: break
			var dirx: float = float(nx_sel - x)
			# wrap direction X shortest path
			if dirx > float(w) * 0.5: dirx -= float(w)
			elif dirx < -float(w) * 0.5: dirx += float(w)
			var diry: float = float(ny_sel - y)
			var dist_len: float = max(0.0001, sqrt(dirx * dirx + diry * diry))
			dirx /= dist_len; diry /= dist_len
			var p_other: int = cell_plate_id[nx_sel + ny_sel * w]
			var u1: float = plate_vel_u[pid]
			var v1: float = plate_vel_v[pid]
			var u2: float = plate_vel_u[p_other]
			var v2: float = plate_vel_v[p_other]
			var rel_u: float = u2 - u1
			var rel_v: float = v2 - v1
			var approach: float = -(rel_u * dirx + rel_v * diry) # positive when converging
			var uplift: float = 0.0
			if approach > 0.1:
				uplift = uplift_rate_per_day * dt_days * approach
			elif approach < -0.1:
				# divergent: ridge uplift smaller + subsidence around
				uplift = ridge_rate_per_day * dt_days * (-approach)
			else:
				# transform shear roughness
				uplift = transform_roughness_per_day * dt_days * (_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5 - 0.5)
			# Apply uplift band to current cell and immediate neighbors for continuity
			for by in range(-boundary_band_cells, boundary_band_cells + 1):
				for bx in range(-boundary_band_cells, boundary_band_cells + 1):
					if abs(bx) + abs(by) > boundary_band_cells: continue
					var xx: int = x + bx
					var yy: int = y + by
					if xx < 0: xx = w - 1
					elif xx >= w: xx = 0
					if yy < 0 or yy >= h: continue
					var ii: int = xx + yy * w
					heights[ii] = clamp(heights[ii] + uplift, -1.0, 2.0)
	# Divergent subsidence: apply gentle lowering at cells where strong divergence
	for y2 in range(h):
		for x2 in range(w):
			var i2: int = x2 + y2 * w
			if boundary_mask[i2] == 0:
				continue
			var pid2: int = cell_plate_id[i2]
			var _u1b: float = plate_vel_u[pid2]
			var _v1b: float = plate_vel_v[pid2]
			var div_score: float = 0.0
			# approximate local divergence by opposite neighbors
			var xm: int = (x2 - 1 + w) % w
			var xp: int = (x2 + 1) % w
			var ym: int = max(0, y2 - 1)
			var yp: int = min(h - 1, y2 + 1)
			var pid_l: int = cell_plate_id[xm + y2 * w]
			var pid_r: int = cell_plate_id[xp + y2 * w]
			var pid_t: int = cell_plate_id[x2 + ym * w]
			var pid_b: int = cell_plate_id[x2 + yp * w]
			if pid_l != pid2: div_score += (plate_vel_u[pid2] - plate_vel_u[pid_l])
			if pid_r != pid2: div_score -= (plate_vel_u[pid2] - plate_vel_u[pid_r])
			if pid_t != pid2: div_score += (plate_vel_v[pid2] - plate_vel_v[pid_t])
			if pid_b != pid2: div_score -= (plate_vel_v[pid2] - plate_vel_v[pid_b])
			if div_score > 0.8:
				heights[i2] = clamp(heights[i2] - subsidence_rate_per_day * dt_days * min(2.0, div_score), -1.0, 2.0)
	# Commit height changes
	generator.last_height = heights
	generator.last_height_final = heights

func _recompute_land_and_shelf(w: int, h: int) -> void:
	# Update is_land from height vs sea level and recompute shoreline features
	var size: int = w * h
	if generator.last_is_land.size() != size:
		generator.last_is_land.resize(size)
	for i in range(size):
		generator.last_is_land[i] = 1 if generator.last_height[i] > generator.config.sea_level else 0
	# Ocean fraction
	var ocean_ct: int = 0
	for ii in range(size): if generator.last_is_land[ii] == 0: ocean_ct += 1
	generator.last_ocean_fraction = float(ocean_ct) / float(max(1, size))
	# Distance to coast (GPU if available)
	if _dtc == null:
		_dtc = DistanceTransformCompute.new()
	var d_gpu: PackedFloat32Array = _dtc.ocean_distance_to_land(w, h, generator.last_is_land, true)
	if d_gpu.size() == size:
		generator.last_water_distance = d_gpu
	# Shelf features (GPU compute)
	if _shelf == null:
		_shelf = ContinentalShelfCompute.new()
	var shore_noise_field := PackedFloat32Array(); shore_noise_field.resize(size)
	for y in range(h):
		for x in range(w):
			var i2: int = x + y * w
			shore_noise_field[i2] = 0.5
	var out_gpu: Dictionary = _shelf.compute(w, h, generator.last_height, generator.last_is_land, generator.config.sea_level, generator.last_water_distance, shore_noise_field, generator.config.shallow_threshold, generator.config.shore_band, true, generator.config.noise_x_scale)
	if out_gpu.size() > 0:
		generator.last_turquoise_water = out_gpu.get("turquoise_water", generator.last_turquoise_water)
		generator.last_beach = out_gpu.get("beach", generator.last_beach)
		generator.last_turquoise_strength = out_gpu.get("turquoise_strength", generator.last_turquoise_strength)
