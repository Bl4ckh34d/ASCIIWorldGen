extends RefCounted

# Biome updater: GPU-only classification and post, with optional cryosphere-only mode.

var generator: Object = null
var _biome_tex: Object = null
var _lava_tex: Object = null
var _blend: Object = null
var _biome_compute: Object = null
var _biome_post_compute: Object = null
var _lithology_compute: Object = null
var _fertility_compute: Object = null
var biome_climate_tau_days: float = 1825.0 # ~5 years for slow biome drift
var biome_transition_tau_days: float = 60.0
var cryosphere_transition_tau_days: float = 8.0
var cryosphere_climate_tau_days: float = 14.0
var biome_transition_max_step: float = 0.45
var cryosphere_transition_max_step: float = 0.8
var ocean_ice_base_thresh_c: float = -9.5
var ocean_ice_wiggle_amp_c: float = 1.1
var _height_min_cache: float = 0.0
var _height_max_cache: float = 1.0
var _height_cache_size: int = -1
var _height_cache_refresh_counter: int = 0
var _transition_epoch: int = 0
const HEIGHT_MINMAX_REFRESH_INTERVAL: int = 24
const CPU_MIRROR_MAX_CELLS: int = 250000
const TEMPORAL_BLEND_MAX_DT_DAYS: float = 2.0
const TEMPORAL_BLEND_MAX_TIME_SCALE: float = 1000.0
const CPU_SYNC_MAX_TIME_SCALE: float = 1000.0
const BIOME_ICE_SHEET_ID: int = 1
const BIOME_GLACIER_ID: int = 24
const FERTILITY_WEATHERING_RATE: float = 0.08
const FERTILITY_HUMUS_RATE: float = 0.05
const FERTILITY_FLOW_SCALE: float = 64.0

var run_full_biome: bool = true
var run_cryosphere: bool = true
var enable_runtime_cpu_mirror_sync: bool = false

func initialize(gen: Object) -> void:
	generator = gen
	_biome_tex = load("res://scripts/systems/BiomeTextureCompute.gd").new()
	_lava_tex = load("res://scripts/systems/LavaTextureCompute.gd").new()
	_blend = load("res://scripts/systems/BiomeClimateBlendCompute.gd").new()
	_biome_compute = load("res://scripts/systems/BiomeCompute.gd").new()
	_biome_post_compute = load("res://scripts/systems/BiomePostCompute.gd").new()
	_lithology_compute = load("res://scripts/systems/LithologyCompute.gd").new()
	_fertility_compute = load("res://scripts/systems/FertilityLithologyCompute.gd").new()

