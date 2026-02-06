extends RefCounted

# Biome updater: GPU-only classification and post, with optional cryosphere-only mode.

var generator: Object = null
var _biome_tex: Object = null
var _lava_tex: Object = null
var _blend: Object = null
var _biome_compute: Object = null
var _biome_post_compute: Object = null
var biome_climate_tau_days: float = 1825.0 # ~5 years for slow biome drift
var _last_update_sim_days: float = -1.0
var _height_min_cache: float = 0.0
var _height_max_cache: float = 1.0
var _height_cache_size: int = -1
var _height_cache_refresh_counter: int = 0
const HEIGHT_MINMAX_REFRESH_INTERVAL: int = 24
const CPU_MIRROR_MAX_CELLS: int = 250000

var run_full_biome: bool = true
var run_cryosphere: bool = true

func initialize(gen: Object) -> void:
	generator = gen
	_biome_tex = load("res://scripts/systems/BiomeTextureCompute.gd").new()
	_lava_tex = load("res://scripts/systems/LavaTextureCompute.gd").new()
	_blend = load("res://scripts/systems/BiomeClimateBlendCompute.gd").new()
	_biome_compute = load("res://scripts/systems/BiomeCompute.gd").new()
	_biome_post_compute = load("res://scripts/systems/BiomePostCompute.gd").new()

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
	var use_gpu_only: bool = ("config" in generator and generator.config.use_gpu_all)
	if not use_gpu_only:
		return {}
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)

	var height_buf: RID = generator.get_persistent_buffer("height")
	var land_buf: RID = generator.get_persistent_buffer("is_land")
	var temp_now_buf: RID = generator.get_persistent_buffer("temperature")
	var moist_now_buf: RID = generator.get_persistent_buffer("moisture")
	var slow_temp_buf: RID = generator.get_persistent_buffer("biome_temp")
	var slow_moist_buf: RID = generator.get_persistent_buffer("biome_moist")
	var beach_buf: RID = generator.get_persistent_buffer("beach")
	var desert_buf: RID = generator.get_persistent_buffer("desert_noise")
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

	var biome_changed: bool = false
	var lava_changed: bool = false

	if run_full_biome:
		var dt_sim: float = dt_days
		if world != null and "simulation_time_days" in world:
			var cur_days: float = float(world.simulation_time_days)
			if _last_update_sim_days >= 0.0:
				dt_sim = max(0.0, cur_days - _last_update_sim_days)
			_last_update_sim_days = cur_days
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

		var ok_classify: bool = _biome_compute.classify_to_buffer(
			w,
			h,
			height_buf,
			land_buf,
			temp_for_classify,
			moist_for_classify,
			beach_buf,
			desert_buf,
			params,
			biome_buf
		)
		if not ok_classify:
			return {}
		if not lake_buf.is_valid() or not lava_buf.is_valid():
			return {}
		var ok_post: bool = _biome_post_compute.apply_overrides_and_lava_gpu(
			w,
			h,
			land_buf,
			temp_for_classify,
			moist_for_classify,
			biome_buf,
			lake_buf,
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
		if run_cryosphere:
			var ok_reapply: bool = _reapply_cryosphere(
				w,
				h,
				biome_tmp,
				biome_buf,
				land_buf,
				height_buf,
				temp_now_buf,
				moist_now_buf
			)
			if not ok_reapply:
				if not _copy_u32_buffer(biome_tmp, biome_buf, size):
					return {}
		else:
			if not _copy_u32_buffer(biome_tmp, biome_buf, size):
				return {}
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
			temp_now_buf,
			moist_now_buf
		)
		if not ok_reapply_only:
			if not _copy_u32_buffer(biome_tmp, biome_buf, size):
				return {}
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
	if biome_changed:
		_sync_cpu_biomes_from_gpu(size)
	if lava_changed:
		_sync_cpu_lava_from_gpu(size)

	var dirty := PackedStringArray()
	if biome_changed:
		dirty.append("biome")
	if lava_changed:
		dirty.append("lava")
	if dirty.size() == 0:
		return {}
	return {"dirty_fields": dirty}

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
		-10.0,
		1.0
	)

func _copy_u32_buffer(src: RID, dst: RID, count: int) -> bool:
	if not src.is_valid() or not dst.is_valid() or count <= 0:
		return false
	if generator._flow_compute == null:
		generator._flow_compute = load("res://scripts/systems/FlowCompute.gd").new()
	if generator._flow_compute == null:
		return false
	if "_ensure" in generator._flow_compute:
		generator._flow_compute._ensure()
	if not ("_dispatch_copy_u32" in generator._flow_compute):
		return false
	generator._flow_compute._dispatch_copy_u32(src, dst, count)
	return true

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
