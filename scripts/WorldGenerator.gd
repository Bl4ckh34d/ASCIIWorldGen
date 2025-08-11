# File: res://scripts/WorldGenerator.gd
extends RefCounted

const TerrainNoise = preload("res://scripts/generation/TerrainNoise.gd")
var ClimateNoise = load("res://scripts/generation/ClimateNoise.gd")
const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")
const WorldState = preload("res://scripts/core/WorldState.gd")
const FeatureNoiseCache = preload("res://scripts/systems/FeatureNoiseCache.gd")
const DistanceTransform = preload("res://scripts/systems/DistanceTransform.gd")
const ContinentalShelf = preload("res://scripts/systems/ContinentalShelf.gd")
var ClimatePost = load("res://scripts/systems/ClimatePost.gd")
const PoolingSystem = preload("res://scripts/systems/PoolingSystem.gd")
const ClimateBase = preload("res://scripts/systems/ClimateBase.gd")
const ClimateAdjust = preload("res://scripts/systems/ClimateAdjust.gd")
var BiomePost = load("res://scripts/systems/BiomePost.gd")
var FlowErosionSystem = load("res://scripts/systems/FlowErosionSystem.gd")

class Config:
	var rng_seed: int = 0
	var width: int = 320
	var height: int = 60
	var octaves: int = 5
	var frequency: float = 0.02
	var lacunarity: float = 2.0
	var gain: float = 0.5
	var warp: float = 24.0
	var sea_level: float = 0.0
	# Shore/turquoise controls
	var shallow_threshold: float = 0.20
	var shore_band: float = 6.0
	var shore_noise_mult: float = 4.0
	# Polar cap control
	var polar_cap_frac: float = 0.12
	# Height to meters scale (for info panel)
	var height_scale_m: float = 6000.0
	# Temperature extremes per seed (for Celsius scaling and lava)
	var temp_min_c: float = -40.0
	var temp_max_c: float = 70.0
	var lava_temp_threshold_c: float = 55.0
	# Rivers toggle
	var rivers_enabled: bool = true
	# Climate jitter and continentality
	var temp_base_offset: float = 0.25
	var temp_scale: float = 1.0
	var moist_base_offset: float = 0.1
	var moist_scale: float = 1.0
	var continentality_scale: float = 1.2
	# Mountain radiance influence
	var mountain_cool_amp: float = 0.15
	var mountain_wet_amp: float = 0.10
	var mountain_radiance_passes: int = 3

var config := Config.new()

var _noise := FastNoiseLite.new()
var _warp_noise := FastNoiseLite.new()
var _shore_noise := FastNoiseLite.new()

var last_height: PackedFloat32Array = PackedFloat32Array()
var last_is_land: PackedByteArray = PackedByteArray()
var last_turquoise_water: PackedByteArray = PackedByteArray()
var last_beach: PackedByteArray = PackedByteArray()
var last_biomes: PackedInt32Array = PackedInt32Array()
var last_water_distance: PackedFloat32Array = PackedFloat32Array()
var last_turquoise_strength: PackedFloat32Array = PackedFloat32Array()
var last_temperature: PackedFloat32Array = PackedFloat32Array()
var last_moisture: PackedFloat32Array = PackedFloat32Array()
var last_distance_to_coast: PackedFloat32Array = PackedFloat32Array()
var last_lava: PackedByteArray = PackedByteArray()
var last_ocean_fraction: float = 0.0
var last_shelf_value_noise_field: PackedFloat32Array = PackedFloat32Array()
var last_lake: PackedByteArray = PackedByteArray()
var last_lake_id: PackedInt32Array = PackedInt32Array()
var last_flow_dir: PackedInt32Array = PackedInt32Array()
var last_flow_accum: PackedFloat32Array = PackedFloat32Array()
var last_river: PackedByteArray = PackedByteArray()
var last_pooled_lake: PackedByteArray = PackedByteArray()

# Phase 0 scaffolding: central state and shared noise cache (currently unused)
var _world_state: Object = null
var _feature_noise_cache: Object = null
var _climate_base: Dictionary = {}

