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
var _intro_seed_base: String = ""
var _intro_world_prepared: bool = false

# Shared gameplay state for scene-to-scene flow (world map -> regional -> POI/battle)
var world_seed_hash: int = 0
var world_width: int = 0
var world_height: int = 0
var world_biome_ids: PackedInt32Array = PackedInt32Array()
var selected_world_tile: Vector2i = Vector2i(-1, -1)
var selected_world_tile_biome_id: int = -1
var selected_world_tile_biome_name: String = ""
var regional_local_pos: Vector2i = Vector2i(48, 48)
var pending_battle: Dictionary = {}
var pending_poi: Dictionary = {}

func reset() -> void:
	star_name = ""
	planet_name = ""
	orbit_norm = 0.5
	moon_count = 0
	moon_seed = 0.0
	intro_completed = false
	_pending_world_config.clear()
	_intro_seed_string = ""
	_intro_seed_base = ""
	_intro_world_prepared = false
	world_seed_hash = 0
	world_width = 0
	world_height = 0
	world_biome_ids = PackedInt32Array()
	selected_world_tile = Vector2i(-1, -1)
	selected_world_tile_biome_id = -1
	selected_world_tile_biome_name = ""
	regional_local_pos = Vector2i(48, 48)
	pending_battle.clear()
	pending_poi.clear()

func prepare_intro_world_config(star_input: String, orbit_value: float, selected_moon_count: int = 0, selected_moon_seed: float = 0.0) -> void:
	star_name = _sanitize_star_name(star_input)
	orbit_norm = clamp(float(orbit_value), 0.0, 1.0)
	moon_count = clamp(int(selected_moon_count), 0, 3)
	moon_seed = max(0.0, float(selected_moon_seed))
	_intro_seed_base = "%s|orbit=%.4f|moons=%d|moonseed=%.3f" % [star_name, orbit_norm, moon_count, moon_seed]
	_intro_seed_string = _intro_seed_base
	_pending_world_config = _derive_world_config(orbit_norm)
	_pending_world_config["seed"] = _intro_seed_base
	_pending_world_config["moon_count"] = moon_count
	_pending_world_config["moon_seed"] = moon_seed
	_intro_world_prepared = true
	intro_completed = false

func set_intro_planet_name(world_name: String) -> void:
	planet_name = _sanitize_planet_name(world_name)
	if _intro_seed_base.is_empty():
		_intro_seed_base = "%s|orbit=%.4f|moons=%d|moonseed=%.3f" % [star_name, orbit_norm, moon_count, moon_seed]
	_intro_seed_string = "%s|planet=%s" % [_intro_seed_base, planet_name]
	intro_completed = _intro_world_prepared and not _pending_world_config.is_empty()

func set_intro_selection(star_input: String, orbit_value: float, world_name: String = "", selected_moon_count: int = 0, selected_moon_seed: float = 0.0) -> void:
	prepare_intro_world_config(star_input, orbit_value, selected_moon_count, selected_moon_seed)
	set_intro_planet_name(world_name)

func has_pending_world_config() -> bool:
	return intro_completed and not _pending_world_config.is_empty()

func consume_world_config() -> Dictionary:
	if _pending_world_config.is_empty():
		return {}
	var out: Dictionary = _pending_world_config.duplicate(true)
	_pending_world_config.clear()
	_intro_world_prepared = false
	intro_completed = false
	return out

func get_intro_seed_string() -> String:
	return _intro_seed_string

func set_world_snapshot(width: int, height: int, seed_hash: int, biome_ids: PackedInt32Array) -> void:
	world_width = max(1, width)
	world_height = max(1, height)
	world_seed_hash = seed_hash
	world_biome_ids = biome_ids.duplicate()

func set_selected_world_tile(x: int, y: int, biome_id: int, biome_name: String, local_x: int = 48, local_y: int = 48) -> void:
	selected_world_tile = Vector2i(x, y)
	selected_world_tile_biome_id = biome_id
	selected_world_tile_biome_name = biome_name
	regional_local_pos = Vector2i(local_x, local_y)

func has_world_snapshot() -> bool:
	return world_width > 0 and world_height > 0 and world_biome_ids.size() == world_width * world_height

func get_world_biome_id(x: int, y: int) -> int:
	if not has_world_snapshot():
		return selected_world_tile_biome_id
	var wx: int = posmod(x, world_width)
	var wy: int = clamp(y, 0, world_height - 1)
	var i: int = wx + wy * world_width
	if i < 0 or i >= world_biome_ids.size():
		return selected_world_tile_biome_id
	return world_biome_ids[i]

