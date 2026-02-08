extends RefCounted
class_name SpellCatalog

static func all_spells() -> Dictionary:
	return {
		"Fire": {
			"kind": "damage",
			"description": "A basic fire spell.",
			"mp_cost": 4,
			"target": "enemy",
			"power": 9,
		},
		"Cure": {
			"kind": "heal_hp",
			"description": "Restores HP to one ally.",
			"mp_cost": 3,
			"target": "party",
			"amount": 18,
		},
	}

static func has_spell(spell_name: String) -> bool:
	return all_spells().has(spell_name)

static func get_spell(spell_name: String) -> Dictionary:
	return all_spells().get(spell_name, {})

static func spells_for_member(member_id: String) -> PackedStringArray:
	# Scaffold: only mage has spells right now.
	if String(member_id) == "mage":
		return PackedStringArray(["Fire", "Cure"])
	return PackedStringArray()

