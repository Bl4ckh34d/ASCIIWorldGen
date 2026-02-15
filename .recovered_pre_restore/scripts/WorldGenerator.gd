# File: res://scripts/WorldGenerator.gd
extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const TerrainNoise = preload("res://scripts/generation/TerrainNoise.gd")
const TerrainCompute = preload("res://scripts/systems/TerrainCompute.gd")
var ClimateNoise = load("res://scripts/generation/ClimateNoise.gd")
const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")
const ArrayPool = preload("res://scripts/core/ArrayPool.gd")
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
const GPUBufferHelper = preload("res://scripts/systems/GPUBufferHelper.gd")
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
var _cloud_tex_compute: Object = null
var _biome_tex_compute: Object = null
var _lava_tex_compute: Object = null
var _river_tex_compute: Object = null

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
	var fixed_water_budget_enabled: bool = true
	var fixed_ocean_fraction_target: float = -1.0
	var sea_level_solver_gain: float = 0.60
	var sea_level_solver_max_step: float = 0.020
	var sea_level_solver_interval_days: float = 7.0
	var sea_level_solver_deadband: float = 0.0015
	var water_budget_sample_interval_days: float = 7.0
	var water_budget_surface_weight: float = 0.35
	# Enforce ocean connectivity gate so inland basins become lakes, not ocean.
	var ocean_connectivity_gate_enabled: bool = true
	# Optional async staging for large buffer uploads (scaffold, off by default).
	var gpu_async_large_updates_enabled: bool = false
	var gpu_async_large_update_threshold_bytes: int = 262144
	var gpu_async_flush_on_readback: bool = true

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
var hydro_iter_stats: Dictionary = {}
var _terrain_metrics_compute: Object = null
var _tectonic_bias_prev_mean_valid: bool = false
var _tectonic_bias_prev_mean_height: float = 0.0
var _array_pool: ArrayPool = null

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
var _water_surface_fraction_target: float = -1.0
var _sea_solver_last_apply_day: float = -1.0
var _water_budget_last_sample_day: float = -1.0
var _water_budget_est_cache: Dictionary = {}

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
	_array_pool = ArrayPool.new()

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
		config.auto_physical_defaults = VariantCasts.to_bool(dict["auto_physical_defaults"])
	if dict.has("fixed_water_budget_enabled"):
		config.fixed_water_budget_enabled = VariantCasts.to_bool(dict["fixed_water_budget_enabled"])
	if dict.has("fixed_ocean_fraction_target"):
		config.fixed_ocean_fraction_target = clamp(float(dict["fixed_ocean_fraction_target"]), -1.0, 0.99)
	if dict.has("sea_level_solver_gain"):
		config.sea_level_solver_gain = clamp(float(dict["sea_level_solver_gain"]), 0.0, 2.0)
	if dict.has("sea_level_solver_max_step"):
		config.sea_level_solver_max_step = clamp(float(dict["sea_level_solver_max_step"]), 0.0001, 0.2)
	if dict.has("sea_level_solver_interval_days"):
		config.sea_level_solver_interval_days = clamp(float(dict["sea_level_solver_interval_days"]), 0.25, 365.0)
	if dict.has("sea_level_solver_deadband"):
		config.sea_level_solver_deadband = clamp(float(dict["sea_level_solver_deadband"]), 0.0, 0.05)
	if dict.has("water_budget_sample_interval_days"):
		config.water_budget_sample_interval_days = clamp(float(dict["water_budget_sample_interval_days"]), 0.25, 365.0)
	if dict.has("water_budget_surface_weight"):
		config.water_budget_surface_weight = clamp(float(dict["water_budget_surface_weight"]), 0.0, 1.0)
	if dict.has("ocean_connectivity_gate_enabled"):
		config.ocean_connectivity_gate_enabled = VariantCasts.to_bool(dict["ocean_connectivity_gate_enabled"])
	if dict.has("gpu_async_large_updates_enabled"):
		config.gpu_async_large_updates_enabled = VariantCasts.to_bool(dict["gpu_async_large_updates_enabled"])
	if dict.has("gpu_async_large_update_threshold_bytes"):
		config.gpu_async_large_update_threshold_bytes = max(1024, int(dict["gpu_async_large_update_threshold_bytes"]))
	if dict.has("gpu_async_flush_on_readback"):
		config.gpu_async_flush_on_readback = VariantCasts.to_bool(dict["gpu_async_flush_on_readback"])
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
		config.rivers_enabled = VariantCasts.to_bool(dict["rivers_enabled"])
	if dict.has("river_threshold_factor"):
		config.river_threshold_factor = clamp(float(dict["river_threshold_factor"]), 0.1, 5.0)
	if dict.has("river_delta_widening"):
		config.river_delta_widening = VariantCasts.to_bool(dict["river_delta_widening"])
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
		config.lakes_enabled = VariantCasts.to_bool(dict["lakes_enabled"])
	if dict.has("realistic_pooling_enabled"):
		config.realistic_pooling_enabled = VariantCasts.to_bool(dict["realistic_pooling_enabled"])
	if dict.has("max_forced_outflows"):
		config.max_…22758 tokens truncated…isions (filter out day/night flicker).
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
		var lava_f32: PackedFloat32Array = _acquire_pool_f32(size, false)
		for i in range(size):
			lava_f32[i] = 1.0 if (i < last_lava.size() and last_lava[i] != 0) else 0.0
		lava_bytes = lava_f32.to_byte_array()
		_release_pool_f32(lava_f32)
	_gpu_buffer_manager.ensure_buffer("lava", float_size, lava_bytes)
	_gpu_buffer_manager.ensure_buffer("wind_u", float_size)
	_gpu_buffer_manager.ensure_buffer("wind_v", float_size)
	_gpu_buffer_manager.ensure_buffer("cloud_source", float_size)
	_gpu_buffer_manager.ensure_buffer("terrain_metrics_stats", TERRAIN_METRICS_STATS_U32_COUNT * 4)

