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
var subsidence_rate_per_day: float = 0.001 # legacy divergence sink
var transform_roughness_per_day: float = 0.0004
var subduction_rate_per_day: float = 0.0016
var trench_rate_per_day: float = 0.0012
var drift_cells_per_day: float = 0.02
var boundary_band_cells: int = 3

# State
var plate_site_x: PackedInt32Array = PackedInt32Array()
var plate_site_y: PackedInt32Array = PackedInt32Array()
var plate_site_weight: PackedFloat32Array = PackedFloat32Array()
var plate_vel_u: PackedFloat32Array = PackedFloat32Array() # per-plate
var plate_vel_v: PackedFloat32Array = PackedFloat32Array() # per-plate
var plate_buoyancy: PackedFloat32Array = PackedFloat32Array() # per-plate (0 oceanic .. 1 continental)
var plate_turn_bias_rad_per_day: PackedFloat32Array = PackedFloat32Array() # signed long-term turning drift
var plate_turn_amp_rad_per_day: PackedFloat32Array = PackedFloat32Array() # oscillatory turning component
var plate_turn_freq_cycles_per_day: PackedFloat32Array = PackedFloat32Array() # per-plate turning tempo
var plate_turn_phase: PackedFloat32Array = PackedFloat32Array()
var cell_plate_id: PackedInt32Array = PackedInt32Array()
var boundary_mask: PackedByteArray = PackedByteArray()
var boundary_mask_render: PackedByteArray = PackedByteArray()

var _dtc: Object = null
var _shelf: Object = null
var _noise: FastNoiseLite
var _boundary_noise: FastNoiseLite
var _gpu_update: Object = null
var _land_mask_compute: Object = null

