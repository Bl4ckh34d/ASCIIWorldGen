# File: res://scripts/WorldGenerator.gd
extends RefCounted

const TerrainNoise = preload("res://scripts/generation/TerrainNoise.gd")
const TerrainCompute = preload("res://scripts/systems/TerrainCompute.gd")
var ClimateNoise = load("res://scripts/generation/ClimateNoise.gd")
const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")
const WorldState = preload("res://scripts/core/WorldState.gd")
const FeatureNoiseCache = preload("res://scripts/systems/FeatureNoiseCache.gd")
const DistanceTransform = preload("res://scripts/systems/DistanceTransform.gd")
const DistanceTransformCompute = preload("res://scripts/systems/DistanceTransformCompute.gd")
const ContinentalShelf = preload("res://scripts/systems/ContinentalShelf.gd")
const ContinentalShelfCompute = preload("res://scripts/systems/ContinentalShelfCompute.gd")
var ClimatePost = load("res://scripts/systems/ClimatePost.gd")
const ClimatePostCompute = preload("res://scripts/systems/ClimatePostCompute.gd")
const PoolingSystem = preload("res://scripts/systems/PoolingSystem.gd")
const ClimateBase = preload("res://scripts/systems/ClimateBase.gd")
const ClimateAdjust = preload("res://scripts/systems/ClimateAdjust.gd")
const ClimateAdjustCompute = preload("res://scripts/systems/ClimateAdjustCompute.gd")
var BiomePost = load("res://scripts/systems/BiomePost.gd")
const BiomePostCompute = preload("res://scripts/systems/BiomePostCompute.gd")
var FlowErosionSystem = load("res://scripts/systems/FlowErosionSystem.gd")
const FlowCompute = preload("res://scripts/systems/FlowCompute.gd")
const RiverCompute = preload("res://scripts/systems/RiverCompute.gd")
const DepressionFillCompute = preload("res://scripts/systems/DepressionFillCompute.gd")
const LakeLabelFromMaskCompute = preload("res://scripts/systems/LakeLabelFromMaskCompute.gd")
const PourPointReduceCompute = preload("res://scripts/systems/PourPointReduceCompute.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")
var _terrain_compute: Object = null
var _dt_compute: Object = null
var _shelf_compute: Object = null
var _climate_compute_gpu: Object = null
var _flow_compute: Object = null
var _river_compute: Object = null
var _lake_label_compute: Object = null
var _gpu_buffer_manager: Object = null

class Config:
	var rng_seed: int = 0
	var width: int = 275
	var height: int = 62
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
	var lava_temp_threshold_c: float = 75.0
	# Rivers toggle
	var rivers_enabled: bool = true
	# Lakes toggle
	var lakes_enabled: bool = true
	# Climate jitter and continentality
	var temp_base_offset: float = 0.25
	var temp_scale: float = 1.0
	var moist_base_offset: float = 0.1
	var moist_scale: float = 1.0
	var continentality_scale: float = 1.2
	# Seasonal climate parameters (normalized temp space)
	var season_phase: float = 0.0
	var season_amp_equator: float = 0.10
	var season_amp_pole: float = 0.25
	var season_ocean_damp: float = 0.60
	# Diurnal temperature cycle
	var diurnal_amp_equator: float = 0.06
	var diurnal_amp_pole: float = 0.03
	var diurnal_ocean_damp: float = 0.4
	var time_of_day: float = 0.0
	# Day-night visual settings
	var day_night_contrast: float = 0.75
	var day_night_base: float = 0.25
	# Mountain radiance influence
	var mountain_cool_amp: float = 0.15
	var mountain_wet_amp: float = 0.10
	var mountain_radiance_passes: int = 3
	# Compute toggles (global)
	var use_gpu_all: bool = true
	# Per-system toggles (override global when needed)
	var use_gpu_clouds: bool = true
	# Feature flags
	var realistic_pooling_enabled: bool = true
	# Use GPU pooling (Phase 2: GPU E + GPU label) when enabled
	var use_gpu_pooling: bool = true
	# Pooling/outflow params
	var max_forced_outflows: int = 3
	var prob_outflow_0: float = 0.50
	var prob_outflow_1: float = 0.35
	var prob_outflow_2: float = 0.10
	var prob_outflow_3: float = 0.05
	# Horizontal noise stretch for ASCII aspect compensation (x multiplier applied to noise samples)
	var noise_x_scale: float = 0.5

var config := Config.new()
var debug_parity: bool = false

var _noise := FastNoiseLite.new()
var _warp_noise := FastNoiseLite.new()
var _shore_noise := FastNoiseLite.new()

var last_height: PackedFloat32Array = PackedFloat32Array()
var last_height_final: PackedFloat32Array = PackedFloat32Array()
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
var last_clouds: PackedFloat32Array = PackedFloat32Array()
var last_light: PackedFloat32Array = PackedFloat32Array()

# Exposed by PlateSystem for coupling (GPU boundary mask as i32)
var _plates_boundary_mask_i32: PackedInt32Array = PackedInt32Array()

