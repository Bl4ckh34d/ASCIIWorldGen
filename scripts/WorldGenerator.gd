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
const ClimateAdjustCompute = preload("res://scripts/systems/ClimateAdjustCompute.gd")
const BiomeCompute = preload("res://scripts/systems/BiomeCompute.gd")
var BiomePost = load("res://scripts/systems/BiomePost.gd")
const BiomePostCompute = preload("res://scripts/systems/BiomePostCompute.gd")
const LithologyCompute = preload("res://scripts/systems/LithologyCompute.gd")
var FlowErosionSystem = load("res://scripts/systems/FlowErosionSystem.gd")
const FlowCompute = preload("res://scripts/systems/FlowCompute.gd")
const RiverCompute = preload("res://scripts/systems/RiverCompute.gd")
const RiverPostCompute = preload("res://scripts/systems/RiverPostCompute.gd")
const RiverMeanderCompute = preload("res://scripts/systems/RiverMeanderCompute.gd")
const VolcanismCompute = preload("res://scripts/systems/VolcanismCompute.gd")
const CloudOverlayCompute = preload("res://scripts/systems/CloudOverlayCompute.gd")
const LandMaskCompute = preload("res://scripts/systems/LandMaskCompute.gd")
const LakeLabelCompute = preload("res://scripts/systems/LakeLabelCompute.gd")
const DepressionFillCompute = preload("res://scripts/systems/DepressionFillCompute.gd")
const LakeLabelFromMaskCompute = preload("res://scripts/systems/LakeLabelFromMaskCompute.gd")
const PourPointReduceCompute = preload("res://scripts/systems/PourPointReduceCompute.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")
const WorldData1TextureCompute = preload("res://scripts/systems/WorldData1TextureCompute.gd")
const WorldData2TextureCompute = preload("res://scripts/systems/WorldData2TextureCompute.gd")
var _terrain_compute: Object = null
var _dt_compute: Object = null
var _shelf_compute: Object = null
var _climate_compute_gpu: Object = null
var _flow_compute: Object = null
var _river_compute: Object = null
var _lake_label_compute: Object = null
var _gpu_buffer_manager: Object = null
var _land_mask_compute: Object = null
var _lithology_compute: Object = null
var _biome_compute: Object = null
var _biome_post_compute: Object = null
var _climate_post_compute: Object = null
var _volcanism_compute: Object = null
var _cloud_overlay_compute: Object = null
var _river_post_compute: Object = null
var _river_meander_compute: Object = null

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
	var lava_temp_threshold_c: float = 120.0
	# Rivers toggle
	var rivers_enabled: bool = true
	# River flow threshold (absolute seed threshold in GPU-only mode).
	var river_threshold: float = 1.0
	# Multiplier applied to river_threshold in GPU-only seeding.
	var river_threshold_factor: float = 1.0
	# Widen river deltas near coast
	var river_delta_widening: bool = true
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
	# Diurnal temperature cycle (enhanced for visibility)
	var diurnal_amp_equator: float = 0.06
	var diurnal_amp_pole: float = 0.03
	var diurnal_ocean_damp: float = 0.6
	var time_of_day: float = 0.0
	# Day-night visual settings
	var day_night_contrast: float = 0.75
	var day_night_base: float = 0.25
	# Intro-scene moon system propagated into world light field
	var moon_count: int = 0
	var moon_seed: float = 0.0
	var moon_shadow_strength: float = 0.55
	# Mountain radiance influence
	var mountain_cool_amp: float = 0.15
	var mountain_wet_amp: float = 0.10
	var mountain_radiance_passes: int = 3
	# Feature flags
	var realistic_pooling_enabled: bool = true
	# Pooling/outflow params
	var max_forced_outflows: int = 3
	var prob_outflow_0: float = 0.50
	var prob_outflow_1: float = 0.35
	var prob_outflow_2: float = 0.10
	var prob_outflow_3: float = 0.05
	# Horizontal noise stretch for ASCII aspect compensation (x multiplier applied to noise samples)
	var noise_x_scale: float = 0.5
	# Guardrails: prevent near-zero oceans when sea level is too low (0 disables clamp)
	var min_ocean_fraction: float = 0.0
	# Lakes shrink as oceans recede; when ocean_fraction == lake_fill_ocean_ref, lakes are full.
	var lake_fill_ocean_ref: float = 1.0

var config := Config.new()
var debug_parity: bool = false
const CLIMATE_CPU_MIRROR_MAX_CELLS: int = 250000

var _noise := FastNoiseLite.new()
var _warp_noise := FastNoiseLite.new()
var _shore_noise := FastNoiseLite.new()

var last_height: PackedFloat32Array = PackedFloat32Array()
var last_height_final: PackedFloat32Array = PackedFloat32Array()
var last_is_land: PackedByteArray = PackedByteArray()
var last_turquoise_water: PackedByteArray = PackedByteArray()
var last_beach: PackedByteArray = PackedByteArray()
var last_biomes: PackedInt32Array = PackedInt32Array()
var last_rock_type: PackedInt32Array = PackedInt32Array()
var last_fertility: PackedFloat32Array = PackedFloat32Array()
var last_water_distance: PackedFloat32Array = PackedFloat32Array()
var last_turquoise_strength: PackedFloat32Array = PackedFloat32Array()
var last_temperature: PackedFloat32Array = PackedFloat32Array()
var last_moisture: PackedFloat32Array = PackedFloat32Array()
var last_distance_to_coast: PackedFloat32Array = PackedFloat32Array()
var last_lava: PackedByteArray = PackedByteArray()
var last_ocean_fraction: float = 0.0
var last_shelf_value_noise_field: PackedFloat32Array = PackedFloat32Array()
var last_desert_noise_field: PackedFloat32Array = PackedFloat32Array()
var last_lake: PackedByteArray = PackedByteArray()
var last_lake_id: PackedInt32Array = PackedInt32Array()
var last_flow_dir: PackedInt32Array = PackedInt32Array()
var last_flow_accum: PackedFloat32Array = PackedFloat32Array()
var last_river: PackedByteArray = PackedByteArray()
var last_pooled_lake: PackedByteArray = PackedByteArray()
var last_clouds: PackedFloat32Array = PackedFloat32Array()
var last_river_seed_threshold: float = 4.0
var cloud_texture_override: Texture2D = null
var light_texture_override: Texture2D = null
var river_texture_override: Texture2D = null
var biome_texture_override: Texture2D = null
var lava_texture_override: Texture2D = null
var world_data_1_override: Texture2D = null
var world_data_2_override: Texture2D = null
var last_light: PackedFloat32Array = PackedFloat32Array()
var biome_phase: float = 0.0
var _temperature_base_offset_ref: float = 0.0
var _temperature_base_scale_ref: float = 1.0

# Exposed by PlateSystem for coupling (GPU boundary mask as i32)
var _plates_boundary_mask_i32: PackedInt32Array = PackedInt32Array()
var _plates_boundary_mask_render_u8: PackedByteArray = PackedByteArray()
var _plates_cell_id_i32: PackedInt32Array = PackedInt32Array()
var _plates_vel_u: PackedFloat32Array = PackedFloat32Array()
var _plates_vel_v: PackedFloat32Array = PackedFloat32Array()
var _plates_buoyancy: PackedFloat32Array = PackedFloat32Array()

# Tectonic activity statistics
var tectonic_stats: Dictionary = {}

# Volcanic activity statistics  
var volcanic_stats: Dictionary = {}

# Parity/validation metrics removed for GPU-only mode
var debug_last_metrics: Dictionary = {}

# Phase 0 scaffolding: central state and shared noise cache (currently unused)
var _world_state: Object = null
var _feature_noise_cache: Object = null
var _climate_base: Dictionary = {}
var _world_data1_tex_compute: Object = null
var _world_data2_tex_compute: Object = null
var _buffers_seeded: bool = false
var _buffer_seed_size: int = 0
var _max_valid_biome_id_cache: int = -1
var _debug_cache_valid: bool = false
var _debug_cache_x0: int = 0
var _debug_cache_y0: int = 0
var _debug_cache_w: int = 0
var _debug_cache_h: int = 0
var _debug_cache_height: PackedFloat32Array = PackedFloat32Array()
var _debug_cache_land: PackedInt32Array = PackedInt32Array()
var _debug_cache_beach: PackedInt32Array = PackedInt32Array()
var _debug_cache_lava: PackedFloat32Array = PackedFloat32Array()
var _debug_cache_river: PackedInt32Array = PackedInt32Array()
var _debug_cache_lake: PackedInt32Array = PackedInt32Array()
var _debug_cache_temp: PackedFloat32Array = PackedFloat32Array()
var _debug_cache_moist: PackedFloat32Array = PackedFloat32Array()
var _debug_cache_biome: PackedInt32Array = PackedInt32Array()
var _debug_cache_rock: PackedInt32Array = PackedInt32Array()
var _debug_cache_fertility: PackedFloat32Array = PackedFloat32Array()