func set_update_modes(full_biome_enabled: bool, cryosphere_enabled: bool) -> void:
	run_full_biome = bool(full_biome_enabled)
	run_cryosphere = bool(cryosphere_enabled)

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	if not run_full_biome and not run_cryosphere:
		return {}
	var w: int = generator.config.width
	var h: int = generator.config.height
	var size: int = w * h
	if generator.last_height.size() != size or generator.last_is_land.size() != size:
		return {}
	if generator.last_temperature.size() != size or generator.last_moisture.size() != size:
		return {}
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)

	var height_buf: RID = generator.get_persistent_buffer("height")
	var land_buf: RID = generator.get_persistent_buffer("is_land")
	var temp_now_buf: RID = generator.get_persistent_buffer("temperature")
	var moist_now_buf: RID = generator.get_persistent_buffer("moisture")
	var slow_temp_buf: RID = generator.get_persistent_buffer("biome_temp")
	var slow_moist_buf: RID = generator.get_persistent_buffer("biome_moist")
	var cryo_temp_buf: RID = generator.get_persistent_buffer("cryo_temp")
	var cryo_moist_buf: RID = generator.get_persistent_buffer("cryo_moist")
	var beach_buf: RID = generator.get_persistent_buffer("beach")
	var desert_buf: RID = generator.get_persistent_buffer("desert_noise")
	var rock_buf: RID = generator.get_persistent_buffer("rock_type")
	var flow_buf: RID = generator.get_persistent_buffer("flow_accum")
	var fertility_buf: RID = generator.get_persistent_buffer("fertility")
	var biome_buf: RID = generator.get_persistent_buffer("biome_id")
	var biome_tmp: RID = generator.get_persistent_buffer("biome_tmp")
	var lake_buf: RID = generator.get_persistent_buffer("lake")
	var lava_buf: RID = generator.get_persistent_buffer("lava")
	if not height_buf.is_valid() or not land_buf.is_valid():
		return {}
	if not biome_buf.is_valid() or not biome_tmp.is_valid():
		return {}
	if not temp_now_buf.is_valid() or not moist_now_buf.is_valid():
		return {}
	if _biome_compute == null:
		_biome_compute = load("res://scripts/systems/BiomeCompute.gd").new()
	if _biome_post_compute == null:
		_biome_post_compute = load("res://scripts/systems/BiomePostCompute.gd").new()
	if _lithology_compute == null:
		_lithology_compute = load("res://scripts/systems/LithologyCompute.gd").new()
	if _fertility_compute == null:
		_fertility_compute = load("res://scripts/systems/FertilityLithologyCompute.gd").new()

	var dt_sim: float = _compute_sim_dt(world, dt_days)
	var allow_cpu_sync: bool = enable_runtime_cpu_mirror_sync and _allow_cpu_mirror_sync(world, size)
	var use_temporal_transition: bool = allow_cpu_sync and _should_use_temporal_transition(world, dt_sim, size)
	var old_biome_bytes: PackedByteArray = PackedByteArray()
	var old_lava_bytes: PackedByteArray = PackedByteArray()
	if use_temporal_transition and "read_persistent_buffer" in generator:
		old_biome_bytes = generator.read_persistent_buffer("biome_id")
		if lava_buf.is_valid():
			old_lava_bytes = generator.read_persistent_buffer("lava")

	var biome_changed: bool = false
	var lava_changed: bool = false
	var lithology_changed: bool = false
	var fertility_changed: bool = false
	var temp_for_cryosphere: RID = temp_now_buf
	var moist_for_cryosphere: RID = moist_now_buf
	# Always keep a smoothed cryosphere climate signal available, even when this
	# instance is running in full-biome mode only. This prevents full biome passes
	# from stripping ice/glacier states between dedicated cryosphere ticks.
	if _blend and cryo_temp_buf.is_valid() and cryo_moist_buf.is_valid():
		var alpha_cryo: float = 0.0
		if dt_sim > 0.0 and cryosphere_climate_tau_days > 0.0:
			alpha_cryo = 1.0 - exp(-dt_sim / max(0.001, cryosphere_climate_tau_days))
		alpha_cryo = clamp(alpha_cryo, 0.0, 1.0)
		if _blend.apply(w, h, temp_now_buf, moist_now_buf, cryo_temp_buf, cryo_moist_buf, alpha_cryo):
			temp_for_cryosphere = cryo_temp_buf
			moist_for_cryosphere = cryo_moist_buf

	if run_full_biome:
		var params := {
			"width": w,
			"height": h,
			"seed": generator.config.rng_seed,
			"freeze_temp_threshold": 0.16,
			"height_scale_m": generator.config.height_scale_m,
			"lapse_c_per_km": 5.5,
			"noise_x_scale": generator.config.noise_x_scale,
			"temp_min_c": generator.config.temp_min_c,
			"temp_max_c": generator.config.temp_max_c,
		}
		params["biome_noise_strength_c"] = 0.8
		params["biome_moist_jitter"] = 0.06
		# Keep biome noise phase stable across ticks to avoid large reclassification jumps.
		params["biome_phase"] = generator.biome_phase if ("biome_phase" in generator) else 0.0
		params["biome_moist_jitter2"] = 0.03
		params["biome_moist_islands"] = 0.35
		params["biome_moist_elev_dry"] = 0.35

		var alpha: float = 0.0
		if dt_sim > 0.0 and biome_climate_tau_days > 0.0:
			alpha = 1.0 - exp(-dt_sim / max(0.001, biome_climate_tau_days))
		alpha = clamp(alpha, 0.0, 1.0)
		var temp_for_classify: RID = temp_now_buf
		var moist_for_classify: RID = moist_now_buf
		if _blend and slow_temp_buf.is_valid() and slow_moist_buf.is_valid():
			if _blend.apply(w, h, temp_now_buf, moist_now_buf, slow_temp_buf, slow_moist_buf, alpha):
				temp_for_classify = slow_temp_buf
				moist_for_classify = slow_moist_buf

		_height_cache_refresh_counter += 1
		if _height_cache_size != size or _height_cache_refresh_counter >= HEIGHT_MINMAX_REFRESH_INTERVAL:
			var min_h := 1e9
			var max_h := -1e9
			for hv in generator.last_height:
				if hv < min_h:
					min_h = hv
				if hv > max_h:
					max_h = hv
			_height_min_cache = min_h
			_height_max_cache = max_h
			_height_cache_size = size
			_height_cache_refresh_counter = 0
		params["min_h"] = _height_min_cache
		params["max_h"] = _height_max_cache

		if rock_buf.is_valid() and biome_tmp.is_valid() and flow_buf.is_valid() and fertility_buf.is_valid() and lava_buf.is_valid():
			var lith_params := {
				"seed": generator.config.rng_seed,
				"noise_x_scale": generator.config.noise_x_scale,
				"min_h": _height_min_cache,
				"max_h": _height_max_cache,
			}
			var ok_lith: bool = _lithology_compute.classify_to_buffer(
				w,
				h,
				height_buf,
				land_buf,
				temp_for_classify,
				moist_for_classify,
				lava_buf,
				desert_buf,
				lith_params,
				biome_tmp
			)
			if ok_lith:
				var ok_fert: bool = _fertility_compute.update_gpu_buffers(
					w,
					h,
					rock_buf,
					biome_tmp,
					biome_buf,
					land_buf,
					moist_for_classify,
					flow_buf,
					lava_buf,
					fertility_buf,
					dt_sim,
					FERTILITY_WEATHERING_RATE,
					FERTILITY_HUMUS_RATE,
					FERTILITY_FLOW_SCALE
				)
				if ok_fert:
					lithology_changed = true
					fertility_changed = true

		var ok_classify: bool = _biome_compute.classify_to_buffer(
			w,
			h,
			height_buf,
			land_buf,
			temp_for_classify,
			moist_for_classify,
			beach_buf,
			desert_buf,
			fertility_buf,
			params,
			biome_buf
		)
		if not ok_classify:
			return {}
		if not lake_buf.is_valid() or not lava_buf.is_valid() or not rock_buf.is_valid():
			return {}
		var ok_post: bool = _biome_post_compute.apply_overrides_and_lava_gpu(
			w,
			h,
			land_buf,
			temp_for_classify,
			moist_for_classify,
			biome_buf,
			lake_buf,
			rock_buf,
			biome_tmp,
			lava_buf,
			generator.config.temp_min_c,
			generator.config.temp_max_c,
			generator.config.lava_temp_threshold_c,
			0.0
		)
		if not ok_post:
			return {}
		lava_changed = true
		# Reapply cryosphere masks after every full-biome pass to avoid
		# periodic ice/glacier popping from cadence mismatch between systems.
		var ok_reapply: bool = _reapply_cryosphere(
			w,
			h,
			biome_tmp,
			biome_buf,
			land_buf,
			height_buf,
			temp_for_cryosphere,
			moist_for_cryosphere
		)
		if not ok_reapply:
			if not _copy_u32_buffer(biome_tmp, biome_buf, size):
				return {}
		if use_temporal_transition:
			var biome_step: float = _compute_transition_fraction(dt_sim, biome_transition_tau_days, biome_transition_max_step)
			biome_changed = _apply_temporal_biome_transition(
				old_biome_bytes,
				old_lava_bytes,
				size,
				biome_step,
				lava_changed
			)
		else:
			# High-speed path: accept full classify/post result and avoid readback blending.
			biome_changed = true
	elif run_cryosphere:
		# Cryosphere-only path: reapply seasonal ice/glacier masks to current biomes.
		if not _copy_u32_buffer(biome_buf, biome_tmp, size):
			return {}
		var ok_reapply_only: bool = _reapply_cryosphere(
			w,
			h,
			biome_tmp,
			biome_buf,
			land_buf,
			height_buf,
			temp_for_cryosphere,
			moist_for_cryosphere
		)
		if not ok_reapply_only:
			if not _copy_u32_buffer(biome_tmp, biome_buf, size):
				return {}
		# Do not stochastic-blend cryosphere-only updates at tiny dt steps (1x speed),
		# otherwise sparse random ice pixels can pop in/out between ticks.
		if use_temporal_transition and old_biome_bytes.size() > 0:
			biome_changed = _did_biome_buffer_change(old_biome_bytes, size)
		else:
			biome_changed = true

	if biome_changed and _biome_tex:
		var btex: Texture2D = _biome_tex.update_from_buffer(w, h, biome_buf)
		if btex and "set_biome_texture_override" in generator:
			generator.set_biome_texture_override(btex)
	if lava_changed and _lava_tex:
		var ltex: Texture2D = _lava_tex.update_from_buffer(w, h, lava_buf)
		if ltex and "set_lava_texture_override" in generator:
			generator.set_lava_texture_override(ltex)
	# Keep CPU-side hover/info arrays aligned with the GPU runtime state.
	if biome_changed and allow_cpu_sync:
		_sync_cpu_biomes_from_gpu(size)
	if lava_changed and allow_cpu_sync:
		_sync_cpu_lava_from_gpu(size)
	if lithology_changed and allow_cpu_sync:
		_sync_cpu_rocks_from_gpu(size)
	if fertility_changed and allow_cpu_sync:
		_sync_cpu_fertility_from_gpu(size)

	var dirty := PackedStringArray()
	if biome_changed:
		dirty.append("biome")
	if lava_changed:
		dirty.append("lava")
	if lithology_changed:
		dirty.append("rock_type")
	if fertility_changed:
		dirty.append("fertility")
	var out := {"consumed_days": dt_sim}
	if dirty.size() > 0:
		out["dirty_fields"] = dirty
	return out