# Parity/validation metrics removed for GPU-only mode
var debug_last_metrics: Dictionary = {}

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
	_gpu_buffer_manager = GPUBufferManager.new()

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
	# Map min/max temperature sliders to normalized climate knobs if provided
	if dict.has("temp_base_offset"):
		config.temp_base_offset = float(dict["temp_base_offset"])
	if dict.has("temp_scale"):
		config.temp_scale = float(dict["temp_scale"])
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
	# Seasonal params (safe defaults keep parity when absent)
	if dict.has("season_phase"):
		config.season_phase = float(dict["season_phase"])
	if dict.has("season_amp_equator"):
		config.season_amp_equator = float(dict["season_amp_equator"])
	if dict.has("season_amp_pole"):
		config.season_amp_pole = float(dict["season_amp_pole"])
	if dict.has("season_ocean_damp"):
		config.season_ocean_damp = float(dict["season_ocean_damp"])
	# Diurnal params
	if dict.has("diurnal_amp_equator"):
		config.diurnal_amp_equator = float(dict["diurnal_amp_equator"])
	if dict.has("diurnal_amp_pole"):
		config.diurnal_amp_pole = float(dict["diurnal_amp_pole"])
	if dict.has("diurnal_ocean_damp"):
		config.diurnal_ocean_damp = float(dict["diurnal_ocean_damp"])
	if dict.has("mountain_cool_amp"):
		config.mountain_cool_amp = float(dict["mountain_cool_amp"]) 
	if dict.has("mountain_wet_amp"):
		config.mountain_wet_amp = float(dict["mountain_wet_amp"]) 
	if dict.has("mountain_radiance_passes"):
		config.mountain_radiance_passes = int(dict["mountain_radiance_passes"]) 
	if dict.has("use_gpu_all"):
		config.use_gpu_all = bool(dict["use_gpu_all"]) 
	if dict.has("use_gpu_clouds"):
		config.use_gpu_clouds = bool(dict["use_gpu_clouds"]) 
	if dict.has("lakes_enabled"):
		config.lakes_enabled = bool(dict["lakes_enabled"])
	if dict.has("realistic_pooling_enabled"):
		config.realistic_pooling_enabled = bool(dict["realistic_pooling_enabled"])
	if dict.has("use_gpu_pooling"):
		config.use_gpu_pooling = bool(dict["use_gpu_pooling"])
	if dict.has("max_forced_outflows"):
		config.max_forced_outflows = int(dict["max_forced_outflows"])
	if dict.has("prob_outflow_0"):
		config.prob_outflow_0 = float(dict["prob_outflow_0"])
	if dict.has("prob_outflow_1"):
		config.prob_outflow_1 = float(dict["prob_outflow_1"])
	if dict.has("prob_outflow_2"):
		config.prob_outflow_2 = float(dict["prob_outflow_2"])
	if dict.has("prob_outflow_3"):
		config.prob_outflow_3 = float(dict["prob_outflow_3"])
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
	# Keep lava threshold independent of current extremes; enforce a hard minimum of 75°C
	config.lava_temp_threshold_c = max(75.0, config.lava_temp_threshold_c)

func _rmse_f32(_a: PackedFloat32Array, _b: PackedFloat32Array, _mask: PackedByteArray = PackedByteArray()) -> float:
	return 0.0
func _mae_f32(_a: PackedFloat32Array, _b: PackedFloat32Array, _mask: PackedByteArray = PackedByteArray()) -> float:
	return 0.0
func _mae_rel_f32(_a: PackedFloat32Array, _b: PackedFloat32Array, _mask: PackedByteArray = PackedByteArray()) -> float:
	return 0.0
func _max_abs_diff_f32(_a: PackedFloat32Array, _b: PackedFloat32Array, _mask: PackedByteArray = PackedByteArray()) -> float:
	return 0.0
func _equality_rate_u8(_a: PackedByteArray, _b: PackedByteArray, _mask: PackedByteArray = PackedByteArray()) -> float:
	return 1.0
