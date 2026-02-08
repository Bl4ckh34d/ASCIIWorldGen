extends RefCounted
class_name EnemyCatalog

static func encounter_for_biome(biome_id: int, seed_roll: float) -> Dictionary:
	if _is_forest_biome(biome_id):
		if seed_roll < 0.50:
			return {"group": "Wolves", "power": 8, "base_hp": 28}
		return {"group": "Bandits", "power": 9, "base_hp": 30}
	if _is_mountain_biome(biome_id):
		if seed_roll < 0.50:
			return {"group": "Goblins", "power": 9, "base_hp": 29}
		return {"group": "Harpies", "power": 10, "base_hp": 32}
	if _is_desert_biome(biome_id):
		if seed_roll < 0.50:
			return {"group": "Scorpions", "power": 9, "base_hp": 30}
		return {"group": "Raiders", "power": 11, "base_hp": 34}
	if biome_id == 10 or biome_id == 23:
		if seed_roll < 0.50:
			return {"group": "Slimes", "power": 7, "base_hp": 26}
		return {"group": "Leeches", "power": 8, "base_hp": 27}
	return {"group": "Wild Beasts", "power": 8, "base_hp": 28}

static func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

static func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

static func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28