func _pack_bytes_to_u32(byte_array: PackedByteArray) -> PackedInt32Array:
	"""Convert PackedByteArray to PackedInt32Array for GPU use"""
	if GPUBufferHelper != null and "bytes_to_u32_mask" in GPUBufferHelper:
		return GPUBufferHelper.bytes_to_u32_mask(byte_array)
	var result := PackedInt32Array()
	result.resize(byte_array.size())
	for i in range(byte_array.size()):
		result[i] = 1 if byte_array[i] != 0 else 0
	return result

func _acquire_pool_i32(size: int, fill_value: int = 0) -> PackedInt32Array:
	if _array_pool != null:
		return _array_pool.acquire_i32(size, fill_value)
	var out := PackedInt32Array()
	out.resize(max(0, size))
	if out.size() > 0:
		out.fill(fill_value)
	return out

func _release_pool_i32(arr: PackedInt32Array) -> void:
	if _array_pool != null:
		_array_pool.release_i32(arr)

func _acquire_pool_f32(size: int, zero_fill: bool = true) -> PackedFloat32Array:
	if _array_pool != null:
		return _array_pool.acquire_f32(size, zero_fill)
	var out := PackedFloat32Array()
	out.resize(max(0, size))
	if zero_fill and out.size() > 0:
		out.fill(0.0)
	return out

func _release_pool_f32(arr: PackedFloat32Array) -> void:
	if _array_pool != null:
		_array_pool.release_f32(arr)

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
		return {
			"error": "Buffer manager not initialized",
			"array_pool": get_array_pool_stats(),
		}
	var stats: Dictionary = _gpu_buffer_manager.get_buffer_stats()
	stats["array_pool"] = get_array_pool_stats()
	return stats

func _update_hydro_iter_rolling(prefix: String, executed_iters: int, early_out: bool) -> void:
	var samples_key: String = "%s_samples" % prefix
	var avg_key: String = "%s_avg_iters" % prefix
	var last_key: String = "%s_last_iters" % prefix
	var early_key: String = "%s_last_early_out" % prefix
	var samples: int = int(hydro_iter_stats.get(samples_key, 0))
	var avg_prev: float = float(hydro_iter_stats.get(avg_key, 0.0))
	var sample_value: float = max(0.0, float(executed_iters))
	var next_samples: int = samples + 1
	var next_avg: float = ((avg_prev * float(samples)) + sample_value) / float(max(1, next_samples))
	hydro_iter_stats[samples_key] = next_samples
	hydro_iter_stats[avg_key] = next_avg
	hydro_iter_stats[last_key] = int(executed_iters)
	hydro_iter_stats[early_key] = VariantCasts.to_bool(early_out)

func _record_hydro_iteration_stats(context: String) -> void:
	hydro_iter_stats["context"] = context
	hydro_iter_stats["updated_msec"] = int(Time.get_ticks_msec())
	if _river_compute != null and "get_last_trace_stats" in _river_compute:
		var rv: Variant = _river_compute.get_last_trace_stats()
		if typeof(rv) == TYPE_DICTIONARY:
			var rs: Dictionary = rv as Dictionary
			hydro_iter_stats["river"] = rs
			_update_hydro_iter_rolling("river", int(rs.get("executed_iters", 0)), VariantCasts.to_bool(rs.get("early_out", false)))
	if _lake_label_compute != null and "get_last_label_stats" in _lake_label_compute:
		var lv: Variant = _lake_label_compute.get_last_label_stats()
		if typeof(lv) == TYPE_DICTIONARY:
			var ls: Dictionary = lv as Dictionary
			hydro_iter_stats["lake"] = ls
			_update_hydro_iter_rolling("lake", int(ls.get("executed_iters", 0)), VariantCasts.to_bool(ls.get("early_out", false)))

func get_hydro_iteration_stats() -> Dictionary:
	return hydro_iter_stats.duplicate(true)

func get_array_pool_stats() -> Dictionary:
	if _array_pool == null:
		return {"enabled": false}
	var stats: Dictionary = _array_pool.get_stats()
	stats["enabled"] = true
	return stats

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
	_reset_gpu_overrides()
	_cleanup_gpu_compute_instances()

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