func _equality_rate_i32(_a: PackedInt32Array, _b: PackedInt32Array, _mask: PackedByteArray = PackedByteArray()) -> float:
	return 1.0

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
		"noise_x_scale": config.noise_x_scale,
		"temp_base_offset": config.temp_base_offset,
		"temp_scale": config.temp_scale,
		"moist_base_offset": config.moist_base_offset,
		"moist_scale": config.moist_scale,
		"continentality_scale": config.continentality_scale,
		"temp_min_c": config.temp_min_c,
		"temp_max_c": config.temp_max_c,
		# Seasonal controls from config (phase may be supplied by TimeSystem)
		"season_phase": config.season_phase,
		"season_amp_equator": config.season_amp_equator,
		"season_amp_pole": config.season_amp_pole,
		"season_ocean_damp": config.season_ocean_damp,
		# Diurnal controls
		"diurnal_amp_equator": config.diurnal_amp_equator,
		"diurnal_amp_pole": config.diurnal_amp_pole,
		"diurnal_ocean_damp": config.diurnal_ocean_damp,
		"time_of_day": config.time_of_day,
		# Day-night visual settings
		"day_of_year": config.season_phase,  # Use season_phase as day_of_year for now
		"day_night_base": config.day_night_base,
		"day_night_contrast": config.day_night_contrast,
	}

	# Step 1: terrain (GPU) with wrapper reuse
	var terrain := {}
	if _terrain_compute == null:
		_terrain_compute = TerrainCompute.new()
	terrain = _terrain_compute.generate(w, h, params)
	last_height = terrain["height"]
	# Final surface height used for sea-level classification (after erosion). Initialized to base height.
	last_height_final = last_height
	last_is_land = terrain["is_land"]

	# Parity disabled in GPU-only mode
	# Track ocean coverage fraction for rendering transitions
	var ocean_count: int = 0
	for i_count in range(w * h):
		if last_is_land[i_count] == 0:
			ocean_count += 1
	last_ocean_fraction = float(ocean_count) / float(max(1, w * h))

	# Land mask provided by GPU terrain; no CPU recompute

	# PoolingSystem: tag inland lakes (use GPU when available)
	var _pool_unused: Dictionary
	if _lake_label_compute == null:
		_lake_label_compute = load("res://scripts/systems/LakeLabelCompute.gd").new()
	# Strict GPU pooling path: compute E on GPU -> lake mask -> GPU labels
	if config.realistic_pooling_enabled and config.use_gpu_pooling:
		var E_out: Dictionary = DepressionFillCompute.new().compute_E(w, h, last_height, last_is_land, true, 96)
		var lake_mask_gpu: PackedByteArray = E_out.get("lake", PackedByteArray())
		var lake_mask_for_label: PackedByteArray = lake_mask_gpu
		var E_gpu: PackedFloat32Array = E_out.get("E", PackedFloat32Array())
		var size_gpu: int = w * h
		if E_gpu.size() == size_gpu and lake_mask_gpu.size() == size_gpu:
			var d: float = clamp(-config.sea_level, 0.0, 1.0)
			if d > 0.0:
				lake_mask_for_label = lake_mask_gpu.duplicate()
				for ii_d in range(size_gpu):
					if last_is_land[ii_d] == 0:
						lake_mask_for_label[ii_d] = 0
						continue
					var spill: float = E_gpu[ii_d]
					var eff: float = spill
					if config.sea_level < spill:
						eff = spill - d * (spill - config.sea_level)
					var thresh: float = eff
					if last_temperature.size() == w * h:
						var t_norm_l: float = last_temperature[ii_d]
						var t_c_l: float = config.temp_min_c + t_norm_l * (config.temp_max_c - config.temp_min_c)
						if t_c_l >= 20.0:
							thresh = eff - 0.01
					lake_mask_for_label[ii_d] = (1 if last_height[ii_d] < thresh else 0)
		var pool_gpu := {}
		if lake_mask_for_label.size() == w * h:
			var lab: Dictionary = LakeLabelFromMaskCompute.new().label_from_mask(w, h, lake_mask_for_label, true)
			if not lab.is_empty() and lab.has("lake") and lab.has("lake_id"):
				var boundary_marked: PackedInt32Array = PourPointReduceCompute.new().mark_candidates(w, h, lake_mask_for_label, last_is_land, true)
				var cand_lake_id: PackedInt32Array = lab["lake_id"]
				if boundary_marked.size() == w * h:
					for ii in range(w * h):
						if boundary_marked[ii] == 0: cand_lake_id[ii] = 0
				# For now, keep GPU labels; pour points selection TBD for full GPU
				pool_gpu = {"lake": lab["lake"], "lake_id": lab["lake_id"], "outflow_seeds": PackedInt32Array()}
		if pool_gpu.has("lake") and pool_gpu.has("lake_id"):
			last_lake = pool_gpu["lake"]
			last_lake_id = pool_gpu["lake_id"]
	# No CPU fallback for pooling in GPU-only mode

	# Build shared feature noise cache (shore/shelf/desert/ice fields)
	if _feature_noise_cache != null:
		var cache_params := {
			"width": w,
			"height": h,
			"seed": config.rng_seed,
			"frequency": config.frequency,
			"noise_x_scale": config.noise_x_scale,
		}
		_feature_noise_cache.build(cache_params)
		last_shelf_value_noise_field = _feature_noise_cache.shelf_value_noise_field

	# Step 2: shoreline features
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
		var sx_mul: float = max(0.0001, config.noise_x_scale)
		for y in range(h):
			for x in range(w):
				var i2: int = x + y * w
				shore_noise_field[i2] = _shore_noise.get_noise_2d(float(x) * sx_mul, float(y)) * 0.5 + 0.5
 	# GPU distance-to-coast
	if _dt_compute == null:
		_dt_compute = DistanceTransformCompute.new()
	var d_gpu: PackedFloat32Array = _dt_compute.ocean_distance_to_land(w, h, last_is_land, true)
	if d_gpu.size() == w * h:
		last_water_distance = d_gpu
	# GPU shelf features
	if _shelf_compute == null:
		_shelf_compute = ContinentalShelfCompute.new()
	var out_gpu: Dictionary = _shelf_compute.compute(w, h, last_height, last_is_land, config.sea_level, last_water_distance, shore_noise_field, config.shallow_threshold, config.shore_band, true, config.noise_x_scale)
	if out_gpu.size() > 0:
		last_turquoise_water = out_gpu.get("turquoise_water", last_turquoise_water)
		last_beach = out_gpu.get("beach", last_beach)
		last_turquoise_strength = out_gpu.get("turquoise_strength", last_turquoise_strength)

 	# Step 3: climate via GPU
	params["distance_to_coast"] = last_water_distance
	var climate: Dictionary
	if _climate_compute_gpu == null:
		_climate_compute_gpu = ClimateAdjustCompute.new()
	# time_of_day is set via SeasonalClimateSystem apply_config; nothing to do here
	climate = _climate_compute_gpu.evaluate(w, h, last_height, last_is_land, _climate_base, params, last_water_distance, last_ocean_fraction)
	last_temperature = climate["temperature"]
	last_moisture = climate["moisture"]
	last_distance_to_coast = last_water_distance

	# Deactivated: clouds overlay generation
	if last_clouds.size() != w * h:
		last_clouds.resize(w * h)
		for i_c in range(w * h): last_clouds[i_c] = 0.0

 	# Mountain radiance: run through ClimatePost GPU
	var climpost: Object = load("res://scripts/systems/ClimatePostCompute.gd").new()
	var post: Dictionary = climpost.apply_mountain_radiance(w, h, last_biomes, last_temperature, last_moisture, config.mountain_cool_amp, config.mountain_wet_amp, max(0, config.mountain_radiance_passes))
	if not post.is_empty():
		last_temperature = post["temperature"]
		last_moisture = post["moisture"]

 	# Step 4: biomes — GPU compute
	var params2 := params.duplicate()
	params2["freeze_temp_threshold"] = 0.16
	params2["height_scale_m"] = config.height_scale_m
	params2["lapse_c_per_km"] = 5.5
	# Animated biome jitter to avoid banding and allow evolution
	params2["biome_noise_strength_c"] = 0.8
	params2["biome_moist_jitter"] = 0.06
	params2["biome_phase"] = float(Time.get_ticks_msec() % 60000) / 60000.0
	params2["biome_moist_jitter2"] = 0.03
	params2["biome_moist_islands"] = 0.35
	params2["biome_moist_elev_dry"] = 0.35
	var desert_field := PackedFloat32Array()
	if _feature_noise_cache != null:
		desert_field = _feature_noise_cache.desert_noise_field
	var beach_mask := last_beach
	var bc: Object = load("res://scripts/systems/BiomeCompute.gd").new()
	var biomes_gpu: PackedInt32Array = bc.classify(w, h, last_height, last_is_land, last_temperature, last_moisture, beach_mask, desert_field, params2)
	if biomes_gpu.size() == w * h:
		last_biomes = biomes_gpu
	# BiomePost: apply hot/cold overrides + lava + salt desert (GPU)
	var bp: Object = load("res://scripts/systems/BiomePostCompute.gd").new()
	var post2: Dictionary = bp.apply_overrides_and_lava(w, h, last_is_land, last_temperature, last_moisture, last_biomes, config.temp_min_c, config.temp_max_c, config.lava_temp_threshold_c, last_lake)
	if not post2.is_empty():
		last_biomes = post2["biomes"]
		last_lava = post2["lava"]
	# Volcanism step (GPU): spawn/decay lava along plate boundaries + hotspots
	var volcanism: Object = load("res://scripts/systems/VolcanismCompute.gd").new()
	if "cell_plate_id" in self and "_plates_sys" in (get_script().get_global_name() if false else {}):
		pass # placeholder to avoid lints; actual plate boundary comes from PlateSystem
	# Best-effort: if a boundary mask was produced by PlateSystem and stored in state, use it. Else, create empty.
	var bnd_i32 := PackedInt32Array(); bnd_i32.resize(w * h)
	if "_plates_sys" in self:
		# If PlateSystem exposed boundary mask in generator, use it
		# Fallback: leave zeros
		pass
	var lava_f32 := PackedFloat32Array()
	lava_f32.resize(w * h)
	for i_l in range(w * h): lava_f32[i_l] = float(last_lava[i_l] if i_l < last_lava.size() else 0)
	var lava_out: PackedFloat32Array = volcanism.step(w, h, bnd_i32, lava_f32, float(1.0/120.0), {
		"decay_rate_per_day": 0.02,
		"spawn_boundary_rate_per_day": 0.05,
		"hotspot_rate_per_day": 0.01,
		"hotspot_threshold": 0.995,
	}, fposmod(float(Time.get_ticks_msec()) / 1000.0, 1.0), int(config.rng_seed))
	if lava_out.size() == w * h:
		# Threshold to byte mask
		last_lava.resize(w * h)
		for li in range(w * h): last_lava[li] = (1 if lava_out[li] > 0.5 else 0)

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
		var _max_lakes_guess: int = max(4, floori(float(w * h) / 2048.0))
		var hydro2: Dictionary
		if _flow_compute == null:
			_flow_compute = FlowCompute.new()
		var fc_out: Dictionary = _flow_compute.compute_flow(w, h, last_height, last_is_land, true)
		if fc_out.size() > 0:
			hydro2 = fc_out
		last_flow_dir = hydro2["flow_dir"]
		last_flow_accum = hydro2["flow_accum"]
		# Use strict-fill lake if provided
		if hydro2.has("lake"):
			last_lake = hydro2["lake"]
		if hydro2.has("lake_id"):
			last_lake_id = hydro2["lake_id"]
		# Trace and prune rivers on GPU
		if _river_compute == null:
			_river_compute = RiverCompute.new()
		var forced: PackedInt32Array = hydro2.get("outflow_seeds", PackedInt32Array())
		var river_gpu: PackedByteArray = _river_compute.trace_rivers_roi(w, h, last_is_land, last_lake, last_flow_dir, last_flow_accum, 0.97, 5, Rect2i(0,0,0,0), forced)
		if river_gpu.size() == w * h:
			last_river = river_gpu
		# GPU river delta widening (post)
		var rpost: Object = load("res://scripts/systems/RiverPostCompute.gd").new()
		var widened: PackedByteArray = rpost.widen_deltas(w, h, last_river, last_is_land, last_water_distance, config.shore_band + config.shallow_threshold)
		if widened.size() == w * h:
			last_river = widened
		# River meander (GPU): subtle lateral shifts
		var meander: Object = load("res://scripts/systems/RiverMeanderCompute.gd").new()
		var meandered: PackedByteArray = meander.step(w, h, last_flow_dir, last_flow_accum, last_river, float(1.0/120.0), 0.3, 0.2, fposmod(float(Time.get_ticks_msec()) / 1000.0, 1.0))
		if meandered.size() == w * h:
			last_river = meandered
		if hydro2.has("lake") and config.lakes_enabled:
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
		# No terrain yet; do full generate
		return generate()
	# 1) Recompute land mask
	if last_is_land.size() != size:
		last_is_land.resize(size)
	var prev_is_land := PackedByteArray()
	prev_is_land.resize(size)
	for i in range(size):
		prev_is_land[i] = last_is_land[i] if i < last_is_land.size() else 0
	for i in range(size):
		last_is_land[i] = 1 if last_height_final[i] > config.sea_level else 0
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
	# Recompute via GPU only
	var shore_noise_field := PackedFloat32Array()
	if _feature_noise_cache != null and _feature_noise_cache.shore_noise_field.size() == size:
		shore_noise_field = _feature_noise_cache.shore_noise_field
	else:
		shore_noise_field.resize(size)
		for yy in range(h):
			for xx in range(w):
				var ii: int = xx + yy * w
				shore_noise_field[ii] = _shore_noise.get_noise_2d(float(xx), float(yy)) * 0.5 + 0.5
	# Distance to coast on GPU
	if _dt_compute == null:
		_dt_compute = DistanceTransformCompute.new()
	var d_gpu2: PackedFloat32Array = _dt_compute.ocean_distance_to_land(w, h, last_is_land, true)
	if d_gpu2.size() == w * h:
		last_water_distance = d_gpu2
	# Shelf features on GPU using finalized distance
	if _shelf_compute == null:
		_shelf_compute = ContinentalShelfCompute.new()
	var out_gpu2: Dictionary = _shelf_compute.compute(w, h, last_height, last_is_land, config.sea_level, last_water_distance, shore_noise_field, config.shallow_threshold, config.shore_band, true, config.noise_x_scale)
	if out_gpu2.size() > 0:
		last_turquoise_water = out_gpu2.get("turquoise_water", last_turquoise_water)
		last_beach = out_gpu2.get("beach", last_beach)
		last_turquoise_strength = out_gpu2.get("turquoise_strength", last_turquoise_strength)
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
		"noise_x_scale": config.noise_x_scale,
		"season_phase": config.season_phase,
		"season_amp_equator": config.season_amp_equator,
		"season_amp_pole": config.season_amp_pole,
		"season_ocean_damp": config.season_ocean_damp,
	}
	params["distance_to_coast"] = last_water_distance
	var climate: Dictionary
	if _climate_compute_gpu == null:
		_climate_compute_gpu = ClimateAdjustCompute.new()
	climate = _climate_compute_gpu.evaluate(w, h, last_height, last_is_land, _climate_base, params, last_water_distance, last_ocean_fraction)
	last_temperature = climate["temperature"]
	last_moisture = climate["moisture"]
	last_distance_to_coast = last_water_distance

	# 5) Reclassify biomes using updated climate (band-limited near coastline)
	var params2 := params.duplicate()
	params2["freeze_temp_threshold"] = 0.16
	params2["height_scale_m"] = config.height_scale_m
	params2["lapse_c_per_km"] = 5.5
	params2["continentality_scale"] = config.continentality_scale
	var new_biomes := PackedInt32Array()
	if config.use_gpu_all:
		var desert_field2 := PackedFloat32Array()
		if _feature_noise_cache != null:
			desert_field2 = _feature_noise_cache.desert_noise_field
		var bc2: Object = load("res://scripts/systems/BiomeCompute.gd").new()
		var biomes_gpu2: PackedInt32Array = bc2.classify(w, h, last_height, last_is_land, last_temperature, last_moisture, last_beach, desert_field2, params2)
		if biomes_gpu2.size() == size:
			new_biomes = biomes_gpu2
		else:
			# GPU-only: keep previous biomes if classify failed to return full buffer
			new_biomes = last_biomes
	else:
		# GPU-only mode; no CPU classifier
		new_biomes = last_biomes
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
	var post2: Dictionary = BiomePost.new().apply_overrides_and_lava(w, h, last_is_land, last_temperature, last_moisture, last_biomes, config.temp_min_c, config.temp_max_c, config.lava_temp_threshold_c, last_lake, last_pooled_lake)
	last_biomes = post2["biomes"]
	last_lava = post2["lava"]

	# 6) Lakes and rivers recompute on sea-level change (order: lakes, then rivers)
	if config.use_gpu_all:
		# Lakes (GPU preferred)
		if _lake_label_compute == null:
			_lake_label_compute = load("res://scripts/systems/LakeLabelCompute.gd").new()
		# Prefer strict CPU pooling for quick sea-level updates too (if enabled)
		var pool2: Dictionary
		if config.realistic_pooling_enabled and config.lakes_enabled:
			# Sea-level quick path: prefer GPU fill+label, fallback to CPU strict pooling
			var E2: Dictionary = DepressionFillCompute.new().compute_E(w, h, last_height, last_is_land, true, 64)
			var lake_mask2: PackedByteArray = E2.get("lake", PackedByteArray())
			# Drying coupling during quick sea-level updates (GPU)
			var lake_mask2_adj: PackedByteArray = lake_mask2
			var E2f: PackedFloat32Array = E2.get("E", PackedFloat32Array())
			var size_q: int = w * h
			if E2f.size() == size_q and lake_mask2.size() == size_q:
				var d2: float = clamp(-config.sea_level, 0.0, 1.0)
				if d2 > 0.0:
					lake_mask2_adj = lake_mask2.duplicate()
					for qi in range(size_q):
						if last_is_land[qi] == 0:
							lake_mask2_adj[qi] = 0
							continue
						var spill_q: float = E2f[qi]
						var eff_q: float = spill_q
						if config.sea_level < spill_q:
							eff_q = spill_q - d2 * (spill_q - config.sea_level)
						lake_mask2_adj[qi] = (1 if last_height[qi] < eff_q else 0)
			var pool2_gpu := {}
			if lake_mask2_adj.size() == w * h:
				var lab2: Dictionary = LakeLabelFromMaskCompute.new().label_from_mask(w, h, lake_mask2_adj, true)
				if not lab2.is_empty() and lab2.has("lake") and lab2.has("lake_id"):
					# GPU-only: skip pour point computation for now
					pool2_gpu = {"lake": lab2["lake"], "lake_id": lab2["lake_id"], "outflow_seeds": PackedInt32Array()}
			if pool2_gpu.has("lake") and pool2_gpu.has("lake_id"):
				pool2 = pool2_gpu
		else:
			# GPU-only: prefer label-from-mask when available; no CPU fallbacks
			pool2 = _lake_label_compute.label_lakes(w, h, last_is_land, true)
		if config.lakes_enabled:
			last_lake = pool2["lake"]
			last_lake_id = pool2["lake_id"]
		else:
			# If lakes disabled, clear lake masks
			var sz2 := w * h
			last_lake.resize(sz2)
			last_lake_id.resize(sz2)
			for i2 in range(sz2):
				last_lake[i2] = 0
				last_lake_id[i2] = 0
		# Flow & rivers (GPU preferred)
		if _flow_compute == null:
			_flow_compute = FlowCompute.new()
		var hydro3: Dictionary = _flow_compute.compute_flow(w, h, last_height, last_is_land, true)
		# GPU-only: no CPU hydro fallback
		last_flow_dir = hydro3.get("flow_dir", last_flow_dir)
		last_flow_accum = hydro3.get("flow_accum", last_flow_accum)
		if _river_compute == null:
			_river_compute = RiverCompute.new()
		var forced2: PackedInt32Array = pool2.get("outflow_seeds", PackedInt32Array())
		var river_gpu: PackedByteArray = _river_compute.trace_rivers_roi(w, h, last_is_land, last_lake, last_flow_dir, last_flow_accum, 0.97, 5, Rect2i(0,0,0,0), forced2)
		if river_gpu.size() == w * h:
			last_river = river_gpu
		# Delta widening (GPU/CPU)
		var rpost: Object = load("res://scripts/systems/RiverPostCompute.gd").new()
		var widened: PackedByteArray = rpost.widen_deltas(w, h, last_river, last_is_land, last_water_distance, config.shore_band + config.shallow_threshold)
		if widened.size() == w * h:
			last_river = widened
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
		# GPU-only: if rivers disabled, clear fields
		var sz: int = w * h
		last_flow_dir.resize(sz)
		last_flow_accum.resize(sz)
		last_river.resize(sz)
		for kk in range(sz):
			last_flow_dir[kk] = -1
			last_flow_accum[kk] = 0.0
			last_river[kk] = 0

	# Lava mask computed in BiomePost
	return last_is_land


