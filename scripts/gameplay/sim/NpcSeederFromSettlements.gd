extends RefCounted
class_name NpcSeederFromSettlements

# Scaffolding: ensure "important NPCs" exist for newly created settlements/states.
# Runs only at coarse cadence (worldgen settlement extraction) and on-demand.

static func _personality_vec(world_seed_hash: int, seed_id: String) -> Dictionary:
	return {
		"agree": DeterministicRng.randf01(world_seed_hash, "pers|%s|a" % seed_id),
		"aggr": DeterministicRng.randf01(world_seed_hash, "pers|%s|g" % seed_id),
		"cur": DeterministicRng.randf01(world_seed_hash, "pers|%s|c" % seed_id),
		"loy": DeterministicRng.randf01(world_seed_hash, "pers|%s|l" % seed_id),
		"greed": DeterministicRng.randf01(world_seed_hash, "pers|%s|r" % seed_id),
	}

static func apply(world_seed_hash: int, econ: EconomyStateModel, pol: PoliticsStateModel, npc: NpcWorldStateModel, epoch_id: String = "prehistoric", epoch_variant: String = "stable") -> bool:
	if econ == null or pol == null or npc == null:
		return false
	world_seed_hash = 1 if int(world_seed_hash) == 0 else int(world_seed_hash)
	epoch_id = String(epoch_id)
	epoch_variant = String(epoch_variant)
	var rigidity: float = EpochSystem.social_rigidity_hint(epoch_id, epoch_variant)
	var changed: bool = false

	# One shopkeeper per settlement (v0).
	for settle_id in econ.settlements.keys():
		var stv: Variant = econ.settlements.get(settle_id, {})
		if typeof(stv) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = stv as Dictionary
		var home_state_id: String = String(st.get("home_state_id", ""))
		var shop_id: String = "npc|shopkeeper|%s" % String(settle_id)
		if npc.important_npcs.has(shop_id):
			continue
		npc.ensure_important_npc(shop_id, {
			"role": "shopkeeper",
			"home_settlement_id": String(settle_id),
			"home_state_id": home_state_id,
			"personality": _personality_vec(world_seed_hash, shop_id),
			"needs": {"hunger": 0.0, "thirst": 0.0, "safety": 0.0, "wealth": 0.3},
			"disposition_base": 0.55,
			"language": "common",
			"epoch": epoch_id,
			"epoch_variant": epoch_variant,
			"social_rigidity": rigidity,
		})
		changed = true

	# One ruler per state (v0).
	for state_id in pol.states.keys():
		var ruler_id: String = "npc|ruler|%s" % String(state_id)
		if npc.important_npcs.has(ruler_id):
			continue
		npc.ensure_important_npc(ruler_id, {
			"role": "ruler",
			"home_state_id": String(state_id),
			"personality": _personality_vec(world_seed_hash, ruler_id),
			"needs": {"hunger": 0.0, "thirst": 0.0, "safety": 0.1, "wealth": 0.9},
			"disposition_base": 0.40,
			"language": "common",
			"epoch": epoch_id,
			"epoch_variant": epoch_variant,
			"social_rigidity": rigidity,
		})
		changed = true

	return changed
