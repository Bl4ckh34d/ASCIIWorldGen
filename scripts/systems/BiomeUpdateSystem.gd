extends RefCounted

# Biome updater: GPU-only classification and post, on its own cadence.

var generator: Object = null
var _biome_tex: Object = null
var _lava_tex: Object = null
var _blend: Object = null
var biome_climate_tau_days: float = 1825.0 # ~5 years for slow biome drift
var _last_update_sim_days: float = -1.0

func initialize(gen: Object) -> void:
	generator = gen
	_biome_tex = load("res://scripts/systems/BiomeTextureCompute.gd").new()
	_lava_tex = load("res://scripts/systems/LavaTextureCompute.gd").new()
	_blend = load("res://scripts/systems/BiomeClimateBlendCompute.gd").new()

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	var dt_sim: float = dt_days
	if world != null and "simulation_time_days" in world:
		var cur_days: float = float(world.simulation_time_days)
		if _last_update_sim_days >= 0.0:
			dt_sim = max(0.0, cur_days - _last_update_sim_days)
		_last_update_sim_days = cur_days
	var w: int = generator.config.width
	var h: int = generator.config.height
	var size: int = w * h
	if generator.last_height.size() != size or generator.last_is_land.size() != size:
		return {}
	if generator.last_temperature.size() != size or generator.last_moisture.size() != size:
		return {}
	# Classify (GPU)
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
	var use_gpu_only: bool = ("config" in generator and generator.config.use_gpu_all)
	var did_gpu: bool = false
	var bc: Object = load("res://scripts/systems/BiomeCompute.gd").new()
	var bp: Object = load("res://scripts/systems/BiomePostCompute.gd").new()
	if use_gpu_only:
		if "ensure_persistent_buffers" in generator:
			generator.ensure_persistent_buffers(false)
		var height_buf: RID = generator.get_persistent_buffer("height")
		var land_buf: RID = generator.get_persistent_buffer("is_land")
		var temp_buf: RID = generator.get_persistent_buffer("temperature")
		var moist_buf: RID = generator.get_persistent_buffer("moisture")
		var slow_temp_buf: RID = generator.get_persistent_buffer("biome_temp")
		var slow_moist_buf: RID = generator.get_persistent_buffer("biome_moist")
		var beach_buf: RID = generator.get_persistent_buffer("beach")
		var desert_buf: RID = generator.get_persistent_buffer("desert_noise")
		var biome_buf: RID = generator.get_persistent_buffer("biome_id")
		var biome_tmp: RID = generator.get_persistent_buffer("biome_tmp")
		var lake_buf: RID = generator.get_persistent_buffer("lake")
		var lava_buf: RID = generator.get_persistent_buffer("lava")
		# Update slow-moving climate buffers for biome stability
		var alpha: float = 0.0
		if dt_sim > 0.0 and biome_climate_tau_days > 0.0:
			alpha = 1.0 - exp(-dt_sim / max(0.001, biome_climate_tau_days))
		alpha = clamp(alpha, 0.0, 1.0)
		if _blend and temp_buf.is_valid() and moist_buf.is_valid() and slow_temp_buf.is_valid() and slow_moist_buf.is_valid():
			if _blend.apply(w, h, temp_buf, moist_buf, slow_temp_buf, slow_moist_buf, alpha):
				temp_buf = slow_temp_buf
				moist_buf = slow_moist_buf
		# Precompute min/max height from CPU array (static) to match shader expectations
		var min_h := 1e9
		var max_h := -1e9
		for hv in generator.last_height:
			if hv < min_h: min_h = hv
			if hv > max_h: max_h = hv
		params["min_h"] = min_h
		params["max_h"] = max_h
		var ok = bc.classify_to_buffer(w, h, height_buf, land_buf, temp_buf, moist_buf, beach_buf, desert_buf, params, biome_buf)
		if ok and biome_tmp.is_valid() and lava_buf.is_valid():
			bp.apply_overrides_and_lava_gpu(w, h, land_buf, temp_buf, moist_buf, biome_buf, lake_buf, biome_tmp, lava_buf, generator.config.temp_min_c, generator.config.temp_max_c, generator.config.lava_temp_threshold_c, 0.0)
			# Copy biome_tmp -> biome_id for stable render (reuse FlowCompute helper)
			if generator._flow_compute == null:
				generator._flow_compute = load("res://scripts/systems/FlowCompute.gd").new()
			if biome_tmp.is_valid() and biome_buf.is_valid():
				if "_ensure" in generator._flow_compute:
					generator._flow_compute._ensure()
				generator._flow_compute._dispatch_copy_u32(biome_tmp, biome_buf, size)
			if _biome_tex:
				var btex: Texture2D = _biome_tex.update_from_buffer(w, h, biome_buf)
				if btex and "set_biome_texture_override" in generator:
					generator.set_biome_texture_override(btex)
			if _lava_tex:
				var ltex: Texture2D = _lava_tex.update_from_buffer(w, h, lava_buf)
				if ltex and "set_lava_texture_override" in generator:
					generator.set_lava_texture_override(ltex)
			did_gpu = true
	if not did_gpu:
		if use_gpu_only:
			return {}
		var desert_field := PackedFloat32Array()
		if "_feature_noise_cache" in generator and generator._feature_noise_cache != null:
			desert_field = generator._feature_noise_cache.desert_noise_field
		var biomes_gpu: PackedInt32Array = bc.classify(w, h, generator.last_height, generator.last_is_land, generator.last_temperature, generator.last_moisture, generator.last_beach, desert_field, params)
		if biomes_gpu.size() == size:
			generator.last_biomes = biomes_gpu
		var post: Dictionary = bp.apply_overrides_and_lava(w, h, generator.last_is_land, generator.last_temperature, generator.last_moisture, generator.last_biomes, generator.config.temp_min_c, generator.config.temp_max_c, generator.config.lava_temp_threshold_c, generator.last_lake)
		if not post.is_empty():
			generator.last_biomes = post.get("biomes", generator.last_biomes)
			generator.last_lava = post.get("lava", generator.last_lava)
	return {"dirty_fields": PackedStringArray(["biome", "lava"]) }