func quick_update_climate() -> void:
	# Recompute only climate (temperature/moisture/precip) using existing terrain, land mask,
	# water distance, and seasonal parameters. Also re-apply mountain radiance.
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size or last_is_land.size() != size:
		return
	# Build climate params from current config and state
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
		"noise_x_scale": config.noise_x_scale,
		"season_phase": config.season_phase,
		"season_amp_equator": config.season_amp_equator,
		"season_amp_pole": config.season_amp_pole,
		"season_ocean_damp": config.season_ocean_damp,
		"diurnal_amp_equator": config.diurnal_amp_equator,
		"diurnal_amp_pole": config.diurnal_amp_pole,
		"diurnal_ocean_damp": config.diurnal_ocean_damp,
		"time_of_day": config.time_of_day,
		"day_of_year": config.season_phase,
		"day_night_base": config.day_night_base,
		"day_night_contrast": config.day_night_contrast,
	}
	params["distance_to_coast"] = last_water_distance
	
	if _climate_compute_gpu == null:
		_climate_compute_gpu = ClimateAdjustCompute.new()
	
	# Fast path: if only seasonal/diurnal phases changed, use cycle_apply_only
	# This is a simplification - in a full implementation you'd track what changed
	var use_fast_path = last_temperature.size() == size
	
	if use_fast_path:
		# Apply only cycles to existing temperature
		last_temperature = _climate_compute_gpu.apply_cycles_only(w, h, last_temperature, last_is_land, last_water_distance, params)
	else:
		# Full climate recompute
		var climate: Dictionary = _climate_compute_gpu.evaluate(w, h, last_height, last_is_land, _climate_base, params, last_water_distance, last_ocean_fraction)
		if climate.size() > 0:
			last_temperature = climate.get("temperature", last_temperature)
			last_moisture = climate.get("moisture", last_moisture)
			# Apply mountain radiance smoothing on updated climate (GPU)
			var climpost: Object = load("res://scripts/systems/ClimatePostCompute.gd").new()
			var post: Dictionary = climpost.apply_mountain_radiance(w, h, last_biomes, last_temperature, last_moisture, config.mountain_cool_amp, config.mountain_wet_amp, max(0, config.mountain_radiance_passes))
			if not post.is_empty():
				last_temperature = post["temperature"]
				last_moisture = post["moisture"]
	
	# Always update light field (cheap)
	last_light = _climate_compute_gpu.evaluate_light_field(w, h, params)
	# Fallback if light field evaluation failed
	if last_light.size() != w * h:
		last_light.resize(w * h)
		last_light.fill(1.0)  # Default to full brightness