func _init() -> void:
	randomize()
	config.rng_seed = randi()
	_setup_noises()
	_setup_temperature_extremes()
	# Initialize refactor scaffolding (kept unused in behavior for now)
	_world_state = WorldState.new()
	_world_state.configure(config.width, config.height, config.rng_seed)
	_world_state.height_scale_m = config.height_scale_m
	_world_state.temp_min_c = config.temp_min_c
	_world_state.temp_max_c = config.temp_max_c
	_world_state.lava_temp_threshold_c = config.lava_temp_threshold_c
	_feature_noise_cache = FeatureNoiseCache.new()
	_climate_base = ClimateBase.new().build(config.rng_seed)

func apply_config(dict: Dictionary) -> void:
	if dict.has("seed"):
		var s: String = str(dict["seed"]) if typeof(dict["seed"]) != TYPE_NIL else ""
		config.rng_seed = s.hash() if s.length() > 0 else randi()
	if dict.has("width"):
		config.width = max(4, int(dict["width"]))
	if dict.has("height"):
		config.height = max(4, int(dict["height"]))
	if dict.has("octaves"):
		config.octaves = max(1, int(dict["octaves"]))
	if dict.has("frequency"):
		config.frequency = float(dict["frequency"]) 
	if dict.has("lacunarity"):
		config.lacunarity = float(dict["lacunarity"]) 
	if dict.has("gain"):
		config.gain = float(dict["gain"]) 
	if dict.has("warp"):
		config.warp = float(dict["warp"]) 
	if dict.has("sea_level"):
		config.sea_level = float(dict["sea_level"]) 
	if dict.has("shallow_threshold"):
		config.shallow_threshold = float(dict["shallow_threshold"]) 
	if dict.has("shore_band"):
		config.shore_band = float(dict["shore_band"]) 
	if dict.has("shore_noise_mult"):
		config.shore_noise_mult = clamp(float(dict["shore_noise_mult"]), 0.1, 20.0)
	if dict.has("polar_cap_frac"):
		config.polar_cap_frac = clamp(float(dict["polar_cap_frac"]), 0.0, 0.5)
	if dict.has("height_scale_m"):
		config.height_scale_m = float(dict["height_scale_m"]) 
	if dict.has("temp_min_c"):
		config.temp_min_c = float(dict["temp_min_c"]) 
	if dict.has("temp_max_c"):
		config.temp_max_c = float(dict["temp_max_c"]) 
	if dict.has("lava_temp_threshold_c"):
		config.lava_temp_threshold_c = float(dict["lava_temp_threshold_c"]) 
	if dict.has("temp_base_offset"):
		config.temp_base_offset = float(dict["temp_base_offset"]) 
	if dict.has("temp_scale"):
		config.temp_scale = float(dict["temp_scale"]) 
	if dict.has("moist_base_offset"):
		config.moist_base_offset = float(dict["moist_base_offset"]) 
	if dict.has("moist_scale"):
		config.moist_scale = float(dict["moist_scale"]) 
	if dict.has("continentality_scale"):
		config.continentality_scale = float(dict["continentality_scale"]) 
	if dict.has("mountain_cool_amp"):
		config.mountain_cool_amp = float(dict["mountain_cool_amp"]) 
	if dict.has("mountain_wet_amp"):
		config.mountain_wet_amp = float(dict["mountain_wet_amp"]) 
	if dict.has("mountain_radiance_passes"):
		config.mountain_radiance_passes = int(dict["mountain_radiance_passes"]) 
	_setup_noises()
	# Only randomize temperature extremes if caller didn't override both
	var override_extremes: bool = dict.has("temp_min_c") and dict.has("temp_max_c")
	if not override_extremes:
		_setup_temperature_extremes()
	# Keep WorldState metadata in sync; create on first use
	if _world_state == null:
		_world_state = WorldState.new()
	_world_state.configure(config.width, config.height, config.rng_seed)
	_world_state.height_scale_m = config.height_scale_m
	_world_state.temp_min_c = config.temp_min_c
	_world_state.temp_max_c = config.temp_max_c
	_world_state.lava_temp_threshold_c = config.lava_temp_threshold_c
	# Rebuild climate base when seed changes
	_climate_base = ClimateBase.new().build(config.rng_seed)