func _compute_sim_dt(_world: Object, dt_days: float) -> float:
	return max(0.0, dt_days)

func _world_time_scale(world: Object) -> float:
	if world != null and "time_scale" in world:
		return max(1.0, float(world.time_scale))
	return 1.0

func _should_use_temporal_transition(world: Object, dt_sim: float, size: int) -> bool:
	if dt_sim <= 0.0 or size <= 0:
		return false
	if size > CPU_MIRROR_MAX_CELLS:
		return false
	if dt_sim > TEMPORAL_BLEND_MAX_DT_DAYS:
		return false
	return _world_time_scale(world) <= TEMPORAL_BLEND_MAX_TIME_SCALE

func _allow_cpu_mirror_sync(world: Object, size: int) -> bool:
	if size <= 0 or size > CPU_MIRROR_MAX_CELLS:
		return false
	return _world_time_scale(world) <= CPU_SYNC_MAX_TIME_SCALE

func _compute_transition_fraction(dt_sim: float, tau_days: float, max_step: float) -> float:
	if dt_sim <= 0.0:
		return 0.0
	if tau_days <= 0.0:
		return clamp(max_step, 0.0, 1.0)
	var raw: float = 1.0 - exp(-dt_sim / max(0.001, tau_days))
	return clamp(raw, 0.0, clamp(max_step, 0.0, 1.0))

