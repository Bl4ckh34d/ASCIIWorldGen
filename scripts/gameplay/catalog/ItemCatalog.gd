extends RefCounted
class_name ItemCatalog

static func all_items() -> Dictionary:
	return {
		"Potion": {
			"kind": "consumable",
			"description": "Restores a small amount of HP.",
			"value": 15,
			"tier": 1,
			"stackable": true,
			"use_effect": {
				"type": "heal_hp",
				"amount": 20,
				"target": "party",
			},
		},
		"Herb": {
			"kind": "consumable",
			"description": "A healing herb used in field medicine.",
			"value": 8,
			"tier": 1,
			"stackable": true,
			"use_effect": {
				"type": "heal_hp",
				"amount": 12,
				"target": "party",
			},
		},
		"Bomb": {
			"kind": "consumable",
			"description": "An explosive that damages one enemy.",
			"value": 30,
			"tier": 1,
			"stackable": true,
			"use_effect": {
				"type": "damage",
				"power": 16,
				"target": "enemy",
				"damage_type": "explosive",
			},
		},
		"Hi-Potion": {
			"kind": "consumable",
			"description": "Refined medicine that restores a moderate amount of HP.",
			"value": 36,
			"tier": 2,
			"stackable": true,
			"use_effect": {
				"type": "heal_hp",
				"amount": 45,
				"target": "party",
			},
		},
		"Fire Bomb": {
			"kind": "consumable",
			"description": "Alchemical charge with stronger fire damage.",
			"value": 58,
			"tier": 2,
			"stackable": true,
			"use_effect": {
				"type": "damage",
				"power": 30,
				"target": "enemy",
				"damage_type": "fire",
			},
		},
		"Royal Tonic": {
			"kind": "consumable",
			"description": "Rare tonic reserved for elite adventurers.",
			"value": 92,
			"tier": 3,
			"stackable": true,
			"use_effect": {
				"type": "heal_hp",
				"amount": 80,
				"target": "party",
			},
		},
		"Bronze Sword": {
			"kind": "weapon",
			"description": "Basic sword for front-line fighters.",
			"value": 120,
			"tier": 1,
			"stackable": false,
			"equip_slot": "weapon",
			"stat_bonuses": {
				"strength": 2,
			},
		},
		"Hunter Bow": {
			"kind": "weapon",
			"description": "A light bow favored by scouts and skirmishers.",
			"value": 136,
			"tier": 1,
			"stackable": false,
			"equip_slot": "weapon",
			"stat_bonuses": {
				"strength": 1,
				"agility": 2,
			},
		},
		"Iron Sword": {
			"kind": "weapon",
			"description": "Reliable steel-forged blade for hardened fighters.",
			"value": 196,
			"tier": 2,
			"stackable": false,
			"equip_slot": "weapon",
			"stat_bonuses": {
				"strength": 4,
			},
		},
		"Steel Greatblade": {
			"kind": "weapon",
			"description": "Heavy two-handed weapon that hits with brutal force.",
			"value": 278,
			"tier": 3,
			"stackable": false,
			"equip_slot": "weapon",
			"stat_bonuses": {
				"strength": 6,
				"defense": 1,
			},
		},
		"Mythril Saber": {
			"kind": "weapon",
			"description": "Masterwork saber with exceptional balance and edge.",
			"value": 392,
			"tier": 4,
			"stackable": false,
			"equip_slot": "weapon",
			"stat_bonuses": {
				"strength": 8,
				"agility": 2,
			},
		},
		"Leather Armor": {
			"kind": "armor",
			"description": "Light armor offering modest protection.",
			"value": 110,
			"tier": 1,
			"stackable": false,
			"equip_slot": "armor",
			"stat_bonuses": {
				"defense": 2,
			},
		},
		"Chainmail Vest": {
			"kind": "armor",
			"description": "Interlocked rings that improve defense without full plate.",
			"value": 172,
			"tier": 2,
			"stackable": false,
			"equip_slot": "armor",
			"stat_bonuses": {
				"defense": 4,
			},
		},
		"Scale Armor": {
			"kind": "armor",
			"description": "Layered scales that absorb strikes from beasts and raiders.",
			"value": 254,
			"tier": 3,
			"stackable": false,
			"equip_slot": "armor",
			"stat_bonuses": {
				"defense": 6,
				"strength": 1,
			},
		},
		"Knight Plate": {
			"kind": "armor",
			"description": "High-end plate armor for elite defenders.",
			"value": 356,
			"tier": 4,
			"stackable": false,
			"equip_slot": "armor",
			"stat_bonuses": {
				"defense": 8,
			},
		},
		"Copper Ring": {
			"kind": "accessory",
			"description": "Simple charm that sharpens reflexes.",
			"value": 94,
			"tier": 1,
			"stackable": false,
			"equip_slot": "accessory",
			"stat_bonuses": {
				"agility": 1,
			},
		},
		"Silver Charm": {
			"kind": "accessory",
			"description": "Inscribed charm with protective and focus runes.",
			"value": 166,
			"tier": 2,
			"stackable": false,
			"equip_slot": "accessory",
			"stat_bonuses": {
				"defense": 1,
				"intellect": 2,
			},
		},
		"Warden Sigil": {
			"kind": "accessory",
			"description": "A faction sigil worn by experienced field captains.",
			"value": 248,
			"tier": 3,
			"stackable": false,
			"equip_slot": "accessory",
			"stat_bonuses": {
				"defense": 2,
				"agility": 2,
			},
		},
		"Sunstone Pendant": {
			"kind": "accessory",
			"description": "Rare pendant that empowers focus and resilience.",
			"value": 338,
			"tier": 4,
			"stackable": false,
			"equip_slot": "accessory",
			"stat_bonuses": {
				"defense": 3,
				"intellect": 3,
			},
		},
	}

static func has_item(item_name: String) -> bool:
	return all_items().has(item_name)

static func get_item(item_name: String) -> Dictionary:
	return all_items().get(item_name, {})

static func items_by_kind(kind: String) -> Array[String]:
	kind = String(kind).to_lower().strip_edges()
	var out: Array[String] = []
	for item_name in all_items().keys():
		var id: String = String(item_name)
		var item: Dictionary = get_item(id)
		if String(item.get("kind", "")).to_lower() == kind:
			out.append(id)
	return out

static func items_up_to_tier(max_tier: int, kinds: Array[String] = []) -> Array[String]:
	max_tier = max(1, int(max_tier))
	var kinds_set: Dictionary = {}
	for kv in kinds:
		kinds_set[String(kv).to_lower().strip_edges()] = true
	var out: Array[String] = []
	for item_name in all_items().keys():
		var id: String = String(item_name)
		var item: Dictionary = get_item(id)
		var tier: int = int(item.get("tier", 1))
		if tier > max_tier:
			continue
		if not kinds_set.is_empty():
			var kind: String = String(item.get("kind", "")).to_lower()
			if not kinds_set.has(kind):
				continue
		out.append(id)
	return out