func _setup_noises() -> void:
	_noise.seed = config.rng_seed
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.frequency = config.frequency
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = config.octaves
	_noise.fractal_lacunarity = config.lacunarity
	_noise.fractal_gain = config.gain

	_warp_noise.seed = config.rng_seed ^ 0x9E3779B9
	_warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_warp_noise.frequency = config.frequency * 1.5
	_warp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_warp_noise.fractal_octaves = 3
	_warp_noise.fractal_lacunarity = 2.0
	_warp_noise.fractal_gain = 0.5

	_shore_noise.seed = config.rng_seed ^ 0xA5F1523D
	_shore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_shore_noise.frequency = max(0.01, config.frequency * 4.0)
	_shore_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_shore_noise.fractal_octaves = 3
	_shore_noise.fractal_lacunarity = 2.0
	_shore_noise.fractal_gain = 0.5

func _setup_temperature_extremes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.rng_seed) ^ 0x1234ABCD
	config.temp_min_c = lerp(-50.0, -15.0, rng.randf())
	config.temp_max_c = lerp(35.0, 85.0, rng.randf())
	config.lava_temp_threshold_c = clamp(config.lava_temp_threshold_c, config.temp_min_c, config.temp_max_c)

func clear() -> void:
	pass

func generate() -> PackedByteArray:
	var w: int = config.width
	var h: int = config.height
	var params := {
		"width": w,
		"height": h,
		"seed": config.rng_seed,
		"frequency": config.frequency,
		"octaves": config.octaves,
		"lacunarity": config.lacunarity,
		"gain": config.gain,
		"warp": config.warp,
		"sea_level": config.sea_level,
		"wrap_x": true,
		"temp_base_offset": config.temp_base_offset,
		"temp_scale": config.temp_scale,
		"moist_base_offset": config.moist_base_offset,
		"moist_scale": config.moist_scale,
		"continentality_scale": config.continentality_scale,
		"temp_min_c": config.temp_min_c,
		"temp_max_c": config.temp_max_c,
	}

	# Step 1: terrain
	var terrain := TerrainNoise.new().generate(params)
	last_height = terrain["height"]
	last_is_land = terrain["is_land"]
	# Track ocean coverage fraction for rendering transitions
	var ocean_count: int = 0
	for i_count in range(w * h):
		if last_is_land[i_count] == 0:
			ocean_count += 1
	last_ocean_fraction = float(ocean_count) / float(max(1, w * h))

	# Rivers disabled for now; refresh land mask only
	for iy in range(h):
		for ix in range(w):
			var ii: int = ix + iy * w
			last_is_land[ii] = 1 if last_height[ii] > config.sea_level else 0

	# PoolingSystem: tag inland lakes (optional; not yet used in rendering)
	var pool := PoolingSystem.new().compute(w, h, last_height, last_is_land, true)
	last_lake = pool["lake"]
	last_lake_id = pool["lake_id"]

	# Build shared feature noise cache (shore/shelf/desert/ice fields)
	if _feature_noise_cache != null:
		var cache_params := {
			"width": w,
			"height": h,
			"seed": config.rng_seed,
			"frequency": config.frequency,
		}
		_feature_noise_cache.build(cache_params)
		last_shelf_value_noise_field = _feature_noise_cache.shelf_value_noise_field

	# Step 2: shoreline features via ContinentalShelf system (keeps behavior)
	var size: int = w * h
	last_turquoise_water.resize(size)
	last_beach.resize(size)
	last_water_distance.resize(size)
	last_turquoise_strength.resize(size)
	# Use cached shore noise field if available; else fall back to per-pixel noise
	var shore_noise_field := PackedFloat32Array()
	if _feature_noise_cache != null and _feature_noise_cache.shore_noise_field.size() == size:
		shore_noise_field = _feature_noise_cache.shore_noise_field
	else:
		shore_noise_field.resize(size)
		for y in range(h):
			for x in range(w):
				var i2: int = x + y * w
				shore_noise_field[i2] = _shore_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
	var shelf_out := ContinentalShelf.new().compute(w, h, last_height, last_is_land, config.sea_level, shore_noise_field, config.shallow_threshold, config.shore_band, true)
	last_turquoise_water = shelf_out["turquoise_water"]
	last_beach = shelf_out["beach"]
	last_water_distance = shelf_out["water_distance"]
	last_turquoise_strength = shelf_out["turquoise_strength"]

	# Step 3: climate via ClimateAdjust using seed-stable ClimateBase and shared coast distance
	params["distance_to_coast"] = last_water_distance
	var climate: Dictionary = ClimateAdjust.new().evaluate(w, h, last_height, last_is_land, _climate_base, params, last_water_distance)
	last_temperature = climate["temperature"]
	last_moisture = climate["moisture"]
	last_distance_to_coast = last_water_distance

	# Mountain radiance: run through ClimatePost system for parity
	var post: Dictionary = ClimatePost.new().apply_mountain_radiance(w, h, last_biomes, last_temperature, last_moisture, config.mountain_cool_amp, config.mountain_wet_amp, max(0, config.mountain_radiance_passes))
	last_temperature = post["temperature"]
	last_moisture = post["moisture"]

	# Step 4: biomes (pass freeze threshold)
	var params2 := params.duplicate()
	params2["freeze_temp_threshold"] = 0.16
	params2["height_scale_m"] = config.height_scale_m
	params2["lapse_c_per_km"] = 5.5
	# Provide cached noise fields if available
	if _feature_noise_cache != null:
		params2["desert_noise_field"] = _feature_noise_cache.desert_noise_field
		params2["ice_wiggle_field"] = _feature_noise_cache.ice_wiggle_field
	last_biomes = BiomeClassifier.new().classify(params2, last_is_land, last_height, last_temperature, last_moisture, last_beach)
	# BiomePost: apply hot/cold overrides + lava in a single place
	var post2: Dictionary = BiomePost.new().apply_overrides_and_lava(w, h, last_is_land, last_temperature, last_moisture, last_biomes, config.temp_min_c, config.temp_max_c, config.lava_temp_threshold_c)
	last_biomes = post2["biomes"]
	last_lava = post2["lava"]

	# Step 4c: ensure every land cell has a valid biome id
	_ensure_valid_biomes()

	# Hot/Cold overrides now live in BiomePost; keep generator overrides disabled

	# Step 4b: ensure ocean ice sheets are present from classifier immediately
	for yo in range(h):
		for xo in range(w):
			var io := xo + yo * w
			if last_is_land[io] == 0:
				# If classifier marked this ocean cell as ICE_SHEET, keep it
				if last_biomes[io] == BiomeClassifier.Biome.ICE_SHEET:
					continue
				# Otherwise keep as Ocean (already set by classifier)
				pass

	# Step 5: rivers (post-climate so we can freeze-gate; cooperate with PoolingSystem lakes)
	if config.rivers_enabled:
		var max_lakes_guess: int = max(4, floori(float(w * h) / 2048.0))
		var hydro2: Dictionary = FlowErosionSystem.new().compute_full(w, h, last_height, last_is_land, {"river_percentile": 0.97, "min_river_length": 5, "lake_mask": last_lake, "max_lakes": max_lakes_guess})
		last_flow_dir = hydro2["flow_dir"]
		last_flow_accum = hydro2["flow_accum"]
		last_river = hydro2["river"]
		if hydro2.has("lake"):
			last_pooled_lake = hydro2["lake"]
		# Freeze gating: remove rivers where glacier or freezing temps
		var size2: int = w * h
		if last_river.size() != size2:
			last_river.resize(size2)
		for gi in range(size2):
			if last_is_land[gi] == 0:
				continue
			var t_norm_g: float = (last_temperature[gi] if gi < last_temperature.size() else 0.5)
			var t_c_g: float = config.temp_min_c + t_norm_g * (config.temp_max_c - config.temp_min_c)
			var is_glacier: bool = (gi < last_biomes.size()) and (last_biomes[gi] == BiomeClassifier.Biome.GLACIER)
			if is_glacier or t_c_g <= 0.0:
				last_river[gi] = 0
	else:
		var sz: int = w * h
		last_flow_dir.resize(sz)
		last_flow_accum.resize(sz)
		last_river.resize(sz)
		for kk in range(sz):
			last_flow_dir[kk] = -1
			last_flow_accum[kk] = 0.0
			last_river[kk] = 0

	return last_is_land

