# File: res://scripts/systems/PlateSystem.gd
extends RefCounted

# Prototype plate tectonics: Voronoi plates with wrap-X, per-plate velocities, and
# small boundary uplift/subsidence. Updates the height field incrementally.

const DistanceTransformCompute = preload("res://scripts/systems/DistanceTransformCompute.gd")
const ContinentalShelfCompute = preload("res://scripts/systems/ContinentalShelfCompute.gd")
const PlateUpdateCompute = preload("res://scripts/systems/PlateUpdateCompute.gd")
const PlateFieldAdvectionCompute = preload("res://scripts/systems/PlateFieldAdvectionCompute.gd")
const TectonicPinholeCleanupCompute = preload("res://scripts/systems/TectonicPinholeCleanupCompute.gd")
const CPU_MIRROR_MAX_CELLS: int = 250000

var generator: Object = null

# Configuration
var num_plates: int = 12
var uplift_rate_per_day: float = 0.0012  # lower convergent uplift to avoid ridge-dominated worlds
var ridge_rate_per_day: float = 0.0005  # divergent ridges are secondary to extensional subsidence
var subsidence_rate_per_day: float = 0.0016 # legacy divergence sink
var transform_roughness_per_day: float = 0.0004
var subduction_rate_per_day: float = 0.0018
var trench_rate_per_day: float = 0.0022
var drift_cells_per_day: float = 0.02
var boundary_band_cells: int = 3
var pinhole_cleanup_enabled: bool = true
var pinhole_min_land_neighbors: int = 8
var pinhole_min_boundary_neighbors: int = 2
var pinhole_uplift_amount: float = 0.0035
var pinhole_max_depth: float = 0.018

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
var _field_advection_compute: Object = null
var _pinhole_cleanup_compute: Object = null
var _cpu_sync_counter: int = 0
var enable_runtime_cpu_mirror_sync: bool = false

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
	_field_advection_compute = PlateFieldAdvectionCompute.new()
	_pinhole_cleanup_compute = TectonicPinholeCleanupCompute.new()

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
	var gpu_ok: bool = false
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)
		var height_buf: RID = generator.get_persistent_buffer("height")
		var height_tmp: RID = generator.get_persistent_buffer("height_tmp")
		var plate_buf: RID = generator.get_persistent_buffer("plate_id")
		var boundary_buf: RID = generator.get_persistent_buffer("plate_boundary")
		var biome_buf: RID = generator.get_persistent_buffer("biome_id")
		var rock_buf: RID = generator.get_persistent_buffer("rock_type")
		var field_tmp_buf: RID = generator.get_persistent_buffer("biome_tmp")
		var lava_buf: RID = generator.get_persistent_buffer("lava")
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
			if not ("dispatch_copy_u32" in generator and bool(generator.dispatch_copy_u32(height_tmp, height_buf, w * h))):
				gpu_ok = false
			# Update land mask buffer from height
			if gpu_ok and _land_mask_compute:
				var land_buf: RID = generator.get_persistent_buffer("is_land")
				if land_buf.is_valid():
					_land_mask_compute.update_from_height(w, h, height_buf, generator.config.sea_level, land_buf)
				if pinhole_cleanup_enabled and lava_buf.is_valid():
					if _pinhole_cleanup_compute == null:
						_pinhole_cleanup_compute = TectonicPinholeCleanupCompute.new()
					var sim_days_seed: int = 0
					if world != null and "simulation_time_days" in world:
						sim_days_seed = int(world.simulation_time_days)
					_pinhole_cleanup_compute.cleanup_gpu_buffers(
						w,
						h,
						height_buf,
						land_buf,
						boundary_buf,
						lava_buf,
						float(generator.config.sea_level),
						pinhole_uplift_amount,
						pinhole_max_depth,
						pinhole_min_land_neighbors,
						pinhole_min_boundary_neighbors,
						int(generator.config.rng_seed) ^ sim_days_seed
					)
		# Advect plate-bound categorical fields so biomes/lithology move with plate drift.
		if gpu_ok and field_tmp_buf.is_valid():
			if _field_advection_compute == null:
				_field_advection_compute = PlateFieldAdvectionCompute.new()
			if biome_buf.is_valid() and _field_advection_compute.advect_i32_gpu_buffers(
				w,
				h,
				biome_buf,
				plate_buf,
				plate_vel_u,
				plate_vel_v,
				dt_days,
				drift_cells_per_day,
				field_tmp_buf
			):
				if not ("dispatch_copy_u32" in generator and bool(generator.dispatch_copy_u32(field_tmp_buf, biome_buf, w * h))):
					gpu_ok = false
			if rock_buf.is_valid() and _field_advection_compute.advect_i32_gpu_buffers(
				w,
				h,
				rock_buf,
				plate_buf,
				plate_vel_u,
				plate_vel_v,
				dt_days,
				drift_cells_per_day,
				field_tmp_buf
			):
				if not ("dispatch_copy_u32" in generator and bool(generator.dispatch_copy_u32(field_tmp_buf, rock_buf, w * h))):
					gpu_ok = false
			# Keep CPU mirrors coherent for systems/UI paths that still read arrays.
			var sync_size: int = w * h
			if enable_runtime_cpu_mirror_sync and "read_persistent_buffer" in generator and _should_sync_cpu_mirror(world, sync_size):
				var biome_bytes: PackedByteArray = generator.read_persistent_buffer("biome_id")
				var biome_i32: PackedInt32Array = biome_bytes.to_int32_array()
				if biome_i32.size() == sync_size and "last_biomes" in generator:
					generator.last_biomes = biome_i32
				var rock_bytes: PackedByteArray = generator.read_persistent_buffer("rock_type")
				var rock_i32: PackedInt32Array = rock_bytes.to_int32_array()
				if rock_i32.size() == sync_size and "last_rock_type" in generator:
					generator.last_rock_type = rock_i32
	if not gpu_ok:
		return {}
	# Expose boundary mask to generator for volcanism coupling
	var boundary_count = 0
	var mask_src: PackedByteArray = boundary_mask_render if boundary_mask_render.size() == w * h else boundary_mask
	var mask_i32 := PackedInt32Array(); mask_i32.resize(w * h)
	for m in range(w * h):
		var val = (1 if mask_src[m] != 0 else 0)
		mask_i32[m] = val
		if val == 1:
			boundary_count += 1
	if "publish_plate_runtime_state" in generator:
		generator.publish_plate_runtime_state(
			PackedInt32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			mask_i32,
			boundary_mask_render,
			boundary_count,
			num_plates
		)
	return {"dirty_fields": PackedStringArray(["height", "is_land", "lava", "shelf", "biome_id", "rock_type"]), "boundary_count": boundary_count}

