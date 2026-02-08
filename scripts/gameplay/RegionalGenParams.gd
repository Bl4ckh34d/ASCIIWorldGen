extends RefCounted
class_name RegionalGenParams

# Biome -> regional generation parameter mapping.
# All values are 0..1 unless otherwise noted.

static func params_for_biome(biome_id: int) -> Dictionary:
	# Default: mild grassland.
	var p := {
		"water": 0.0,
		"sand": 0.0,
		"snow": 0.0,
		"swamp": 0.0,
		"trees": 0.10,
		"shrubs": 0.22,
		"rocks": 0.08,
		"roughness": 0.22,
		"elev_bias": 0.0,
		"elev_amp": 0.22,
	}

	# Water / coast
	if biome_id == 0: # OCEAN
		p["water"] = 1.0
		p["elev_amp"] = 0.05
		p["roughness"] = 0.10
		return p
	if biome_id == 1: # ICE_SHEET
		p["water"] = 1.0
		p["snow"] = 1.0
		p["elev_amp"] = 0.05
		p["roughness"] = 0.10
		return p
	if biome_id == 2: # BEACH
		p["sand"] = 1.0
		p["trees"] = 0.05
		p["shrubs"] = 0.12
		p["rocks"] = 0.10
		p["roughness"] = 0.12
		p["elev_amp"] = 0.10
		return p

	# Wetlands
	if biome_id == 10 or biome_id == 23: # SWAMP / FROZEN_MARSH
		p["swamp"] = 1.0
		p["water"] = 0.18
		p["trees"] = 0.18
		p["shrubs"] = 0.45
		p["rocks"] = 0.04
		p["roughness"] = 0.18
		p["elev_amp"] = 0.14
		if biome_id == 23:
			p["snow"] = 0.45
		return p

	# Forests
	if _is_forest_biome(biome_id):
		p["trees"] = 0.60
		p["shrubs"] = 0.28
		p["rocks"] = 0.08
		p["roughness"] = 0.22
		p["elev_amp"] = 0.18
		if biome_id == 22: # FROZEN_FOREST
			p["snow"] = 0.55
		if biome_id == 27: # SCORCHED_FOREST (also used for scorched swamp)
			p["sand"] = 0.15
			p["shrubs"] = 0.18
		return p

	# Mountains / high relief
	if _is_mountain_biome(biome_id):
		p["trees"] = 0.08
		p["shrubs"] = 0.10
		p["rocks"] = 0.55
		p["roughness"] = 0.85
		p["elev_bias"] = 0.10
		p["elev_amp"] = 0.42
		if biome_id == 24: # GLACIER
			p["snow"] = 1.0
			p["trees"] = 0.0
			p["shrubs"] = 0.02
		elif biome_id == 19: # ALPINE
			p["snow"] = 0.65
			p["trees"] = 0.02
			p["shrubs"] = 0.06
		return p

	# Desert / wasteland
	if _is_desert_biome(biome_id):
		p["sand"] = 0.85
		p["trees"] = 0.02
		p["shrubs"] = 0.08
		p["rocks"] = 0.22
		p["roughness"] = 0.28
		p["elev_amp"] = 0.18
		if biome_id == 5: # DESERT_ICE
			p["snow"] = 0.70
		if biome_id == 28: # SALT_DESERT
			p["sand"] = 0.65
			p["rocks"] = 0.30
		return p

	# Cold band
	if biome_id == 20: # TUNDRA
		p["snow"] = 0.45
		p["trees"] = 0.04
		p["shrubs"] = 0.22
		p["rocks"] = 0.12
		p["roughness"] = 0.24
		p["elev_amp"] = 0.18
		return p

	# Hills
	if biome_id == 16 or biome_id == 34 or biome_id == 41: # HILLS / FROZEN_HILLS / SCORCHED_HILLS
		p["trees"] = 0.14
		p["shrubs"] = 0.22
		p["rocks"] = 0.22
		p["roughness"] = 0.45
		p["elev_amp"] = 0.30
		if biome_id == 34:
			p["snow"] = 0.45
		if biome_id == 41:
			p["sand"] = 0.12
		return p

	# Steppe / grassland / savanna variants
	if biome_id == 6 or biome_id == 30 or biome_id == 37: # STEPPE
		p["trees"] = 0.05
		p["shrubs"] = 0.18
		p["rocks"] = 0.10
		p["roughness"] = 0.20
		p["elev_amp"] = 0.18
		if biome_id == 30:
			p["snow"] = 0.35
		if biome_id == 37:
			p["sand"] = 0.10
		return p
	if biome_id == 7 or biome_id == 29 or biome_id == 36: # GRASSLAND
		p["trees"] = 0.10
		p["shrubs"] = 0.22
		p["rocks"] = 0.08
		p["roughness"] = 0.18
		p["elev_amp"] = 0.18
		if biome_id == 29:
			p["snow"] = 0.35
		if biome_id == 36:
			p["sand"] = 0.12
		return p
	if biome_id == 21 or biome_id == 33 or biome_id == 40: # SAVANNA
		p["trees"] = 0.18
		p["shrubs"] = 0.18
		p["rocks"] = 0.10
		p["roughness"] = 0.18
		p["elev_amp"] = 0.18
		if biome_id == 33:
			p["snow"] = 0.25
		if biome_id == 40:
			p["sand"] = 0.10
		return p

	# Volcanic / specials (treat like rocky badlands)
	if biome_id == 25 or biome_id == 26: # LAVA_FIELD / VOLCANIC_BADLANDS
		p["trees"] = 0.0
		p["shrubs"] = 0.02
		p["rocks"] = 0.70
		p["roughness"] = 0.70
		p["elev_bias"] = 0.05
		p["elev_amp"] = 0.30
		return p

	return p

static func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

static func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

static func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28