func _apply_temporal_biome_transition(
		old_biome_bytes: PackedByteArray,
		old_lava_bytes: PackedByteArray,
		size: int,
		step_fraction: float,
		blend_lava: bool
	) -> bool:
	if generator == null or size <= 0:
		return false
	step_fraction = clamp(step_fraction, 0.0, 1.0)
	if step_fraction >= 0.999:
		return true
	if old_biome_bytes.size() <= 0 or not ("read_persistent_buffer" in generator):
		return true
	var new_biome_bytes: PackedByteArray = generator.read_persistent_buffer("biome_id")
	if new_biome_bytes.size() <= 0:
		return false
	var old_ids: PackedInt32Array = old_biome_bytes.to_int32_array()
	var new_ids: PackedInt32Array = new_biome_bytes.to_int32_array()
	if old_ids.size() != size or new_ids.size() != size:
		return true

	_transition_epoch += 1
	var epoch: int = _transition_epoch
	var hash_seed: int = int(generator.config.rng_seed) ^ 0x6E624EB7
	var merged_ids: PackedInt32Array = old_ids.duplicate()
	var has_target_diff: bool = false
	var changed_any: bool = false
	for i in range(size):
		var old_id: int = old_ids[i]
		var new_id: int = new_ids[i]
		if old_id == new_id:
			continue
		# Cryosphere transitions should be deterministic to avoid visible pixel popping.
		if _is_cryosphere_biome(old_id) or _is_cryosphere_biome(new_id):
			merged_ids[i] = new_id
			changed_any = true
			has_target_diff = true
			continue
		has_target_diff = true
		if _hash01_temporal(i, epoch, hash_seed) < step_fraction:
			merged_ids[i] = new_id
			changed_any = true

	# Restore partial blend into the authoritative biome GPU buffer.
	if "update_persistent_buffer" in generator:
		generator.update_persistent_buffer("biome_id", merged_ids.to_byte_array())

	# Keep lava coherent with temporal biome adoption when full biome pass produced new lava.
	if blend_lava and old_lava_bytes.size() > 0 and "read_persistent_buffer" in generator and "update_persistent_buffer" in generator:
		var new_lava_bytes: PackedByteArray = generator.read_persistent_buffer("lava")
		if new_lava_bytes.size() > 0:
			var old_lava: PackedFloat32Array = old_lava_bytes.to_float32_array()
			var new_lava: PackedFloat32Array = new_lava_bytes.to_float32_array()
			if old_lava.size() == size and new_lava.size() == size:
				var merged_lava: PackedFloat32Array = old_lava.duplicate()
				for li in range(size):
					if old_ids[li] == new_ids[li]:
						merged_lava[li] = new_lava[li]
					elif _hash01_temporal(li, epoch, hash_seed) < step_fraction:
						merged_lava[li] = new_lava[li]
				generator.update_persistent_buffer("lava", merged_lava.to_byte_array())

	if size <= CPU_MIRROR_MAX_CELLS:
		generator.last_biomes = merged_ids

	# If target had no diff, there was no visible biome transition this tick.
	if not has_target_diff:
		return false
	return changed_any