func _should_sync_cpu_mirror(world: Object, size: int) -> bool:
	if size <= 0 or size > CPU_MIRROR_MAX_CELLS:
		return false
	var ts: float = 1.0
	if world != null and "time_scale" in world:
		ts = max(1.0, float(world.time_scale))
	var interval: int = 1
	if ts >= 100000.0:
		interval = 160
	elif ts >= 10000.0:
		interval = 80
	elif ts >= 1000.0:
		interval = 32
	elif ts >= 100.0:
		interval = 12
	elif ts >= 10.0:
		interval = 4
	_cpu_sync_counter += 1
	if _cpu_sync_counter <= 1:
		return true
	return (_cpu_sync_counter % max(1, interval)) == 0

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
	var half_span: int = max(1, int(floor(float(n) * 0.5)))
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
		# Geologic-scale cadence: mostly slow turners, with rare moderate outliers.
		var fast_turner: bool = rng.randf() < 0.08
		var bias_mag: float = rng.randf_range(6.0e-10, 7.0e-9)
		var amp_mag: float = rng.randf_range(1.2e-9, 1.2e-8)
		if fast_turner:
			bias_mag *= rng.randf_range(1.4, 2.2)
			amp_mag *= rng.randf_range(1.5, 2.4)
		plate_turn_bias_rad_per_day[p] = bias_mag * (-1.0 if rng.randf() < 0.5 else 1.0)
		plate_turn_amp_rad_per_day[p] = amp_mag * (-1.0 if rng.randf() < 0.5 else 1.0)
		# Period range: ~5k to ~50k years (in sim-days) with plate-specific phase.
		plate_turn_freq_cycles_per_day[p] = rng.randf_range(1.0 / 18250000.0, 1.0 / 1825000.0)
		plate_turn_phase[p] = rng.randf_range(-PI, PI)
	cell_plate_id.resize(size)
	boundary_mask.resize(size)
	for i in range(size):
		cell_plate_id[i] = 0
		boundary_mask[i] = 0
	# GPU Voronoi + boundary mask
	if _gpu_update == null:
		_gpu_update = PlateUpdateCompute.new()
	var plate_seed: int = (int(generator.config.rng_seed) ^ 0x6A09E667)
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
		plate_seed,
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
		var mask_i32 := PackedInt32Array()
		mask_i32.resize(size)
		var boundary_count: int = 0
		for bi in range(size):
			var v: int = (1 if boundary_mask[bi] != 0 else 0)
			mask_i32[bi] = v
			if v == 1:
				boundary_count += 1
		if "publish_plate_runtime_state" in generator:
			generator.publish_plate_runtime_state(
				cell_plate_id,
				plate_vel_u,
				plate_vel_v,
				plate_buoyancy,
				mask_i32,
				boundary_mask_render,
				boundary_count,
				num_plates
			)
	# Update GPU buffers for plates/boundaries
	if generator and "ensure_plate_gpu_buffers" in generator:
		var mask_src: PackedByteArray = boundary_mask_render if boundary_mask_render.size() == size else boundary_mask
		generator.ensure_plate_gpu_buffers(cell_plate_id, mask_src)

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
		var dtheta: float = clamp(turn_rate * dt_days, -0.05, 0.05)
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
		if "publish_plate_runtime_state" in generator:
			generator.publish_plate_runtime_state(
				PackedInt32Array(),
				plate_vel_u,
				plate_vel_v,
				PackedFloat32Array(),
				PackedInt32Array(),
				PackedByteArray()
			)

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
				uplift = uplift_rate_per_day * dt_days * approach * 0.72
			elif approach < -0.1:
				# Divergent boundaries: stabilize around a shallow rift floor.
				# This avoids runaway abyssal deepening as plates continue separating.
				var div: float = (-approach) - 0.1
				var land_factor: float = clamp((heights[i] - generator.config.sea_level + 0.02) / 0.35, 0.0, 1.0)
				var rift_target: float = lerp(generator.config.sea_level - 0.16, generator.config.sea_level - 0.08, land_factor)
				var to_target: float = rift_target - heights[i]
				var settle_rate: float = subduction_rate_per_day * dt_days * div * lerp(0.40, 0.26, land_factor)
				uplift = clamp(to_target, -settle_rate, settle_rate)
				uplift += ridge_rate_per_day * dt_days * div * lerp(0.44, 0.16, land_factor)
				var divergence_floor: float = lerp(generator.config.sea_level - 0.24, generator.config.sea_level - 0.12, land_factor)
				if heights[i] + uplift < divergence_floor:
					uplift = divergence_floor - heights[i]
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
	# Divergent stabilization: keep extensional seams narrow and prevent endless deepening.
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
			if div_score > 1.2:
				var land_factor2: float = clamp((heights[i2] - generator.config.sea_level + 0.02) / 0.35, 0.0, 1.0)
				var floor_level: float = lerp(generator.config.sea_level - 0.24, generator.config.sea_level - 0.12, land_factor2)
				var rift_target2: float = lerp(generator.config.sea_level - 0.16, generator.config.sea_level - 0.08, land_factor2)
				var to_target2: float = rift_target2 - heights[i2]
				var settle2: float = subduction_rate_per_day * dt_days * min(1.6, div_score) * lerp(0.30, 0.20, land_factor2)
				heights[i2] = clamp(heights[i2] + clamp(to_target2, -settle2, settle2), floor_level, 2.0)
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