func _init() -> void:
	randomize()
	config.rng_seed = randi()
	biome_phase = _compute_biome_phase(config.rng_seed)
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
	var seed_changed: bool = dict.has("seed")
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
	if dict.has("min_ocean_fraction"):
		config.min_ocean_fraction = clamp(float(dict["min_ocean_fraction"]), 0.0, 0.95)
	if dict.has("lake_fill_ocean_ref"):
		config.lake_fill_ocean_ref = clamp(float(dict["lake_fill_ocean_ref"]), 0.05, 1.0)
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
		config.lava_temp_threshold_c = max(120.0, float(dict["lava_temp_threshold_c"]))
	if dict.has("river_threshold"):
		config.river_threshold = max(0.0, float(dict["river_threshold"]))
	if dict.has("rivers_enabled"):
		config.rivers_enabled = bool(dict["rivers_enabled"])
	if dict.has("river_threshold_factor"):
		config.river_threshold_factor = clamp(float(dict["river_threshold_factor"]), 0.1, 5.0)
	if dict.has("river_delta_widening"):
		config.river_delta_widening = bool(dict["river_delta_widening"])
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
	if dict.has("day_night_base"):
		config.day_night_base = clamp(float(dict["day_night_base"]), 0.0, 1.0)
	if dict.has("day_night_contrast"):
		config.day_night_contrast = clamp(float(dict["day_night_contrast"]), 0.0, 2.0)
	if dict.has("moon_count"):
		config.moon_count = clamp(int(dict["moon_count"]), 0, 3)
	if dict.has("moon_seed"):
		config.moon_seed = max(0.0, float(dict["moon_seed"]))
	if dict.has("moon_shadow_strength"):
		config.moon_shadow_strength = clamp(float(dict["moon_shadow_strength"]), 0.0, 1.0)
	if dict.has("mountain_cool_amp"):
		config.mountain_cool_amp = float(dict["mountain_cool_amp"]) 
	if dict.has("mountain_wet_amp"):
		config.mountain_wet_amp = float(dict["mountain_wet_amp"]) 
	if dict.has("mountain_radiance_passes"):
		config.mountain_radiance_passes = int(dict["mountain_radiance_passes"]) 
	if dict.has("lakes_enabled"):
		config.lakes_enabled = bool(dict["lakes_enabled"])
	if dict.has("realistic_pooling_enabled"):
		config.realistic_pooling_enabled = bool(dict["realistic_pooling_enabled"])
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
	if seed_changed:
		biome_phase = _compute_biome_phase(config.rng_seed)
	_setup_noises()
	# Keep temperature extremes stable across partial config updates.
	# Re-roll only on explicit seed changes when caller did not provide temperature values.
	var caller_set_temp_range: bool = dict.has("temp_min_c") or dict.has("temp_max_c")
	if seed_changed and not caller_set_temp_range:
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
	# Keep lava threshold independent of current extremes; enforce a hard minimum of 120 degC
	config.lava_temp_threshold_c = max(120.0, config.lava_temp_threshold_c)

func _compute_biome_phase(seed: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed) ^ 0xB16B00B5
	return rng.randf()

func _lake_fill_iterations(w: int, h: int, ocean_frac: float) -> int:
	# More iterations for larger maps and low-ocean cases to avoid giant "lake blocks".
	var base: int = max(96, int(ceil(float(max(w, h)) * 0.75)))
	var scale: float = 1.0
	if ocean_frac < 0.25:
		scale = 1.25
	if ocean_frac < 0.10:
		scale = 1.5
	return int(ceil(float(base) * scale))

func _height_quantile(height_values: PackedFloat32Array, fraction: float) -> float:
	var size: int = height_values.size()
	if size <= 0:
		return 0.0
	var target: float = clamp(fraction, 0.0, 1.0)
	var bins: int = 512
	var counts := PackedInt32Array()
	counts.resize(bins)
	for h in height_values:
		var t: float = clamp((h + 1.0) * 0.5, 0.0, 1.0)
		var idx: int = int(t * float(bins - 1))
		counts[idx] += 1
	var threshold: int = int(ceil(target * float(size)))
	var cumulative: int = 0
	for i in range(bins):
		cumulative += counts[i]
		if cumulative >= threshold:
			var bin_t: float = (float(i) + 0.5) / float(bins)
			return lerp(-1.0, 1.0, bin_t)
	return 1.0

func _clamp_sea_level_for_min_ocean(height_values: PackedFloat32Array, desired_sea_level: float) -> float:
	var result: float = desired_sea_level
	if config.min_ocean_fraction <= 0.0 or height_values.size() == 0:
		return result
	var min_level: float = _height_quantile(height_values, config.min_ocean_fraction)
	if result < min_level:
		result = min_level
	return result

func _lake_fill_strength(ocean_frac: float) -> float:
	var ref: float = max(0.0001, config.lake_fill_ocean_ref)
	return clamp(ocean_frac / ref, 0.0, 1.0)

func _tectonic_hash01(x: int, y: int, seed: int) -> float:
	var n: float = float(x) * 12.9898 + float(y) * 78.233 + float(seed) * 0.0137
	var s: float = sin(n) * 43758.5453
	return s - floor(s)

func _apply_tectonic_foundation(_w: int, _h: int) -> void:
	# CPU tectonic foundation was removed for GPU-only generation mode.
	# Preserve method signature for compatibility with older call paths.
	pass

func _compute_river_seed_threshold(
		_flow_accum: PackedFloat32Array,
		_is_land: PackedByteArray,
		min_threshold: float,
		factor: float
	) -> float:
	# GPU-only river seeding: use configured fixed threshold and avoid CPU percentile sort.
	return max(min_threshold, min_threshold * max(0.1, factor))

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
	# FIXED: Proper resource cleanup to prevent memory leaks
	# Clear all arrays to free memory
	last_height.clear()
	last_is_land.clear()
	last_water_distance.clear()
	last_turquoise_water.clear()
	last_turquoise_strength.clear()
	last_beach.clear()
	last_shelf_value_noise_field.clear()
	last_flow_dir.clear()
	last_flow_accum.clear()
	last_river.clear()
	last_lake.clear()
	last_lake_id.clear()
	last_pooled_lake.clear()
	last_lava.clear()
	last_temperature.clear()
	last_moisture.clear()
	last_biomes.clear()
	last_rock_type.clear()
	last_fertility.clear()
	last_clouds.clear()
	last_light.clear()
	_plates_boundary_mask_i32.clear()
	_plates_boundary_mask_render_u8.clear()
	_plates_cell_id_i32.clear()
	_plates_vel_u.clear()
	_plates_vel_v.clear()
	_plates_buoyancy.clear()
	world_data_1_override = null
	world_data_2_override = null
	cloud_texture_override = null
	light_texture_override = null
	river_texture_override = null
	biome_texture_override = null
	lava_texture_override = null
	_buffers_seeded = false
	_buffer_seed_size = 0
	
	# Clear GPU compute instances (they'll be recreated as needed)
	_terrain_compute = null
	_dt_compute = null
	_shelf_compute = null
	_climate_compute_gpu = null
	_flow_compute = null
	_river_compute = null
	_lake_label_compute = null
	
	# Clear GPU buffer manager
	if _gpu_buffer_manager:
		_gpu_buffer_manager.cleanup()
		_gpu_buffer_manager = null
	_buffers_seeded = false
	_buffer_seed_size = 0
	
	# Clear stats dictionaries
	tectonic_stats.clear()
	volcanic_stats.clear()
	
	# Clear world state
	if _world_state:
		_world_state = null
	
	# Reset ocean fraction
	last_ocean_fraction = 0.5
	# debug removed

func _is_valid_climate_result(climate: Dictionary, expected_size: int) -> bool:
	if climate.is_empty():
		return false
	if not climate.has("temperature") or not climate.has("moisture"):
		return false
	var t_val = climate.get("temperature")
	var m_val = climate.get("moisture")
	if typeof(t_val) != TYPE_PACKED_FLOAT32_ARRAY or typeof(m_val) != TYPE_PACKED_FLOAT32_ARRAY:
		return false
	var t: PackedFloat32Array = t_val
	var m: PackedFloat32Array = m_val
	return t.size() == expected_size and m.size() == expected_size

func _evaluate_climate_gpu_only(
		w: int,
		h: int,
		params: Dictionary,
		distance_to_coast: PackedFloat32Array,
		ocean_frac: float
	) -> Dictionary:
	var size: int = max(0, w * h)
	if _climate_compute_gpu == null:
		_climate_compute_gpu = ClimateAdjustCompute.new()
	var climate_gpu: Dictionary = _climate_compute_gpu.evaluate(
		w,
		h,
		last_height,
		last_is_land,
		_climate_base,
		params,
		distance_to_coast,
		ocean_frac
	)
	if _is_valid_climate_result(climate_gpu, size):
		return climate_gpu
	push_error("Climate GPU evaluate failed in GPU-only mode.")
	return {}

