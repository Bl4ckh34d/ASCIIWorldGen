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
	return {"dirty_fields": PackedStringArray(["climate"]) }
