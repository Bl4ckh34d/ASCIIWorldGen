# File: res://scripts/systems/SeasonalClimateSystem.gd
extends RefCounted

# Lightweight system that updates seasonal climate parameters on cadence.
# It does not recompute climate itself; it only adjusts generator config so
# next climate recompute picks up phase/amplitudes.

var generator: Object = null
var time_system: Object = null
var _light_update_counter: int = 0
var _climate_update_counter: int = 0
var climate_update_interval_ticks: int = 6
var light_update_interval_ticks: int = 1
var _light_tex: Object = null
var _cpu_climate_mirror_counter: int = 0
var _paleo_initialized: bool = false
var _paleo_base_offset: float = 0.25
var _paleo_last_applied_offset: float = 0.25
const TAU: float = 6.28318530718
const PALEO_PRIMARY_PERIOD_DAYS: float = 15330000.0   # ~42k years
const PALEO_SECONDARY_PERIOD_DAYS: float = 4015000.0  # ~11k years
const PALEO_DRIFT_PERIOD_DAYS: float = 2555000.0      # ~7k years
const PALEO_PRIMARY_AMP_C: float = 3.6
const PALEO_SECONDARY_AMP_C: float = 1.8
const PALEO_DRIFT_AMP_C: float = 1.2
const CPU_CLIMATE_MIRROR_INTERVAL_TICKS: int = 30

func initialize(gen: Object, time_sys: Object = null) -> void:
	generator = gen
	time_system = time_sys