func quick_update_sea_level(new_sea_level: float) -> PackedByteArray:
	# Fast path: only recompute artifacts depending on sea level.
	# Requires that base terrain (last_height) already exists.
	config.sea_level = new_sea_level
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size:
		# No terrain yet; fallback to full generation
		return generate()
	# 1) Recompute land mask
	if last_is_land.size() != size:
		last_is_land.resize(size)
	var prev_is_land := PackedByteArray()
	prev_is_land.resize(size)
	for i in range(size):
		prev_is_land[i] = last_is_land[i] if i < last_is_land.size() else 0
	for i in range(size):
		last_is_land[i] = 1 if last_height[i] > config.sea_level else 0
	# Update ocean fraction
	var ocean_ct: int = 0
	for ii in range(size):
		if last_is_land[ii] == 0:
			ocean_ct += 1
	last_ocean_fraction = float(ocean_ct) / float(max(1, size))
	# 2) Recompute shoreline features (turquoise, beaches) and distance to land
	if last_turquoise_water.size() != size:
		last_turquoise_water.resize(size)
	if last_beach.size() != size:
		last_beach.resize(size)
	if last_water_distance.size() != size:
		last_water_distance.resize(size)
	if last_turquoise_strength.size() != size:
		last_turquoise_strength.resize(size)
	# 2) Recompute shoreline features and distance via ContinentalShelf (wrap_x=false for parity with quick path)
	var shore_noise_field := PackedFloat32Array()
	shore_noise_field.resize(size)
	for yy in range(h):
		for xx in range(w):
			var ii: int = xx + yy * w
			shore_noise_field[ii] = _shore_noise.get_noise_2d(float(xx), float(yy)) * 0.5 + 0.5
	var shelf2 := ContinentalShelf.new().compute(w, h, last_height, last_is_land, config.sea_level, shore_noise_field, config.shallow_threshold, config.shore_band, false)
	last_turquoise_water = shelf2["turquoise_water"]
	last_beach = shelf2["beach"]
	last_water_distance = shelf2["water_distance"]
	last_turquoise_strength = shelf2["turquoise_strength"]
	# 3) Recompute climate fields to reflect new coastline and sea coverage
	var params := {
		"width": w,
		"height": h,
		"seed": config.rng_seed,
		"frequency": config.frequency,
		"octaves": config.octaves,
		"lacunarity": config.lacunarity,
		"gain": config.gain,
		"warp": config.warp,
		"sea_level": config.sea_level,
		"temp_base_offset": config.temp_base_offset,
		"temp_scale": config.temp_scale,
		"moist_base_offset": config.moist_base_offset,
		"moist_scale": config.moist_scale,
		"continentality_scale": config.continentality_scale,
		"temp_min_c": config.temp_min_c,
		"temp_max_c": config.temp_max_c,
	}
	params["distance_to_coast"] = last_water_distance
	var climate: Dictionary = ClimateAdjust.new().evaluate(w, h, last_height, last_is_land, _climate_base, params, last_water_distance)
	last_temperature = climate["temperature"]
	last_moisture = climate["moisture"]
	last_distance_to_coast = last_water_distance

	# 5) Reclassify biomes using updated climate (band-limited near coastline)
	var params2 := params.duplicate()
	params2["freeze_temp_threshold"] = 0.16
	params2["height_scale_m"] = config.height_scale_m
	params2["lapse_c_per_km"] = 5.5
	var new_biomes := BiomeClassifier.new().classify(params2, last_is_land, last_height, last_temperature, last_moisture, last_beach)
	# Build band mask (near coast or toggled land/water)
	var band := PackedByteArray(); band.resize(size)
	var band_count: int = 0
	var band_radius: float = config.shore_band + config.shallow_threshold
	for bi in range(size):
		var toggled: bool = prev_is_land[bi] != last_is_land[bi]
		var near_coast: bool = (last_water_distance[bi] if bi < last_water_distance.size() else 0.0) <= band_radius
		var in_band: bool = toggled or near_coast
		band[bi] = 1 if in_band else 0
		if in_band:
			band_count += 1
	var frac: float = float(band_count) / float(max(1, size))
	var merge_partial: bool = frac < 0.25
	if last_biomes.size() != size:
		last_biomes.resize(size)
	if merge_partial:
		for mi in range(size):
			if band[mi] != 0:
				last_biomes[mi] = new_biomes[mi]
	else:
		last_biomes = new_biomes
	_ensure_valid_biomes()
	# Centralized hot/cold/lava application
	var post2: Dictionary = BiomePost.new().apply_overrides_and_lava(w, h, last_is_land, last_temperature, last_moisture, last_biomes, config.temp_min_c, config.temp_max_c, config.lava_temp_threshold_c)
	last_biomes = post2["biomes"]
	last_lava = post2["lava"]

	# 6) Lakes and rivers recompute on sea-level change (order: lakes, then rivers)
	var pool2 := PoolingSystem.new().compute(w, h, last_height, last_is_land, true)
	last_lake = pool2["lake"]
	last_lake_id = pool2["lake_id"]
	if config.rivers_enabled:
		var max_lakes_guess2: int = max(4, floori(float(w * h) / 2048.0))
		var hydro3: Dictionary = FlowErosionSystem.new().compute_full(w, h, last_height, last_is_land, {"river_percentile": 0.97, "min_river_length": 5, "lake_mask": last_lake, "max_lakes": max_lakes_guess2})
		last_flow_dir = hydro3["flow_dir"]
		last_flow_accum = hydro3["flow_accum"]
		last_river = hydro3["river"]
		if hydro3.has("lake"):
			last_pooled_lake = hydro3["lake"]
		# Freeze gating
		for gi2 in range(size):
			if last_is_land[gi2] == 0:
				continue
			var t_norm2: float = (last_temperature[gi2] if gi2 < last_temperature.size() else 0.5)
			var t_c2: float = config.temp_min_c + t_norm2 * (config.temp_max_c - config.temp_min_c)
			var is_gl2: bool = (gi2 < last_biomes.size()) and (last_biomes[gi2] == BiomeClassifier.Biome.GLACIER)
			if is_gl2 or t_c2 <= 0.0:
				last_river[gi2] = 0
	else:
		if last_river.size() != size:
			last_river.resize(size)
			for rk in range(size):
				last_river[rk] = 0

	# Lava mask computed in BiomePost
	return last_is_land

