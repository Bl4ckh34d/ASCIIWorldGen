extends RefCounted
class_name SocietySeeder

const DeterministicRng = preload("res://scripts/gameplay/DeterministicRng.gd")
const CommodityCatalog = preload("res://scripts/gameplay/catalog/CommodityCatalog.gd")
const EconomyStateModel = preload("res://scripts/gameplay/models/EconomyState.gd")
const PoliticsStateModel = preload("res://scripts/gameplay/models/PoliticsState.gd")
const NpcWorldStateModel = preload("res://scripts/gameplay/models/NpcWorldState.gd")
const EpochSystem = preload("res://scripts/gameplay/sim/EpochSystem.gd")

static func seed_on_world_tile_visit(world_seed_hash: int, world_x: int, world_y: int, biome_id: int, econ: EconomyStateModel, pol: PoliticsStateModel, npc: NpcWorldStateModel, epoch_id: String = "prehistoric", epoch_variant: String = "stable") -> void:
	if econ == null or pol == null or npc == null:
		return
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
	epoch_id = String(epoch_id)
	epoch_variant = String(epoch_variant)
	# Skip oceans/ice sheets (reserved low IDs in current project).
	if biome_id <= 1:
		return

	var settle_id: String = EconomyStateModel.settlement_id_for_tile(world_x, world_y)
	if econ.settlements.has(settle_id):
		return

	# Low density v0: seed occasional settlements to keep save size reasonable.
	var roll: float = DeterministicRng.randf01(world_seed_hash, "seed_settle|%d|%d|b=%d" % [world_x, world_y, biome_id])
	var chance: float = 0.075
	if roll > chance:
		return

	var pop: int = DeterministicRng.randi_range(world_seed_hash, "seed_pop|%d|%d" % [world_x, world_y], 80, 420)
	var name: String = _settlement_name(world_seed_hash, world_x, world_y)

	var prod: Dictionary = {}
	var cons: Dictionary = {}
	var stock: Dictionary = {}
	var prices: Dictionary = {}
	var scarcity: Dictionary = {}

	for key in CommodityCatalog.keys():
		var k: String = String(key)
		var c: float = 0.0
		match k:
			"water":
				c = float(pop) * 1.00
			"food":
				c = float(pop) * 0.85
			"fuel":
				c = float(pop) * 0.45
			"medicine":
				c = float(pop) * 0.05
			"materials":
				c = float(pop) * 0.22
			"arms":
				c = float(pop) * 0.03
			_:
				c = float(pop) * 0.10
		cons[k] = c
		prices[k] = CommodityCatalog.base_price(k)
		stock[k] = c * float(DeterministicRng.randi_range(world_seed_hash, "seed_stock_days|%s|%d|%d" % [k, world_x, world_y], 3, 12))
		scarcity[k] = 0.0

	# Pick 2 specialties (net exporters).
	var keys: Array[String] = CommodityCatalog.keys()
	var i0: int = DeterministicRng.randi_range(world_seed_hash, "seed_spec0|%d|%d" % [world_x, world_y], 0, keys.size() - 1)
	var i1: int = DeterministicRng.randi_range(world_seed_hash, "seed_spec1|%d|%d" % [world_x, world_y], 0, keys.size() - 1)
	if i1 == i0:
		i1 = (i0 + 1) % keys.size()
	var spec0: String = keys[i0]
	var spec1: String = keys[i1]

	for k in cons.keys():
		var c2: float = float(cons[k])
		var ratio: float = 0.70
		if String(k) == spec0 or String(k) == spec1:
			ratio = 1.25 + DeterministicRng.randf01(world_seed_hash, "seed_prod_ratio|%s|%d|%d" % [String(k), world_x, world_y]) * 0.55
		else:
			ratio = 0.55 + DeterministicRng.randf01(world_seed_hash, "seed_prod_ratio|%s|%d|%d" % [String(k), world_x, world_y]) * 0.50
		prod[k] = c2 * ratio

	econ.ensure_settlement(settle_id, {
		"name": name,
		"world_x": int(world_x),
		"world_y": int(world_y),
		"population": pop,
		"production": prod,
		"consumption": cons,
		"stockpile": stock,
		"prices": prices,
		"scarcity": scarcity,
		"specialties": [spec0, spec1],
	})

	# Politics: assign the settlement's tile as a province owned by a coarse "realm" region.
	var region: int = 16
	var sx: int = int(floor(float(world_x) / float(region)))
	var sy: int = int(floor(float(world_y) / float(region)))
	var state_id: String = "state|%d|%d" % [sx, sy]
	var gov_hint: String = EpochSystem.government_hint(epoch_id, epoch_variant)
	var rigidity: float = EpochSystem.social_rigidity_hint(epoch_id, epoch_variant)
	if not pol.states.has(state_id):
		pol.ensure_state(state_id, {
			"name": _state_name(world_seed_hash, sx, sy),
			"capital_settlement_id": settle_id,
			"government": gov_hint,
			"government_auto": true,
			"epoch": epoch_id,
			"epoch_variant": epoch_variant,
			"social_rigidity": rigidity,
		})
	var prov_id: String = pol.province_id_at(world_x, world_y)
	pol.ensure_province(prov_id, {
		"world_x": int(world_x),
		"world_y": int(world_y),
		"owner_state_id": state_id,
		"settlement_id": settle_id,
		"unrest": 0.10,
	})

	# Important NPCs: seed a shopkeeper and a ruler (one per state).
	var shop_id: String = "npc|shopkeeper|%s" % settle_id
	npc.ensure_important_npc(shop_id, {
		"role": "shopkeeper",
		"home_settlement_id": settle_id,
		"home_state_id": state_id,
		"personality": _personality_vec(world_seed_hash, shop_id),
		"needs": {"hunger": 0.0, "thirst": 0.0, "safety": 0.0, "wealth": 0.2},
		"disposition_base": 0.55,
		"language": "common",
		"epoch": epoch_id,
		"epoch_variant": epoch_variant,
		"social_rigidity": rigidity,
	})
	var ruler_id: String = "npc|ruler|%s" % state_id
	if not npc.important_npcs.has(ruler_id):
		npc.ensure_important_npc(ruler_id, {
			"role": "ruler",
			"home_state_id": state_id,
			"personality": _personality_vec(world_seed_hash, ruler_id),
			"needs": {"hunger": 0.0, "thirst": 0.0, "safety": 0.1, "wealth": 0.9},
			"disposition_base": 0.40,
			"language": "common",
			"epoch": epoch_id,
			"epoch_variant": epoch_variant,
			"social_rigidity": rigidity,
		})

