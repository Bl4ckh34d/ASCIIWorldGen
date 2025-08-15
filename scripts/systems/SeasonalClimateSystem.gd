# File: res://scripts/systems/SeasonalClimateSystem.gd
extends RefCounted

# Lightweight system that updates seasonal climate parameters on cadence.
# It does not recompute climate itself; it only adjusts generator config so
# next climate recompute picks up phase/amplitudes.

var generator: Object = null
var _light_update_counter: int = 0

func initialize(gen: Object) -> void:
	generator = gen

func tick(_dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	# Debug: Track that this system is actually being called
	print("SeasonalClimateSystem.tick() called - dt_days: %.6f" % _dt_days)
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
		# Update day-night light field EVERY tick to ensure continuous movement
		_light_update_counter += 1
		_update_light_field(world)  # Always update for continuous day-night cycle
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
		# ACCELERATED SEASONS: Make seasonal changes happen much faster for visibility
		day_of_year = fposmod(sim_days / 30.0, 1.0)  # Full year cycle every 30 sim days instead of 365
		time_of_day = fposmod(sim_days, 1.0)  # Daily cycle unchanged
	
	var light_params = {
		"day_of_year": day_of_year,
		"time_of_day": time_of_day,
		"day_night_base": generator.config.day_night_base,
		"day_night_contrast": generator.config.day_night_contrast
	}
	
	# Debug day-night cycle more frequently to catch freezing
	if _light_update_counter % 10 == 0:
		var season_name = ""
		if day_of_year < 0.25:
			season_name = "Winter"
		elif day_of_year < 0.5:
			season_name = "Spring" 
		elif day_of_year < 0.75:
			season_name = "Summer"
		else:
			season_name = "Fall"
		print("Day-Night Debug - Sim days: %.3f, Day of year: %.3f (%s), Time of day: %.3f" % [world.simulation_time_days if world != null and "simulation_time_days" in world else -1, day_of_year, season_name, time_of_day])
	
	# Evaluate light field on GPU
	var light_field = generator._climate_compute_gpu.evaluate_light_field(w, h, light_params)
	
	# Store in generator for ASCII rendering
	if light_field.size() == w * h:
		generator.last_light = light_field