func generate() -> PackedByteArray:
	var w: int = config.width
	var h: int = config.height
	# Avoid stale GPU texture overlays when regenerating without a full clear().
	cloud_texture_override = null
	light_texture_override = null
	river_texture_override = null
	biome_texture_override = null
	lava_texture_override = null
	world_data_1_override = null
	world_data_2_override = null
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
		"moon_count": float(config.moon_count),
		"moon_seed": config.moon_seed,
		"moon_shadow_strength": config.moon_shadow_strength,
		"sim_days": config.season_phase * 365.0 + config.time_of_day,
	}

	# Step 1: terrain (GPU) with wrapper reuse
	var terrain := {}
	if _terrain_compute == null:
		_terrain_compute = TerrainCompute.new()
	terrain = _terrain_compute.generate(w, h, params)
	if terrain.is_empty() or not terrain.has("height") or not terrain.has("is_land"):
		push_error("Terrain generation failed in GPU-only mode.")
		return PackedByteArray()
	last_height = terrain["height"]
	# CPU tectonic foundation is disabled in GPU-only mode.
	# Final surface height used for sea-level classification.
	last_height_final = last_height
	last_is_land = terrain["is_land"]
	# Clamp sea level if it would eliminate nearly all oceans, then recompute land mask.
	var effective_sea_level: float = _clamp_sea_level_for_min_ocean(last_height_final, config.sea_level)
	if abs(effective_sea_level - config.sea_level) > 0.000001:
		config.sea_level = effective_sea_level
	var size_init: int = w * h
	if last_is_land.size() != size_init:
		last_is_land.resize(size_init)
	for i_init in range(size_init):
		last_is_land[i_init] = 1 if last_height_final[i_init] > config.sea_level else 0

	# Parity disabled in GPU-only mode
	# OPTIMIZED: Track ocean coverage fraction efficiently
	# Use count() method instead of manual loop for better performance
	var ocean_count: int = last_is_land.count(0)
	last_ocean_fraction = float(ocean_count) / float(max(1, w * h))

	# Land mask provided by GPU terrain; no CPU recompute

	# PoolingSystem: tag inland lakes (use GPU when available)
	var _pool_unused: Dictionary
	if _lake_label_compute == null:
		_lake_label_compute = LakeLabelCompute.new()
	# Strict GPU pooling path: compute E on GPU -> lake mask -> GPU labels
	if config.realistic_pooling_enabled:
		var iters: int = _lake_fill_iterations(w, h, last_ocean_fraction)
		var E_out: Dictionary = DepressionFillCompute.new().compute_E(w, h, last_height, last_is_land, true, iters)
		var lake_mask_gpu: PackedByteArray = E_out.get("lake", PackedByteArray())
		# Guard against non-converged fills creating giant lake blocks
		if lake_mask_gpu.size() == w * h and last_is_land.size() == w * h:
			var land_ct: int = 0
			var lake_ct: int = 0
			for i_guard in range(w * h):
				if last_is_land[i_guard] != 0:
					land_ct += 1
					if lake_mask_gpu[i_guard] != 0:
						lake_ct += 1
			var lake_ratio: float = float(lake_ct) / float(max(1, land_ct))
			if lake_ratio > 0.45 and last_ocean_fraction < 0.15:
				# Treat as invalid lake mask when oceans are tiny
				lake_mask_gpu.fill(0)
		var lake_mask_for_label: PackedByteArray = lake_mask_gpu
		var E_gpu: PackedFloat32Array = E_out.get("E", PackedFloat32Array())
		var size_gpu: int = w * h
		if E_gpu.size() == size_gpu and lake_mask_gpu.size() == size_gpu:
			var lake_strength: float = _lake_fill_strength(last_ocean_fraction)
			if lake_strength < 0.999:
				lake_mask_for_label = lake_mask_gpu.duplicate()
				for ii_d in range(size_gpu):
					if last_is_land[ii_d] == 0:
						lake_mask_for_label[ii_d] = 0
						continue
					var spill: float = E_gpu[ii_d]
					var eff: float = lerp(config.sea_level, spill, lake_strength)
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
				# Keep full lake_id labels for rendering; pour point selection TBD for full GPU.
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
		last_desert_noise_field = _feature_noise_cache.desert_noise_field

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
				var t: float = float(x) / float(max(1, w))
				var n0: float = _shore_noise.get_noise_2d(float(x) * sx_mul, float(y))
				var n1: float = _shore_noise.get_noise_2d((float(x) + float(w)) * sx_mul, float(y))
				shore_noise_field[i2] = lerp(n0, n1, t) * 0.5 + 0.5
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
	# time_of_day is set via SeasonalClimateSystem apply_config; nothing to do here
	var climate: Dictionary = _evaluate_climate_gpu_only(w, h, params, last_water_distance, last_ocean_fraction)
	if not _is_valid_climate_result(climate, size):
		push_error("Climate GPU evaluate failed during generate(); aborting world generation in GPU-only mode.")
		return last_is_land
	last_temperature = climate["temperature"]
	last_moisture = climate["moisture"]
	last_distance_to_coast = last_water_distance

	# Build initial day/night light field used by cloud generation and rendering.
	if _climate_compute_gpu != null:
		var light_init: PackedFloat32Array = _climate_compute_gpu.evaluate_light_field(w, h, params)
		if light_init.size() == w * h:
			last_light = light_init
	if last_light.size() != w * h:
		last_light.resize(w * h)
		last_light.fill(0.75)

	# Mountain radiance: run through ClimatePost GPU
	var climpost: Object = ensure_climate_post_compute()
	var post: Dictionary = climpost.apply_mountain_radiance(w, h, last_biomes, last_temperature, last_moisture, config.mountain_cool_amp, config.mountain_wet_amp, max(0, config.mountain_radiance_passes))
	if not post.is_empty():
		last_temperature = post["temperature"]
		last_moisture = post["moisture"]

	# Step 3b: lithology (GPU) - establish base rock materials before biome post overrides.
	_update_lithology_map(w, h)
	_seed_fertility_from_lithology(true)

	# Step 4: biomes -- GPU compute
	var params2 := params.duplicate()
	params2["freeze_temp_threshold"] = 0.16
	params2["height_scale_m"] = config.height_scale_m
	params2["lapse_c_per_km"] = 5.5
	# Animated biome jitter to avoid banding and allow evolution
	params2["biome_noise_strength_c"] = 0.8
	params2["biome_moist_jitter"] = 0.06
	params2["biome_phase"] = biome_phase
	params2["biome_moist_jitter2"] = 0.03
	params2["biome_moist_islands"] = 0.35
	params2["biome_moist_elev_dry"] = 0.35
	var desert_field := PackedFloat32Array()
	if _feature_noise_cache != null:
		desert_field = _feature_noise_cache.desert_noise_field
	var beach_mask := last_beach
	var bc: Object = ensure_biome_compute()
	var biomes_gpu: PackedInt32Array = bc.classify(w, h, last_height, last_is_land, last_temperature, last_moisture, beach_mask, desert_field, params2, last_fertility)
	if biomes_gpu.size() == w * h:
		last_biomes = biomes_gpu
		# BiomePost: apply hot/cold overrides + lava + salt desert (GPU)
		var bp: Object = ensure_biome_post_compute()
		var post2: Dictionary = bp.apply_overrides_and_lava(w, h, last_is_land, last_temperature, last_moisture, last_biomes, config.temp_min_c, config.temp_max_c, config.lava_temp_threshold_c, last_lake, 1.0, last_rock_type)
		if not post2.is_empty():
			last_biomes = post2["biomes"]
			last_lava = post2["lava"]
	# Volcanism step (GPU): spawn/decay lava along plate boundaries + hotspots
	var volcanism: Object = ensure_volcanism_compute()
	if "cell_plate_id" in self and "_plates_sys" in (get_script().get_global_name() if false else {}):
		pass # placeholder to avoid lints; actual plate boundary comes from PlateSystem
	# Best-effort: if a boundary mask was produced by PlateSystem and stored in state, use it. Else, create empty.
	var bnd_i32 := PackedInt32Array(); bnd_i32.resize(w * h)
	if _plates_boundary_mask_i32.size() == w * h:
		# Use the boundary mask populated by PlateSystem
		bnd_i32 = _plates_boundary_mask_i32
	else:
		# OPTIMIZED: No plate boundaries - use fill() instead of loop
		bnd_i32.fill(0)
	# OPTIMIZED: Convert lava mask efficiently
	var lava_f32 := PackedFloat32Array()
	lava_f32.resize(w * h)
	for i_l in range(min(w * h, last_lava.size())):
		lava_f32[i_l] = float(last_lava[i_l])
	# Fill remaining with zeros if needed
	if last_lava.size() < w * h:
		for i_l in range(last_lava.size(), w * h):
			lava_f32[i_l] = 0.0
	var lava_out: PackedFloat32Array = volcanism.step(w, h, bnd_i32, lava_f32, float(1.0/120.0), {
		"decay_rate_per_day": 0.02,
		"spawn_boundary_rate_per_day": 0.05,
		"hotspot_rate_per_day": 0.01,
		"hotspot_threshold": 0.995,
	}, fposmod(float(Time.get_ticks_msec()) / 1000.0, 1.0), int(config.rng_seed))
	if lava_out.size() == w * h:
		# OPTIMIZED: Threshold to byte mask efficiently  
		last_lava.resize(w * h)
		# Vectorized approach for better performance
		for li in range(w * h):
			last_lava[li] = (1 if lava_out[li] > 0.5 else 0)

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

	# Initialize clouds after biomes/light are ready to avoid low-detail startup artifacts.
	var cloud_compute: Object = ensure_cloud_overlay_compute()
	var phase0: float = fposmod(config.season_phase, 1.0)
	var clouds_init: PackedFloat32Array = cloud_compute.compute_clouds(
		w,
		h,
		last_temperature,
		last_moisture,
		last_is_land,
		last_light,
		last_biomes,
		phase0,
		int(config.rng_seed),
		false
	)
	if clouds_init.size() == w * h:
		last_clouds = clouds_init
	else:
		if last_clouds.size() != w * h:
			last_clouds.resize(w * h)
		last_clouds.fill(0.0)

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
		# Trace rivers on GPU
		if _river_compute == null:
			_river_compute = RiverCompute.new()
		var forced: PackedInt32Array = hydro2.get("outflow_seeds", PackedInt32Array())
		var thr_seed: float = _compute_river_seed_threshold(last_flow_accum, last_is_land, config.river_threshold, config.river_threshold_factor)
		last_river_seed_threshold = thr_seed
		var river_gpu: PackedByteArray = _river_compute.trace_rivers_roi(w, h, last_is_land, last_lake, last_flow_dir, last_flow_accum, thr_seed, 5, Rect2i(0,0,0,0), forced)
		if river_gpu.size() == w * h:
			last_river = river_gpu
		# GPU river delta widening (post)
		if config.river_delta_widening:
			var rpost: Object = ensure_river_post_compute()
			var delta_shore_dist: float = min(config.shore_band, 2.0)
			var widened: PackedByteArray = rpost.widen_deltas(w, h, last_river, last_is_land, last_water_distance, delta_shore_dist)
			if widened.size() == w * h:
				last_river = widened
		# River meander (GPU): subtle lateral shifts
		var meander: Object = ensure_river_meander_compute()
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

	# Seed GPU buffers from freshly generated CPU arrays before simulation starts.
	if _gpu_buffer_manager == null:
		_gpu_buffer_manager = GPUBufferManager.new()
	ensure_persistent_buffers(true)

	return last_is_land

