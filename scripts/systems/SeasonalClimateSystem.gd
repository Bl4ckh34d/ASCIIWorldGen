# File: res://scripts/systems/SeasonalClimateSystem.gd
extends RefCounted

# Lightweight system that updates seasonal climate parameters on cadence.
# It does not recompute climate itself; it only adjusts generator config so
# next climate recompute picks up phase/amplitudes.

var generator: Object = null

func initialize(gen: Object) -> void:
	generator = gen

func tick(_dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	# Compute season phase from world time if available; otherwise no-op
	var season_phase: float = 0.0
	if world != null:
		var sim_days := 0.0
		if "simulation_time_days" in world:
			sim_days = float(world.simulation_time_days)
		season_phase = fposmod(sim_days / 365.0, 1.0)
	# Update seasonal and diurnal phases/amps
	var time_of_day: float = 0.0
	if world != null and "tick_days" in world and "simulation_time_days" in world:
		time_of_day = fposmod(float(world.simulation_time_days), 1.0)
	generator.apply_config({
		"season_phase": season_phase,
		"season_amp_equator": float(generator.config.season_amp_equator if "config" in generator else 0.10),
		"season_amp_pole": float(generator.config.season_amp_pole if "config" in generator else 0.25),
		"season_ocean_damp": float(generator.config.season_ocean_damp if "config" in generator else 0.60),
		"diurnal_amp_equator": float(generator.config.diurnal_amp_equator if "config" in generator else 0.06),
		"diurnal_amp_pole": float(generator.config.diurnal_amp_pole if "config" in generator else 0.03),
		"diurnal_ocean_damp": float(generator.config.diurnal_ocean_damp if "config" in generator else 0.40),
		"time_of_day": time_of_day,
	})
	# Climate refresh every tick (GPU-only); biomes handled by separate cadence system
	if world != null:
		if "quick_update_climate" in generator:
			generator.quick_update_climate()
		# Update day-night light field every tick (cheap)
		_update_light_field(world)
	return {"dirty_fields": PackedStringArray(["climate", "light"]) }

func _update_light_field(world: Object) -> void:
	"""Update the day-night light field using GPU compute"""
	if generator == null or not ("_climate_compute_gpu" in generator):
		return
	
	# Ensure climate compute GPU system exists
	if generator._climate_compute_gpu == null:
		generator._climate_compute_gpu = load("res://scripts/systems/ClimateAdjustCompute.gd").new()
	
	var w = generator.config.width
	var h = generator.config.height
	
	# Calculate day of year and time of day from simulation time
	var day_of_year = 0.0
	var time_of_day = 0.0
	if world != null and "simulation_time_days" in world:
		var sim_days = float(world.simulation_time_days)
		day_of_year = fposmod(sim_days / 365.0, 1.0)
		time_of_day = fposmod(sim_days, 1.0)  # Daily cycle
	
	var light_params = {
		"day_of_year": day_of_year,
		"time_of_day": time_of_day,
		"day_night_base": generator.config.day_night_base,
		"day_night_contrast": generator.config.day_night_contrast
	}
	
	# Evaluate light field on GPU
	var light_field = generator._climate_compute_gpu.evaluate_light_field(w, h, light_params)
	
	# Store in generator for ASCII rendering
	if light_field.size() == w * h:
		generator.last_light = light_field