func get_width() -> int:
	return config.width

func get_height() -> int:
	return config.height

func get_cell_info(x: int, y: int) -> Dictionary:
	if x < 0 or y < 0 or x >= config.width or y >= config.height:
		return {}
	var i: int = x + y * config.width
	var h_val: float = 0.0
	var land: bool = false
	if i >= 0 and i < last_height.size():
		h_val = last_height[i]
	if i >= 0 and i < last_is_land.size():
		land = last_is_land[i] != 0
	var beach: bool = false
	var turq: bool = false
	if i >= 0 and i < last_beach.size():
		beach = last_beach[i] != 0
	if i >= 0 and i < last_turquoise_water.size():
		turq = last_turquoise_water[i] != 0
	var is_lava: bool = false
	if i >= 0 and i < last_lava.size():
		is_lava = last_lava[i] != 0
	var is_river: bool = false
	if i >= 0 and i < last_river.size():
		is_river = last_river[i] != 0
	var is_lake: bool = false
	if i >= 0 and i < last_lake.size():
		is_lake = last_lake[i] != 0
	var biome_id: int = -1
	var biome_name: String = "Ocean"
	if i >= 0 and i < last_biomes.size():
		var bid: int = last_biomes[i]
		if land:
			biome_id = bid
			biome_name = _biome_to_string(bid)
		else:
			# Allow special ocean biomes like ICE_SHEET to show in info instead of generic Ocean
			if bid == BiomeClassifier.Biome.ICE_SHEET:
				biome_id = bid
				biome_name = _biome_to_string(bid)
			else:
				biome_id = -1
				biome_name = "Ocean"
	# Convert normalized temperature to Celsius using per-seed extremes
	var t_norm: float = (last_temperature[i] if i < last_temperature.size() else 0.5)
	var temp_c: float = config.temp_min_c + t_norm * (config.temp_max_c - config.temp_min_c)
	var humidity: float = (last_moisture[i] if i < last_moisture.size() else 0.5)
	return {
		"height": h_val,
		"is_land": land,
		"is_beach": beach,
		"is_turquoise_water": turq,
		"is_lava": is_lava,
		"is_river": is_river,
		"is_lake": is_lake,
		"biome": biome_id,
		"biome_name": biome_name,
		"temp_c": temp_c,
		"humidity": humidity,
	}

