# File: res://scripts/WorldGenerator.gd
extends RefCounted

const TerrainNoise = preload("res://scripts/generation/TerrainNoise.gd")
const TerrainCompute = preload("res://scripts/systems/TerrainCompute.gd")
var ClimateNoise = load("res://scripts/generation/ClimateNoise.gd")
const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")
const WorldState = preload("res://scripts/core/WorldState.gd")
const FeatureNoiseCache = preload("res://scripts/systems/FeatureNoiseCache.gd")
const DistanceTransformCompute = preload("res://scripts/systems/DistanceTransformCompute.gd")
const ContinentalShelfCompute = preload("res://scripts/systems/ContinentalShelfCompute.gd")
const ClimatePostCompute = preload("res://scripts/systems/ClimatePostCompute.gd")
const PoolingSystem = preload("res://scripts/systems/PoolingSystem.gd")
const ClimateBase = preload("res://scripts/systems/ClimateBase.gd")
const ClimateAdjustCompute = preload("res://scripts/systems/ClimateAdjustCompute.gd")
const BiomeCompute = preload("res://scripts/systems/BiomeCompute.gd")
const BiomePostCompute = preload("res://scripts/systems/BiomePostCompute.gd")
const LithologyCompute = preload("res://scripts/systems/LithologyCompute.gd")
const FertilityLithologyCompute = preload("res://scripts/systems/FertilityLithologyCompute.gd")
var FlowErosionSystem = load("res://scripts/systems/FlowErosionSystem.gd")
const FlowCompute = preload("res://scripts/systems/FlowCompute.gd")
const RiverCompute = preload("res://scripts/systems/RiverCompute.gd")
const RiverPostCompute = preload("res://scripts/systems/RiverPostCompute.gd")
const RiverFreezeCompute = preload("res://scripts/systems/RiverFreezeCompute.gd")
const VolcanismCompute = preload("res://scripts/systems/VolcanismCompute.gd")
const CloudOverlayCompute = preload("res://scripts/systems/CloudOverlayCompute.gd")
const LandMaskCompute = preload("res://scripts/systems/LandMaskCompute.gd")
const LakeLabelCompute = preload("res://scripts/systems/LakeLabelCompute.gd")
const OceanLandGateCompute = preload("res://scripts/systems/OceanLandGateCompute.gd")
const DepressionFillCompute = preload("res://scripts/systems/DepressionFillCompute.gd")
const LakeLabelFromMaskCompute = preload("res://scripts/systems/LakeLabelFromMaskCompute.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")
const WorldData1TextureCompute = preload("res://scripts/systems/WorldData1TextureCompute.gd")
const WorldData2TextureCompute = preload("res://scripts/systems/WorldData2TextureCompute.gd")
const TerrainHydroMetricsCompute = preload("res://scripts/systems/TerrainHydroMetricsCompute.gd")
var _terrain_compute: Object = null
var _dt_compute: Object = null
var _shelf_compute: Object = null
var _climate_compute_gpu: Object = null
var _flow_compute: Object = null
var _river_compute: Object = null
var _lake_label_compute: Object = null
var _ocean_land_gate_compute: Object = null
var _gpu_buffer_manager: Object = null
var _land_mask_compute: Object = null
var _lithology_compute: Object = null
var _biome_compute: Object = null
var _biome_post_compute: Object = null
var _fertility_compute: Object = null
var _climate_post_compute: Object = null
var _volcanism_compute: Object = null
var _cloud_overlay_compute: Object = null
var _river_post_compute: Object = null
var _river_freeze_compute: Object = null

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
	# Widen river deltas near coast for major rivers.
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
	# Diurnal temperature cycle (continental interiors swing more than coasts/ocean)
	var diurnal_amp_equator: float = 0.05
	var diurnal_amp_pole: float = 0.09
	var diurnal_ocean_damp: float = 0.28
	var time_of_day: float = 0.0
	# Day-night visual settings
	var day_night_contrast: float = 0.992
	var day_night_base: float = 0.008
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
	# Use seed-derived physically plausible defaults for climate-shaping knobs.
	var auto_physical_defaults: bool = true
	# Keep ocean extent stable over long tectonic runs.
	var fixed_water_budget_enabled: bool = false
	var fixed_ocean_fraction_target: float = -1.0
	var sea_level_solver_gain: float = 0.45
	var sea_level_solver_max_step: float = 0.015
	# Enforce ocean connectivity gate so inland basins become lakes, not ocean.
	var ocean_connectivity_gate_enabled: bool = true

var config := Config.new()
var debug_parity: bool = false
const CLIMATE_CPU_MIRROR_MAX_CELLS: int = 250000
const TERRAIN_METRICS_STATS_U32_COUNT: int = 6
const TERRAIN_METRICS_HEIGHT_OFFSET: float = 1.5
const TERRAIN_METRICS_HEIGHT_SUM_SCALE: float = 1024.0
const TERRAIN_METRICS_SLOPE_MEAN_THRESHOLD: float = 0.085
const TERRAIN_METRICS_SLOPE_PEAK_THRESHOLD: float = 0.22

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
var _physical_defaults_seed: int = -2147483648

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
var water_budget_stats: Dictionary = {}
var _terrain_metrics_compute: Object = null
var _tectonic_bias_prev_mean_valid: bool = false
var _tectonic_bias_prev_mean_height: float = 0.0

# Phase 0 scaffolding: central state and shared noise cache (currently unused)
var _world_state: Object = null
var _feature_noise_cache: Object = null
var _climate_base: Dictionary = {}
var _world_data1_tex_compute: Object = null
var _world_data2_tex_compute: Object = null
var _buffers_seeded: bool = false
var _buffer_seed_size: int = 0
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
const DEBUG_CACHE_STALE_USEC: int = 250000
var _debug_cache_last_refresh_usec: int = 0
var _climate_cpu_mirror_dirty: bool = true
var _water_budget_initialized: bool = false
var _water_total_target: float = 0.0
var _water_ocean_fraction_target: float = -1.0
var _sea_solver_last_apply_day: float = -1.0

func _init() -> void:
	randomize()
	config.rng_seed = randi()
	biome_phase = _compute_biome_phase(config.rng_seed)
	_apply_seeded_physical_defaults(true)
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
	if dict.has("auto_physical_defaults"):
		config.auto_physical_defaults = bool(dict["auto_physical_defaults"])
	if dict.has("fixed_water_budget_enabled"):
		config.fixed_water_budget_enabled = bool(dict["fixed_water_budget_enabled"])
	if dict.has("fixed_ocean_fraction_target"):
		config.fixed_ocean_fraction_target = clamp(float(dict["fixed_ocean_fraction_target"]), -1.0, 0.99)
	if dict.has("sea_level_solver_gain"):
		config.sea_level_solver_gain = clamp(float(dict["sea_level_solver_gain"]), 0.0, 2.0)
	if dict.has("sea_level_solver_max_step"):
		config.sea_level_solver_max_step = clamp(float(dict["sea_level_solver_max_step"]), 0.0001, 0.2)
	if dict.has("ocean_connectivity_gate_enabled"):
		config.ocean_connectivity_gate_enabled = bool(dict["ocean_connectivity_gate_enabled"])
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
	_apply_seeded_physical_defaults(seed_changed)
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

func _apply_seeded_physical_defaults(force: bool = false) -> void:
	if not config.auto_physical_defaults:
		return
	if not force and _physical_defaults_seed == int(config.rng_seed):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.rng_seed) ^ 0x6E624EB7
	# Keep climate control values inside realistic envelopes with small seed variance.
	config.continentality_scale = clamp(1.08 + rng.randf_range(-0.16, 0.16), 0.82, 1.32)
	config.temp_base_offset = clamp(0.22 + rng.randf_range(-0.07, 0.07), 0.08, 0.34)
	config.temp_scale = clamp(1.0 + rng.randf_range(-0.07, 0.07), 0.90, 1.12)
	config.moist_base_offset = clamp(0.10 + rng.randf_range(-0.05, 0.05), 0.02, 0.18)
	config.moist_scale = clamp(1.0 + rng.randf_range(-0.08, 0.08), 0.88, 1.14)
	config.season_amp_equator = clamp(0.10 + rng.randf_range(-0.02, 0.02), 0.07, 0.13)
	config.season_amp_pole = clamp(0.25 + rng.randf_range(-0.03, 0.03), 0.20, 0.30)
	config.season_ocean_damp = clamp(0.60 + rng.randf_range(-0.06, 0.06), 0.48, 0.72)
	config.diurnal_amp_equator = clamp(0.05 + rng.randf_range(-0.012, 0.012), 0.035, 0.065)
	config.diurnal_amp_pole = clamp(0.09 + rng.randf_range(-0.015, 0.015), 0.07, 0.12)
	config.diurnal_ocean_damp = clamp(0.28 + rng.randf_range(-0.06, 0.06), 0.16, 0.40)
	_physical_defaults_seed = int(config.rng_seed)

func _setup_temperature_extremes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.rng_seed) ^ 0x1234ABCD
	config.temp_min_c = lerp(-50.0, -15.0, rng.randf())
	config.temp_max_c = lerp(35.0, 85.0, rng.randf())
	# Keep lava threshold independent of current extremes; enforce a hard minimum of 120 degC
	config.lava_temp_threshold_c = max(120.0, config.lava_temp_threshold_c)

