extends RefCounted
class_name ItemCatalog

static func all_items() -> Dictionary:
	return {
		"Potion": {
			"kind": "consumable",
			"description": "Restores a small amount of HP.",
			"value": 15,
			"stackable": true,
			"use_effect": {
				"type": "heal_hp",
				"amount": 20,
			},
		},
		"Herb": {
			"kind": "consumable",
			"description": "A healing herb used in field medicine.",
			"value": 8,
			"stackable": true,
			"use_effect": {
				"type": "heal_hp",
				"amount": 12,
			},
		},
		"Bronze Sword": {
			"kind": "weapon",
			"description": "Basic sword for front-line fighters.",
			"value": 120,
			"stackable": false,
			"equip_slot": "weapon",
			"stat_bonuses": {
				"strength": 2,
			},
		},
		"Leather Armor": {
			"kind": "armor",
			"description": "Light armor offering modest protection.",
			"value": 110,
			"stackable": false,
			"equip_slot": "armor",
			"stat_bonuses": {
				"defense": 2,
			},
		},
	}

static func has_item(item_name: String) -> bool:
	return all_items().has(item_name)

static func get_item(item_name: String) -> Dictionary:
	return all_items().get(item_name, {})