func quick_update_sea_level(new_sea_level: float) -> PackedByteArray:
	# Fast path: only recompute artifacts depending on sea level.
	# Requires that base terrain (last_height) already exists.
	var prev_sea_level: float = config.sea_level
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size:
		# No terrain yet; do full generate
		return generate()
	# If GPU systems have modified height, pull the latest height from GPU buffers
	# so sea-level classification reflects the current terrain.
	if _gpu_buffer_manager != null:
		ensure_persistent_buffers(false)
		var hbuf: RID = get_persistent_buffer("height")
		if hbuf.is_valid():
			var hbytes: PackedByteArray = PackedByteArray()
			hbytes = _gpu_buffer_manager.read_buffer("height", "height") as PackedByteArray
			var hvals: PackedFloat32Array = PackedFloat32Array()
			hvals = hbytes.to_float32_array()
			if hvals.size() == size:
				last_height = hvals
				last_height_final = hvals
	if last_height_final.size() != size:
		last_height_final = last_height
	var desired_sea_level: float = new_sea_level
	if last_height_final.size() == size:
		desired_sea_level = _clamp_sea_level_for_min_ocean(last_height_final, desired_sea_level)
	config.sea_level = desired_sea_level
	# 1) Recompute land mask
	if last_is_land.size() != size:
		last_is_land.resize(size)
	var prev_is_land := PackedByteArray()
	prev_is_land.resize(size)
	for i in range(size):
		prev_is_land[i] = last_is_land[i] if i < last_is_land.size() else 0
	var land_updated_gpu: bool = false
	if _gpu_buffer_manager != null:
			var land_buf: RID = get_persistent_buffer("is_land")
			var hbuf2: RID = get_persistent_buffer("height")
			if land_buf.is_valid() and hbuf2.is_valid():
				if _land_mask_compute == null:
					_land_mask_compute = LandMaskCompute.new()
			land_updated_gpu = _land_mask_compute.update_from_height(w, h, hbuf2, config.sea_level, land_buf)
			if land_updated_gpu:
				var lbytes: PackedByteArray = PackedByteArray()
				lbytes = _gpu_buffer_manager.read_buffer("is_land", "is_land") as PackedByteArray
				var lvals: PackedInt32Array = PackedInt32Array()
				lvals = lbytes.to_int32_array()
				if lvals.size() == size:
					for i in range(size):
						last_is_land[i] = 1 if lvals[i] != 0 else 0
	if not land_updated_gpu:
		for i in range(size):
			last_is_land[i] = 1 if last_height_final[i] > config.sea_level else 0
		# Sync GPU land buffer immediately so rendering reflects new sea level
		if _gpu_buffer_manager != null:
			update_persistent_buffer("is_land", _pack_bytes_to_u32(last_is_land).to_byte_array())
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
				var t2: float = float(xx) / float(max(1, w))
				var n0b: float = _shore_noise.get_noise_2d(float(xx) * config.noise_x_scale, float(yy))
				var n1b: float = _shore_noise.get_noise_2d((float(xx) + float(w)) * config.noise_x_scale, float(yy))
				shore_noise_field[ii] = lerp(n0b, n1b, t2) * 0.5 + 0.5
	# Distance to coast on GPU
	if _dt_compute == null:
		_dt_compute = DistanceTransformCompute.new()
	var d_gpu2: PackedFloat32Array = _dt_compute.ocean_distance_to_land(w, h, last_is_land, true)
	if d_gpu2.size() == w * h:
		last_water_distance = d_gpu2
		if _gpu_buffer_manager != null:
			update_persistent_buffer("distance", last_water_distance.to_byte_array())
	# Shelf features on GPU using finalized distance
	if _shelf_compute == null:
		_shelf_compute = ContinentalShelfCompute.new()
	var out_gpu2: Dictionary = _shelf_compute.compute(w, h, last_height, last_is_land, config.sea_level, last_water_distance, shore_noise_field, config.shallow_threshold, config.shore_band, true, config.noise_x_scale)
	if out_gpu2.size() > 0:
		last_turquoise_water = out_gpu2.get("turquoise_water", last_turquoise_water)
		last_beach = out_gpu2.get("beach", last_beach)
		last_turquoise_strength = out_gpu2.get("turquoise_strength", last_turquoise_strength)
		if _gpu_buffer_manager != null:
			update_persistent_buffer("beach", _pack_bytes_to_u32(last_beach).to_byte_array())
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
		"diurnal_amp_equator": config.diurnal_amp_equator,
		"diurnal_amp_pole": config.diurnal_amp_pole,
		"diurnal_ocean_damp": config.diurnal_ocean_damp,
		"time_of_day": config.time_of_day,
	}
	params["distance_to_coast"] = last_water_distance
	var climate: Dictionary = _evaluate_climate_gpu_only(w, h, params, last_water_distance, last_ocean_fraction)
	if not _is_valid_climate_result(climate, size):
		push_error("Climate GPU evaluate failed during quick sea-level update; keeping previous climate fields.")
		return last_is_land
	last_temperature = climate["temperature"]
	last_moisture = climate["moisture"]
	last_distance_to_coast = last_water_distance
	if _gpu_buffer_manager != null:
		update_persistent_buffer("temperature", last_temperature.to_byte_array())
		update_persistent_buffer("temperature_base", last_temperature.to_byte_array())
		_temperature_base_offset_ref = config.temp_base_offset
		_temperature_base_scale_ref = max(0.001, config.temp_scale)
		update_persistent_buffer("moisture", last_moisture.to_byte_array())
		update_persistent_buffer("biome_temp", last_temperature.to_byte_array())
		update_persistent_buffer("biome_moist", last_moisture.to_byte_array())
	_update_lithology_map(w, h)
	_seed_fertility_from_lithology(false)

	# 5) Reclassify biomes using updated climate (band-limited near coastline)
	var params2 := params.duplicate()
	params2["freeze_temp_threshold"] = 0.16
	params2["height_scale_m"] = config.height_scale_m
	params2["lapse_c_per_km"] = 5.5
	params2["continentality_scale"] = config.continentality_scale
	# Keep biome jitter parameters consistent with initial generation
	params2["biome_noise_strength_c"] = 0.8
	params2["biome_moist_jitter"] = 0.06
	params2["biome_phase"] = biome_phase
	params2["biome_moist_jitter2"] = 0.03
	params2["biome_moist_islands"] = 0.35
	params2["biome_moist_elev_dry"] = 0.35
	var new_biomes := PackedInt32Array()
	var desert_field2 := PackedFloat32Array()
	if _feature_noise_cache != null:
		desert_field2 = _feature_noise_cache.desert_noise_field
	var bc2: Object = ensure_biome_compute()
	var biomes_gpu2: PackedInt32Array = bc2.classify(w, h, last_height, last_is_land, last_temperature, last_moisture, last_beach, desert_field2, params2, last_fertility)
	if biomes_gpu2.size() == size:
		new_biomes = biomes_gpu2
	else:
		# GPU-only: keep previous biomes if classify failed to return full buffer
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
	var allow_full_replace: bool = abs(config.sea_level - prev_sea_level) > 0.12
	var merge_partial: bool = not allow_full_replace
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
	var bp2: Object = ensure_biome_post_compute()
	var post2: Dictionary = bp2.apply_overrides_and_lava(w, h, last_is_land, last_temperature, last_moisture, last_biomes, config.temp_min_c, config.temp_max_c, config.lava_temp_threshold_c, last_lake, 0.0, last_rock_type)
	if not post2.is_empty():
		last_biomes = post2.get("biomes", last_biomes)
		last_lava = post2.get("lava", last_lava)
	if _gpu_buffer_manager != null:
		update_persistent_buffer("biome_id", last_biomes.to_byte_array())

	# 6) Lakes and rivers recompute on sea-level change (order: lakes, then rivers)
	# Lakes (GPU preferred)
	if _lake_label_compute == null:
		_lake_label_compute = LakeLabelCompute.new()
	var pool2: Dictionary
	if config.realistic_pooling_enabled and config.lakes_enabled:
		# Sea-level quick path: prefer GPU fill+label, fallback to CPU strict pooling
		var iters2: int = _lake_fill_iterations(w, h, last_ocean_fraction)
		var E2: Dictionary = DepressionFillCompute.new().compute_E(w, h, last_height, last_is_land, true, iters2)
		var lake_mask2: PackedByteArray = E2.get("lake", PackedByteArray())
		# Drying coupling during quick sea-level updates (GPU)
		var lake_mask2_adj: PackedByteArray = lake_mask2
		var E2f: PackedFloat32Array = E2.get("E", PackedFloat32Array())
		var size_q: int = w * h
		if E2f.size() == size_q and lake_mask2.size() == size_q:
			var lake_strength2: float = _lake_fill_strength(last_ocean_fraction)
			if lake_strength2 < 0.999:
				lake_mask2_adj = lake_mask2.duplicate()
				for qi in range(size_q):
					if last_is_land[qi] == 0:
						lake_mask2_adj[qi] = 0
						continue
					var spill_q: float = E2f[qi]
					var eff_q: float = lerp(config.sea_level, spill_q, lake_strength2)
					lake_mask2_adj[qi] = (1 if last_height[qi] < eff_q else 0)
		# Guard against non-converged fills creating giant lake blocks
		if lake_mask2_adj.size() == size_q and last_is_land.size() == size_q:
			var land_ct2: int = 0
			var lake_ct2: int = 0
			for gi in range(size_q):
				if last_is_land[gi] != 0:
					land_ct2 += 1
					if lake_mask2_adj[gi] != 0:
						lake_ct2 += 1
			var lake_ratio2: float = float(lake_ct2) / float(max(1, land_ct2))
			if lake_ratio2 > 0.45 and last_ocean_fraction < 0.15:
				lake_mask2_adj.fill(0)
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
	if config.rivers_enabled:
		if _river_compute == null:
			_river_compute = RiverCompute.new()
		var forced2: PackedInt32Array = pool2.get("outflow_seeds", PackedInt32Array())
		var thr_seed2: float = _compute_river_seed_threshold(last_flow_accum, last_is_land, config.river_threshold, config.river_threshold_factor)
		last_river_seed_threshold = thr_seed2
		var river_gpu: PackedByteArray = _river_compute.trace_rivers_roi(w, h, last_is_land, last_lake, last_flow_dir, last_flow_accum, thr_seed2, 5, Rect2i(0,0,0,0), forced2)
		if river_gpu.size() == w * h:
			last_river = river_gpu
		# Delta widening (GPU/CPU)
		if config.river_delta_widening:
			var rpost: Object = ensure_river_post_compute()
			var delta_shore_dist2: float = min(config.shore_band, 2.0)
			var widened: PackedByteArray = rpost.widen_deltas(w, h, last_river, last_is_land, last_water_distance, delta_shore_dist2)
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
		if last_river.size() != size:
			last_river.resize(size)
		last_river.fill(0)

	# Lava mask computed in BiomePost
	if _gpu_buffer_manager != null:
		ensure_persistent_buffers(true)
	return last_is_land