func tick(_dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	
	_light_update_counter += 1
	_climate_update_counter += 1
	# Compute season phase from world time if available; otherwise no-op
	var season_phase: float = 0.0
	if world != null:
		var sim_days := 0.0
		if "simulation_time_days" in world:
			sim_days = float(world.simulation_time_days)
		var days_per_year = time_system.get_days_per_year() if time_system and "get_days_per_year" in time_system else 365.0
		season_phase = fposmod(sim_days / days_per_year, 1.0)
	# Update seasonal and diurnal phases/amps
	var time_of_day: float = 0.0
	var sim_days: float = 0.0
	if world != null and "tick_days" in world and "simulation_time_days" in world:
		time_of_day = fposmod(float(world.simulation_time_days), 1.0)
		sim_days = float(world.simulation_time_days)
	if "config" in generator:
		generator.config.season_phase = season_phase
		generator.config.time_of_day = time_of_day
		_apply_paleoclimate(sim_days)
	# Climate refresh every tick (GPU-only); biomes handled by separate cadence system
	if world != null:
		var do_climate_update: bool = (_climate_update_counter <= 1) or (_climate_update_counter % max(1, climate_update_interval_ticks) == 0)
		if do_climate_update and "quick_update_climate" in generator:
			# Light is updated below every tick; skip light update in climate pass.
			generator.quick_update_climate(true)
			# Keep hover/info climate values approximately aligned with GPU runtime state.
			_cpu_climate_mirror_counter += 1
			if (_cpu_climate_mirror_counter % CPU_CLIMATE_MIRROR_INTERVAL_TICKS) == 0:
				if "sync_climate_cpu_mirror_from_gpu" in generator:
					generator.sync_climate_cpu_mirror_from_gpu()
		var do_light_update: bool = (_light_update_counter <= 1) or (_light_update_counter % max(1, light_update_interval_ticks) == 0)
		if do_light_update:
			_update_light_field(world)
	return {"dirty_fields": PackedStringArray(["climate", "light"]) }

func set_update_intervals(climate_interval_ticks: int, light_interval_ticks: int) -> void:
	climate_update_interval_ticks = max(1, int(climate_interval_ticks))
	light_update_interval_ticks = max(1, int(light_interval_ticks))

func request_full_resync() -> void:
	_climate_update_counter = 0
	_light_update_counter = 0
	_cpu_climate_mirror_counter = 0
	_paleo_initialized = false

func _apply_paleoclimate(sim_days: float) -> void:
	if generator == null or not ("config" in generator):
		return
	var cfg = generator.config
	var current_offset: float = float(cfg.temp_base_offset)
	if not _paleo_initialized:
		_paleo_initialized = true
		_paleo_base_offset = current_offset
		_paleo_last_applied_offset = current_offset
	else:
		# Respect user/runtime edits to base temp offset (slider, presets, etc.).
		if abs(current_offset - _paleo_last_applied_offset) > 0.0001:
			_paleo_base_offset = current_offset
	var seed: int = int(cfg.rng_seed) if "rng_seed" in cfg else 0
	var phase0: float = _hash11(float(seed) * 0.137 + 11.7) * TAU
	var phase1: float = _hash11(float(seed) * 0.173 + 23.4) * TAU
	var phase2: float = _hash11(float(seed) * 0.211 + 37.9) * TAU
	var cyc0: float = sin(sim_days / PALEO_PRIMARY_PERIOD_DAYS * TAU + phase0) * PALEO_PRIMARY_AMP_C
	var cyc1: float = sin(sim_days / PALEO_SECONDARY_PERIOD_DAYS * TAU + phase1) * PALEO_SECONDARY_AMP_C
	var drift_n: float = _value_noise_1d(sim_days / PALEO_DRIFT_PERIOD_DAYS + phase2 * 0.15) * 2.0 - 1.0
	var drift_c: float = drift_n * PALEO_DRIFT_AMP_C
	var offset_c: float = clamp(cyc0 + cyc1 + drift_c, -6.5, 5.5)
	var temp_span_c: float = max(1.0, float(cfg.temp_max_c - cfg.temp_min_c))
	var offset_norm: float = offset_c / temp_span_c
	var out_offset: float = clamp(_paleo_base_offset + offset_norm, -0.45, 0.45)
	cfg.temp_base_offset = out_offset
	_paleo_last_applied_offset = out_offset

func _hash11(x: float) -> float:
	return fract(sin(x * 127.1 + 311.7) * 43758.5453123)

func _value_noise_1d(x: float) -> float:
	var i0: float = floor(x)
	var i1: float = i0 + 1.0
	var f: float = fract(x)
	var u: float = f * f * (3.0 - 2.0 * f)
	return lerp(_hash11(i0), _hash11(i1), u)

func _update_light_field(world: Object) -> void:
	"""Update the day-night light field using GPU compute"""
	if generator == null or not ("_climate_compute_gpu" in generator):
		return
	if not ("config" in generator and generator.config.use_gpu_all):
		return
	
	# Ensure climate compute GPU system exists
	if generator._climate_compute_gpu == null:
		generator._climate_compute_gpu = load("res://scripts/systems/ClimateAdjustCompute.gd").new()
	
	var w = generator.config.width
	var h = generator.config.height
	
	# Calculate day of year and time of day from simulation time
	var day_of_year = 0.0
	var time_of_day = 0.0
	var sim_days: float = 0.0
	if world != null and "simulation_time_days" in world:
		sim_days = float(world.simulation_time_days)
		# Use configurable year length from time system
		var days_per_year = time_system.get_days_per_year() if time_system and "get_days_per_year" in time_system else 365.0
		day_of_year = fposmod(sim_days / days_per_year, 1.0)
		time_of_day = fposmod(sim_days, 1.0)  # Daily cycle unchanged
		
	else:
		# No world state available - use defaults
		day_of_year = 0.0
		time_of_day = 0.0
	
	var light_params = {
		"day_of_year": day_of_year,
		"time_of_day": time_of_day,
		"day_night_base": generator.config.day_night_base if generator.config else 0.25,
		"day_night_contrast": generator.config.day_night_contrast if generator.config else 0.75,
		"moon_count": float(generator.config.moon_count) if generator.config else 0.0,
		"moon_seed": generator.config.moon_seed if generator.config else 0.0,
		"moon_shadow_strength": generator.config.moon_shadow_strength if generator.config else 0.55,
		"sim_days": sim_days if world != null and "simulation_time_days" in world else (day_of_year * 365.0 + time_of_day)
	}

	if _light_tex == null:
		_light_tex = load("res://scripts/systems/LightTextureCompute.gd").new()
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)
	var light_buf: RID = generator.get_persistent_buffer("light") if "get_persistent_buffer" in generator else RID()
	if not light_buf.is_valid():
		return
	var ok_gpu: bool = generator._climate_compute_gpu.evaluate_light_field_gpu(w, h, light_params, light_buf)
	if ok_gpu and _light_tex:
		var tex: Texture2D = _light_tex.update_from_buffer(w, h, light_buf)
		if tex and "set_light_texture_override" in generator:
			generator.set_light_texture_override(tex)
