# File: res://scripts/systems/PlateSystem.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

# Prototype plate tectonics: Voronoi plates with wrap-X, per-plate velocities, and
# small boundary uplift/subsidence. Updates the height field incrementally.

const PlateUpdateCompute = preload("res://scripts/systems/PlateUpdateCompute.gd")
const PlateFieldAdvectionCompute = preload("res://scripts/systems/PlateFieldAdvectionCompute.gd")
const TectonicPinholeCleanupCompute = preload("res://scripts/systems/TectonicPinholeCleanupCompute.gd")
const TerrainRelaxCompute = preload("res://scripts/systems/TerrainRelaxCompute.gd")

var generator: Object = null

# Configuration
var num_plates: int = 12
var randomize_plate_count: bool = true
const RANDOM_PLATE_COUNT_MIN: int = 4
const RANDOM_PLATE_COUNT_MAX: int = 18
var uplift_rate_per_day: float = 0.0012  # lower convergent uplift to avoid ridge-dominated worlds
var ridge_rate_per_day: float = 0.0005  # divergent ridges are secondary to extensional subsidence
var subsidence_rate_per_day: float = 0.0016 # legacy divergence sink
var transform_roughness_per_day: float = 0.0004
var subduction_rate_per_day: float = 0.0018
var trench_rate_per_day: float = 0.00135
var drift_cells_per_day: float = 0.0008
var boundary_band_cells: int = 3
var max_boundary_delta_per_day: float = 0.080
var divergence_response: float = 1.0
var terrain_relax_enabled: bool = true
var terrain_relax_iterations: int = 4
var terrain_relax_rate: float = 0.55
var terrain_relax_max_delta_interior: float = 0.024
var terrain_relax_max_delta_boundary: float = 0.082
var terrain_relax_max_step_per_iter: float = 0.014
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
var boundary_readback_interval_days: float = 60.0
var velocity_min_magnitude: float = 0.25
var velocity_max_magnitude: float = 2.10
var velocity_bias_equator_u: float = -0.70
var velocity_bias_midlat_u: float = 0.50
var velocity_bias_polar_u: float = -0.40
var velocity_meridional_scale: float = 0.30
var velocity_bias_jitter: float = 0.20

var _boundary_noise: FastNoiseLite
var _gpu_update: Object = null
var _land_mask_compute: Object = null
var _field_advection_compute: Object = null
var _pinhole_cleanup_compute: Object = null
var _terrain_relax_compute: Object = null
var _boundary_readback_accum_days: float = 0.0
var _last_hydrology_refresh_marker: int = -1

func _cleanup_if_supported(obj: Variant) -> void:
	if obj == null:
		return
	if obj is Object:
		var ref_obj: Object = obj as Object
		if ref_obj.has_method("cleanup"):
			ref_obj.call("cleanup")
		elif ref_obj.has_method("clear"):
			ref_obj.call("clear")

func cleanup() -> void:
	_cleanup_if_supported(_gpu_update)
	_cleanup_if_supported(_land_mask_compute)
	_cleanup_if_supported(_field_advection_compute)
	_cleanup_if_supported(_pinhole_cleanup_compute)
	_cleanup_if_supported(_terrain_relax_compute)
	_gpu_update = null
	_land_mask_compute = null
	_field_advection_compute = null
	_pinhole_cleanup_compute = null
	_terrain_relax_compute = null
	generator = null
	plate_site_x.clear()
	plate_site_y.clear()
	plate_site_weight.clear()
	plate_vel_u.clear()
	plate_vel_v.clear()
	plate_buoyancy.clear()
	plate_turn_bias_rad_per_day.clear()
	plate_turn_amp_rad_per_day.clear()
	plate_turn_freq_cycles_per_day.clear()
	plate_turn_phase.clear()
	cell_plate_id.clear()
	boundary_mask.clear()
	boundary_mask_render.clear()
	_boundary_readback_accum_days = 0.0
	_last_hydrology_refresh_marker = -1