func _hash01_temporal(cell_index: int, epoch: int, hash_seed: int) -> float:
	var n: float = float(cell_index) * 0.61803398875 + float(epoch) * 12.9898 + float(hash_seed) * 0.00137
	var s: float = sin(n) * 43758.5453
	return s - floor(s)

func _is_cryosphere_biome(biome_id: int) -> bool:
	return biome_id == BIOME_ICE_SHEET_ID or biome_id == BIOME_GLACIER_ID

func _did_biome_buffer_change(old_biome_bytes: PackedByteArray, size: int) -> bool:
	if generator == null or size <= 0:
		return false
	if old_biome_bytes.size() <= 0:
		return true
	if not ("read_persistent_buffer" in generator):
		return true
	var new_biome_bytes: PackedByteArray = generator.read_persistent_buffer("biome_id")
	if new_biome_bytes.size() <= 0:
		return false
	if new_biome_bytes.size() != old_biome_bytes.size():
		return true
	return new_biome_bytes != old_biome_bytes

func _reapply_cryosphere(
		w: int,
		h: int,
		biome_in_buf: RID,
		biome_out_buf: RID,
		land_buf: RID,
		height_buf: RID,
		temp_buf: RID,
		moist_buf: RID
	) -> bool:
	if _biome_compute == null:
		return false
	if not ("reapply_cryosphere_to_buffer" in _biome_compute):
		return false
	return _biome_compute.reapply_cryosphere_to_buffer(
		w,
		h,
		biome_in_buf,
		biome_out_buf,
		land_buf,
		height_buf,
		temp_buf,
		moist_buf,
		generator.config.temp_min_c,
		generator.config.temp_max_c,
		generator.config.height_scale_m,
		5.5,
		ocean_ice_base_thresh_c,
		ocean_ice_wiggle_amp_c
	)

