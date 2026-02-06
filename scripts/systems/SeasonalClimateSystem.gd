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
	if world != null and "tick_days" in world and "simulation_time_days" in world:
		time_of_day = fposmod(float(world.simulation_time_days), 1.0)
	if "config" in generator:
		generator.config.season_phase = season_phase
		generator.config.time_of_day = time_of_day
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