func _compute_biome_phase(rng_seed: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(rng_seed) ^ 0xB16B00B5
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

func _height_mirror_has_signal(height_values: PackedFloat32Array) -> bool:
	if height_values.is_empty():
		return false
	var min_h: float = 1e20
	var max_h: float = -1e20
	for hv in height_values:
		if hv < min_h:
			min_h = hv
		if hv > max_h:
			max_h = hv
	return (max_h - min_h) > 0.0001

func _estimate_ocean_fraction_from_sea_level(sea_level: float) -> float:
	var est: float = 0.5 + 0.45 * clamp(sea_level, -1.0, 1.0)
	if config.min_ocean_fraction > 0.0:
		est = max(est, config.min_ocean_fraction)
	return clamp(est, 0.02, 0.98)

func _compute_river_seed_threshold(
		_flow_accum: PackedFloat32Array,
		_is_land: PackedByteArray,
		min_threshold: float,
		factor: float
	) -> float:
	# GPU-only river seeding: use configured fixed threshold and avoid CPU percentile sort.
	return max(min_threshold, min_threshold * max(0.1, factor))

func _compute_delta_source_min_accum(
		flow_accum: PackedFloat32Array,
		river_mask: PackedByteArray,
		is_land: PackedByteArray
	) -> float:
	var size: int = min(flow_accum.size(), min(river_mask.size(), is_land.size()))
	if size <= 0:
		return 1e9
	var samples: Array = []
	var land_count: int = 0
	for i in range(size):
		if is_land[i] == 0:
			continue
		land_count += 1
		if river_mask[i] == 0:
			continue
		samples.append(float(flow_accum[i]))
	if samples.is_empty():
		return 1e9
	samples.sort()
	var q_idx: int = int(floor(float(samples.size() - 1) * 0.88))
	q_idx = clamp(q_idx, 0, samples.size() - 1)
	var q_val: float = float(samples[q_idx])
	var area_floor: float = max(24.0, float(land_count) * 0.0035)
	return max(area_floor, q_val)

func _estimate_delta_source_min_accum(size: int, river_seed_threshold: float) -> float:
	# GPU fast-path estimate used when flow_accum is kept on GPU.
	var area_floor: float = max(24.0, float(size) * 0.0015)
	var seed_scaled: float = max(8.0, river_seed_threshold * 6.0)
	return max(area_floor, seed_scaled)

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
	_river_freeze_compute = null
	_lake_label_compute = null
	_ocean_land_gate_compute = null
	_terrain_metrics_compute = null
	
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
	_water_budget_initialized = false
	_water_total_target = 0.0
	_water_ocean_fraction_target = -1.0
	_sea_solver_last_apply_day = -1.0
	_tectonic_bias_prev_mean_valid = false
	_tectonic_bias_prev_mean_height = 0.0
	water_budget_stats.clear()
	_climate_cpu_mirror_dirty = true
	# Reset hover/debug cache so new generations never show stale tile info.
	_debug_cache_valid = false
	_debug_cache_x0 = 0
	_debug_cache_y0 = 0
	_debug_cache_w = 0
	_debug_cache_h = 0
	_debug_cache_last_refresh_usec = 0
	_debug_cache_height.clear()
	_debug_cache_land.clear()
	_debug_cache_beach.clear()
	_debug_cache_lava.clear()
	_debug_cache_river.clear()
	_debug_cache_lake.clear()
	_debug_cache_temp.clear()
	_debug_cache_moist.clear()
	_debug_cache_biome.clear()
	_debug_cache_rock.clear()
	_debug_cache_fertility.clear()
	# debug removed

func _evaluate_climate_gpu_only(
		w: int,
		h: int,
		params: Dictionary,
		distance_to_coast: PackedFloat32Array,
		ocean_frac: float
	) -> bool:
	var size: int = max(0, w * h)
	if _climate_compute_gpu == null:
		_climate_compute_gpu = ClimateAdjustCompute.new()
	# Strict GPU-only climate path (buffer-to-buffer).
	if _gpu_buffer_manager != null:
		ensure_persistent_buffers(false)
		var hbuf: RID = get_persistent_buffer("height")
		var land_buf: RID = get_persistent_buffer("is_land")
		var dist_buf: RID = get_persistent_buffer("distance")
		var temp_buf: RID = get_persistent_buffer("temperature")
		var moist_buf: RID = get_persistent_buffer("moisture")
		var light_buf: RID = get_persistent_buffer("light")
		var precip_buf: RID = ensure_gpu_storage_buffer("precip", size * 4)
		if hbuf.is_valid() and land_buf.is_valid() and dist_buf.is_valid() and temp_buf.is_valid() and moist_buf.is_valid() and light_buf.is_valid() and precip_buf.is_valid():
			# GPU-only mode: terrain/land buffers are authoritative and must never be
			# overwritten from CPU mirrors (which may be intentionally stale/empty).
			if distance_to_coast.size() == size:
				update_persistent_buffer("distance", distance_to_coast.to_byte_array())
			var ok_gpu: bool = _climate_compute_gpu.evaluate_to_buffers_gpu(w, h, hbuf, land_buf, dist_buf, light_buf, params, ocean_frac, temp_buf, moist_buf, precip_buf)
			if ok_gpu:
				_climate_cpu_mirror_dirty = true
				return true
	push_error("Climate GPU evaluate failed in GPU-only mode.")
	return false

func _build_feature_noise_gpu_buffers(w: int, h: int, size: int) -> bool:
	if _gpu_buffer_manager == null:
		return false
	if w <= 0 or h <= 0 or size <= 0:
		return false
	if _feature_noise_cache == null:
		_feature_noise_cache = FeatureNoiseCache.new()
	if not ("build" in _feature_noise_cache):
		return false
	var desert_buf: RID = ensure_gpu_storage_buffer("desert_noise", size * 4)
	var ice_buf: RID = ensure_gpu_storage_buffer("ice_wiggle_noise", size * 4)
	var shore_buf: RID = ensure_gpu_storage_buffer("shore_noise", size * 4)
	var shelf_buf: RID = ensure_gpu_storage_buffer("shelf_value_noise", size * 4)
	if not desert_buf.is_valid() or not ice_buf.is_valid() or not shore_buf.is_valid() or not shelf_buf.is_valid():
		return false
	var noise_params := {
		"width": w,
		"height": h,
		"seed": config.rng_seed,
		"frequency": config.frequency,
		"noise_x_scale": config.noise_x_scale,
	}
	_feature_noise_cache.build(noise_params)
	var desert_noise: PackedFloat32Array = _feature_noise_cache.desert_noise_field
	var ice_wiggle: PackedFloat32Array = _feature_noise_cache.ice_wiggle_field
	var shore_noise: PackedFloat32Array = _feature_noise_cache.shore_noise_field
	var shelf_noise: PackedFloat32Array = _feature_noise_cache.shelf_value_noise_field
	if desert_noise.size() != size or ice_wiggle.size() != size or shore_noise.size() != size or shelf_noise.size() != size:
		return false
	# Keep CPU mirrors in sync for renderer/debug consumers while preserving GPU
	# buffer authority for runtime simulation.
	last_desert_noise_field = desert_noise
	last_shelf_value_noise_field = shelf_noise
	var ok_desert: bool = update_persistent_buffer("desert_noise", desert_noise.to_byte_array())
	var ok_ice: bool = update_persistent_buffer("ice_wiggle_noise", ice_wiggle.to_byte_array())
	var ok_shore: bool = update_persistent_buffer("shore_noise", shore_noise.to_byte_array())
	var ok_shelf: bool = update_persistent_buffer("shelf_value_noise", shelf_noise.to_byte_array())
	return ok_desert and ok_ice and ok_shore and ok_shelf

func generate() -> PackedByteArray:
	var w: int = config.width
	var h: int = config.height
	_prepare_new_generation_state(w * h)
	_apply_seeded_physical_defaults(true)
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

	# Step 1: terrain (CPU noise generation for parity; upload once to GPU buffers)
	var size_init: int = w * h
	var terrain_cpu: Dictionary = TerrainNoise.new().generate(params)
	var height_cpu: PackedFloat32Array = terrain_cpu.get("height", PackedFloat32Array())
	var land_cpu: PackedByteArray = terrain_cpu.get("is_land", PackedByteArray())
	if height_cpu.size() != size_init or land_cpu.size() != size_init:
		push_error("Terrain generation failed (CPU noise path returned invalid sizes).")
		return PackedByteArray()
	last_height = height_cpu
	last_height_final = height_cpu
	last_is_land = land_cpu
	# Clamp sea level if it would eliminate nearly all oceans, then recompute land mask.
	var effective_sea_level: float = config.sea_level
	if _height_mirror_has_signal(last_height_final):
		effective_sea_level = _clamp_sea_level_for_min_ocean(last_height_final, config.sea_level)
	if abs(effective_sea_level - config.sea_level) > 0.000001:
		config.sea_level = effective_sea_level
		for i_land in range(size_init):
			last_is_land[i_land] = 1 if last_height_final[i_land] > config.sea_level else 0
	var ocean_ct_init: int = 0
	for i_ocean in range(size_init):
		if last_is_land[i_ocean] == 0:
			ocean_ct_init += 1
	last_ocean_fraction = float(ocean_ct_init) / float(max(1, size_init))
	# Upload CPU-generated terrain to persistent buffers for downstream GPU systems.
	_buffers_seeded = false
	_buffer_seed_size = 0
	ensure_persistent_buffers(true)

	# PoolingSystem: generation path mirrors runtime GPU lake pipeline.
	ensure_persistent_buffers(false)
	var height_buf_gen: RID = get_persistent_buffer("height")
	var land_buf_gen: RID = get_persistent_buffer("is_land")
	var lake_buf_gen: RID = get_persistent_buffer("lake")
	var lake_id_buf_gen: RID = get_persistent_buffer("lake_id")
	var lakes_ok_gen: bool = false
	if config.lakes_enabled and height_buf_gen.is_valid() and land_buf_gen.is_valid() and lake_buf_gen.is_valid() and lake_id_buf_gen.is_valid():
		if config.realistic_pooling_enabled:
			var iters: int = _lake_fill_iterations(w, h, last_ocean_fraction)
			var e_primary: RID = ensure_gpu_storage_buffer("lake_e_primary", size_init * 4)
			var e_tmp: RID = ensure_gpu_storage_buffer("lake_e_tmp", size_init * 4)
			if e_primary.is_valid() and e_tmp.is_valid():
				var fill_gen: Object = DepressionFillCompute.new()
				if fill_gen != null and "compute_lake_mask_gpu_buffers" in fill_gen:
					var fill_ok: bool = fill_gen.compute_lake_mask_gpu_buffers(
						w,
						h,
						height_buf_gen,
						land_buf_gen,
						true,
						iters,
						e_primary,
						e_tmp,
						lake_buf_gen
					)
					if fill_ok:
						var label_gen: Object = LakeLabelFromMaskCompute.new()
						var label_iters: int = max(16, min(512, w + h))
						if label_gen != null and "label_from_mask_gpu_buffers" in label_gen:
							lakes_ok_gen = label_gen.label_from_mask_gpu_buffers(w, h, lake_buf_gen, true, lake_id_buf_gen, label_iters)
		else:
			if _lake_label_compute == null:
				_lake_label_compute = LakeLabelCompute.new()
			if _lake_label_compute != null and "label_lakes_gpu_buffers" in _lake_label_compute:
				var label_iters2: int = max(16, min(512, w + h))
				lakes_ok_gen = _lake_label_compute.label_lakes_gpu_buffers(w, h, land_buf_gen, true, lake_buf_gen, lake_id_buf_gen, label_iters2)
	elif not config.lakes_enabled:
		lakes_ok_gen = true
	if not lakes_ok_gen:
		push_error("Generate: lake pipeline GPU path failed (CPU fallback removed).")
		return PackedByteArray()
	last_lake.resize(size_init)
	last_lake.fill(0)
	last_lake_id.resize(size_init)
	last_lake_id.fill(0)
	if not apply_ocean_connectivity_gate_runtime():
		push_error("Generate: ocean connectivity gate failed.")
		return PackedByteArray()

	# Step 2: feature noise + shoreline features (GPU buffer-to-buffer, no readback)
	var size: int = w * h
	last_turquoise_water.resize(size)
	last_beach.resize(size)
	last_water_distance.resize(size)
	last_turquoise_strength.resize(size)
	ensure_persistent_buffers(false)
	var height_buf_step2: RID = get_persistent_buffer("height")
	var land_buf_step2: RID = get_persistent_buffer("is_land")
	var dist_buf_step2: RID = get_persistent_buffer("distance")
	var dist_tmp_buf_step2: RID = get_persistent_buffer("distance_tmp")
	var beach_buf_step2: RID = get_persistent_buffer("beach")
	var turq_buf_step2: RID = get_persistent_buffer("turquoise")
	var strength_buf_step2: RID = get_persistent_buffer("turquoise_strength")
	if not height_buf_step2.is_valid() or not land_buf_step2.is_valid() or not dist_buf_step2.is_valid() or not dist_tmp_buf_step2.is_valid() or not beach_buf_step2.is_valid() or not turq_buf_step2.is_valid() or not strength_buf_step2.is_valid():
		push_error("Generate: required GPU buffers unavailable for feature/shoreline pass.")
		return PackedByteArray()
	if not _build_feature_noise_gpu_buffers(w, h, size):
		push_error("Generate: feature noise GPU pass failed.")
		return PackedByteArray()
	var shore_noise_buf_step2: RID = get_persistent_buffer("shore_noise")
	if not shore_noise_buf_step2.is_valid():
		push_error("Generate: shore noise GPU buffer missing after feature noise pass.")
		return PackedByteArray()
	# Distance-to-coast on GPU buffers
	if _dt_compute == null:
		_dt_compute = DistanceTransformCompute.new()
	var dt_ok: bool = _dt_compute.ocean_distance_to_land_gpu_buffers(w, h, land_buf_step2, true, dist_buf_step2, dist_tmp_buf_step2)
	if not dt_ok:
		push_error("Generate: distance transform GPU pass failed.")
		return PackedByteArray()
	# Shelf features on GPU buffers
	if _shelf_compute == null:
		_shelf_compute = ContinentalShelfCompute.new()
	var shelf_ok: bool = _shelf_compute.compute_to_buffers(
		w,
		h,
		height_buf_step2,
		land_buf_step2,
		dist_buf_step2,
		shore_noise_buf_step2,
		config.sea_level,
		config.shallow_threshold,
		config.shore_band,
		true,
		config.noise_x_scale,
		turq_buf_step2,
		beach_buf_step2,
		strength_buf_step2
	)
	if not shelf_ok:
		push_error("Generate: continental shelf GPU pass failed.")
		return PackedByteArray()
	# Keep CPU mirrors sized but non-authoritative in GPU-only mode.
	last_water_distance.fill(0.0)
	last_turquoise_water.fill(0)
	last_beach.fill(0)
	last_turquoise_strength.fill(0.0)

	# Step 3: climate via GPU
	params["distance_to_coast"] = PackedFloat32Array()
	# time_of_day is set via SeasonalClimateSystem apply_config; nothing to do here
	var climate_ok: bool = _evaluate_climate_gpu_only(w, h, params, PackedFloat32Array(), last_ocean_fraction)
	if not climate_ok:
		push_error("Climate GPU evaluate failed during generate(); aborting world generation in GPU-only mode.")
		return PackedByteArray()
	# CPU climate arrays are non-authoritative in GPU-only mode.
	if last_temperature.size() != size:
		last_temperature.resize(size)
		last_temperature.fill(0.5)
	if last_moisture.size() != size:
		last_moisture.resize(size)
		last_moisture.fill(0.5)
	if last_distance_to_coast.size() != size:
		last_distance_to_coast.resize(size)
	last_distance_to_coast.fill(0.0)

	# Build initial day/night light field directly in persistent GPU buffer.
	var light_ok: bool = false
	if _climate_compute_gpu != null and _gpu_buffer_manager != null:
		ensure_persistent_buffers(false)
		var light_buf_init: RID = get_persistent_buffer("light")
		var height_buf_init: RID = get_persistent_buffer("height")
		if light_buf_init.is_valid() and height_buf_init.is_valid():
			light_ok = _climate_compute_gpu.evaluate_light_field_gpu(w, h, params, height_buf_init, light_buf_init)
	if not light_ok:
		push_error("Generate: light field GPU pass failed (CPU fallback removed).")
		return PackedByteArray()
	if last_light.size() != w * h:
		last_light.resize(w * h)
		last_light.fill(0.75)

	# Mountain radiance: run this pass fully on persistent GPU buffers when possible.
	var climpost: Object = ensure_climate_post_compute()
	var mr_passes: int = max(0, config.mountain_radiance_passes)
	var mr_gpu_ok: bool = false
	if _gpu_buffer_manager != null and mr_passes > 0:
		ensure_persistent_buffers(false)
		var b_buf0: RID = get_persistent_buffer("biome_id")
		var t_buf0: RID = get_persistent_buffer("temperature")
		var m_buf0: RID = get_persistent_buffer("moisture")
		var t_tmp0: RID = get_persistent_buffer("temperature_tmp")
		var m_tmp0: RID = get_persistent_buffer("moisture_tmp")
		if b_buf0.is_valid() and t_buf0.is_valid() and m_buf0.is_valid() and t_tmp0.is_valid() and m_tmp0.is_valid() and "apply_mountain_radiance_to_buffers" in climpost:
			var mr0: Dictionary = climpost.apply_mountain_radiance_to_buffers(
				w, h, b_buf0, t_buf0, m_buf0, t_tmp0, m_tmp0,
				config.mountain_cool_amp, config.mountain_wet_amp, mr_passes
			)
			mr_gpu_ok = bool(mr0.get("ok", false))
			if mr_gpu_ok and not bool(mr0.get("temp_in_primary", true)):
				dispatch_copy_u32(t_tmp0, t_buf0, size)
			if mr_gpu_ok and not bool(mr0.get("moist_in_primary", true)):
				dispatch_copy_u32(m_tmp0, m_buf0, size)
	if mr_passes > 0 and not mr_gpu_ok:
		push_error("Generate: mountain radiance GPU pass failed (CPU fallback removed).")
		return PackedByteArray()
	# Reset biome/cryosphere climate history from current generated climate to avoid
	# stale persistence artifacts (e.g. isolated frozen biome seeds after regen).
	_sync_biome_climate_history_buffers(size)

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
	var min_h2: float = -1.0
	var max_h2: float = 1.0
	if _height_mirror_has_signal(last_height):
		min_h2 = 1e20
		max_h2 = -1e20
		for hv2 in last_height:
			min_h2 = min(min_h2, hv2)
			max_h2 = max(max_h2, hv2)
	params2["min_h"] = min_h2
	params2["max_h"] = max_h2
	ensure_persistent_buffers(false)
	var height_buf0: RID = get_persistent_buffer("height")
	var land_buf0: RID = get_persistent_buffer("is_land")
	var temp_buf0: RID = get_persistent_buffer("temperature")
	var moist_buf0: RID = get_persistent_buffer("moisture")
	var beach_buf0: RID = get_persistent_buffer("beach")
	var desert_buf0: RID = get_persistent_buffer("desert_noise")
	var biome_noise_buf0: RID = get_persistent_buffer("shore_noise")
	var fertility_buf0: RID = get_persistent_buffer("fertility")
	var biome_buf0: RID = get_persistent_buffer("biome_id")
	var biome_tmp_buf0: RID = get_persistent_buffer("biome_tmp")
	var lava_buf0: RID = get_persistent_buffer("lava")
	var lake_buf0: RID = get_persistent_buffer("lake")
	var rock_buf0: RID = get_persistent_buffer("rock_type")
	var bc: Object = ensure_biome_compute()
	var bp: Object = ensure_biome_post_compute()
	var post_ok0: bool = false
	var gpu_ready0: bool = height_buf0.is_valid() and land_buf0.is_valid() and temp_buf0.is_valid() and moist_buf0.is_valid() and beach_buf0.is_valid() and fertility_buf0.is_valid() and biome_buf0.is_valid() and biome_tmp_buf0.is_valid() and lava_buf0.is_valid() and lake_buf0.is_valid() and rock_buf0.is_valid()
	if gpu_ready0:
		var classified_ok0: bool = bc.classify_to_buffer(w, h, height_buf0, land_buf0, temp_buf0, moist_buf0, beach_buf0, desert_buf0, fertility_buf0, params2, biome_tmp_buf0, biome_noise_buf0)
		if classified_ok0:
			post_ok0 = bp.apply_overrides_and_lava_gpu(
				w,
				h,
				land_buf0,
				temp_buf0,
				moist_buf0,
				biome_tmp_buf0,
				lake_buf0,
				rock_buf0,
				biome_buf0,
				lava_buf0,
				config.temp_min_c,
				config.temp_max_c,
				config.lava_temp_threshold_c,
				1.0
			)
	if not post_ok0:
		push_error("Generate: biome GPU post pipeline failed (CPU fallback removed).")
		return PackedByteArray()
	# Volcanism step (GPU): generation starts with hotspot-only volcanism.
	# Boundary-driven volcanism is applied by runtime Plate/Volcanism systems once
	# current-world plate boundaries are available.
	var volcanism: Object = ensure_volcanism_compute()
	var bnd_i32 := PackedInt32Array(); bnd_i32.resize(w * h)
	bnd_i32.fill(0)
	var boundary_buf0: RID = ensure_gpu_storage_buffer("plate_boundary", size * 4, bnd_i32.to_byte_array())
	var lava_buf_after_biome: RID = get_persistent_buffer("lava")
	if boundary_buf0.is_valid() and lava_buf_after_biome.is_valid():
		volcanism.step_gpu_buffers(w, h, boundary_buf0, lava_buf_after_biome, float(1.0 / 120.0), {
		"decay_rate_per_day": 0.02,
		"spawn_boundary_rate_per_day": 0.05,
		"hotspot_rate_per_day": 0.01,
		"hotspot_threshold": 0.995,
	}, fposmod(float(Time.get_ticks_msec()) / 1000.0, 1.0), int(config.rng_seed))

	# Hot/cold biome overrides are applied in the GPU biome post pass.

	# Initialize clouds after biomes/light are ready to avoid low-detail startup artifacts.
	var cloud_compute: Object = ensure_cloud_overlay_compute()
	var phase0: float = fposmod(config.season_phase, 1.0)
	ensure_persistent_buffers(false)
	var cloud_buf0: RID = get_persistent_buffer("clouds")
	var temp_buf_cloud: RID = get_persistent_buffer("temperature")
	var moist_buf_cloud: RID = get_persistent_buffer("moisture")
	var land_buf_cloud: RID = get_persistent_buffer("is_land")
	var light_buf_cloud: RID = get_persistent_buffer("light")
	var biome_buf_cloud: RID = get_persistent_buffer("biome_id")
	var height_buf_cloud: RID = get_persistent_buffer("height")
	var wind_u_buf_cloud: RID = get_persistent_buffer("wind_u")
	var wind_v_buf_cloud: RID = get_persistent_buffer("wind_v")
	if cloud_buf0.is_valid() and temp_buf_cloud.is_valid() and moist_buf_cloud.is_valid() and land_buf_cloud.is_valid() and light_buf_cloud.is_valid() and biome_buf_cloud.is_valid() and height_buf_cloud.is_valid() and wind_u_buf_cloud.is_valid() and wind_v_buf_cloud.is_valid():
		cloud_compute.compute_clouds_to_buffer(
			w, h,
			temp_buf_cloud,
			moist_buf_cloud,
			land_buf_cloud,
			light_buf_cloud,
			biome_buf_cloud,
			height_buf_cloud,
			wind_u_buf_cloud,
			wind_v_buf_cloud,
			phase0,
			int(config.rng_seed),
			cloud_buf0
		)
		var cloud_tex_compute: Object = load("res://scripts/systems/CloudTextureCompute.gd").new()
		var ctex: Texture2D = cloud_tex_compute.update_from_buffer(w, h, cloud_buf0)
		if ctex:
			set_cloud_texture_override(ctex)

	# Ensure persistent GPU buffers are seeded from current world fields before hydro chaining.
	if _gpu_buffer_manager == null:
		_gpu_buffer_manager = GPUBufferManager.new()
	ensure_persistent_buffers(false)

	# Step 5: rivers (post-climate so we can freeze-gate; cooperate with PoolingSystem lakes)
	if config.rivers_enabled:
		var size2: int = w * h
		if _flow_compute == null:
			_flow_compute = FlowCompute.new()
		var hbuf: RID = get_persistent_buffer("height")
		var land_buf: RID = get_persistent_buffer("is_land")
		var flow_dir_buf: RID = get_persistent_buffer("flow_dir")
		var flow_acc_buf: RID = get_persistent_buffer("flow_accum")
		var river_buf: RID = get_persistent_buffer("river")
		var lake_buf: RID = get_persistent_buffer("lake")
		var dist_buf: RID = get_persistent_buffer("distance")
		if not hbuf.is_valid() or not land_buf.is_valid() or not flow_dir_buf.is_valid() or not flow_acc_buf.is_valid() or not river_buf.is_valid() or not lake_buf.is_valid():
			return last_is_land
		var flow_ok: bool = _flow_compute.compute_flow_gpu_buffers(w, h, hbuf, land_buf, true, flow_dir_buf, flow_acc_buf, Rect2i(0, 0, 0, 0), _gpu_buffer_manager)
		if not flow_ok:
			return last_is_land
		if _river_compute == null:
			_river_compute = RiverCompute.new()
		var thr_seed: float = _compute_river_seed_threshold(PackedFloat32Array(), last_is_land, config.river_threshold, config.river_threshold_factor)
		last_river_seed_threshold = thr_seed
		var traced_ok: bool = _river_compute.trace_rivers_gpu_buffers(
			w, h,
			land_buf,
			lake_buf,
			flow_dir_buf,
			flow_acc_buf,
			thr_seed,
			5,
			Rect2i(0, 0, 0, 0),
			river_buf,
			true
		)
		if not traced_ok:
			return last_is_land
		# GPU river delta widening (post): keep conservative and major-river-gated.
		if config.river_delta_widening and dist_buf.is_valid():
			var rpost: Object = ensure_river_post_compute()
			var delta_shore_dist: float = min(config.shore_band, 1.0)
			var delta_min_accum: float = _estimate_delta_source_min_accum(size2, thr_seed)
			var river_tmp_buf: RID = ensure_gpu_storage_buffer("river_tmp", size2 * 4)
			if river_tmp_buf.is_valid():
				var widened_ok: bool = rpost.widen_deltas_gpu_buffers(w, h, river_buf, land_buf, dist_buf, flow_acc_buf, delta_shore_dist, delta_min_accum, river_tmp_buf)
				if widened_ok:
					dispatch_copy_u32(river_tmp_buf, river_buf, size2)
		# Freeze-gate rivers directly on GPU.
		var river_freeze0: Object = ensure_river_freeze_compute()
		var temp_buf_r0: RID = get_persistent_buffer("temperature")
		var biome_buf_r0: RID = get_persistent_buffer("biome_id")
		if river_freeze0 != null and temp_buf_r0.is_valid() and biome_buf_r0.is_valid():
			river_freeze0.apply_gpu_buffers(
				w,
				h,
				river_buf,
				land_buf,
				temp_buf_r0,
				biome_buf_r0,
				config.temp_min_c,
				config.temp_max_c,
				int(BiomeClassifier.Biome.GLACIER),
				0.0
			)
	else:
		var sz: int = w * h
		last_flow_dir.resize(sz)
		last_flow_accum.resize(sz)
		last_river.resize(sz)
		for kk in range(sz):
			last_flow_dir[kk] = -1
			last_flow_accum[kk] = 0.0
			last_river[kk] = 0
		update_persistent_buffer("river", _pack_bytes_to_u32(last_river).to_byte_array())

	# Seed GPU buffers from freshly generated CPU arrays before simulation starts.
	if _gpu_buffer_manager == null:
		_gpu_buffer_manager = GPUBufferManager.new()
	ensure_persistent_buffers(false)
	update_water_budget_and_sea_solver(0.0, null)

	return last_is_land

func _prepare_new_generation_state(size: int) -> void:
	if size <= 0:
		return
	# Force first persistent-buffer allocation/update in this generation to upload
	# deterministic seed data instead of reusing prior-world runtime state.
	_buffers_seeded = false
	_buffer_seed_size = 0

	last_flow_dir.resize(size)
	last_flow_dir.fill(-1)
	last_flow_accum.resize(size)
	last_flow_accum.fill(0.0)
	last_river.resize(size)
	last_river.fill(0)
	last_lake.resize(size)
	last_lake.fill(0)
	last_lake_id.resize(size)
	last_lake_id.fill(0)
	last_lava.resize(size)
	last_lava.fill(0)
	last_biomes.resize(size)
	last_biomes.fill(0)
	last_rock_type.resize(size)
	last_rock_type.fill(LithologyCompute.ROCK_BASALTIC)
	last_temperature.resize(size)
	last_temperature.fill(0.5)
	last_moisture.resize(size)
	last_moisture.fill(0.5)
	last_fertility.resize(size)
	for i_f in range(size):
		last_fertility[i_f] = _base_fertility_for_rock(last_rock_type[i_f])
	_water_budget_initialized = false
	_water_total_target = 0.0
	_water_ocean_fraction_target = -1.0
	_sea_solver_last_apply_day = -1.0
	_tectonic_bias_prev_mean_valid = false
	_tectonic_bias_prev_mean_height = 0.0
	water_budget_stats.clear()
	last_clouds.resize(size)
	last_clouds.fill(0.0)
	last_light.resize(size)
	last_light.fill(0.75)
	# Plate runtime state is authoritative only for the active world.
	_plates_boundary_mask_i32.clear()
	_plates_boundary_mask_render_u8.clear()
	_plates_cell_id_i32.clear()
	_plates_vel_u.clear()
	_plates_vel_v.clear()
	_plates_buoyancy.clear()

func _sync_biome_climate_history_buffers(size: int) -> void:
	if size <= 0:
		return
	if _gpu_buffer_manager == null:
		return
	ensure_persistent_buffers(false)
	var temp_buf: RID = get_persistent_buffer("temperature")
	var moist_buf: RID = get_persistent_buffer("moisture")
	if not temp_buf.is_valid() or not moist_buf.is_valid():
		return
	var temp_base_buf: RID = get_persistent_buffer("temperature_base")
	if temp_base_buf.is_valid():
		dispatch_copy_u32(temp_buf, temp_base_buf, size)
	var biome_temp_buf: RID = get_persistent_buffer("biome_temp")
	if biome_temp_buf.is_valid():
		dispatch_copy_u32(temp_buf, biome_temp_buf, size)
	var cryo_temp_buf: RID = get_persistent_buffer("cryo_temp")
	if cryo_temp_buf.is_valid():
		dispatch_copy_u32(temp_buf, cryo_temp_buf, size)
	var biome_moist_buf: RID = get_persistent_buffer("biome_moist")
	if biome_moist_buf.is_valid():
		dispatch_copy_u32(moist_buf, biome_moist_buf, size)
	var cryo_moist_buf: RID = get_persistent_buffer("cryo_moist")
	if cryo_moist_buf.is_valid():
		dispatch_copy_u32(moist_buf, cryo_moist_buf, size)

func quick_update_sea_level(new_sea_level: float) -> PackedByteArray:
	# Fast path: only recompute artifacts depending on sea level.
	# Requires that base terrain (last_height) already exists.
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size:
		# No terrain yet; do full generate
		return generate()
	# Runtime uses persistent GPU buffers; do not read back height here.
	if _gpu_buffer_manager != null:
		ensure_persistent_buffers(false)
	if last_height_final.size() != size:
		last_height_final = last_height
	var desired_sea_level: float = new_sea_level
	if _height_mirror_has_signal(last_height_final):
		desired_sea_level = _clamp_sea_level_for_min_ocean(last_height_final, desired_sea_level)
	config.sea_level = desired_sea_level
	# 1) Recompute land mask
	if last_is_land.size() != size:
		last_is_land.resize(size)
	var land_updated_gpu: bool = false
	var land_buf: RID = RID()
	var height_buf: RID = RID()
	var dist_buf: RID = RID()
	var dist_tmp_buf: RID = RID()
	var beach_buf: RID = RID()
	var strength_buf: RID = RID()
	if _gpu_buffer_manager != null:
		land_buf = get_persistent_buffer("is_land")
		height_buf = get_persistent_buffer("height")
		dist_buf = get_persistent_buffer("distance")
		dist_tmp_buf = ensure_gpu_storage_buffer("distance_tmp", size * 4)
		beach_buf = get_persistent_buffer("beach")
		strength_buf = ensure_gpu_storage_buffer("turquoise_strength", size * 4)
		if land_buf.is_valid() and height_buf.is_valid():
			if _land_mask_compute == null:
				_land_mask_compute = LandMaskCompute.new()
			land_updated_gpu = _land_mask_compute.update_from_height(w, h, height_buf, config.sea_level, land_buf)
	# Keep a CPU mirror for systems still consuming last_is_land (no GPU readback).
	if _height_mirror_has_signal(last_height_final):
		for i in range(size):
			last_is_land[i] = 1 if last_height_final[i] > config.sea_level else 0
	else:
		last_is_land.fill(1 if 0.0 > config.sea_level else 0)
	if not land_updated_gpu and _gpu_buffer_manager != null:
		update_persistent_buffer("is_land", _pack_bytes_to_u32(last_is_land).to_byte_array())
	# Enforce ocean connectivity before downstream shoreline/climate work.
	if not apply_ocean_connectivity_gate_runtime():
		push_warning("quick_update_sea_level: ocean connectivity gate failed; using raw sea-level land mask.")
	# Update ocean fraction
	if _height_mirror_has_signal(last_height_final):
		var ocean_ct: int = 0
		for ii in range(size):
			if last_is_land[ii] == 0:
				ocean_ct += 1
		last_ocean_fraction = float(ocean_ct) / float(max(1, size))
	else:
		last_ocean_fraction = _estimate_ocean_fraction_from_sea_level(config.sea_level)
	# 2) Recompute shoreline features (turquoise, beaches) and distance to land
	if last_turquoise_water.size() != size:
		last_turquoise_water.resize(size)
	if last_beach.size() != size:
		last_beach.resize(size)
	if last_water_distance.size() != size:
		last_water_distance.resize(size)
	if last_turquoise_strength.size() != size:
		last_turquoise_strength.resize(size)
	# Recompute via GPU only.
	if not _build_feature_noise_gpu_buffers(w, h, size):
		push_error("quick_update_sea_level: feature noise GPU pass failed.")
		return last_is_land
	var shore_noise_buf: RID = get_persistent_buffer("shore_noise")
	# Distance to coast on GPU (buffer-to-buffer, no readback)
	if _dt_compute == null:
		_dt_compute = DistanceTransformCompute.new()
	var dt_ok: bool = false
	if _gpu_buffer_manager != null and land_buf.is_valid() and dist_buf.is_valid() and dist_tmp_buf.is_valid():
		dt_ok = _dt_compute.ocean_distance_to_land_gpu_buffers(w, h, land_buf, true, dist_buf, dist_tmp_buf)
	if not dt_ok:
		push_error("quick_update_sea_level: distance transform GPU update failed (CPU fallback disabled).")
		return last_is_land
	# Shelf features on GPU using finalized distance (buffer-to-buffer, no readback)
	if _shelf_compute == null:
		_shelf_compute = ContinentalShelfCompute.new()
	var turq_buf: RID = ensure_gpu_storage_buffer("turquoise", size * 4)
	var shelf_ok: bool = false
	if _gpu_buffer_manager != null and height_buf.is_valid() and land_buf.is_valid() and dist_buf.is_valid() and shore_noise_buf.is_valid() and beach_buf.is_valid() and turq_buf.is_valid() and strength_buf.is_valid():
		shelf_ok = _shelf_compute.compute_to_buffers(
			w,
			h,
			height_buf,
			land_buf,
			dist_buf,
			shore_noise_buf,
			config.sea_level,
			config.shallow_threshold,
			config.shore_band,
			true,
			config.noise_x_scale,
			turq_buf,
			beach_buf,
			strength_buf
		)
	if not shelf_ok:
		push_error("quick_update_sea_level: continental shelf GPU update failed (CPU fallback disabled).")
		return last_is_land
	# 3) Recompute climate fields from persistent GPU buffers.
	quick_update_climate(true)
	_update_lithology_map(w, h)
	_seed_fertility_from_lithology(false)

	# 5) Reclassify biomes/lava directly on GPU buffers.
	quick_update_biomes()

	# 6) Lakes and rivers recompute on sea-level change (order: lakes, then rivers)
	var lake_buf2: RID = get_persistent_buffer("lake")
	var lake_id_buf2: RID = get_persistent_buffer("lake_id")
	if config.lakes_enabled:
		if _gpu_buffer_manager == null or not height_buf.is_valid() or not land_buf.is_valid() or not lake_buf2.is_valid() or not lake_id_buf2.is_valid():
			push_error("quick_update_sea_level: lake buffers unavailable (CPU fallback disabled).")
			return last_is_land
		var lakes_ok: bool = false
		if config.realistic_pooling_enabled:
			var iters2: int = _lake_fill_iterations(w, h, last_ocean_fraction)
			var e_primary: RID = ensure_gpu_storage_buffer("lake_e_primary", size * 4)
			var e_tmp: RID = ensure_gpu_storage_buffer("lake_e_tmp", size * 4)
			if e_primary.is_valid() and e_tmp.is_valid():
				var fill: Object = DepressionFillCompute.new()
				if fill != null and "compute_lake_mask_gpu_buffers" in fill:
					var fill_ok: bool = fill.compute_lake_mask_gpu_buffers(
						w,
						h,
						height_buf,
						land_buf,
						true,
						iters2,
						e_primary,
						e_tmp,
						lake_buf2
					)
					if fill_ok:
						var lab2: Object = LakeLabelFromMaskCompute.new()
						var label_iters: int = max(16, min(512, w + h))
						if lab2 != null and "label_from_mask_gpu_buffers" in lab2:
							lakes_ok = lab2.label_from_mask_gpu_buffers(w, h, lake_buf2, true, lake_id_buf2, label_iters)
		else:
			if _lake_label_compute == null:
				_lake_label_compute = LakeLabelCompute.new()
			if _lake_label_compute != null and "label_lakes_gpu_buffers" in _lake_label_compute:
				var label_iters2: int = max(16, min(512, w + h))
				lakes_ok = _lake_label_compute.label_lakes_gpu_buffers(w, h, land_buf, true, lake_buf2, lake_id_buf2, label_iters2)
		if not lakes_ok:
			push_error("quick_update_sea_level: lake recompute GPU path failed (CPU fallback disabled).")
			return last_is_land
	else:
		# If lakes are disabled, clear lake buffers and CPU mirror arrays.
		var zeros_i32 := PackedInt32Array()
		zeros_i32.resize(size)
		update_persistent_buffer("lake", zeros_i32.to_byte_array())
		update_persistent_buffer("lake_id", zeros_i32.to_byte_array())
		last_lake.resize(size)
		last_lake.fill(0)
		last_lake_id.resize(size)
		last_lake_id.fill(0)
	# Flow/rivers refresh on GPU-only path.
	quick_update_flow_rivers()

	if _gpu_buffer_manager != null:
		ensure_persistent_buffers(false)
	return last_is_land


func quick_update_climate(skip_light: bool = false) -> void:
	# Recompute climate on persistent GPU buffers only (no runtime readback).
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if size <= 0 or _gpu_buffer_manager == null:
		return
	ensure_persistent_buffers(false)

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
	var temp_offset_delta: float = config.temp_base_offset - _temperature_base_offset_ref
	var temp_scale_ratio: float = config.temp_scale / max(0.001, _temperature_base_scale_ref)
	params["temp_base_offset_delta"] = temp_offset_delta
	params["temp_scale_ratio"] = temp_scale_ratio

	if _climate_compute_gpu == null:
		_climate_compute_gpu = ClimateAdjustCompute.new()
	var height_buf: RID = get_persistent_buffer("height")
	var land_buf: RID = get_persistent_buffer("is_land")
	var dist_buf: RID = get_persistent_buffer("distance")
	var temp_buf: RID = get_persistent_buffer("temperature")
	var temp_base_buf: RID = get_persistent_buffer("temperature_base")
	var temp_tmp_buf: RID = get_persistent_buffer("temperature_tmp")
	var moist_buf: RID = get_persistent_buffer("moisture")
	var light_buf: RID = get_persistent_buffer("light")
	if not height_buf.is_valid() or not land_buf.is_valid() or not dist_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid() or not light_buf.is_valid():
		return
	if not temp_base_buf.is_valid():
		temp_base_buf = temp_buf

	var fast_baseline_ok: bool = abs(temp_offset_delta) < 0.02 and abs(temp_scale_ratio - 1.0) < 0.05
	var use_fast_path: bool = fast_baseline_ok and temp_base_buf.is_valid()
	var climate_ok: bool = false
	if use_fast_path:
		# Use previous runtime temperature as input so sunlight forcing has thermal memory.
		if temp_tmp_buf.is_valid():
			climate_ok = _climate_compute_gpu.apply_cycles_only_gpu(w, h, temp_buf, land_buf, dist_buf, light_buf, params, temp_tmp_buf)
			if climate_ok:
				dispatch_copy_u32(temp_tmp_buf, temp_buf, size)
		else:
			climate_ok = _climate_compute_gpu.apply_cycles_only_gpu(w, h, temp_buf, land_buf, dist_buf, light_buf, params, temp_buf)
	else:
		var precip_buf: RID = ensure_gpu_storage_buffer("precip", size * 4)
		if precip_buf.is_valid():
			climate_ok = _climate_compute_gpu.evaluate_to_buffers_gpu(
				w,
				h,
				height_buf,
				land_buf,
				dist_buf,
				light_buf,
				params,
				last_ocean_fraction,
				temp_buf,
				moist_buf,
				precip_buf
			)
	if not climate_ok:
		push_error("Climate GPU update failed in quick_update_climate (no CPU fallback/readback).")
		return
	_climate_cpu_mirror_dirty = true

	var climpost: Object = ensure_climate_post_compute()
	var mr_passes: int = max(0, config.mountain_radiance_passes)
	if mr_passes > 0 and climpost != null and "apply_mountain_radiance_to_buffers" in climpost:
		var biome_buf: RID = get_persistent_buffer("biome_id")
		var t_tmp: RID = get_persistent_buffer("temperature_tmp")
		var m_tmp: RID = get_persistent_buffer("moisture_tmp")
		if biome_buf.is_valid() and t_tmp.is_valid() and m_tmp.is_valid():
			var mr: Dictionary = climpost.apply_mountain_radiance_to_buffers(
				w,
				h,
				biome_buf,
				temp_buf,
				moist_buf,
				t_tmp,
				m_tmp,
				config.mountain_cool_amp,
				config.mountain_wet_amp,
				mr_passes
			)
			if bool(mr.get("ok", false)):
				if not bool(mr.get("temp_in_primary", true)):
					dispatch_copy_u32(t_tmp, temp_buf, size)
				if not bool(mr.get("moist_in_primary", true)):
					dispatch_copy_u32(m_tmp, moist_buf, size)

	# Keep baseline/smoothed buffers coherent without CPU mirror sync.
	if not use_fast_path and temp_base_buf.is_valid():
		dispatch_copy_u32(temp_buf, temp_base_buf, size)
		_temperature_base_offset_ref = config.temp_base_offset
		_temperature_base_scale_ref = max(0.001, config.temp_scale)
	var biome_temp_buf: RID = get_persistent_buffer("biome_temp")
	var biome_moist_buf: RID = get_persistent_buffer("biome_moist")
	var cryo_temp_buf: RID = get_persistent_buffer("cryo_temp")
	var cryo_moist_buf: RID = get_persistent_buffer("cryo_moist")
	if biome_temp_buf.is_valid():
		dispatch_copy_u32(temp_buf, biome_temp_buf, size)
	if biome_moist_buf.is_valid():
		dispatch_copy_u32(moist_buf, biome_moist_buf, size)
	if cryo_temp_buf.is_valid():
		dispatch_copy_u32(temp_buf, cryo_temp_buf, size)
	if cryo_moist_buf.is_valid():
		dispatch_copy_u32(moist_buf, cryo_moist_buf, size)

	# Always update light field unless caller skips.
	if not skip_light:
		var height_buf_light: RID = get_persistent_buffer("height")
		if light_buf.is_valid() and height_buf_light.is_valid():
			_climate_compute_gpu.evaluate_light_field_gpu(w, h, params, height_buf_light, light_buf)

func _update_lithology_map(w: int, h: int) -> void:
	var size: int = w * h
	if size <= 0:
		return
	if _gpu_buffer_manager == null:
		push_error("_update_lithology_map: GPU buffer manager unavailable (CPU fallback removed).")
		return
	if _lithology_compute == null:
		_lithology_compute = LithologyCompute.new()
	var lith_params := {
		"seed": config.rng_seed,
		"noise_x_scale": config.noise_x_scale,
	}
	var min_h: float = -1.0
	var max_h: float = 1.0
	if _height_mirror_has_signal(last_height):
		min_h = 1e20
		max_h = -1e20
		for hv in last_height:
			if hv < min_h:
				min_h = hv
			if hv > max_h:
				max_h = hv
	lith_params["min_h"] = min_h
	lith_params["max_h"] = max_h

	ensure_persistent_buffers(false)
	var height_buf: RID = get_persistent_buffer("height")
	var land_buf: RID = get_persistent_buffer("is_land")
	var temp_buf: RID = get_persistent_buffer("temperature")
	var moist_buf: RID = get_persistent_buffer("moisture")
	var lava_buf: RID = get_persistent_buffer("lava")
	var desert_buf: RID = get_persistent_buffer("desert_noise")
	var rock_buf: RID = get_persistent_buffer("rock_type")
	if not height_buf.is_valid() or not land_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid() or not lava_buf.is_valid() or not rock_buf.is_valid():
		push_error("_update_lithology_map: required GPU buffers unavailable (CPU fallback removed).")
		return
	var ok_gpu: bool = _lithology_compute.classify_to_buffer(
		w, h, height_buf, land_buf, temp_buf, moist_buf, lava_buf, desert_buf, lith_params, rock_buf
	)
	if not ok_gpu:
		push_error("_update_lithology_map: lithology GPU classify failed (CPU fallback removed).")
		return

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
	if _gpu_buffer_manager == null:
		push_error("_seed_fertility_from_lithology: GPU buffer manager unavailable (CPU fallback removed).")
		return
	ensure_persistent_buffers(false)
	var rock_buf: RID = get_persistent_buffer("rock_type")
	var land_buf: RID = get_persistent_buffer("is_land")
	var moist_buf: RID = get_persistent_buffer("moisture")
	var lava_buf: RID = get_persistent_buffer("lava")
	var fertility_buf: RID = get_persistent_buffer("fertility")
	var fert: Object = ensure_fertility_compute()
	if not rock_buf.is_valid() or not land_buf.is_valid() or not moist_buf.is_valid() or not lava_buf.is_valid() or not fertility_buf.is_valid() or fert == null or not ("seed_from_lithology_gpu_buffers" in fert):
		push_error("_seed_fertility_from_lithology: required GPU fertility resources unavailable (CPU fallback removed).")
		return
	var gpu_ok: bool = fert.seed_from_lithology_gpu_buffers(
		config.width,
		config.height,
		rock_buf,
		land_buf,
		moist_buf,
		lava_buf,
		fertility_buf,
		(reset_existing or last_fertility.size() != size)
	)
	if not gpu_ok:
		push_error("_seed_fertility_from_lithology: fertility GPU seed failed (CPU fallback removed).")

func quick_update_biomes() -> void:
	# Reclassify biomes entirely on GPU buffers (no runtime readback/fallback).
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if size <= 0 or _gpu_buffer_manager == null:
		return
	_update_lithology_map(w, h)
	_seed_fertility_from_lithology(false)
	ensure_persistent_buffers(false)

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
	params2["biome_noise_strength_c"] = 0.8
	params2["biome_moist_jitter"] = 0.06
	params2["biome_phase"] = biome_phase
	params2["biome_moist_jitter2"] = 0.03
	params2["biome_moist_islands"] = 0.35
	params2["biome_moist_elev_dry"] = 0.35
	var min_h: float = -1.0
	var max_h: float = 1.0
	if _height_mirror_has_signal(last_height):
		min_h = 1e20
		max_h = -1e20
		for hv in last_height:
			min_h = min(min_h, hv)
			max_h = max(max_h, hv)
	params2["min_h"] = min_h
	params2["max_h"] = max_h

	var height_buf: RID = get_persistent_buffer("height")
	var land_buf: RID = get_persistent_buffer("is_land")
	var temp_buf: RID = get_persistent_buffer("temperature")
	var moist_buf: RID = get_persistent_buffer("moisture")
	var beach_buf: RID = get_persistent_buffer("beach")
	var desert_buf: RID = get_persistent_buffer("desert_noise")
	var biome_noise_buf: RID = get_persistent_buffer("shore_noise")
	var fertility_buf: RID = get_persistent_buffer("fertility")
	var biome_buf: RID = get_persistent_buffer("biome_id")
	var biome_tmp_buf: RID = get_persistent_buffer("biome_tmp")
	var lava_buf: RID = get_persistent_buffer("lava")
	var lake_buf: RID = get_persistent_buffer("lake")
	var rock_buf: RID = get_persistent_buffer("rock_type")
	if not height_buf.is_valid() or not land_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid() or not beach_buf.is_valid():
		return
	if not fertility_buf.is_valid() or not biome_buf.is_valid() or not biome_tmp_buf.is_valid() or not lava_buf.is_valid() or not lake_buf.is_valid() or not rock_buf.is_valid():
		return

	var bc: Object = ensure_biome_compute()
	if bc == null or not bc.classify_to_buffer(w, h, height_buf, land_buf, temp_buf, moist_buf, beach_buf, desert_buf, fertility_buf, params2, biome_tmp_buf, biome_noise_buf):
		push_error("quick_update_biomes: GPU classify failed (CPU fallback disabled).")
		return
	var bp: Object = ensure_biome_post_compute()
	if bp == null or not bp.apply_overrides_and_lava_gpu(
		w,
		h,
		land_buf,
		temp_buf,
		moist_buf,
		biome_tmp_buf,
		lake_buf,
		rock_buf,
		biome_buf,
		lava_buf,
		config.temp_min_c,
		config.temp_max_c,
		config.lava_temp_threshold_c,
		1.0
	):
		push_error("quick_update_biomes: GPU postprocess failed (CPU fallback disabled).")
		return

	# Refresh GPU texture overrides directly from buffers.
	var biome_tex_compute: Object = load("res://scripts/systems/BiomeTextureCompute.gd").new()
	var lava_tex_compute: Object = load("res://scripts/systems/LavaTextureCompute.gd").new()
	var btex: Texture2D = biome_tex_compute.update_from_buffer(w, h, biome_buf)
	if btex:
		set_biome_texture_override(btex)
	var ltex: Texture2D = lava_tex_compute.update_from_buffer(w, h, lava_buf)
	if ltex:
		set_lava_texture_override(ltex)


func quick_update_flow_rivers() -> void:
	# Recompute flow direction, accumulation, and river mask from current fields.
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size or last_is_land.size() != size:
		return
	ensure_persistent_buffers(false)
	var hbuf: RID = get_persistent_buffer("height")
	var land_buf: RID = get_persistent_buffer("is_land")
	var flow_dir_buf: RID = get_persistent_buffer("flow_dir")
	var flow_acc_buf: RID = get_persistent_buffer("flow_accum")
	var river_buf: RID = get_persistent_buffer("river")
	var lake_buf: RID = get_persistent_buffer("lake")
	var dist_buf: RID = get_persistent_buffer("distance")
	if not hbuf.is_valid() or not land_buf.is_valid() or not flow_dir_buf.is_valid() or not flow_acc_buf.is_valid() or not river_buf.is_valid() or not lake_buf.is_valid():
		return
	if _flow_compute == null:
		_flow_compute = FlowCompute.new()
	var ok_flow: bool = _flow_compute.compute_flow_gpu_buffers(w, h, hbuf, land_buf, true, flow_dir_buf, flow_acc_buf, Rect2i(0, 0, 0, 0), _gpu_buffer_manager)
	if not ok_flow:
		return
	if not config.rivers_enabled:
		if last_river.size() != size:
			last_river.resize(size)
		last_river.fill(0)
		update_persistent_buffer("river", _pack_bytes_to_u32(last_river).to_byte_array())
		var river_tex_off: Object = load("res://scripts/systems/RiverTextureCompute.gd").new()
		var tex_off: Texture2D = river_tex_off.update_from_buffer(w, h, river_buf)
		if tex_off:
			set_river_texture_override(tex_off)
		return
	if _river_compute == null:
		_river_compute = RiverCompute.new()
	var thr_seed3: float = _compute_river_seed_threshold(PackedFloat32Array(), last_is_land, config.river_threshold, config.river_threshold_factor)
	last_river_seed_threshold = thr_seed3
	var traced_ok: bool = _river_compute.trace_rivers_gpu_buffers(
		w, h,
		land_buf,
		lake_buf,
		flow_dir_buf,
		flow_acc_buf,
		thr_seed3,
		5,
		Rect2i(0, 0, 0, 0),
		river_buf,
		true
	)
	if not traced_ok:
		return
	if config.river_delta_widening and dist_buf.is_valid():
		var rpost: Object = ensure_river_post_compute()
		var delta_shore_dist3: float = min(config.shore_band, 1.0)
		var delta_min_accum3: float = _estimate_delta_source_min_accum(size, thr_seed3)
		var river_tmp_buf: RID = ensure_gpu_storage_buffer("river_tmp", size * 4)
		if river_tmp_buf.is_valid():
			var widened_ok: bool = rpost.widen_deltas_gpu_buffers(
				w,
				h,
				river_buf,
				land_buf,
				dist_buf,
				flow_acc_buf,
				delta_shore_dist3,
				delta_min_accum3,
				river_tmp_buf
			)
			if widened_ok:
				dispatch_copy_u32(river_tmp_buf, river_buf, size)

	# Freeze-gate rivers directly on GPU.
	var temp_buf: RID = get_persistent_buffer("temperature")
	var biome_buf: RID = get_persistent_buffer("biome_id")
	var river_freeze: Object = ensure_river_freeze_compute()
	if river_freeze != null and temp_buf.is_valid() and biome_buf.is_valid():
		river_freeze.apply_gpu_buffers(
			w,
			h,
			river_buf,
			land_buf,
			temp_buf,
			biome_buf,
			config.temp_min_c,
			config.temp_max_c,
			int(BiomeClassifier.Biome.GLACIER),
			0.0
		)

	# Update GPU texture override from the authoritative river buffer.
	var river_tex: Object = load("res://scripts/systems/RiverTextureCompute.gd").new()
	var rtex: Texture2D = river_tex.update_from_buffer(w, h, river_buf)
	if rtex:
		set_river_texture_override(rtex)

func apply_ocean_connectivity_gate_runtime() -> bool:
	# Convert inland water components into lakes-on-land so oceans remain boundary-connected.
	if not config.ocean_connectivity_gate_enabled:
		return true
	if _gpu_buffer_manager == null:
		return false
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if size <= 0:
		return false
	ensure_persistent_buffers(false)
	var land_buf: RID = get_persistent_buffer("is_land")
	var lake_buf: RID = get_persistent_buffer("lake")
	var lake_id_buf: RID = get_persistent_buffer("lake_id")
	if not land_buf.is_valid() or not lake_buf.is_valid() or not lake_id_buf.is_valid():
		return false
	if _lake_label_compute == null:
		_lake_label_compute = LakeLabelCompute.new()
	if _ocean_land_gate_compute == null:
		_ocean_land_gate_compute = OceanLandGateCompute.new()
	var label_iters: int = max(16, min(512, w + h))
	var labeled_ok: bool = _lake_label_compute != null and _lake_label_compute.label_lakes_gpu_buffers(w, h, land_buf, true, lake_buf, lake_id_buf, label_iters)
	if not labeled_ok:
		return false
	var keep_lakes: bool = bool(config.lakes_enabled)
	var gate_ok: bool = _ocean_land_gate_compute != null and _ocean_land_gate_compute.apply(w, h, land_buf, lake_buf, lake_id_buf, keep_lakes)
	if not gate_ok:
		return false
	return true

func _collect_terrain_hydro_metrics_gpu() -> Dictionary:
	var out := {
		"ok": false,
		"total_cells": 0.0,
		"ocean_cells": 0.0,
		"lake_cells": 0.0,
		"slope_outlier_cells": 0.0,
		"inland_below_sea_cells": 0.0,
		"inland_ocean_cells": 0.0,
		"ocean_fraction": 0.0,
		"mean_height": 0.0,
	}
	if _gpu_buffer_manager == null:
		return out
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if size <= 0:
		return out
	ensure_persistent_buffers(false)
	var height_buf: RID = get_persistent_buffer("height")
	var land_buf: RID = get_persistent_buffer("is_land")
	var lake_buf: RID = get_persistent_buffer("lake")
	if not height_buf.is_valid() or not land_buf.is_valid() or not lake_buf.is_valid():
		return out
	var stats_buf: RID = ensure_gpu_storage_buffer("terrain_metrics_stats", TERRAIN_METRICS_STATS_U32_COUNT * 4)
	if not stats_buf.is_valid():
		return out
	var zeros := PackedInt32Array()
	zeros.resize(TERRAIN_METRICS_STATS_U32_COUNT)
	zeros.fill(0)
	if not update_persistent_buffer("terrain_metrics_stats", zeros.to_byte_array()):
		return out
	var metrics_compute: Object = ensure_terrain_metrics_compute()
	if metrics_compute == null:
		return out
	var metrics_ok: bool = metrics_compute.collect_metrics(
		w,
		h,
		height_buf,
		land_buf,
		lake_buf,
		stats_buf,
		config.sea_level,
		TERRAIN_METRICS_SLOPE_MEAN_THRESHOLD,
		TERRAIN_METRICS_SLOPE_PEAK_THRESHOLD,
		TERRAIN_METRICS_HEIGHT_SUM_SCALE
	)
	if not metrics_ok:
		return out
	var stats_bytes: PackedByteArray = read_persistent_buffer_region("terrain_metrics_stats", 0, TERRAIN_METRICS_STATS_U32_COUNT * 4)
	if stats_bytes.size() < TERRAIN_METRICS_STATS_U32_COUNT * 4:
		return out
	var stats_i32: PackedInt32Array = stats_bytes.to_int32_array()
	if stats_i32.size() < TERRAIN_METRICS_STATS_U32_COUNT:
		return out
	var total_cells: float = max(1.0, float(stats_i32[0]))
	var ocean_cells: float = max(0.0, float(stats_i32[1]))
	var lake_cells: float = max(0.0, float(stats_i32[2]))
	var slope_outliers: float = max(0.0, float(stats_i32[3]))
	var inland_below_sea: float = max(0.0, float(stats_i32[4]))
	var hsum_q: float = max(0.0, float(stats_i32[5]))
	var mean_height: float = (hsum_q / TERRAIN_METRICS_HEIGHT_SUM_SCALE) / total_cells - TERRAIN_METRICS_HEIGHT_OFFSET
	var ocean_fraction: float = clamp(ocean_cells / total_cells, 0.0, 1.0)
	out["ok"] = true
	out["total_cells"] = total_cells
	out["ocean_cells"] = ocean_cells
	out["lake_cells"] = lake_cells
	out["slope_outlier_cells"] = slope_outliers
	out["inland_below_sea_cells"] = inland_below_sea
	# "Inland ocean" is tracked as inland below-sea cells after connectivity gating.
	out["inland_ocean_cells"] = inland_below_sea
	out["ocean_fraction"] = ocean_fraction
	out["mean_height"] = mean_height
	last_ocean_fraction = ocean_fraction
	debug_last_metrics = out.duplicate()
	return out

func sample_terrain_hydro_metrics() -> Dictionary:
	return _collect_terrain_hydro_metrics_gpu()

func register_tectonic_tick_metrics(dt_days: float) -> Dictionary:
	var metrics: Dictionary = _collect_terrain_hydro_metrics_gpu()
	if not bool(metrics.get("ok", false)):
		return metrics
	var mean_height: float = float(metrics.get("mean_height", 0.0))
	tectonic_stats["mean_height"] = mean_height
	tectonic_stats["slope_outlier_cells"] = float(metrics.get("slope_outlier_cells", 0.0))
	tectonic_stats["inland_ocean_cells"] = float(metrics.get("inland_ocean_cells", 0.0))
	if _tectonic_bias_prev_mean_valid:
		var delta_h: float = mean_height - _tectonic_bias_prev_mean_height
		var net_bias: float = float(tectonic_stats.get("net_height_bias", 0.0)) + delta_h
		var samples: int = int(tectonic_stats.get("height_bias_samples", 0)) + 1
		var days_total: float = float(tectonic_stats.get("height_bias_days_total", 0.0)) + max(0.0, dt_days)
		tectonic_stats["last_height_delta"] = delta_h
		tectonic_stats["net_height_bias"] = net_bias
		tectonic_stats["height_bias_samples"] = samples
		tectonic_stats["height_bias_days_total"] = days_total
		tectonic_stats["net_height_bias_per_tick"] = net_bias / float(max(1, samples))
		if days_total > 0.0:
			tectonic_stats["net_height_bias_per_day"] = net_bias / days_total
		if dt_days > 0.0:
			tectonic_stats["last_height_delta_per_day"] = delta_h / dt_days
	_tectonic_bias_prev_mean_height = mean_height
	_tectonic_bias_prev_mean_valid = true
	return metrics

func _estimate_reservoirs_from_gpu(max_cells: int = CLIMATE_CPU_MIRROR_MAX_CELLS) -> Dictionary:
	var out := {
		"ok": false,
		"ocean_cells": 0.0,
		"lake_cells": 0.0,
		"atmo": 0.0,
		"ice_cells": 0.0,
		"total": 0.0,
		"ocean_fraction": 0.0,
		"slope_outlier_cells": 0.0,
		"inland_below_sea_cells": 0.0,
		"inland_ocean_cells": 0.0,
		"mean_height": 0.0,
	}
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if size <= 0:
		return out
	var metrics: Dictionary = _collect_terrain_hydro_metrics_gpu()
	if not bool(metrics.get("ok", false)):
		return out
	var ocean_cells: float = float(metrics.get("ocean_cells", 0.0))
	var lake_cells: float = float(metrics.get("lake_cells", 0.0))
	var atmo: float = 0.0
	var ice: float = 0.0
	out["ok"] = true
	out["ocean_cells"] = ocean_cells
	out["lake_cells"] = lake_cells
	out["atmo"] = atmo
	out["ice_cells"] = ice
	out["total"] = ocean_cells + lake_cells + atmo + ice
	out["ocean_fraction"] = float(metrics.get("ocean_fraction", 0.0))
	out["slope_outlier_cells"] = float(metrics.get("slope_outlier_cells", 0.0))
	out["inland_below_sea_cells"] = float(metrics.get("inland_below_sea_cells", 0.0))
	out["inland_ocean_cells"] = float(metrics.get("inland_ocean_cells", 0.0))
	out["mean_height"] = float(metrics.get("mean_height", 0.0))
	return out

func update_water_budget_and_sea_solver(dt_days: float, world: Object) -> Dictionary:
	var out := {"ok": false, "sea_level_changed": false}
	if not config.fixed_water_budget_enabled:
		return out
	var est: Dictionary = _estimate_reservoirs_from_gpu()
	if not bool(est.get("ok", false)):
		return out
	var total_units: float = float(est.get("total", 0.0))
	var ocean_frac: float = float(est.get("ocean_fraction", 0.0))
	if not _water_budget_initialized:
		_water_total_target = total_units
		_water_ocean_fraction_target = config.fixed_ocean_fraction_target if config.fixed_ocean_fraction_target >= 0.0 else ocean_frac
		_water_budget_initialized = true
	if config.fixed_ocean_fraction_target >= 0.0:
		_water_ocean_fraction_target = config.fixed_ocean_fraction_target
	var now_days: float = 0.0
	if world != null and "simulation_time_days" in world:
		now_days = float(world.simulation_time_days)
	else:
		now_days = float(Time.get_ticks_msec()) / 1000.0
	var can_apply: bool = (_sea_solver_last_apply_day < 0.0) or ((now_days - _sea_solver_last_apply_day) >= 28.0)
	var sea_changed: bool = false
	if can_apply:
		var err_ocean: float = _water_ocean_fraction_target - ocean_frac
		var sea_step: float = clamp(err_ocean * config.sea_level_solver_gain, -config.sea_level_solver_max_step, config.sea_level_solver_max_step)
		if abs(sea_step) >= 0.00025:
			var new_sea: float = clamp(config.sea_level + sea_step, -1.0, 1.0)
			quick_update_sea_level(new_sea)
			# Sea-level update rebuilds land; enforce connectivity gate again.
			apply_ocean_connectivity_gate_runtime()
			sea_changed = true
			_sea_solver_last_apply_day = now_days
	water_budget_stats = {
		"target_total": _water_total_target,
		"current_total": total_units,
		"target_ocean_fraction": _water_ocean_fraction_target,
		"current_ocean_fraction": ocean_frac,
		"drift_total": total_units - _water_total_target,
		"slope_outlier_cells": float(est.get("slope_outlier_cells", 0.0)),
		"inland_below_sea_cells": float(est.get("inland_below_sea_cells", 0.0)),
		"inland_ocean_cells": float(est.get("inland_ocean_cells", 0.0)),
		"mean_height": float(est.get("mean_height", 0.0)),
		"net_tectonic_height_bias": float(tectonic_stats.get("net_height_bias", 0.0)),
		"sea_level": config.sea_level,
		"sea_level_changed": sea_changed,
		"dt_days": dt_days,
	}
	out["ok"] = true
	out["sea_level_changed"] = sea_changed
	return out

func get_width() -> int:
	return config.width

func get_height() -> int:
	return config.height

func _decode_u32_mask_to_u8(mask_u32: PackedInt32Array, size: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(max(0, size))
	if mask_u32.size() != size:
		return out
	for i in range(size):
		out[i] = 1 if int(mask_u32[i]) != 0 else 0
	return out

func get_biome_snapshot_from_gpu(max_cells: int = 250000) -> PackedInt32Array:
	# `last_biomes` is not guaranteed to stay in sync in GPU-only runtime.
	# For gameplay (regional/local maps) we need an authoritative snapshot.
	var w: int = int(config.width)
	var h: int = int(config.height)
	var size: int = w * h
	if size <= 0:
		return PackedInt32Array()
	if size > max_cells:
		return PackedInt32Array()
	if _gpu_buffer_manager == null:
		return last_biomes.duplicate()
	ensure_persistent_buffers(false)
	if RenderingServer.has_method("force_sync"):
		RenderingServer.force_sync()
	var bytes: PackedByteArray = read_persistent_buffer_region("biome_id", 0, size * 4)
	if bytes.size() != size * 4:
		return last_biomes.duplicate()
	return bytes.to_int32_array()

func get_land_snapshot_from_gpu(max_cells: int = 250000) -> PackedByteArray:
	# Transition-point readback for validating biome snapshots.
	var w: int = int(config.width)
	var h: int = int(config.height)
	var size: int = w * h
	if size <= 0:
		return PackedByteArray()
	if size > max_cells:
		return PackedByteArray()
	if _gpu_buffer_manager == null:
		return last_is_land.duplicate()
	ensure_persistent_buffers(false)
	if RenderingServer.has_method("force_sync"):
		RenderingServer.force_sync()
	var bytes: PackedByteArray = read_persistent_buffer_region("is_land", 0, size * 4)
	if bytes.size() != size * 4:
		return last_is_land.duplicate()
	var u32_vals: PackedInt32Array = bytes.to_int32_array()
	var out: PackedByteArray = _decode_u32_mask_to_u8(u32_vals, size)
	if out.size() == size:
		return out
	return last_is_land.duplicate()

func get_cell_info(x: int, y: int) -> Dictionary:
	if x < 0 or y < 0 or x >= config.width or y >= config.height:
		return {}
	# Keep cell-info climate/biome reads coherent with authoritative GPU buffers.
	if _gpu_buffer_manager != null:
		sync_debug_cpu_snapshot(x, y)
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
	var height_m: float = h_val * config.height_scale_m
	return {
		"height": h_val,
		"height_m": height_m,
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

# GPU Buffer Management for Persistent SSBOs
func ensure_persistent_buffers(refresh: bool = true) -> void:
	"""Allocate persistent GPU buffers for all major world data"""
	if _gpu_buffer_manager == null:
		_gpu_buffer_manager = GPUBufferManager.new()

	var size: int = config.width * config.height
	# Safety: callers frequently request refresh=false; still seed from CPU mirrors
	# when buffers are uninitialized or dimensions changed.
	if not refresh and ((not _buffers_seeded) or (_buffer_seed_size != size)):
		refresh = true
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
	_gpu_buffer_manager.ensure_buffer("temperature_tmp", float_size)
	# Baseline temperature used for non-accumulative seasonal/diurnal cycle application.
	_gpu_buffer_manager.ensure_buffer("temperature_base", float_size, last_temperature.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("moisture", float_size, last_moisture.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("moisture_tmp", float_size)
	# Slow-moving climate buffers for biome evolution.
	_gpu_buffer_manager.ensure_buffer("biome_temp", float_size, last_temperature.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("biome_moist", float_size, last_moisture.to_byte_array() if refresh else PackedByteArray())
	# Medium-timescale climate buffers for cryosphere decisions (filter out day/night flicker).
	_gpu_buffer_manager.ensure_buffer("cryo_temp", float_size, last_temperature.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("cryo_moist", float_size, last_moisture.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("flow_dir", int_size, last_flow_dir.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("flow_accum", float_size, last_flow_accum.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("biome_id", int_size, last_biomes.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("biome_prev", int_size, last_biomes.to_byte_array() if refresh else PackedByteArray())
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
	_gpu_buffer_manager.ensure_buffer("river_tmp", int_size)
	_gpu_buffer_manager.ensure_buffer("lake", int_size, _pack_bytes_to_u32(last_lake).to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("lake_id", int_size, last_lake_id.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("lake_e_primary", float_size)
	_gpu_buffer_manager.ensure_buffer("lake_e_tmp", float_size)
	_gpu_buffer_manager.ensure_buffer("distance", float_size, last_distance_to_coast.to_byte_array() if refresh else PackedByteArray())
	_gpu_buffer_manager.ensure_buffer("distance_tmp", float_size)
	_gpu_buffer_manager.ensure_buffer("turquoise", int_size)
	_gpu_buffer_manager.ensure_buffer("turquoise_strength", float_size)
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
	_gpu_buffer_manager.ensure_buffer("terrain_metrics_stats", TERRAIN_METRICS_STATS_U32_COUNT * 4)

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

func ensure_terrain_metrics_compute() -> Object:
	if _terrain_metrics_compute == null:
		_terrain_metrics_compute = TerrainHydroMetricsCompute.new()
	return _terrain_metrics_compute

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

func ensure_fertility_compute() -> Object:
	if _fertility_compute == null:
		_fertility_compute = FertilityLithologyCompute.new()
	return _fertility_compute

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

func ensure_river_freeze_compute() -> Object:
	if _river_freeze_compute == null:
		_river_freeze_compute = RiverFreezeCompute.new()
	return _river_freeze_compute

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
			var stale_refresh: bool = false
			if _debug_cache_last_refresh_usec > 0:
				stale_refresh = (Time.get_ticks_usec() - _debug_cache_last_refresh_usec) >= DEBUG_CACHE_STALE_USEC
			need_refresh = near_edge or stale_refresh
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
	_debug_cache_last_refresh_usec = Time.get_ticks_usec()

func sync_climate_cpu_mirror_from_gpu(_max_cells: int = CLIMATE_CPU_MIRROR_MAX_CELLS) -> void:
	"""Optional compatibility sync for legacy CPU reads; not used in runtime hot paths."""
	if not _climate_cpu_mirror_dirty:
		return
	if _gpu_buffer_manager == null:
		return
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if size <= 0 or size > _max_cells:
		return
	var temp_vals: PackedFloat32Array = _read_window_f32("temperature", 0, 0, w, h, w)
	var moist_vals: PackedFloat32Array = _read_window_f32("moisture", 0, 0, w, h, w)
	var synced: bool = false
	if temp_vals.size() == size:
		last_temperature = temp_vals
		synced = true
	if moist_vals.size() == size:
		last_moisture = moist_vals
		synced = true
	if synced:
		_climate_cpu_mirror_dirty = false

func mark_climate_cpu_mirror_dirty() -> void:
	"""Signals that GPU climate/moisture buffers changed and CPU mirrors are stale."""
	_climate_cpu_mirror_dirty = true

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