static func _settlement_name(world_seed_hash: int, world_x: int, world_y: int) -> String:
	var a: Array[String] = ["Brin", "Cal", "Dor", "Eld", "Fen", "Gal", "Har", "Ire", "Kel", "Lor", "Mor", "Nor", "Or", "Per", "Riv", "Sol", "Tor", "Val", "Wyn", "Yar"]
	var b: Array[String] = ["dale", "ford", "haven", "hold", "keep", "mere", "port", "rest", "stead", "ton", "watch", "wick"]
	var i0: int = DeterministicRng.randi_range(world_seed_hash, "nm_a|%d|%d" % [world_x, world_y], 0, a.size() - 1)
	var i1: int = DeterministicRng.randi_range(world_seed_hash, "nm_b|%d|%d" % [world_x, world_y], 0, b.size() - 1)
	return "%s%s" % [a[i0], b[i1]]

static func _state_name(world_seed_hash: int, sx: int, sy: int) -> String:
	var a: Array[String] = ["Ash", "Bright", "Cinder", "Dusk", "Eagle", "Frost", "Gild", "High", "Iron", "Jade", "Keen", "Lion", "Mist", "Night", "Oak", "Pale", "Quartz", "Red", "Stone", "Wyrm"]
	var b: Array[String] = ["Crown", "March", "Realm", "Throne", "Union", "Dominion", "League", "Order"]
	var i0: int = DeterministicRng.randi_range(world_seed_hash, "sn_a|%d|%d" % [sx, sy], 0, a.size() - 1)
	var i1: int = DeterministicRng.randi_range(world_seed_hash, "sn_b|%d|%d" % [sx, sy], 0, b.size() - 1)
	return "%s %s" % [a[i0], b[i1]]

static func _personality_vec(world_seed_hash: int, seed_id: String) -> Dictionary:
	# 0..1 traits: agreeableness, aggression, curiosity, loyalty, greed
	return {
		"agree": DeterministicRng.randf01(world_seed_hash, "pers|%s|a" % seed_id),
		"aggr": DeterministicRng.randf01(world_seed_hash, "pers|%s|g" % seed_id),
		"cur": DeterministicRng.randf01(world_seed_hash, "pers|%s|c" % seed_id),
		"loy": DeterministicRng.randf01(world_seed_hash, "pers|%s|l" % seed_id),
		"greed": DeterministicRng.randf01(world_seed_hash, "pers|%s|r" % seed_id),
	}