func initialize(gen: Object) -> void:
	generator = gen
	_apply_velocity_model_from_generator()
	_boundary_noise = FastNoiseLite.new()
	_boundary_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_boundary_noise.frequency = 0.08
	if "config" in generator:
		_boundary_noise.seed = int(generator.config.rng_seed) ^ 0xB16B00B5
	_build_plates()
	_land_mask_compute = load("res://scripts/systems/LandMaskCompute.gd").new()
	_field_advection_compute = PlateFieldAdvectionCompute.new()
	_pinhole_cleanup_compute = TectonicPinholeCleanupCompute.new()
	_terrain_relax_compute = TerrainRelaxCompute.new()

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
	var hydrology_refreshed: bool = false
	var boundary_buf: RID = RID()
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)
		var height_buf: RID = generator.get_persistent_buffer("height")
		var height_tmp: RID = generator.get_persistent_buffer("height_tmp")
		var plate_buf: RID = generator.get_persistent_buffer("plate_id")
		boundary_buf = generator.get_persistent_buffer("plate_boundary")
		var biome_buf: RID = generator.get_persistent_buffer("biome_id")
		var rock_buf: RID = generator.get_persistent_buffer("rock_type")
		var field_tmp_buf: RID = generator.get_persistent_buffer("biome_tmp")
		var lava_buf: RID = generator.get_persistent_buffer("lava")
		if height_buf.is_valid() and height_tmp.is_valid() and plate_buf.is_valid() and boundary_buf.is_valid():
			var tectonic_rates: Dictionary = _build_tectonic_rate_params()
			gpu_ok = _gpu_update.apply_gpu_buffers(
				w, h,
				height_buf,
				plate_buf,
				boundary_buf,
				plate_vel_u,
				plate_vel_v,
				plate_buoyancy,
				dt_days,
				tectonic_rates,
				boundary_band_cells,
				float(Time.get_ticks_msec() % 100000) / 100000.0,
				height_tmp
			)
		if gpu_ok:
			# Copy height_tmp -> height (reuse FlowCompute copy)
			if not ("dispatch_copy_u32" in generator and VariantCastsUtil.to_bool(generator.dispatch_copy_u32(height_tmp, height_buf, w * h))):
				gpu_ok = false
			if gpu_ok and terrain_relax_enabled:
				if _terrain_relax_compute == null:
					_terrain_relax_compute = TerrainRelaxCompute.new()
				var relax_iters: int = clamp(terrain_relax_iterations, 1, 8)
				var in_buf: RID = height_buf
				var out_buf: RID = height_tmp
				for _it in range(relax_iters):
					var relax_ok: bool = _terrain_relax_compute.relax_gpu_buffers(
						w,
						h,
						in_buf,
						out_buf,
						boundary_buf,
						lava_buf,
						float(generator.config.sea_level),
						terrain_relax_max_delta_interior,
						terrain_relax_max_delta_boundary,
						terrain_relax_rate,
						terrain_relax_max_step_per_iter
					)
					if not relax_ok:
						gpu_ok = false
						break
					var tbuf: RID = in_buf
					in_buf = out_buf
					out_buf = tbuf
				if gpu_ok and in_buf != height_buf:
					if not ("dispatch_copy_u32" in generator and VariantCastsUtil.to_bool(generator.dispatch_copy_u32(in_buf, height_buf, w * h))):
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
				if gpu_ok and "apply_ocean_connectivity_gate_runtime" in generator:
					if not VariantCastsUtil.to_bool(generator.apply_ocean_connectivity_gate_runtime()):
						gpu_ok = false
		# Keep categorical plate-linked fields moving with tectonic drift.
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
				if not ("dispatch_copy_u32" in generator and VariantCastsUtil.to_bool(generator.dispatch_copy_u32(field_tmp_buf, biome_buf, w * h))):
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
				if not ("dispatch_copy_u32" in generator and VariantCastsUtil.to_bool(generator.dispatch_copy_u32(field_tmp_buf, rock_buf, w * h))):
					gpu_ok = false
	if gpu_ok:
		hydrology_refreshed = _refresh_hydrology_after_tectonics(world)
	if gpu_ok and boundary_buf.is_valid():
		_boundary_readback_accum_days += max(0.0, dt_days)
		if boundary_readback_interval_days <= 0.0 or _boundary_readback_accum_days >= boundary_readback_interval_days:
			_refresh_boundary_masks_from_gpu(w, h, boundary_buf)
			_boundary_readback_accum_days = 0.0
	if not gpu_ok:
		return {}
	# Expose boundary mask to generator for volcanism coupling
	var boundary_count = 0
	var mask_src: PackedByteArray = _select_boundary_render_source(w, h)
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
	if "register_tectonic_tick_metrics" in generator:
		generator.register_tectonic_tick_metrics(dt_days)
	var dirty := PackedStringArray(["height", "is_land", "lava", "shelf", "biome_id", "rock_type"])
	if hydrology_refreshed:
		dirty.append("flow")
		dirty.append("river")
		dirty.append("lake")
	return {"dirty_fields": dirty, "boundary_count": boundary_count}

