extends RefCounted
class_name PoiRegistry

const DeterministicRng = preload("res://scripts/gameplay/DeterministicRng.gd")

static func get_poi_at(world_seed_hash: int, world_x: int, world_y: int, local_x: int, local_y: int, biome_id: int) -> Dictionary:
	if biome_id == 0 or biome_id == 1:
		return {}
	if local_x % 12 != 0 or local_y % 12 != 0:
		return {}
	var key_root: String = "poi|%d|%d|%d|%d|%d" % [world_x, world_y, local_x, local_y, biome_id]
	var roll: float = DeterministicRng.randf01(world_seed_hash, key_root)
	var house_chance: float = 0.040
	var dungeon_chance: float = 0.014
	if _is_mountain_biome(biome_id):
		house_chance = 0.020
		dungeon_chance = 0.038
	elif _is_forest_biome(biome_id):
		house_chance = 0.045
		dungeon_chance = 0.018
		elif _is_desert_biome(biome_id):
			house_chance = 0.018
			dungeon_chance = 0.030
		if roll <= house_chance:
			var shop_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|shop")
			var shop_chance: float = 0.15
			return {
				"type": "House",
				"id": "house_%d_%d_%d_%d" % [world_x, world_y, local_x, local_y],
				"seed_key": key_root,
				"is_shop": shop_roll <= shop_chance,
			}
	if roll <= house_chance + dungeon_chance:
		return {
			"type": "Dungeon",
			"id": "dungeon_%d_%d_%d_%d" % [world_x, world_y, local_x, local_y],
			"seed_key": key_root,
		}
	return {}

static func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

static func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

static func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28
