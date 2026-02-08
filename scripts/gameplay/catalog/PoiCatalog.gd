extends RefCounted
class_name PoiCatalog

static func get_type_data(poi_type: String) -> Dictionary:
	match poi_type:
		"House":
			return {
				"display_name": "House",
				"category": "settlement",
				"clears_on_exit": false,
			}
		"Dungeon":
			return {
				"display_name": "Dungeon",
				"category": "danger",
				# Cleared when the dungeon boss is defeated (not on exit).
				"clears_on_exit": false,
			}
		_:
			return {
				"display_name": poi_type,
				"category": "unknown",
				"clears_on_exit": false,
			}