func _build_plates() -> void:
	if generator == null:
		return
	var w: int = generator.config.width
	var h: int = generator.config.height
	var size: int = max(0, w * h)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(generator.config.rng_seed) ^ 0xC1A0
	var target_plate_count: int = num_plates
	if randomize_plate_count:
		target_plate_count = rng.randi_range(RANDOM_PLATE_COUNT_MIN, RANDOM_PLATE_COUNT_MAX)
	var n: int = clamp(target_plate_count, 2, 128)
	num_plates = n
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
		var vel: Vector2 = _sample_initial_plate_velocity(lat, rng)
		plate_vel_u[p] = vel.x
		plate_vel_v[p] = vel.y
		# Per-plate drift-direction evolution profile.
		# Multi-year cadence: mostly slow turners, with rare moderate outliers.
		var fast_turner: bool = rng.randf() < 0.08
		var bias_mag: float = rng.randf_range(6.0e-10, 7.0e-9)
		var amp_mag: float = rng.randf_range(1.2e-9, 1.2e-8)
		if fast_turner:
			bias_mag *= rng.randf_range(1.4, 2.2)
			amp_mag *= rng.randf_range(1.5, 2.4)
		plate_turn_bias_rad_per_day[p] = bias_mag * (-1.0 if rng.randf() < 0.5 else 1.0)
		plate_turn_amp_rad_per_day[p] = amp_mag * (-1.0 if rng.randf() < 0.5 else 1.0)
		# Period range: ~5 to ~25 years (in sim-days) with plate-specific phase.
		plate_turn_freq_cycles_per_day[p] = rng.randf_range(1.0 / 9125.0, 1.0 / 1825.0)
		plate_turn_phase[p] = rng.randf_range(-PI, PI)
	cell_plate_id.resize(size)
	boundary_mask.resize(size)
	boundary_mask_render.resize(size)
	for i in range(size):
		cell_plate_id[i] = 0
		boundary_mask[i] = 0
		boundary_mask_render[i] = 0
	# GPU Voronoi + boundary mask
	if _gpu_update == null:
		_gpu_update = PlateUpdateCompute.new()
	var plate_seed: int = (int(generator.config.rng_seed) ^ 0x6A09E667)
	# Stronger, multi-scale warp to avoid straight Voronoi-looking plate seams.
	var warp_strength_cells: float = clamp(float(min(w, h)) * 0.12, 8.0, 28.0)
	var warp_frequency: float = 0.010
	var lat_anisotropy: float = 1.22
	var built_gpu: bool = false
	if generator and "ensure_persistent_buffers" in generator and "ensure_gpu_storage_buffer" in generator:
		generator.ensure_persistent_buffers(false)
		var plate_buf: RID = generator.ensure_gpu_storage_buffer("plate_id", size * 4)
		var boundary_buf: RID = generator.ensure_gpu_storage_buffer("plate_boundary", size * 4)
		if plate_buf.is_valid() and boundary_buf.is_valid():
			built_gpu = _gpu_update.build_voronoi_and_boundary_gpu_buffers(
				w,
				h,
				plate_site_x,
				plate_site_y,
				plate_buf,
				boundary_buf,
				plate_site_weight,
				plate_seed,
				warp_strength_cells,
				warp_frequency,
				lat_anisotropy
			)
			if built_gpu:
				_refresh_boundary_masks_from_gpu(w, h, boundary_buf)
	if not built_gpu:
		push_error("PlateSystem: GPU Voronoi/boundary build failed; plate buffers remain zeroed.")
	# Expose raw plate fields so terrain generation can use the same tectonic structure.
	if generator:
		if "publish_plate_runtime_state" in generator:
			generator.publish_plate_runtime_state(
				PackedInt32Array(),
				plate_vel_u,
				plate_vel_v,
				plate_buoyancy,
				PackedInt32Array(),
				boundary_mask_render,
				0,
				num_plates
			)

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
		var clamped: Vector2 = _clamp_velocity(un * sfix, vn * sfix)
		plate_vel_u[p] = clamped.x
		plate_vel_v[p] = clamped.y
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

func _refresh_hydrology_after_tectonics(world: Object) -> bool:
	if generator == null:
		return false
	var marker: int = _simulation_refresh_marker(world)
	if marker == _last_hydrology_refresh_marker:
		return false
	_last_hydrology_refresh_marker = marker
	if "quick_update_lakes_and_rivers" in generator:
		return VariantCastsUtil.to_bool(generator.quick_update_lakes_and_rivers())
	if "quick_update_flow_rivers" in generator:
		generator.quick_update_flow_rivers()
		return true
	return false

func _simulation_refresh_marker(world: Object) -> int:
	if world != null and "simulation_time_days" in world:
		return int(round(float(world.simulation_time_days) * 1000000.0))
	return int(Time.get_ticks_msec())

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

