# File: res://scripts/systems/SeasonalClimateSystem.gd
extends RefCounted

# Lightweight system that updates seasonal climate parameters on cadence.
# It does not recompute climate itself; it only adjusts generator config so
# next climate recompute picks up phase/amplitudes.

var generator: Object = null
var time_system: Object = null
var _light_update_counter: int = 0

func initialize(gen: Object, time_sys: Object = null) -> void:
	generator = gen
	time_system = time_sys

func tick(_dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	
	_light_update_counter += 1
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
		"day_night_contrast": generator.config.day_night_contrast if generator.config else 0.75
	}
	
	
	
	# Evaluate light field on GPU
	var light_field = generator._climate_compute_gpu.evaluate_light_field(w, h, light_params)
	
	# Store light field in generator for ASCII rendering
	if light_field.size() == w * h:
		generator.last_light = light_field
	else:
		# GPU light field generation failed - create CPU fallback
		# GPU light field generation failed - use CPU fallback
		_create_cpu_light_field(w, h, day_of_year, time_of_day)

func _create_cpu_light_field(w: int, h: int, day_of_year: float, time_of_day: float) -> void:
	"""CPU fallback for light field generation when GPU fails"""
	var size = w * h
	generator.last_light.resize(size)
	
	# Enhanced tilt for dramatic seasonal effect (same as GPU shader)
	var tilt = deg_to_rad(30.0)  # Increased from 23.44° to 30°
	var delta = -tilt * cos(2.0 * PI * day_of_year)
	
	for y in range(h):
		for x in range(w):
			var i = x + y * w
			
			# Latitude calculation
			var lat_norm = (float(y) / max(1.0, float(h) - 1.0)) - 0.5  # -0.5..+0.5
			var phi = lat_norm * PI  # -pi/2..+pi/2
			
			# Hour angle (longitude effect)
			var H_ang = 2.0 * PI * (time_of_day + float(x) / float(max(1, w)))
			
			# Sun elevation calculation
			var s = sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(H_ang)
			
			# Create terminator with twilight zone
			var terminator_threshold = 0.02
			var daylight = 0.0
			
			if s > terminator_threshold:
				# Day side
				daylight = 1.0
				# Summer brightness boost at high latitudes
				var lat_abs = abs(lat_norm) * 2.0
				var same_hemisphere_as_sun = (lat_norm * delta) > 0.0
				if same_hemisphere_as_sun and lat_abs > 0.6:
					daylight = min(1.0, 1.0 + lat_abs * abs(delta) * 2.0)
			elif s > -terminator_threshold:
				# Twilight zone
				var twilight = (s + terminator_threshold) / (2.0 * terminator_threshold)
				daylight = twilight * 0.6
			else:
				# Night side
				daylight = 0.1
				# Polar night effect
				var lat_abs = abs(lat_norm) * 2.0
				var opposite_hemisphere = (lat_norm * delta) < 0.0
				if opposite_hemisphere and lat_abs > 0.6 and abs(delta) > deg_to_rad(15.0):
					daylight = max(0.05, daylight * (1.0 - lat_abs * abs(delta) * 1.5))
			
			# Apply base and contrast
			var day_night_base = generator.config.day_night_base if generator.config else 0.25
			var day_night_contrast = generator.config.day_night_contrast if generator.config else 0.75
			var final_light = clamp(day_night_base + day_night_contrast * daylight, 0.0, 1.0)
			
			generator.last_light[i] = final_light