func queue_battle(encounter_data: Dictionary) -> void:
	pending_battle = encounter_data.duplicate(true)

func consume_battle() -> Dictionary:
	if pending_battle.is_empty():
		return {}
	var out: Dictionary = pending_battle.duplicate(true)
	pending_battle.clear()
	return out

func queue_poi(poi_data: Dictionary) -> void:
	pending_poi = poi_data.duplicate(true)

func consume_poi() -> Dictionary:
	if pending_poi.is_empty():
		return {}
	var out: Dictionary = pending_poi.duplicate(true)
	pending_poi.clear()
	return out

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
	# Use side-specific edge curves so extremes ramp up close to the zone limits,
	# keeping mid-side placements broadly habitable.
	var edge: float = clamp(abs(orbit_n - 0.5) * 2.0, 0.0, 1.0)
	var habitability: float = 1.0 - edge
	var hot_side: float = clamp((0.5 - orbit_n) * 2.0, 0.0, 1.0)
	var cold_side: float = clamp((orbit_n - 0.5) * 2.0, 0.0, 1.0)
	var hot_extreme: float = pow(hot_side, 2.20)
	var cold_extreme: float = pow(cold_side, 2.20)
	var harshness: float = pow(edge, 1.55)

	# Temperature envelope: make hot-side placement warm up more decisively so
	# ice retreat comes mainly from climate, not explicit cap forcing.
	var temp_min_c: float = -12.0 - cold_extreme * 50.0 + hot_extreme * 20.0
	var temp_max_c: float = 46.0 - cold_extreme * 22.0 + hot_extreme * 52.0

	# Keep oceans present through most of the band; reduce only near harsh hot edge.
	var sea_level: float = 0.08 - harshness * 0.10 - hot_extreme * 0.20 + cold_extreme * 0.06
	sea_level = clamp(sea_level, -0.40, 0.22)

	# Keep explicit polar-cap forcing small on hot-side worlds; let temperature drive the rest.
	var hot_cap_suppression: float = clamp(1.0 - hot_extreme * 0.90, 0.08, 1.0)
	var polar_cap_raw: float = 0.015 + cold_extreme * 0.35 + pow(cold_side, 1.4) * 0.06
	var polar_cap_frac: float = clamp(polar_cap_raw * hot_cap_suppression, 0.005, 0.50)
	var moist_base_offset: float = 0.10 + habitability * 0.10 - hot_extreme * 0.20 - cold_extreme * 0.06
	var moist_scale: float = clamp(0.84 + habitability * 0.22 - hot_extreme * 0.12 + cold_extreme * 0.04, 0.62, 1.14)
	var season_amp_equator: float = clamp(lerp(0.05, 0.14, harshness) - hot_extreme * 0.015, 0.04, 0.14)
	var season_amp_pole: float = clamp(0.14 + cold_extreme * 0.22 + harshness * 0.05 - hot_extreme * 0.08, 0.10, 0.40)
	var diurnal_amp_equator: float = lerp(0.08, 0.20, hot_extreme)
	var diurnal_amp_pole: float = lerp(0.04, 0.12, hot_extreme)
	var min_ocean_fraction: float = clamp(0.03 + habitability * 0.10 + cold_extreme * 0.03 - hot_extreme * 0.04, 0.02, 0.18)
	var lake_fill_ocean_ref: float = clamp(0.50 + habitability * 0.40 + cold_extreme * 0.08 - hot_extreme * 0.12, 0.30, 1.00)

	return {
		"temp_min_c": temp_min_c,
		"temp_max_c": temp_max_c,
		"temp_base_offset": 0.20 + hot_extreme * 0.22 - cold_extreme * 0.18,
		"temp_scale": clamp(0.96 + hot_extreme * 0.18 + cold_extreme * 0.10 - harshness * 0.05, 0.88, 1.18),
		"sea_level": sea_level,
		"polar_cap_frac": polar_cap_frac,
		"moist_base_offset": moist_base_offset,
		"moist_scale": moist_scale,
		"season_amp_equator": season_amp_equator,
		"season_amp_pole": season_amp_pole,
		"diurnal_amp_equator": diurnal_amp_equator,
		"diurnal_amp_pole": diurnal_amp_pole,
		"season_ocean_damp": lerp(0.52, 0.76, cold_extreme),
		"continentality_scale": lerp(1.08, 1.40, harshness),
		"min_ocean_fraction": min_ocean_fraction,
		"lake_fill_ocean_ref": lake_fill_ocean_ref,
	}