func quick_update_climate(skip_light: bool = false) -> void:
	# Recompute only climate (temperature/moisture/precip) using existing terrain, land mask,
	# water distance, and seasonal parameters. Also re-apply mountain radiance.
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size or last_is_land.size() != size:
		return
	if _gpu_buffer_manager != null:
		ensure_persistent_buffers(false)
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
		"moon_count": float(config.moon_count),
		"moon_seed": config.moon_seed,
		"moon_shadow_strength": config.moon_shadow_strength,
		"sim_days": config.season_phase * 365.0 + config.time_of_day,
	}
	params["distance_to_coast"] = last_water_distance
	var temp_offset_delta: float = config.temp_base_offset - _temperature_base_offset_ref
	var temp_scale_ratio: float = config.temp_scale / max(0.001, _temperature_base_scale_ref)
	params["temp_base_offset_delta"] = temp_offset_delta
	params["temp_scale_ratio"] = temp_scale_ratio
	
	if _climate_compute_gpu == null:
		_climate_compute_gpu = ClimateAdjustCompute.new()
	
	# Fast path: if only seasonal/diurnal phases changed, use cycle_apply_only
	# If long-term drift changed the baseline significantly, force full GPU climate
	# pass so moisture/biomes stay coherent with temperature.
	var fast_baseline_ok: bool = abs(temp_offset_delta) < 0.02 and abs(temp_scale_ratio - 1.0) < 0.05
	var use_fast_path = last_temperature.size() == size and fast_baseline_ok
	if _gpu_buffer_manager == null:
		return
	var used_gpu_fast: bool = false
	var updated_moisture: bool = false
	if use_fast_path:
		var temp_buf := get_persistent_buffer("temperature")
		var temp_base_buf := get_persistent_buffer("temperature_base")
		var land_buf := get_persistent_buffer("is_land")
		var dist_buf := get_persistent_buffer("distance")
		if not temp_base_buf.is_valid():
			temp_base_buf = temp_buf
		if temp_buf.is_valid() and temp_base_buf.is_valid() and land_buf.is_valid() and dist_buf.is_valid():
			# Apply cycles from a fixed baseline to avoid additive drift/saturation.
			used_gpu_fast = _climate_compute_gpu.apply_cycles_only_gpu(w, h, temp_base_buf, land_buf, dist_buf, params, temp_buf)
	if use_fast_path and not used_gpu_fast:
		# Keep runtime stable: skip expensive full recompute when fast GPU path is unavailable.
		return
	if not use_fast_path:
		# Full climate recompute
		var climate: Dictionary = _evaluate_climate_gpu_only(w, h, params, last_water_distance, last_ocean_fraction)
		if not _is_valid_climate_result(climate, size):
			push_error("Climate GPU evaluate failed during runtime climate update; preserving current climate fields.")
			return
		last_temperature = climate["temperature"]
		last_moisture = climate["moisture"]
		updated_moisture = true
		# Apply mountain radiance smoothing on updated climate (GPU)
		var climpost: Object = ensure_climate_post_compute()
		var post: Dictionary = climpost.apply_mountain_radiance(w, h, last_biomes, last_temperature, last_moisture, config.mountain_cool_amp, config.mountain_wet_amp, max(0, config.mountain_radiance_passes))
		if not post.is_empty():
			last_temperature = post["temperature"]
			last_moisture = post["moisture"]
			updated_moisture = true
	
	# Always update light field unless caller skips (GPU-only path).
	if not skip_light:
		var light_buf: RID = get_persistent_buffer("light")
		if light_buf.is_valid():
			_climate_compute_gpu.evaluate_light_field_gpu(w, h, params, light_buf)
	# Keep GPU persistent buffers in sync for GPU-only simulation
	if _gpu_buffer_manager != null:
		# Only update GPU buffers from CPU arrays when CPU arrays are current.
		if not used_gpu_fast:
			update_persistent_buffer("temperature", last_temperature.to_byte_array())
			update_persistent_buffer("temperature_base", last_temperature.to_byte_array())
			_temperature_base_offset_ref = config.temp_base_offset
			_temperature_base_scale_ref = max(0.001, config.temp_scale)
		if updated_moisture:
			update_persistent_buffer("moisture", last_moisture.to_byte_array())

func _update_lithology_map(w: int, h: int) -> void:
	var size: int = w * h
	if size <= 0:
		return
	if last_height.size() != size or last_is_land.size() != size or last_temperature.size() != size or last_moisture.size() != size:
		last_rock_type.resize(size)
		last_rock_type.fill(LithologyCompute.ROCK_BASALTIC)
		return
	if _lithology_compute == null:
		_lithology_compute = LithologyCompute.new()
	var lith_params := {
		"seed": config.rng_seed,
		"noise_x_scale": config.noise_x_scale,
	}
	var rocks_gpu: PackedInt32Array = _lithology_compute.classify(
		w,
		h,
		last_height,
		last_is_land,
		last_temperature,
		last_moisture,
		last_lava,
		last_desert_noise_field,
		lith_params
	)
	if rocks_gpu.size() == size:
		last_rock_type = rocks_gpu
	else:
		last_rock_type.resize(size)
		last_rock_type.fill(LithologyCompute.ROCK_BASALTIC)
	if _gpu_buffer_manager != null:
		# Do not trigger full persistent-buffer seeding here; many other fields may still
		# be transiently unsized during generation. Only ensure/update rock_type.
		_gpu_buffer_manager.ensure_buffer("rock_type", size * 4, last_rock_type.to_byte_array())
		update_persistent_buffer("rock_type", last_rock_type.to_byte_array())

func _base_fertility_for_rock(rock_type: int) -> float:
	match rock_type:
		LithologyCompute.ROCK_BASALTIC:
			return 0.86
		LithologyCompute.ROCK_VOLCANIC_ASH:
			return 0.78
		LithologyCompute.ROCK_LIMESTONE:
			return 0.68
		LithologyCompute.ROCK_SEDIMENTARY_CLASTIC:
			return 0.54
		LithologyCompute.ROCK_METAMORPHIC:
			return 0.46
		LithologyCompute.ROCK_GRANITIC:
			return 0.34
		_:
			return 0.50