func _biome_to_string(b: int) -> String:
	match b:
		BiomeClassifier.Biome.ICE_SHEET:
			return "Ice Sheet"
		BiomeClassifier.Biome.OCEAN:
			return "Ocean"
		BiomeClassifier.Biome.BEACH:
			return "Beach"
		BiomeClassifier.Biome.DESERT_SAND:
			return "Sand Desert"
		BiomeClassifier.Biome.DESERT_ROCK:
			return "Rock Desert"
		BiomeClassifier.Biome.DESERT_ICE:
			return "Ice Desert"
		BiomeClassifier.Biome.STEPPE:
			return "Steppe"
		BiomeClassifier.Biome.GRASSLAND:
			return "Grassland"
		BiomeClassifier.Biome.MEADOW:
			return "Meadow"
		BiomeClassifier.Biome.PRAIRIE:
			return "Prairie"
		BiomeClassifier.Biome.SWAMP:
			return "Swamp"
		BiomeClassifier.Biome.BOREAL_FOREST:
			return "Boreal Forest"
		BiomeClassifier.Biome.CONIFER_FOREST:
			return "Conifer Forest"
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return "Temperate Forest"
		BiomeClassifier.Biome.RAINFOREST:
			return "Rainforest"
		BiomeClassifier.Biome.HILLS:
			return "Hills"
		BiomeClassifier.Biome.FOOTHILLS:
			return "Foothills"
		BiomeClassifier.Biome.MOUNTAINS:
			return "Mountains"
		BiomeClassifier.Biome.ALPINE:
			return "Alpine"
		_:
			return "Grassland"