func quick_update_biomes() -> void:
	# Reclassify biomes using current climate (temperature/moisture) and height/land/beach.
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size or last_is_land.size() != size or last_temperature.size() != size or last_moisture.size() != size:
		return
	var params2 := {
		"width": w,
		"height": h,
		"seed": config.rng_seed,
		"freeze_temp_threshold": 0.16,
		"height_scale_m": config.height_scale_m,
		"lapse_c_per_km": 5.5,
		"noise_x_scale": config.noise_x_scale,
		"temp_min_c": config.temp_min_c,
		"temp_max_c": config.temp_max_c,
	}
	# Animated biome jitter to avoid banding and allow evolution
	params2["biome_noise_strength_c"] = 0.8
	params2["biome_moist_jitter"] = 0.06
	params2["biome_phase"] = float(Time.get_ticks_msec() % 60000) / 60000.0
	params2["biome_moist_jitter2"] = 0.03
	params2["biome_moist_islands"] = 0.35
	params2["biome_moist_elev_dry"] = 0.35
	# GPU classify only
	var desert_field := PackedFloat32Array()
	if _feature_noise_cache != null:
		desert_field = _feature_noise_cache.desert_noise_field
	var beach_mask := last_beach
	var bc: Object = load("res://scripts/systems/BiomeCompute.gd").new()
	var biomes_gpu: PackedInt32Array = bc.classify(w, h, last_height, last_is_land, last_temperature, last_moisture, beach_mask, desert_field, params2)
	if biomes_gpu.size() == w * h:
		last_biomes = biomes_gpu
	# Postprocess: hot/cold overrides + lava
	var bp: Object = load("res://scripts/systems/BiomePostCompute.gd").new()
	var post2: Dictionary = bp.apply_overrides_and_lava(w, h, last_is_land, last_temperature, last_moisture, last_biomes, config.temp_min_c, config.temp_max_c, config.lava_temp_threshold_c, last_lake)
	if not post2.is_empty():
		last_biomes = post2.get("biomes", last_biomes)
		last_lava = post2.get("lava", last_lava)
	_ensure_valid_biomes()