func initialize(gen: Object) -> void:
	generator = gen
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.02
	_boundary_noise = FastNoiseLite.new()
	_boundary_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_boundary_noise.frequency = 0.08
	if "config" in generator:
		_noise.seed = int(generator.config.rng_seed) ^ 0x517A
		_boundary_noise.seed = int(generator.config.rng_seed) ^ 0xB16B00B5
	_build_plates()
	_dtc = DistanceTransformCompute.new()
	_shelf = ContinentalShelfCompute.new()
	_land_mask_compute = load("res://scripts/systems/LandMaskCompute.gd").new()

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	var w: int = generator.config.width
	var h: int = generator.config.height
	if w * h <= 0:
		return {}
	# Refresh boundary mask lazily if dims changed
	if cell_plate_id.size() != w * h:
		_build_plates()
	_update_plate_direction(dt_days, world)
	# Prefer GPU update if pipeline available
	if _gpu_update == null:
		_gpu_update = PlateUpdateCompute.new()
	var use_gpu_only: bool = ("config" in generator and generator.config.use_gpu_all)
	var gpu_ok: bool = false
	if use_gpu_only and "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)
		var height_buf: RID = generator.get_persistent_buffer("height")
		var height_tmp: RID = generator.get_persistent_buffer("height_tmp")
		var plate_buf: RID = generator.get_persistent_buffer("plate_id")
		var boundary_buf: RID = generator.get_persistent_buffer("plate_boundary")
		if height_buf.is_valid() and height_tmp.is_valid() and plate_buf.is_valid() and boundary_buf.is_valid():
			gpu_ok = _gpu_update.apply_gpu_buffers(
				w, h,
				height_buf,
				plate_buf,
				boundary_buf,
				plate_vel_u,
				plate_vel_v,
				plate_buoyancy,
				dt_days,
				{
					"uplift_rate_per_day": uplift_rate_per_day,
					"ridge_rate_per_day": ridge_rate_per_day,
					"transform_roughness_per_day": transform_roughness_per_day,
					"subduction_rate_per_day": subduction_rate_per_day,
					"trench_rate_per_day": trench_rate_per_day,
					"drift_cells_per_day": drift_cells_per_day,
					"sea_level": float(generator.config.sea_level),
				},
				boundary_band_cells,
				float(Time.get_ticks_msec() % 100000) / 100000.0,
				height_tmp
				)
			if gpu_ok:
				# Copy height_tmp -> height (reuse FlowCompute copy)
				if generator._flow_compute == null:
					generator._flow_compute = load("res://scripts/systems/FlowCompute.gd").new()
				if "_ensure" in generator._flow_compute:
					generator._flow_compute._ensure()
				generator._flow_compute._dispatch_copy_u32(height_tmp, height_buf, w * h)
				# Update land mask buffer from height
				if _land_mask_compute:
					var land_buf: RID = generator.get_persistent_buffer("is_land")
					if land_buf.is_valid():
						_land_mask_compute.update_from_height(w, h, height_buf, generator.config.sea_level, land_buf)
	if not gpu_ok:
		return {}
	# Expose boundary mask to generator for volcanism coupling
	var boundary_count = 0
	if "_plates_boundary_mask_i32" in generator:
		var mask_src: PackedByteArray = boundary_mask_render if boundary_mask_render.size() == w * h else boundary_mask
		# build Int32 mask from ByteArray boundary_mask
		var mask_i32 := PackedInt32Array(); mask_i32.resize(w * h)
		for m in range(w * h): 
			var val = (1 if mask_src[m] != 0 else 0)
			mask_i32[m] = val
			if val == 1: boundary_count += 1
		generator._plates_boundary_mask_i32 = mask_i32
	# Provide render mask (kept crisp; curvature comes from warped Voronoi boundaries)
	if "_plates_boundary_mask_render_u8" in generator:
		generator._plates_boundary_mask_render_u8 = boundary_mask_render
		# Store boundary count for other systems to use
		if "tectonic_stats" not in generator:
			generator.tectonic_stats = {}
		generator.tectonic_stats["boundary_cells"] = boundary_count
		generator.tectonic_stats["total_plates"] = num_plates
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
	plate_site_weight.resize(n)
	plate_vel_u.resize(n)
	plate_vel_v.resize(n)
	plate_buoyancy.resize(n)
	plate_turn_bias_rad_per_day.resize(n)
	plate_turn_amp_rad_per_day.resize(n)
	plate_turn_freq_cycles_per_day.resize(n)
	plate_turn_phase.resize(n)
	var guaranteed_large_idx: int = rng.randi_range(0, max(0, n - 1))
	var half_span: int = max(1, int(n / 2))
	var guaranteed_small_idx: int = (guaranteed_large_idx + half_span) % max(1, n)
	for p in range(n):
		plate_site_x[p] = rng.randi_range(0, max(0, w - 1))
		plate_site_y[p] = rng.randi_range(0, max(0, h - 1))
		var lat: float = abs(float(plate_site_y[p]) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
		var is_cont: bool = rng.randf() < 0.42
		var buoy: float = rng.randf_range(0.58, 0.92) if is_cont else rng.randf_range(0.15, 0.46)
		plate_buoyancy[p] = buoy
		# Smaller weight -> larger Voronoi region.
		# Use a broad distribution so a few major plates coexist with many smaller ones.
		var w_plate: float = 1.0
		if p == guaranteed_large_idx:
			w_plate = rng.randf_range(0.22, 0.46)
		elif p == guaranteed_small_idx:
			w_plate = rng.randf_range(2.00, 3.20)
		else:
			var tier_roll: float = rng.randf()
			if tier_roll < 0.24:
				w_plate = rng.randf_range(0.28, 0.75) # major plates
			elif tier_roll > 0.82:
				w_plate = rng.randf_range(1.45, 2.85) # microplates
			else:
				w_plate = rng.randf_range(0.78, 1.55) # mid-size plates
		# Mild buoyancy influence: buoyant/continental plates tend to be slightly larger.
		w_plate *= (0.90 - (buoy - 0.5) * 0.12)
		plate_site_weight[p] = clamp(w_plate, 0.20, 3.40)
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
		# Per-plate drift-direction evolution profile.
		# Fast outliers change direction noticeably sooner than slow, stable plates.
		var fast_turner: bool = rng.randf() < 0.22
		var bias_mag: float = rng.randf_range(4.0e-7, 4.0e-6)
		var amp_mag: float = rng.randf_range(1.0e-6, 1.2e-5)
		if fast_turner:
			bias_mag *= rng.randf_range(1.6, 3.2)
			amp_mag *= rng.randf_range(1.7, 3.4)
		plate_turn_bias_rad_per_day[p] = bias_mag * (-1.0 if rng.randf() < 0.5 else 1.0)
		plate_turn_amp_rad_per_day[p] = amp_mag * (-1.0 if rng.randf() < 0.5 else 1.0)
		# Period range: ~35 to ~500 years (in sim-days) with plate-specific phase.
		plate_turn_freq_cycles_per_day[p] = rng.randf_range(1.0 / 180000.0, 1.0 / 13000.0)
		plate_turn_phase[p] = rng.randf_range(-PI, PI)
	cell_plate_id.resize(size)
	boundary_mask.resize(size)
	for i in range(size):
		cell_plate_id[i] = 0
		boundary_mask[i] = 0
	# GPU Voronoi + boundary mask
	if _gpu_update == null:
		_gpu_update = PlateUpdateCompute.new()
	var seed: int = (int(generator.config.rng_seed) ^ 0x6A09E667)
	# Stronger, multi-scale warp to avoid straight Voronoi-looking plate seams.
	var warp_strength_cells: float = clamp(float(min(w, h)) * 0.12, 8.0, 28.0)
	var warp_frequency: float = 0.010
	var lat_anisotropy: float = 1.22
	var built: Dictionary = _gpu_update.build_voronoi_and_boundary(
		w,
		h,
		plate_site_x,
		plate_site_y,
		plate_site_weight,
		seed,
		warp_strength_cells,
		warp_frequency,
		lat_anisotropy
	)
	if not built.is_empty():
		var pid: PackedInt32Array = built.get("plate_id", PackedInt32Array())
		var bnd: PackedInt32Array = built.get("boundary_mask", PackedInt32Array())
		if pid.size() == size:
			cell_plate_id = pid
		if bnd.size() == size:
			boundary_mask.resize(size)
			for k in range(size):
				boundary_mask[k] = (1 if bnd[k] != 0 else 0)
	_build_boundary_render_mask(w, h)
	# Expose raw plate fields so terrain generation can use the same tectonic structure.
	if generator:
		if "_plates_cell_id_i32" in generator:
			generator._plates_cell_id_i32 = cell_plate_id.duplicate()
		if "_plates_vel_u" in generator:
			generator._plates_vel_u = plate_vel_u.duplicate()
		if "_plates_vel_v" in generator:
			generator._plates_vel_v = plate_vel_v.duplicate()
		if "_plates_buoyancy" in generator:
			generator._plates_buoyancy = plate_buoyancy.duplicate()
		if "_plates_boundary_mask_i32" in generator:
			var mask_i32 := PackedInt32Array()
			mask_i32.resize(size)
			var boundary_count: int = 0
			for bi in range(size):
				var v: int = (1 if boundary_mask[bi] != 0 else 0)
				mask_i32[bi] = v
				if v == 1:
					boundary_count += 1
			generator._plates_boundary_mask_i32 = mask_i32
			if "tectonic_stats" in generator:
				generator.tectonic_stats["boundary_cells"] = boundary_count
				generator.tectonic_stats["total_plates"] = num_plates
	# Update GPU buffers for plates/boundaries
	if generator and "_gpu_buffer_manager" in generator and generator._gpu_buffer_manager != null:
		var size_bytes := size * 4
		var mask_src: PackedByteArray = boundary_mask_render if boundary_mask_render.size() == size else boundary_mask
		generator._gpu_buffer_manager.ensure_buffer("plate_id", size_bytes, cell_plate_id.to_byte_array())
		generator._gpu_buffer_manager.ensure_buffer("plate_boundary", size_bytes, generator._pack_bytes_to_u32(mask_src).to_byte_array())
	if generator and "_plates_boundary_mask_render_u8" in generator:
		generator._plates_boundary_mask_render_u8 = boundary_mask_render

func _update_plate_direction(dt_days: float, world: Object) -> void:
	if dt_days <= 0.0:
		return
	var n: int = min(
		plate_vel_u.size(),
		min(
			plate_vel_v.size(),
			min(
				plate_turn_bias_rad_per_day.size(),
				min(plate_turn_amp_rad_per_day.size(), min(plate_turn_freq_cycles_per_day.size(), plate_turn_phase.size()))
			)
		)
	)
	if n <= 0:
		return
	var sim_days: float = 0.0
	if world != null and "simulation_time_days" in world:
		sim_days = float(world.simulation_time_days)
	else:
		sim_days = float(Time.get_ticks_msec()) / 1000.0
	var tau: float = PI * 2.0
	for p in range(n):
		var u: float = plate_vel_u[p]
		var v: float = plate_vel_v[p]
		var speed0: float = sqrt(max(1e-9, u * u + v * v))
		var freq: float = max(1.0e-8, plate_turn_freq_cycles_per_day[p])
		var phase: float = plate_turn_phase[p]
		var osc0: float = sin(sim_days * freq * tau + phase)
		var osc1: float = sin(sim_days * freq * tau * 0.47 + phase * 1.83)
		var turn_rate: float = plate_turn_bias_rad_per_day[p] + plate_turn_amp_rad_per_day[p] * (0.70 * osc0 + 0.30 * osc1)
		var dtheta: float = clamp(turn_rate * dt_days, -0.28, 0.28)
		if abs(dtheta) <= 1.0e-9:
			continue
		var cs: float = cos(dtheta)
		var sn: float = sin(dtheta)
		var un: float = u * cs - v * sn
		var vn: float = u * sn + v * cs
		# Keep drift magnitudes stable; only change direction.
		var speed1: float = sqrt(max(1e-9, un * un + vn * vn))
		var sfix: float = speed0 / speed1
		plate_vel_u[p] = un * sfix
		plate_vel_v[p] = vn * sfix
	# Mirror evolved velocities for systems that sample generator plate state.
	if generator:
		if "_plates_vel_u" in generator:
			generator._plates_vel_u = plate_vel_u.duplicate()
		if "_plates_vel_v" in generator:
			generator._plates_vel_v = plate_vel_v.duplicate()

func _build_boundary_render_mask(w: int, h: int) -> void:
	var size: int = w * h
	if size <= 0 or boundary_mask.size() != size:
		return
	boundary_mask_render.resize(size)
	var band: int = max(1, boundary_band_cells)
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if boundary_mask[i] != 0:
				boundary_mask_render[i] = 1
				continue
			var nearest_md: int = band + 1
			for oy in range(-band, band + 1):
				for ox in range(-band, band + 1):
					var md: int = abs(ox) + abs(oy)
					if md == 0 or md > band:
						continue
					var nx: int = x + ox
					var ny: int = y + oy
					if nx < 0:
						nx = w - 1
					elif nx >= w:
						nx = 0
					if ny < 0 or ny >= h:
						continue
					var j: int = nx + ny * w
					if boundary_mask[j] != 0 and md < nearest_md:
						nearest_md = md
			if nearest_md > band:
				boundary_mask_render[i] = 0
				continue
			var t: float = 1.0 - float(nearest_md - 1) / float(max(1, band))
			var n: float = _boundary_noise.get_noise_2d(float(x) * 0.37, float(y) * 0.37) * 0.5 + 0.5
			var keep: float = clamp(t * 0.78 + n * 0.22 - 0.12, 0.0, 1.0)
			boundary_mask_render[i] = (1 if keep > 0.42 else 0)

func _update_boundary_uplift(dt_days: float, w: int, h: int) -> void:
	var size: int = w * h
	if generator.last_height.size() != size:
		return
	var heights: PackedFloat32Array = generator.last_height
	var mask_src: PackedByteArray = boundary_mask_render if boundary_mask_render.size() == size else boundary_mask
	# Adjust along boundary band
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if mask_src[i] == 0:
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
