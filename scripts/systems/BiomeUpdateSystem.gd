extends RefCounted

# Biome updater: GPU-only classification and post, on its own cadence.

var generator: Object = null

func initialize(gen: Object) -> void:
	generator = gen

func tick(_dt_days: float, _world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
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
	params["biome_phase"] = float(Time.get_ticks_msec() % 60000) / 60000.0
	params["biome_moist_jitter2"] = 0.03
	params["biome_moist_islands"] = 0.35
	params["biome_moist_elev_dry"] = 0.35
	var desert_field := PackedFloat32Array()
	if "_feature_noise_cache" in generator and generator._feature_noise_cache != null:
		desert_field = generator._feature_noise_cache.desert_noise_field
	var bc: Object = load("res://scripts/systems/BiomeCompute.gd").new()
	var biomes_gpu: PackedInt32Array = bc.classify(w, h, generator.last_height, generator.last_is_land, generator.last_temperature, generator.last_moisture, generator.last_beach, desert_field, params)
	if biomes_gpu.size() == size:
		generator.last_biomes = biomes_gpu
	# Post (GPU)
	var bp: Object = load("res://scripts/systems/BiomePostCompute.gd").new()
	var post: Dictionary = bp.apply_overrides_and_lava(w, h, generator.last_is_land, generator.last_temperature, generator.last_moisture, generator.last_biomes, generator.config.temp_min_c, generator.config.temp_max_c, generator.config.lava_temp_threshold_c, generator.last_lake)
	if not post.is_empty():
		generator.last_biomes = post.get("biomes", generator.last_biomes)
		generator.last_lava = post.get("lava", generator.last_lava)
	return {"dirty_fields": PackedStringArray(["biome", "lava"]) }