func _ensure_valid_biomes() -> void:
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_biomes.size() != size:
		last_biomes.resize(size)
	for i in range(size):
		if last_is_land[i] == 0:
			# Preserve special ocean biomes like ICE_SHEET from classifier
			var prev: int = (last_biomes[i] if i < last_biomes.size() else BiomeClassifier.Biome.OCEAN)
			last_biomes[i] = prev if prev == BiomeClassifier.Biome.ICE_SHEET else BiomeClassifier.Biome.OCEAN
			continue
		if i < last_beach.size() and last_beach[i] != 0:
			last_biomes[i] = BiomeClassifier.Biome.BEACH
			continue
		var b: int = (last_biomes[i] if i < last_biomes.size() else -1)
		if b < 0 or b > BiomeClassifier.Biome.ALPINE:
			last_biomes[i] = _fallback_biome(i)

func _fallback_biome(i: int) -> int:
	# Deterministic fallback using same features as classifier
	var t: float = (last_temperature[i] if i < last_temperature.size() else 0.5)
	var m: float = (last_moisture[i] if i < last_moisture.size() else 0.5)
	var elev: float = (last_height[i] if i < last_height.size() else 0.0)
	# freeze check
	if t <= 0.16:
		return BiomeClassifier.Biome.DESERT_ICE
	var high: float = clamp((elev - 0.5) * 2.0, 0.0, 1.0)
	var alpine: float = clamp((elev - 0.8) * 5.0, 0.0, 1.0)
	var cold: float = clamp((0.45 - t) * 3.0, 0.0, 1.0)
	var hot: float = clamp((t - 0.60) * 2.4, 0.0, 1.0)
	var dry: float = clamp((0.40 - m) * 2.6, 0.0, 1.0)
	var wet: float = clamp((m - 0.70) * 2.6, 0.0, 1.0)
	if high > 0.6:
		return BiomeClassifier.Biome.ALPINE if alpine > 0.5 else BiomeClassifier.Biome.MOUNTAINS
	if dry > 0.6 and hot > 0.3:
		return BiomeClassifier.Biome.DESERT_SAND
	if dry > 0.6 and hot <= 0.3:
		return BiomeClassifier.Biome.DESERT_ROCK
	if cold > 0.6 and dry > 0.4:
		return BiomeClassifier.Biome.DESERT_ICE
	if wet > 0.6 and hot > 0.4:
		return BiomeClassifier.Biome.RAINFOREST
	if m > 0.55 and t > 0.5:
		return BiomeClassifier.Biome.TROPICAL_FOREST
	if wet > 0.5 and cold > 0.4:
		return BiomeClassifier.Biome.SWAMP
	if cold > 0.6:
		return BiomeClassifier.Biome.BOREAL_FOREST
	if m > 0.6 and t > 0.5:
		return BiomeClassifier.Biome.TEMPERATE_FOREST
	if m > 0.4 and t > 0.4:
		return BiomeClassifier.Biome.CONIFER_FOREST
	if m > 0.3 and t > 0.3:
		return BiomeClassifier.Biome.MEADOW
	if m > 0.25 and t > 0.35:
		return BiomeClassifier.Biome.PRAIRIE
	if m > 0.2 and t > 0.25:
		return BiomeClassifier.Biome.STEPPE
	if high > 0.3:
		return BiomeClassifier.Biome.FOOTHILLS
	if high > 0.2:
		return BiomeClassifier.Biome.HILLS
	return BiomeClassifier.Biome.GRASSLAND