func quick_update_flow_rivers() -> void:
	# Recompute flow direction, accumulation, and river mask from current fields.
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size or last_is_land.size() != size:
		return
	if _flow_compute == null:
		_flow_compute = FlowCompute.new()
	var fc_out: Dictionary = _flow_compute.compute_flow(w, h, last_height, last_is_land, true)
	if fc_out.size() > 0:
		last_flow_dir = fc_out.get("flow_dir", last_flow_dir)
		last_flow_accum = fc_out.get("flow_accum", last_flow_accum)
		if _river_compute == null:
			_river_compute = RiverCompute.new()
		var forced: PackedInt32Array = fc_out.get("outflow_seeds", PackedInt32Array())
		var river_gpu: PackedByteArray = _river_compute.trace_rivers_roi(w, h, last_is_land, last_lake, last_flow_dir, last_flow_accum, 0.97, 5, Rect2i(0,0,0,0), forced)
		if river_gpu.size() == size:
			last_river = river_gpu
			var rpost: Object = load("res://scripts/systems/RiverPostCompute.gd").new()
			var widened: PackedByteArray = rpost.widen_deltas(w, h, last_river, last_is_land, last_water_distance, config.shore_band + config.shallow_threshold)
			if widened.size() == size:
				last_river = widened

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
			# Promote lava field as its own biome name
			if i < last_lava.size() and last_lava[i] != 0:
				biome_id = BiomeClassifier.Biome.LAVA_FIELD if BiomeClassifier.Biome.has("LAVA_FIELD") else bid
				biome_name = "Lava Field"
			else:
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
	# Apply descriptive prefixes for extreme temperatures in info panel
	var display_name: String = biome_name
	if land and not is_lava:
		var bid2: int = (last_biomes[i] if i < last_biomes.size() else -1)
		if temp_c <= -5.0:
			if bid2 != BiomeClassifier.Biome.GLACIER and bid2 != BiomeClassifier.Biome.DESERT_ICE and bid2 != BiomeClassifier.Biome.ICE_SHEET and bid2 != BiomeClassifier.Biome.FROZEN_FOREST and bid2 != BiomeClassifier.Biome.FROZEN_MARSH:
				display_name = "Frozen " + display_name
		elif temp_c >= 45.0:
			if bid2 != BiomeClassifier.Biome.LAVA_FIELD:
				display_name = "Scorched " + display_name
	return {
		"height": h_val,
		"is_land": land,
		"is_beach": beach,
		"is_turquoise_water": turq,
		"is_lava": is_lava,
		"is_river": is_river,
		"is_lake": is_lake,
		"biome": biome_id,
		"biome_name": display_name,
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
		BiomeClassifier.Biome.WASTELAND:
			return "Wasteland"
		BiomeClassifier.Biome.DESERT_ICE:
			return "Ice Desert"
		BiomeClassifier.Biome.STEPPE:
			return "Steppe"
		BiomeClassifier.Biome.GRASSLAND:
			return "Grassland"
		BiomeClassifier.Biome.SWAMP:
			return "Swamp"
		BiomeClassifier.Biome.BOREAL_FOREST:
			return "Boreal Forest"
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return "Temperate Forest"
		BiomeClassifier.Biome.RAINFOREST:
			return "Rainforest"
		BiomeClassifier.Biome.HILLS:
			return "Hills"
		BiomeClassifier.Biome.MOUNTAINS:
			return "Mountains"
		BiomeClassifier.Biome.ALPINE:
			return "Alpine"
		BiomeClassifier.Biome.FROZEN_FOREST:
			return "Frozen Forest"
		BiomeClassifier.Biome.FROZEN_MARSH:
			return "Frozen Marsh"
		BiomeClassifier.Biome.FROZEN_GRASSLAND:
			return "Frozen Grassland"
		BiomeClassifier.Biome.FROZEN_STEPPE:
			return "Frozen Steppe"
		# Frozen Meadow/Prairie merged into Frozen Grassland
		BiomeClassifier.Biome.FROZEN_SAVANNA:
			return "Frozen Savanna"
		BiomeClassifier.Biome.FROZEN_HILLS:
			return "Frozen Hills"
		# Foothills merged into Hills
		BiomeClassifier.Biome.SCORCHED_GRASSLAND:
			return "Scorched Grassland"
		BiomeClassifier.Biome.SCORCHED_STEPPE:
			return "Scorched Steppe"
		# Scorched Meadow/Prairie merged into Scorched Grassland
		BiomeClassifier.Biome.SCORCHED_SAVANNA:
			return "Scorched Savanna"
		BiomeClassifier.Biome.SCORCHED_HILLS:
			return "Scorched Hills"
		# Foothills merged into Hills
		BiomeClassifier.Biome.SALT_DESERT:
			return "Salt Desert"
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
		return BiomeClassifier.Biome.WASTELAND
	if cold > 0.6 and dry > 0.4:
		return BiomeClassifier.Biome.DESERT_ICE
	if wet > 0.6 and hot > 0.4:
		return BiomeClassifier.Biome.RAINFOREST
	if m > 0.55 and t > 0.5:
		return BiomeClassifier.Biome.RAINFOREST
	if wet > 0.5 and cold > 0.4:
		return BiomeClassifier.Biome.SWAMP
	if cold > 0.6:
		return BiomeClassifier.Biome.BOREAL_FOREST
	if m > 0.6 and t > 0.5:
		return BiomeClassifier.Biome.TEMPERATE_FOREST
	if m > 0.4 and t > 0.4:
		return BiomeClassifier.Biome.BOREAL_FOREST
	if m > 0.3 and t > 0.3:
		return BiomeClassifier.Biome.GRASSLAND
	if m > 0.25 and t > 0.35:
		return BiomeClassifier.Biome.GRASSLAND
	if m > 0.2 and t > 0.25:
		return BiomeClassifier.Biome.STEPPE
	if high > 0.3:
		return BiomeClassifier.Biome.HILLS
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
					last_biomes[i] = BiomeClassifier.Biome.DESERT_SAND if noise_val < sand_prob else BiomeClassifier.Biome.WASTELAND
				else:
					# Hot but not very dry: keep relief unless quite dry
					if (b == BiomeClassifier.Biome.MOUNTAINS or b == BiomeClassifier.Biome.ALPINE or b == BiomeClassifier.Biome.HILLS):
						if m < 0.35:
							last_biomes[i] = BiomeClassifier.Biome.WASTELAND
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
					last_biomes[i] = BiomeClassifier.Biome.WASTELAND

# GPU Buffer Management for Persistent SSBOs
func ensure_persistent_buffers() -> void:
	"""Allocate persistent GPU buffers for all major world data"""
	if _gpu_buffer_manager == null:
		return
	
	var size = config.width * config.height
	var float_size = size * 4  # 4 bytes per float32
	var _byte_size = size      # 1 byte per byte
	var int_size = size * 4   # 4 bytes per int32
	
	# Allocate persistent buffers for common data
	_gpu_buffer_manager.ensure_buffer("height", float_size, last_height.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("is_land", int_size, _pack_bytes_to_u32(last_is_land).to_byte_array())
	_gpu_buffer_manager.ensure_buffer("temperature", float_size, last_temperature.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("moisture", float_size, last_moisture.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("flow_dir", int_size, last_flow_dir.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("flow_accum", float_size, last_flow_accum.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("biome_id", int_size, last_biomes.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("river", int_size, _pack_bytes_to_u32(last_river).to_byte_array())
	_gpu_buffer_manager.ensure_buffer("lake", int_size, _pack_bytes_to_u32(last_lake).to_byte_array())
	_gpu_buffer_manager.ensure_buffer("lake_id", int_size, last_lake_id.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("distance", float_size, last_distance_to_coast.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("clouds", float_size, last_clouds.to_byte_array())
	_gpu_buffer_manager.ensure_buffer("light", float_size, last_light.to_byte_array())

func _pack_bytes_to_u32(byte_array: PackedByteArray) -> PackedInt32Array:
	"""Convert PackedByteArray to PackedInt32Array for GPU use"""
	var result = PackedInt32Array()
	result.resize(byte_array.size())
	for i in range(byte_array.size()):
		result[i] = 1 if byte_array[i] != 0 else 0
	return result

func update_persistent_buffer(name: String, data: PackedByteArray) -> bool:
	"""Update a persistent buffer with new data"""
	if _gpu_buffer_manager == null:
		return false
	return _gpu_buffer_manager.update_buffer(name, data)

func get_persistent_buffer(name: String) -> RID:
	"""Get a persistent buffer RID for compute shader binding"""
	if _gpu_buffer_manager == null:
		return RID()
	return _gpu_buffer_manager.get_buffer(name)

func read_persistent_buffer(name: String) -> PackedByteArray:
	"""Read data back from a persistent buffer (should be used sparingly)"""
	if _gpu_buffer_manager == null:
		return PackedByteArray()
	return _gpu_buffer_manager.read_buffer(name, name)

func get_buffer_memory_stats() -> Dictionary:
	"""Get GPU buffer memory usage statistics"""
	if _gpu_buffer_manager == null:
		return {"error": "Buffer manager not initialized"}
	return _gpu_buffer_manager.get_buffer_stats()

func cleanup_gpu_resources() -> void:
	"""Clean up GPU resources when shutting down"""
	if _gpu_buffer_manager != null:
		_gpu_buffer_manager.cleanup()
