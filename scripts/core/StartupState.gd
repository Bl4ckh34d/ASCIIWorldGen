# File: res://scripts/core/StartupState.gd
extends Node

var star_name: String = ""
var planet_name: String = ""
var orbit_norm: float = 0.5
var intro_completed: bool = false

var _pending_world_config: Dictionary = {}
var _intro_seed_string: String = ""

func reset() -> void:
	star_name = ""
	planet_name = ""
	orbit_norm = 0.5
	intro_completed = false
	_pending_world_config.clear()
	_intro_seed_string = ""

func set_intro_selection(name: String, orbit_value: float, world_name: String = "") -> void:
	star_name = _sanitize_star_name(name)
	planet_name = _sanitize_planet_name(world_name)
	orbit_norm = clamp(float(orbit_value), 0.0, 1.0)
	_intro_seed_string = "%s|%s|orbit=%.4f" % [star_name, planet_name, orbit_norm]
	_pending_world_config = _derive_world_config(orbit_norm)
	_pending_world_config["seed"] = _intro_seed_string
	intro_completed = true

func has_pending_world_config() -> bool:
	return intro_completed and not _pending_world_config.is_empty()

func consume_world_config() -> Dictionary:
	if _pending_world_config.is_empty():
		return {}
	var out: Dictionary = _pending_world_config.duplicate(true)
	_pending_world_config.clear()
	intro_completed = false
	return out

func get_intro_seed_string() -> String:
	return _intro_seed_string

func _sanitize_star_name(name: String) -> String:
	var cleaned: String = name.strip_edges()
	if cleaned.is_empty():
		return "Unnamed Star"
	if cleaned.length() > 64:
		return cleaned.substr(0, 64)
	return cleaned

func _sanitize_planet_name(name: String) -> String:
	var cleaned: String = name.strip_edges()
	if cleaned.is_empty():
		return "Unnamed World"
	if cleaned.length() > 64:
		return cleaned.substr(0, 64)
	return cleaned

func _derive_world_config(orbit: float) -> Dictionary:
	# Left side of the habitable band is hotter, right side is colder.
	var heat: float = 1.0 - clamp(orbit, 0.0, 1.0)
	# Center of band is most temperate; edges are harsher.
	var habitability: float = 1.0 - abs(orbit - 0.5) * 2.0
	habitability = clamp(habitability, 0.0, 1.0)

	var temp_min_c: float = lerp(-78.0, -8.0, heat)
	var temp_max_c: float = lerp(22.0, 92.0, heat)
	var sea_level: float = lerp(-0.20, 0.06, habitability)
	var polar_cap_frac: float = lerp(0.30, 0.04, heat)
	var moist_base_offset: float = lerp(0.03, 0.20, heat)
	var moist_scale: float = lerp(0.85, 1.25, heat)
	var season_amp_equator: float = lerp(0.07, 0.13, 1.0 - habitability)
	var season_amp_pole: float = lerp(0.18, 0.40, 1.0 - habitability)
	var diurnal_amp_equator: float = lerp(0.10, 0.19, heat)
	var diurnal_amp_pole: float = lerp(0.05, 0.11, heat)
	var min_ocean_fraction: float = lerp(0.03, 0.10, habitability)
	var lake_fill_ocean_ref: float = lerp(0.55, 1.00, habitability)

	return {
		"temp_min_c": temp_min_c,
		"temp_max_c": temp_max_c,
		"temp_base_offset": lerp(-0.32, 0.38, heat),
		"temp_scale": lerp(0.86, 1.28, heat),
		"sea_level": sea_level,
		"polar_cap_frac": polar_cap_frac,
		"moist_base_offset": moist_base_offset,
		"moist_scale": moist_scale,
		"season_amp_equator": season_amp_equator,
		"season_amp_pole": season_amp_pole,
		"diurnal_amp_equator": diurnal_amp_equator,
		"diurnal_amp_pole": diurnal_amp_pole,
		"season_ocean_damp": lerp(0.50, 0.72, 1.0 - heat),
		"continentality_scale": lerp(1.05, 1.45, 1.0 - habitability),
		"min_ocean_fraction": min_ocean_fraction,
		"lake_fill_ocean_ref": lake_fill_ocean_ref,
	}