func _apply_velocity_model_from_generator() -> void:
	if generator == null or not ("config" in generator):
		return
	var cfg: Object = generator.config
	if cfg == null:
		return
	velocity_min_magnitude = max(0.01, float(_cfg_value(cfg, "plate_velocity_min_magnitude", velocity_min_magnitude)))
	velocity_max_magnitude = max(velocity_min_magnitude, float(_cfg_value(cfg, "plate_velocity_max_magnitude", velocity_max_magnitude)))
	velocity_bias_equator_u = float(_cfg_value(cfg, "plate_velocity_bias_equator_u", velocity_bias_equator_u))
	velocity_bias_midlat_u = float(_cfg_value(cfg, "plate_velocity_bias_midlat_u", velocity_bias_midlat_u))
	velocity_bias_polar_u = float(_cfg_value(cfg, "plate_velocity_bias_polar_u", velocity_bias_polar_u))
	velocity_meridional_scale = clamp(float(_cfg_value(cfg, "plate_velocity_meridional_scale", velocity_meridional_scale)), 0.01, 2.0)
	velocity_bias_jitter = clamp(float(_cfg_value(cfg, "plate_velocity_bias_jitter", velocity_bias_jitter)), 0.0, 1.0)
	max_boundary_delta_per_day = clamp(float(_cfg_value(cfg, "plate_max_boundary_delta_per_day", max_boundary_delta_per_day)), 0.001, 0.50)
	divergence_response = clamp(float(_cfg_value(cfg, "plate_divergence_response", divergence_response)), 0.2, 2.5)
	boundary_readback_interval_days = max(0.0, float(_cfg_value(cfg, "plate_boundary_readback_interval_days", boundary_readback_interval_days)))

func _cfg_value(cfg: Object, key: String, fallback: Variant) -> Variant:
	if cfg != null and key in cfg:
		return cfg.get(key)
	return fallback

func _sample_initial_plate_velocity(lat: float, rng: RandomNumberGenerator) -> Vector2:
	var u: float = rng.randf_range(-1.0, 1.0)
	var v: float = rng.randf_range(-1.0, 1.0) * velocity_meridional_scale
	if lat < 0.3:
		u += velocity_bias_equator_u
	elif lat < 0.7:
		u += velocity_bias_midlat_u
	else:
		u += velocity_bias_polar_u
	u += rng.randf_range(-velocity_bias_jitter, velocity_bias_jitter)
	v += rng.randf_range(-velocity_bias_jitter, velocity_bias_jitter) * velocity_meridional_scale
	return _clamp_velocity(u, v)

func _clamp_velocity(u: float, v: float) -> Vector2:
	var mag: float = sqrt(max(1e-9, u * u + v * v))
	var target: float = clamp(mag, velocity_min_magnitude, velocity_max_magnitude)
	var scale: float = target / mag
	return Vector2(u * scale, v * scale)

func _refresh_boundary_masks_from_gpu(w: int, h: int, boundary_buf: RID) -> void:
	if generator == null or not boundary_buf.is_valid() or not ("read_persistent_buffer_region" in generator):
		return
	var size: int = max(0, w * h)
	if size <= 0:
		return
	var bytes: PackedByteArray = generator.read_persistent_buffer_region("plate_boundary", 0, size * 4)
	if bytes.size() < size * 4:
		return
	var boundary_i32: PackedInt32Array = bytes.to_int32_array()
	if boundary_i32.size() < size:
		return
	boundary_mask.resize(size)
	for i in range(size):
		boundary_mask[i] = 1 if boundary_i32[i] != 0 else 0
	_build_boundary_render_mask(w, h)

func _select_boundary_render_source(w: int, h: int) -> PackedByteArray:
	var size: int = max(0, w * h)
	if boundary_mask_render.size() == size and _has_any_nonzero(boundary_mask_render):
		return boundary_mask_render
	if boundary_mask.size() == size:
		return boundary_mask
	var empty := PackedByteArray()
	empty.resize(size)
	return empty

func _has_any_nonzero(mask: PackedByteArray) -> bool:
	for i in range(mask.size()):
		if mask[i] != 0:
			return true
	return false

func _build_tectonic_rate_params() -> Dictionary:
	# Clamp to stable envelopes before handing values to GPU update.
	return {
		"uplift_rate_per_day": clamp(uplift_rate_per_day, 0.0, 0.050),
		"ridge_rate_per_day": clamp(ridge_rate_per_day, 0.0, 0.050),
		"transform_roughness_per_day": clamp(transform_roughness_per_day, 0.0, 0.050),
		"subduction_rate_per_day": clamp(subduction_rate_per_day, 0.0, 0.050),
		"trench_rate_per_day": clamp(trench_rate_per_day, 0.0, 0.050),
		"drift_cells_per_day": clamp(drift_cells_per_day, 0.0, 0.20),
		"sea_level": float(generator.config.sea_level),
		"max_boundary_delta_per_day": clamp(max_boundary_delta_per_day, 0.001, 0.50),
		"divergence_response": clamp(divergence_response, 0.2, 2.5),
	}