func _seed_fertility_from_lithology(reset_existing: bool = false) -> void:
	var size: int = config.width * config.height
	if size <= 0:
		return
	var must_reset: bool = reset_existing or last_fertility.size() != size
	if must_reset:
		last_fertility.resize(size)
	for i in range(size):
		var on_land: bool = (i < last_is_land.size() and last_is_land[i] != 0)
		var has_lava: bool = (i < last_lava.size() and last_lava[i] != 0)
		if not on_land:
			if must_reset:
				last_fertility[i] = 0.04
			else:
				last_fertility[i] = clamp(lerp(last_fertility[i], 0.04, 0.25), 0.0, 1.0)
			continue
		var rock: int = last_rock_type[i] if i < last_rock_type.size() else LithologyCompute.ROCK_BASALTIC
		var base: float = _base_fertility_for_rock(rock)
		var moist: float = last_moisture[i] if i < last_moisture.size() else 0.5
		var target: float = clamp(base * (0.78 + 0.22 * clamp(moist, 0.0, 1.0)), 0.0, 1.0)
		if has_lava:
			target = min(target, base * 0.30)
		if must_reset:
			last_fertility[i] = target
		else:
			last_fertility[i] = clamp(lerp(last_fertility[i], target, 0.20), 0.0, 1.0)
	if _gpu_buffer_manager != null:
		_gpu_buffer_manager.ensure_buffer("fertility", size * 4, last_fertility.to_byte_array())
		update_persistent_buffer("fertility", last_fertility.to_byte_array())

func quick_update_biomes() -> void:
	# Reclassify biomes using current climate (temperature/moisture) and height/land/beach.
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size or last_is_land.size() != size or last_temperature.size() != size or last_moisture.size() != size:
		return
	_update_lithology_map(w, h)
	_seed_fertility_from_lithology(false)
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
	params2["biome_phase"] = biome_phase
	params2["biome_moist_jitter2"] = 0.03
	params2["biome_moist_islands"] = 0.35
	params2["biome_moist_elev_dry"] = 0.35
	# GPU classify only
	var desert_field := PackedFloat32Array()
	if _feature_noise_cache != null:
		desert_field = _feature_noise_cache.desert_noise_field
	var beach_mask := last_beach
	var bc: Object = ensure_biome_compute()
	var biomes_gpu: PackedInt32Array = bc.classify(w, h, last_height, last_is_land, last_temperature, last_moisture, beach_mask, desert_field, params2, last_fertility)
	if biomes_gpu.size() == w * h:
		last_biomes = biomes_gpu
	# Postprocess: hot/cold overrides + lava
	var bp: Object = ensure_biome_post_compute()
	var post2: Dictionary = bp.apply_overrides_and_lava(w, h, last_is_land, last_temperature, last_moisture, last_biomes, config.temp_min_c, config.temp_max_c, config.lava_temp_threshold_c, last_lake, 1.0, last_rock_type)
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
		if not config.rivers_enabled:
			if last_river.size() != size:
				last_river.resize(size)
			last_river.fill(0)
			return
		if _river_compute == null:
			_river_compute = RiverCompute.new()
		var forced: PackedInt32Array = fc_out.get("outflow_seeds", PackedInt32Array())
		var thr_seed3: float = _compute_river_seed_threshold(last_flow_accum, last_is_land, config.river_threshold, config.river_threshold_factor)
		last_river_seed_threshold = thr_seed3
		var river_gpu: PackedByteArray = _river_compute.trace_rivers_roi(w, h, last_is_land, last_lake, last_flow_dir, last_flow_accum, thr_seed3, 5, Rect2i(0,0,0,0), forced)
		if river_gpu.size() == size:
			last_river = river_gpu
			if config.river_delta_widening:
				var rpost: Object = ensure_river_post_compute()
				var delta_shore_dist3: float = min(config.shore_band, 2.0)
				var widened: PackedByteArray = rpost.widen_deltas(w, h, last_river, last_is_land, last_water_distance, delta_shore_dist3)
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
	var ci: int = _debug_cache_index(x, y)
	var h_val: float = 0.0
	var land: bool = false
	if ci >= 0 and ci < _debug_cache_height.size():
		h_val = _debug_cache_height[ci]
	elif i >= 0 and i < last_height.size():
		h_val = last_height[i]
	if ci >= 0 and ci < _debug_cache_land.size():
		land = _debug_cache_land[ci] != 0
	elif i >= 0 and i < last_is_land.size():
		land = last_is_land[i] != 0
	var beach: bool = false
	var turq: bool = false
	if ci >= 0 and ci < _debug_cache_beach.size():
		beach = _debug_cache_beach[ci] != 0
	elif i >= 0 and i < last_beach.size():
		beach = last_beach[i] != 0
	if i >= 0 and i < last_turquoise_water.size():
		turq = last_turquoise_water[i] != 0
	var is_lava: bool = false
	if ci >= 0 and ci < _debug_cache_lava.size():
		is_lava = _debug_cache_lava[ci] > 0.5
	elif i >= 0 and i < last_lava.size():
		is_lava = last_lava[i] != 0
	var is_river: bool = false
	if ci >= 0 and ci < _debug_cache_river.size():
		is_river = _debug_cache_river[ci] != 0
	elif i >= 0 and i < last_river.size():
		is_river = last_river[i] != 0
	var is_lake: bool = false
	if ci >= 0 and ci < _debug_cache_lake.size():
		is_lake = _debug_cache_lake[ci] != 0
	elif i >= 0 and i < last_lake.size():
		is_lake = last_lake[i] != 0
	var biome_id: int = -1
	var biome_name: String = "Ocean"
	var bid: int = last_biomes[i] if i >= 0 and i < last_biomes.size() else -1
	if ci >= 0 and ci < _debug_cache_biome.size():
		bid = _debug_cache_biome[ci]
	if bid >= 0:
		if land:
			# Promote lava field as its own biome name
			if is_lava:
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
	if ci >= 0 and ci < _debug_cache_temp.size():
		t_norm = _debug_cache_temp[ci]
	var temp_c: float = config.temp_min_c + t_norm * (config.temp_max_c - config.temp_min_c)
	var humidity: float = (last_moisture[i] if i < last_moisture.size() else 0.5)
	if ci >= 0 and ci < _debug_cache_moist.size():
		humidity = _debug_cache_moist[ci]
	var rock_id: int = (last_rock_type[i] if i >= 0 and i < last_rock_type.size() else LithologyCompute.ROCK_BASALTIC)
	if ci >= 0 and ci < _debug_cache_rock.size():
		rock_id = _debug_cache_rock[ci]
	var fertility: float = (last_fertility[i] if i < last_fertility.size() else _base_fertility_for_rock(rock_id))
	if ci >= 0 and ci < _debug_cache_fertility.size():
		fertility = _debug_cache_fertility[ci]
	# Apply descriptive prefixes for extreme temperatures in info panel
	var display_name: String = biome_name
	if land and not is_lava:
		var bid2: int = bid
		if temp_c <= -5.0:
			if bid2 != BiomeClassifier.Biome.GLACIER and bid2 != BiomeClassifier.Biome.DESERT_ICE and bid2 != BiomeClassifier.Biome.ICE_SHEET and bid2 != BiomeClassifier.Biome.FROZEN_FOREST and bid2 != BiomeClassifier.Biome.FROZEN_MARSH:
				display_name = "Frozen " + display_name
		elif temp_c >= 45.0:
			if bid2 != BiomeClassifier.Biome.LAVA_FIELD:
				display_name = "Scorched " + display_name
	var rock_name: String = _rock_to_string(rock_id)
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
		"rock_type": rock_id,
		"rock_name": rock_name,
		"temp_c": temp_c,
		"humidity": humidity,
		"fertility": fertility,
		# Tectonic information
		"is_plate_boundary": (_plates_boundary_mask_i32.size() > i and _plates_boundary_mask_i32[i] == 1),
		"tectonic_plates": tectonic_stats.get("total_plates", 0),
		"boundary_cells": tectonic_stats.get("boundary_cells", 0),
		# Volcanic information
		"active_lava_cells": volcanic_stats.get("active_lava_cells", 0),
		"eruption_potential": volcanic_stats.get("eruption_potential", 0.0),
	}

func _rock_to_string(r: int) -> String:
	match r:
		LithologyCompute.ROCK_BASALTIC:
			return "Basaltic"
		LithologyCompute.ROCK_GRANITIC:
			return "Granitic"
		LithologyCompute.ROCK_SEDIMENTARY_CLASTIC:
			return "Silicate Sedimentary"
		LithologyCompute.ROCK_LIMESTONE:
			return "Limestone"
		LithologyCompute.ROCK_METAMORPHIC:
			return "Metamorphic"
		LithologyCompute.ROCK_VOLCANIC_ASH:
			return "Volcanic Ash"
		_:
			return "Unknown Rock"

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
	var max_valid_biome_id: int = _get_max_valid_biome_id()
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
		if b < 0 or b > max_valid_biome_id:
			last_biomes[i] = _fallback_biome(i)

