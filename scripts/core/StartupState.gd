# File: res://scripts/core/StartupState.gd
extends Node

var star_name: String = ""
var planet_name: String = ""
var orbit_norm: float = 0.5
var moon_count: int = 0
var moon_seed: float = 0.0
var intro_completed: bool = false

var _pending_world_config: Dictionary = {}
var _intro_seed_string: String = ""

func reset() -> void:
	star_name = ""
	planet_name = ""
	orbit_norm = 0.5
	moon_count = 0
	moon_seed = 0.0
	intro_completed = false
	_pending_world_config.clear()
	_intro_seed_string = ""

func set_intro_selection(star_input: String, orbit_value: float, world_name: String = "", selected_moon_count: int = 0, selected_moon_seed: float = 0.0) -> void:
	star_name = _sanitize_star_name(star_input)
	planet_name = _sanitize_planet_name(world_name)
	orbit_norm = clamp(float(orbit_value), 0.0, 1.0)
	moon_count = clamp(int(selected_moon_count), 0, 3)
	moon_seed = max(0.0, float(selected_moon_seed))
	_intro_seed_string = "%s|%s|orbit=%.4f|moons=%d|moonseed=%.3f" % [star_name, planet_name, orbit_norm, moon_count, moon_seed]
	_pending_world_config = _derive_world_config(orbit_norm)
	_pending_world_config["seed"] = _intro_seed_string
	_pending_world_config["moon_count"] = moon_count
	_pending_world_config["moon_seed"] = moon_seed
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

func _sanitize_star_name(raw_value: String) -> String:
	var cleaned: String = raw_value.strip_edges()
	if cleaned.is_empty():
		return "Unnamed Star"
	if cleaned.length() > 64:
		return cleaned.substr(0, 64)
	return cleaned

func _sanitize_planet_name(raw_value: String) -> String:
	var cleaned: String = raw_value.strip_edges()
	if cleaned.is_empty():
		return "Unnamed World"
	if cleaned.length() > 64:
		return cleaned.substr(0, 64)
	return cleaned

func _derive_world_config(orbit: float) -> Dictionary:
	var orbit_n: float = clamp(orbit, 0.0, 1.0)
	# Left side of the habitable band is hotter, right side is colder.
	var heat: float = 1.0 - orbit_n
	var cold: float = orbit_n
	# Center of band is most temperate; edges are harsher.
	var edge: float = clamp(abs(orbit_n - 0.5) * 2.0, 0.0, 1.0)
	var habitability: float = 1.0 - edge
	var hot_extreme: float = pow(heat, 1.35)
	var cold_extreme: float = pow(cold, 1.35)
	var harshness: float = pow(edge, 1.20)

	# Stronger directional climate split so left/right zone edges feel clearly different.
	var temp_min_c: float = lerp(-118.0, 18.0, heat)
	var temp_max_c: float = lerp(4.0, 112.0, heat)

	# Keep very-low oceans on the hot edge; allow somewhat more water on cold edge.
	var sea_level: float = 0.10 - harshness * 0.42 - hot_extreme * 0.24 + cold_extreme * 0.12
	sea_level = clamp(sea_level, -0.72, 0.22)

	var polar_cap_frac: float = clamp(0.03 + cold_extreme * 0.55 + harshness * 0.06, 0.02, 0.62)
	var moist_base_offset: float = 0.02 + habitability * 0.16 - hot_extreme * 0.34 - cold_extreme * 0.10
	var moist_scale: float = clamp(0.74 + habitability * 0.34 - hot_extreme * 0.18, 0.58, 1.22)
	var season_amp_equator: float = lerp(0.05, 0.18, harshness)
	var season_amp_pole: float = lerp(0.15, 0.52, harshness)
	var diurnal_amp_equator: float = lerp(0.07, 0.24, hot_extreme)
	var diurnal_amp_pole: float = lerp(0.03, 0.14, hot_extreme)
	var min_ocean_fraction: float = clamp(0.015 + habitability * 0.11 + cold_extreme * 0.05 - hot_extreme * 0.01, 0.01, 0.20)
	var lake_fill_ocean_ref: float = clamp(0.40 + habitability * 0.75 + cold_extreme * 0.10 - hot_extreme * 0.18, 0.25, 1.10)

	return {
		"temp_min_c": temp_min_c,
		"temp_max_c": temp_max_c,
		"temp_base_offset": lerp(-0.55, 0.62, heat),
		"temp_scale": lerp(0.64, 1.46, heat),
		"sea_level": sea_level,
		"polar_cap_frac": polar_cap_frac,
		"moist_base_offset": moist_base_offset,
		"moist_scale": moist_scale,
		"season_amp_equator": season_amp_equator,
		"season_amp_pole": season_amp_pole,
		"diurnal_amp_equator": diurnal_amp_equator,
		"diurnal_amp_pole": diurnal_amp_pole,
		"season_ocean_damp": lerp(0.44, 0.82, cold_extreme),
		"continentality_scale": lerp(1.10, 1.68, harshness),
		"min_ocean_fraction": min_ocean_fraction,
		"lake_fill_ocean_ref": lake_fill_ocean_ref,
	}