func _apply_mountain_radiance(w: int, h: int) -> void:
	var passes: int = max(0, config.mountain_radiance_passes)
	if passes == 0:
		return
	var cool_amp: float = config.mountain_cool_amp
	var wet_amp: float = config.mountain_wet_amp
	if last_biomes.size() != w * h:
		return
	for p in range(passes):
		var temp2 := last_temperature.duplicate()
		var moist2 := last_moisture.duplicate()
		for y in range(h):
			for x in range(w):
				var i: int = x + y * w
				var b: int = last_biomes[i]
				if b == BiomeClassifier.Biome.MOUNTAINS or b == BiomeClassifier.Biome.ALPINE:
					for dy in range(-2, 3):
						for dx in range(-2, 3):
							var nx: int = x + dx
							var ny: int = y + dy
							if nx < 0 or ny < 0 or nx >= w or ny >= h:
								continue
							var j: int = nx + ny * w
							var dist: float = sqrt(float(dx * dx + dy * dy))
							var fall: float = clamp(1.0 - dist / 3.0, 0.0, 1.0)
							temp2[j] = clamp(temp2[j] - cool_amp * fall / float(passes), 0.0, 1.0)
							moist2[j] = clamp(moist2[j] + wet_amp * fall / float(passes), 0.0, 1.0)
		last_temperature = temp2
		last_moisture = moist2

func _apply_hot_temperature_override(w: int, h: int) -> void:
	var t_c_threshold: float = 30.0
	var n := FastNoiseLite.new()
	n.seed = int(config.rng_seed) ^ 0xBEEF
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.008
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if last_is_land.size() != w * h or last_is_land[i] == 0:
				continue
			var t_norm: float = (last_temperature[i] if i < last_temperature.size() else 0.5)
			var t_c: float = config.temp_min_c + t_norm * (config.temp_max_c - config.temp_min_c)
			if t_c >= t_c_threshold and t_c < config.lava_temp_threshold_c:
				var m: float = (last_moisture[i] if i < last_moisture.size() else 0.5)
				var b: int = last_biomes[i]
				# Very dry → deserts
				if m < 0.40:
					var hot: float = clamp((t_norm - 0.60) * 2.4, 0.0, 1.0)
					var noise_val: float = n.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
					var sand_prob: float = clamp(0.25 + 0.6 * hot, 0.0, 0.98)
					last_biomes[i] = BiomeClassifier.Biome.DESERT_SAND if noise_val < sand_prob else BiomeClassifier.Biome.DESERT_ROCK
				else:
					# Hot but not very dry: keep relief unless quite dry
					if (b == BiomeClassifier.Biome.MOUNTAINS or b == BiomeClassifier.Biome.ALPINE or b == BiomeClassifier.Biome.HILLS or b == BiomeClassifier.Biome.FOOTHILLS):
						if m < 0.35:
							last_biomes[i] = BiomeClassifier.Biome.DESERT_ROCK
						# else keep relief biome
					else:
						last_biomes[i] = BiomeClassifier.Biome.STEPPE

func _apply_cold_temperature_override(w: int, h: int) -> void:
	var t_c_threshold: float = 2.0
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if last_is_land.size() != w * h or last_is_land[i] == 0:
				continue
			var t_norm: float = (last_temperature[i] if i < last_temperature.size() else 0.5)
			var t_c: float = config.temp_min_c + t_norm * (config.temp_max_c - config.temp_min_c)
			if t_c <= t_c_threshold:
				var m: float = (last_moisture[i] if i < last_moisture.size() else 0.0)
				if m >= 0.25:
					last_biomes[i] = BiomeClassifier.Biome.DESERT_ICE
				else:
					last_biomes[i] = BiomeClassifier.Biome.DESERT_ROCK