func _copy_u32_buffer(src: RID, dst: RID, count: int) -> bool:
	if not src.is_valid() or not dst.is_valid() or count <= 0:
		return false
	if "dispatch_copy_u32" in generator:
		return bool(generator.dispatch_copy_u32(src, dst, count))
	return false

func _sync_cpu_biomes_from_gpu(size: int) -> void:
	if generator == null or size <= 0 or size > CPU_MIRROR_MAX_CELLS:
		return
	if not ("read_persistent_buffer" in generator):
		return
	var bytes: PackedByteArray = generator.read_persistent_buffer("biome_id")
	if bytes.size() <= 0:
		return
	var biomes_cpu: PackedInt32Array = bytes.to_int32_array()
	if biomes_cpu.size() == size:
		generator.last_biomes = biomes_cpu

func _sync_cpu_lava_from_gpu(size: int) -> void:
	if generator == null or size <= 0 or size > CPU_MIRROR_MAX_CELLS:
		return
	if not ("read_persistent_buffer" in generator):
		return
	var bytes: PackedByteArray = generator.read_persistent_buffer("lava")
	if bytes.size() <= 0:
		return
	var lava_f32: PackedFloat32Array = bytes.to_float32_array()
	if lava_f32.size() != size:
		return
	var lava_cpu := PackedByteArray()
	lava_cpu.resize(size)
	for i in range(size):
		lava_cpu[i] = 1 if lava_f32[i] > 0.5 else 0
	generator.last_lava = lava_cpu

func _sync_cpu_rocks_from_gpu(size: int) -> void:
	if generator == null or size <= 0 or size > CPU_MIRROR_MAX_CELLS:
		return
	if not ("read_persistent_buffer" in generator):
		return
	var bytes: PackedByteArray = generator.read_persistent_buffer("rock_type")
	if bytes.size() <= 0:
		return
	var rocks_cpu: PackedInt32Array = bytes.to_int32_array()
	if rocks_cpu.size() == size:
		generator.last_rock_type = rocks_cpu

func _sync_cpu_fertility_from_gpu(size: int) -> void:
	if generator == null or size <= 0 or size > CPU_MIRROR_MAX_CELLS:
		return
	if not ("read_persistent_buffer" in generator):
		return
	var bytes: PackedByteArray = generator.read_persistent_buffer("fertility")
	if bytes.size() <= 0:
		return
	var fert_cpu: PackedFloat32Array = bytes.to_float32_array()
	if fert_cpu.size() == size and "last_fertility" in generator:
		generator.last_fertility = fert_cpu