func _get_max_valid_biome_id() -> int:
	if _max_valid_biome_id_cache >= 0:
		return _max_valid_biome_id_cache
	var max_id: int = 0
	for biome_value in BiomeClassifier.Biome.values():
		max_id = max(max_id, int(biome_value))
	_max_valid_biome_id_cache = max_id
	return _max_valid_biome_id_cache

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
				# Very dry -> deserts
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
func ensure_persistent_buffers(refresh: bool = true) -> void:
	"""Allocate persistent GPU buffers for all major world data"""
	if _gpu_buffer_manager == null:
		_gpu_buffer_manager = GPUBufferManager.new()

	var size: int = config.width * config.height
	var float_size: int = size * 4
	var int_size: int = size * 4
	if refresh:
		# Normalize CPU-side array sizes before uploading as initial buffer data.
		if last_height.size() != size:
			last_height.resize(size)
			last_height.fill(0.0)
		if last_is_land.size() != size:
			last_is_land.resize(size)
			last_is_land.fill(0)
		if last_temperature.size() != size:
			last_temperature.resize(size)
			last_temperature.fill(0.5)
		if last_moisture.size() != size:
			last_moisture.resize(size)
			last_moisture.fill(0.5)
		if last_flow_dir.size() != size:
			last_flow_dir.resize(size)
			last_flow_dir.fill(-1)
		if last_flow_accum.size() != size:
			last_flow_accum.resize(size)
			last_flow_accum.fill(0.0)
		if last_biomes.size() != size:
			last_biomes.resize(size)
			last_biomes.fill(0)
		if last_rock_type.size() != size:
			last_rock_type.resize(size)
			last_rock_type.fill(LithologyCompute.ROCK_BASALTIC)
		if last_fertility.size() != size:
			last_fertility.resize(size)
			for i_f in range(size):
				last_fertility[i_f] = _base_fertility_for_rock(last_rock_type[i_f])
		if last_beach.size() != size:
			last_beach.resize(size)
			last_beach.fill(0)
		if last_river.size() != size:
			last_river.resize(size)
			last_river.fill(0)
		if last_lake.size() != size:
			last_lake.resize(size)
			last_lake.fill(0)
		if last_lake_id.size() != size:
			last_lake_id.resize(size)
			last_lake_id.fill(0)
		if last_distance_to_coast.size() != size:
			last_distance_to_coast.resize(size)
			last_distance_to_coast.fill(0.0)
		if last_clouds.size() != size:
			last_clouds.resize(size)
			last_clouds.fill(0.0)
		if last_lava.size() != size:
			last_lava.resize(size)
			last_lava.fill(0)
		_buffers_seeded = true
		_buffer_seed_size = size
	if refresh and last_light.size() != size:
		last_light.resize(size)
		last_light.fill(1.0)

	# Allocate persistent buffers for common data.
	_gpu_buffer_manager.ensure_buffer("height", float_size, last_height.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("height_tmp", float_size)
	_gpu_buffer_manager.ensure_buffer("is_land", int_size, _pack_bytes_to_u32(last_is_land).to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("temperature", float_size, last_temperature.to_byte_array() if refresh else PackedByteArray())
	# Baseline temperature used for non-accumulative seasonal/diurnal cycle application.
	_gpu_buffer_manager.ensure_buffer("temperature_base", float_size, last_temperature.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("moisture", float_size, last_moisture.to_byte_array() if refresh else PackedByteArray())
	# Slow-moving climate buffers for biome evolution.
	_gpu_buffer_manager.ensure_buffer("biome_temp", float_size, last_temperature.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("biome_moist", float_size, last_moisture.to_byte_array() if refresh else PackedByteArray())
	# Medium-timescale climate buffers for cryosphere decisions (filter out day/night flicker).
	_gpu_buffer_manager.ensure_buffer("cryo_temp", float_size, last_temperature.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("cryo_moist", float_size, last_moisture.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("flow_dir", int_size, last_flow_dir.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("flow_accum", float_size, last_flow_accum.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("biome_id", int_size, last_biomes.to_byte_array() if refresh else PackedByteArray())
	if refresh and last_rock_type.size() != size:
		last_rock_type.resize(size)
		last_rock_type.fill(LithologyCompute.ROCK_BASALTIC)
	if refresh and last_fertility.size() != size:
		last_fertility.resize(size)
		for i_rf in range(size):
			last_fertility[i_rf] = _base_fertility_for_rock(last_rock_type[i_rf])
	_gpu_buffer_manager.ensure_buffer("rock_type", int_size, last_rock_type.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("fertility", float_size, last_fertility.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("biome_tmp", int_size)
	_gpu_buffer_manager.ensure_buffer("beach", int_size, _pack_bytes_to_u32(last_beach).to_byte_array() if refresh else PackedByteArray())
	if last_desert_noise_field.size() == size:
		_gpu_buffer_manager.ensure_buffer("desert_noise", float_size, last_desert_noise_field.to_byte_array() if refresh else PackedByteArray())
	else:
		_gpu_buffer_manager.ensure_buffer("desert_noise", float_size)
	_gpu_buffer_manager.ensure_buffer("river", int_size, _pack_bytes_to_u32(last_river).to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("lake", int_size, _pack_bytes_to_u32(last_lake).to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("lake_id", int_size, last_lake_id.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("distance", float_size, last_distance_to_coast.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("clouds", float_size, last_clouds.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("light", float_size, last_light.to_byte_array() if refresh else PackedByteArray())
	var lava_bytes := PackedByteArray()
	if refresh:
		var lava_f32 := PackedFloat32Array()
		lava_f32.resize(size)
		for i in range(size):
			lava_f32[i] = 1.0 if (i < last_lava.size() and last_lava[i] != 0) else 0.0
		lava_bytes = lava_f32.to_byte_array()
	_gpu_buffer_manager.ensure_buffer("lava", float_size, lava_bytes)
	_gpu_buffer_manager.ensure_buffer("wind_u", float_size)
	_gpu_buffer_manager.ensure_buffer("wind_v", float_size)
	_gpu_buffer_manager.ensure_buffer("cloud_source", float_size)

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

func get_gpu_buffer_manager() -> Object:
	return _gpu_buffer_manager

func ensure_gpu_storage_buffer(name: String, size_bytes: int, initial_data: PackedByteArray = PackedByteArray()) -> RID:
	if _gpu_buffer_manager == null:
		_gpu_buffer_manager = GPUBufferManager.new()
	return _gpu_buffer_manager.ensure_buffer(name, size_bytes, initial_data)

func ensure_flow_compute() -> Object:
	if _flow_compute == null:
		_flow_compute = FlowCompute.new()
	return _flow_compute

func ensure_river_compute() -> Object:
	if _river_compute == null:
		_river_compute = RiverCompute.new()
	return _river_compute

func ensure_climate_compute_gpu() -> Object:
	if _climate_compute_gpu == null:
		_climate_compute_gpu = ClimateAdjustCompute.new()
	return _climate_compute_gpu

func ensure_climate_post_compute() -> Object:
	if _climate_post_compute == null:
		_climate_post_compute = ClimatePostCompute.new()
	return _climate_post_compute

func ensure_biome_compute() -> Object:
	if _biome_compute == null:
		_biome_compute = BiomeCompute.new()
	return _biome_compute

func ensure_biome_post_compute() -> Object:
	if _biome_post_compute == null:
		_biome_post_compute = BiomePostCompute.new()
	return _biome_post_compute

func ensure_volcanism_compute() -> Object:
	if _volcanism_compute == null:
		_volcanism_compute = VolcanismCompute.new()
	return _volcanism_compute

func ensure_cloud_overlay_compute() -> Object:
	if _cloud_overlay_compute == null:
		_cloud_overlay_compute = CloudOverlayCompute.new()
	return _cloud_overlay_compute

func ensure_river_post_compute() -> Object:
	if _river_post_compute == null:
		_river_post_compute = RiverPostCompute.new()
	return _river_post_compute

func ensure_river_meander_compute() -> Object:
	if _river_meander_compute == null:
		_river_meander_compute = RiverMeanderCompute.new()
	return _river_meander_compute

func dispatch_copy_u32(src: RID, dst: RID, count: int) -> bool:
	if not src.is_valid() or not dst.is_valid() or count <= 0:
		return false
	var flow_obj: Object = ensure_flow_compute()
	if flow_obj == null:
		return false
	if "_ensure" in flow_obj:
		flow_obj._ensure()
	if not ("_dispatch_copy_u32" in flow_obj):
		return false
	flow_obj._dispatch_copy_u32(src, dst, count)
	return true

func publish_plate_runtime_state(
		cell_plate_id: PackedInt32Array,
		vel_u: PackedFloat32Array,
		vel_v: PackedFloat32Array,
		buoyancy: PackedFloat32Array,
		boundary_i32: PackedInt32Array,
		boundary_render_u8: PackedByteArray,
		boundary_count: int = -1,
		total_plates: int = -1
	) -> void:
	if cell_plate_id.size() > 0:
		_plates_cell_id_i32 = cell_plate_id.duplicate()
	if vel_u.size() > 0:
		_plates_vel_u = vel_u.duplicate()
	if vel_v.size() > 0:
		_plates_vel_v = vel_v.duplicate()
	if buoyancy.size() > 0:
		_plates_buoyancy = buoyancy.duplicate()
	if boundary_i32.size() > 0:
		_plates_boundary_mask_i32 = boundary_i32.duplicate()
	if boundary_render_u8.size() > 0:
		_plates_boundary_mask_render_u8 = boundary_render_u8.duplicate()
	if boundary_count >= 0:
		tectonic_stats["boundary_cells"] = boundary_count
	if total_plates >= 0:
		tectonic_stats["total_plates"] = total_plates

func ensure_plate_gpu_buffers(cell_plate_id: PackedInt32Array, boundary_mask_u8: PackedByteArray) -> void:
	var size: int = cell_plate_id.size()
	if size <= 0:
		return
	var size_bytes: int = size * 4
	ensure_gpu_storage_buffer("plate_id", size_bytes, cell_plate_id.to_byte_array())
	if boundary_mask_u8.size() == size:
		ensure_gpu_storage_buffer("plate_boundary", size_bytes, _pack_bytes_to_u32(boundary_mask_u8).to_byte_array())

func ensure_plate_boundary_buffer_from_state(size: int) -> RID:
	var existing: RID = get_persistent_buffer("plate_boundary")
	if existing.is_valid():
		return existing
	if size > 0 and _plates_boundary_mask_i32.size() == size:
		ensure_gpu_storage_buffer("plate_boundary", size * 4, _plates_boundary_mask_i32.to_byte_array())
		return get_persistent_buffer("plate_boundary")
	return RID()

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

func read_persistent_buffer_region(name: String, offset_bytes: int, size_bytes: int) -> PackedByteArray:
	if _gpu_buffer_manager == null:
		return PackedByteArray()
	if "read_buffer_region" in _gpu_buffer_manager:
		return _gpu_buffer_manager.read_buffer_region(name, offset_bytes, size_bytes)
	return PackedByteArray()

func _debug_cache_index(x: int, y: int) -> int:
	if not _debug_cache_valid:
		return -1
	if x < _debug_cache_x0 or y < _debug_cache_y0:
		return -1
	if x >= _debug_cache_x0 + _debug_cache_w or y >= _debug_cache_y0 + _debug_cache_h:
		return -1
	return (x - _debug_cache_x0) + (y - _debug_cache_y0) * _debug_cache_w

func _read_window_f32(buffer_name: String, x0: int, y0: int, rw: int, rh: int, world_w: int) -> PackedFloat32Array:
	var out := PackedByteArray()
	var row_bytes: int = rw * 4
	for ry in range(rh):
		var off: int = ((y0 + ry) * world_w + x0) * 4
		var row: PackedByteArray = read_persistent_buffer_region(buffer_name, off, row_bytes)
		if row.size() != row_bytes:
			return PackedFloat32Array()
		out.append_array(row)
	return out.to_float32_array()

func _read_window_i32(buffer_name: String, x0: int, y0: int, rw: int, rh: int, world_w: int) -> PackedInt32Array:
	var out := PackedByteArray()
	var row_bytes: int = rw * 4
	for ry in range(rh):
		var off: int = ((y0 + ry) * world_w + x0) * 4
		var row: PackedByteArray = read_persistent_buffer_region(buffer_name, off, row_bytes)
		if row.size() != row_bytes:
			return PackedInt32Array()
		out.append_array(row)
	return out.to_int32_array()

func sync_debug_cpu_snapshot(x: int, y: int, radius_tiles: int = 3, prefetch_margin_tiles: int = 2, max_cells: int = 250000) -> void:
	"""Refresh hover/debug cache from a small GPU window (default 7x7) around the cursor."""
	if _gpu_buffer_manager == null:
		return
	var size: int = config.width * config.height
	if size <= 0 or size > max_cells:
		return
	var cx: int = clamp(x, 0, config.width - 1)
	var cy: int = clamp(y, 0, config.height - 1)
	var margin: int = max(0, prefetch_margin_tiles)
	var need_refresh: bool = true
	if _debug_cache_valid:
		var idx: int = _debug_cache_index(cx, cy)
		if idx >= 0:
			var local_x: int = cx - _debug_cache_x0
			var local_y: int = cy - _debug_cache_y0
			var near_edge: bool = (
				local_x <= margin
				or local_y <= margin
				or local_x >= max(0, _debug_cache_w - 1 - margin)
				or local_y >= max(0, _debug_cache_h - 1 - margin)
			)
			need_refresh = near_edge
	if not need_refresh:
		return
	var r: int = max(0, radius_tiles)
	var x0: int = max(0, cx - r)
	var y0: int = max(0, cy - r)
	var x1: int = min(config.width - 1, cx + r)
	var y1: int = min(config.height - 1, cy + r)
	var rw: int = x1 - x0 + 1
	var rh: int = y1 - y0 + 1
	if rw <= 0 or rh <= 0:
		return
	_debug_cache_height = _read_window_f32("height", x0, y0, rw, rh, config.width)
	_debug_cache_land = _read_window_i32("is_land", x0, y0, rw, rh, config.width)
	_debug_cache_beach = _read_window_i32("beach", x0, y0, rw, rh, config.width)
	_debug_cache_lava = _read_window_f32("lava", x0, y0, rw, rh, config.width)
	_debug_cache_river = _read_window_i32("river", x0, y0, rw, rh, config.width)
	_debug_cache_lake = _read_window_i32("lake", x0, y0, rw, rh, config.width)
	_debug_cache_temp = _read_window_f32("temperature", x0, y0, rw, rh, config.width)
	_debug_cache_moist = _read_window_f32("moisture", x0, y0, rw, rh, config.width)
	_debug_cache_biome = _read_window_i32("biome_id", x0, y0, rw, rh, config.width)
	_debug_cache_rock = _read_window_i32("rock_type", x0, y0, rw, rh, config.width)
	_debug_cache_fertility = _read_window_f32("fertility", x0, y0, rw, rh, config.width)
	_debug_cache_valid = (
		_debug_cache_height.size() == rw * rh
		and _debug_cache_land.size() == rw * rh
		and _debug_cache_temp.size() == rw * rh
		and _debug_cache_moist.size() == rw * rh
		and _debug_cache_biome.size() == rw * rh
		and _debug_cache_rock.size() == rw * rh
		and _debug_cache_fertility.size() == rw * rh
	)
	_debug_cache_x0 = x0
	_debug_cache_y0 = y0
	_debug_cache_w = rw
	_debug_cache_h = rh

func sync_climate_cpu_mirror_from_gpu(_max_cells: int = CLIMATE_CPU_MIRROR_MAX_CELLS) -> void:
	"""GPU-only runtime: CPU climate mirror sync is intentionally disabled."""
	pass

func get_buffer_memory_stats() -> Dictionary:
	"""Get GPU buffer memory usage statistics"""
	if _gpu_buffer_manager == null:
		return {"error": "Buffer manager not initialized"}
	return _gpu_buffer_manager.get_buffer_stats()

func update_base_textures_gpu(use_bedrock_view: bool = false) -> void:
	"""Update base world textures (data1/data2) directly from GPU buffers."""
	if _gpu_buffer_manager == null:
		return
	var size: int = config.width * config.height
	var seed_needed: bool = (not _buffers_seeded) or (_buffer_seed_size != size)
	ensure_persistent_buffers(seed_needed)
	if _world_data1_tex_compute == null:
		_world_data1_tex_compute = WorldData1TextureCompute.new()
	if _world_data2_tex_compute == null:
		_world_data2_tex_compute = WorldData2TextureCompute.new()
	var w: int = config.width
	var h: int = config.height
	var height_buf := get_persistent_buffer("height")
	var temp_buf := get_persistent_buffer("temperature")
	var moist_buf := get_persistent_buffer("moisture")
	var light_buf := get_persistent_buffer("light")
	var biome_buf := get_persistent_buffer("biome_id")
	var rock_buf := get_persistent_buffer("rock_type")
	var land_buf := get_persistent_buffer("is_land")
	var beach_buf := get_persistent_buffer("beach")
	if height_buf.is_valid() and temp_buf.is_valid() and moist_buf.is_valid() and light_buf.is_valid():
		var tex1: Texture2D = _world_data1_tex_compute.update_from_buffers(w, h, height_buf, temp_buf, moist_buf, light_buf)
		if tex1:
			world_data_1_override = tex1
		else:
			world_data_1_override = null
	else:
		world_data_1_override = null
	if biome_buf.is_valid() and land_buf.is_valid() and beach_buf.is_valid():
		var tex2: Texture2D = _world_data2_tex_compute.update_from_buffers(
			w,
			h,
			biome_buf,
			land_buf,
			beach_buf,
			rock_buf,
			use_bedrock_view
		)
		if tex2:
			world_data_2_override = tex2
		else:
			world_data_2_override = null
	else:
		world_data_2_override = null

func cleanup_gpu_resources() -> void:
	"""Clean up GPU resources when shutting down"""
	if _gpu_buffer_manager != null:
		_gpu_buffer_manager.cleanup()

func set_cloud_texture_override(tex: Texture2D) -> void:
	cloud_texture_override = tex

func set_light_texture_override(tex: Texture2D) -> void:
	light_texture_override = tex

func set_river_texture_override(tex: Texture2D) -> void:
	river_texture_override = tex

func set_biome_texture_override(tex: Texture2D) -> void:
	biome_texture_override = tex

func set_lava_texture_override(tex: Texture2D) -> void:
	lava_texture_override = tex

func set_world_data_1_override(tex: Texture2D) -> void:
	world_data_1_override = tex

func set_world_data_2_override(tex: Texture2D) -> void:
	world_data_2_override = tex
