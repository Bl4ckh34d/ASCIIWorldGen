extends RefCounted
class_name EconomyFromSettlements


# Coarse economy bootstrapping derived from settlements + inferred world fields.
# Runs only at explicit coarse cadence (worldgen extraction), never per-frame.
#
# v0: production/consumption scales with population and uses biome+latitude heuristics.
# Later: feed from climate fields, tech/epoch, trade routes, war shocks, etc.

static func _biome_family(biome_id: int) -> String:
	# Keep in sync with other "biome proxy" heuristics (wildlife/civ start).
	if biome_id <= 1:
		return "ocean"
	# deserts
	if biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28:
		return "desert"
	# mountains-ish
	if biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41:
		return "mountain"
	# swamp
	if biome_id == 17:
		return "swamp"
	# forests-ish
	if biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27:
		return "forest"
	# grassland/steppe/savanna etc
	if biome_id == 7 or biome_id == 16 or biome_id == 10 or biome_id == 23:
		return "grass"
	return "other"

static func _lat_abs01(world_h: int, world_y: int) -> float:
	if world_h <= 1:
		return 0.0
	var t: float = float(clamp(int(world_y), 0, world_h - 1)) / float(world_h - 1)
	return abs(0.5 - t) * 2.0

static func _consumption_for_pop(pop: float, lat_abs: float) -> Dictionary:
	# Basic daily consumption per commodity. Keep it stable and simple.
	var p: float = max(0.0, float(pop))
	var cold: float = clamp(lat_abs, 0.0, 1.0)
	var out: Dictionary = {}
	out["water"] = p * 1.00
	out["food"] = p * 0.85
	out["fuel"] = p * (0.40 + cold * 0.25) # higher near poles
	out["medicine"] = p * 0.05
	out["materials"] = p * 0.22
	out["arms"] = p * 0.03
	return out

static func _prod_ratio_for(biome_family: String, key: String, level: String) -> float:
	# Ratio of production vs consumption for a given commodity.
	# 1.0 => self-sufficient, <1 => net importer, >1 => net exporter.
	biome_family = String(biome_family)
	key = String(key)
	level = String(level)

	var r: float = 0.70
	match key:
		"water":
			match biome_family:
				"desert": r = 0.45
				"mountain": r = 0.90
				"swamp": r = 1.20
				"forest": r = 1.10
				"grass": r = 1.00
				_: r = 0.95
		"food":
			match biome_family:
				"desert": r = 0.35
				"mountain": r = 0.60
				"swamp": r = 0.75
				"forest": r = 1.05
				"grass": r = 1.25
				_: r = 0.95
		"fuel":
			match biome_family:
				"desert": r = 0.60
				"mountain": r = 0.75
				"swamp": r = 0.80
				"forest": r = 1.30
				"grass": r = 0.90
				_: r = 0.95
		"medicine":
			match biome_family:
				"desert": r = 0.60
				"mountain": r = 0.75
				"swamp": r = 1.00
				"forest": r = 0.95
				"grass": r = 0.85
				_: r = 0.85
		"materials":
			match biome_family:
				"desert": r = 0.85
				"mountain": r = 1.55
				"swamp": r = 0.80
				"forest": r = 1.05
				"grass": r = 0.90
				_: r = 0.95
		"arms":
			# Arms are mostly a function of settlement complexity (crafting) in v0.
			r = 0.75
			if level == "city":
				r = 1.15
			elif level == "village":
				r = 0.95
			else:
				r = 0.80
		_:
			r = 0.80
	return r

static func _pick_specialties(world_seed_hash: int, settlement_id: String, biome_family: String) -> Array[String]:
	var keys: Array[String] = CommodityCatalog.keys()
	if keys.is_empty():
		return []
	# Bias specialties by biome family, but keep deterministic and simple.
	var pool: Array[String] = keys.duplicate()
	if biome_family == "desert":
		# Slight push towards materials/arms; water/food are less likely exports.
		pool.erase("water")
		pool.erase("food")
		pool.append_array(["materials", "materials", "arms"])
	elif biome_family == "mountain":
		pool.append_array(["materials", "materials", "fuel"])
	elif biome_family == "forest":
		pool.append_array(["fuel", "fuel", "food"])
	elif biome_family == "grass":
		pool.append_array(["food", "food", "water"])
	elif biome_family == "swamp":
		pool.append_array(["water", "medicine"])
	var i0: int = DeterministicRng.randi_range(world_seed_hash, "econ_spec0|%s" % settlement_id, 0, pool.size() - 1)
	var i1: int = DeterministicRng.randi_range(world_seed_hash, "econ_spec1|%s" % settlement_id, 0, pool.size() - 1)
	if i1 == i0:
		i1 = (i0 + 1) % pool.size()
	var a: String = String(pool[i0])
	var b: String = String(pool[i1])
	if b == a:
		b = String(keys[(i0 + 1) % keys.size()])
	return [a, b]

static func apply(
	world_seed_hash: int,
	world_w: int,
	world_h: int,
	world_biome_ids: PackedInt32Array,
	econ: EconomyStateModel,
	settlement_state: SettlementStateModel,
	pol: PoliticsStateModel
) -> bool:
	if econ == null or settlement_state == null or pol == null:
		return false
	world_w = max(1, int(world_w))
	world_h = max(1, int(world_h))
	var size: int = world_w * world_h
	if world_biome_ids.size() != size:
		return false

	var changed: bool = false
	for sid in econ.settlements.keys():
		var v: Variant = econ.settlements.get(sid, {})
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = (v as Dictionary).duplicate(true)
		var wx: int = int(st.get("world_x", 0))
		var wy: int = int(st.get("world_y", 0))
		wx = posmod(wx, world_w)
		wy = clamp(wy, 0, world_h - 1)

		var pop: float = float(st.get("population", 0.0))
		if pop <= 0.0:
			pop = float(st.get("pop_est", 0.0))
		# Prefer settlement-state pop estimate if available.
		var ssid: String = SettlementStateModel.settlement_id_at(wx, wy)
		var sv: Variant = settlement_state.settlements.get(ssid, {})
		var level: String = ""
		if typeof(sv) == TYPE_DICTIONARY:
			var sd: Dictionary = sv as Dictionary
			level = String(sd.get("level", ""))
			if pop <= 0.0:
				pop = float(sd.get("pop_est", 0.0))
		if level.is_empty():
			level = String(st.get("level", ""))

		# Autogen when missing or previously autogen'd.
		var prod0: Variant = st.get("production", {})
		var cons0: Variant = st.get("consumption", {})
		var autogen: bool = VariantCasts.to_bool(st.get("__autogen_v0", false))
		if typeof(prod0) != TYPE_DICTIONARY or (prod0 as Dictionary).is_empty():
			autogen = true
		if typeof(cons0) != TYPE_DICTIONARY or (cons0 as Dictionary).is_empty():
			autogen = true
		if not autogen:
			continue

		var idx: int = wx + wy * world_w
		var biome_id: int = int(world_biome_ids[idx])
		var fam: String = _biome_family(biome_id)
		var lat_abs: float = _lat_abs01(world_h, wy)

		var cons: Dictionary = _consumption_for_pop(pop, lat_abs)
		# Small deterministic variation per settlement.
		for k in cons.keys():
			var key: String = String(k)
			var jitter: float = (DeterministicRng.randf01(world_seed_hash, "econ_cons_jit|%s|%s" % [String(sid), key]) - 0.5) * 0.12
			cons[key] = max(0.001, float(cons[key]) * (1.0 + jitter))

		var specialties: Array[String] = _pick_specialties(world_seed_hash, String(sid), fam)
		var prod: Dictionary = {}
		for key in CommodityCatalog.keys():
			var base_c: float = float(cons.get(key, 0.001))
			var ratio: float = _prod_ratio_for(fam, String(key), level)
			# Specialty boost.
			if specialties.has(String(key)):
				ratio *= 1.40
			var jitter_p: float = (DeterministicRng.randf01(world_seed_hash, "econ_prod_jit|%s|%s" % [String(sid), String(key)]) - 0.5) * 0.30
			prod[String(key)] = max(0.0, base_c * ratio * (1.0 + jitter_p))

		var stock: Dictionary = {}
		var prices: Dictionary = {}
		var scarcity: Dictionary = {}
		for key in CommodityCatalog.keys():
			var k2: String = String(key)
			prices[k2] = CommodityCatalog.base_price(k2)
			scarcity[k2] = 0.0
			var days: int = DeterministicRng.randi_range(world_seed_hash, "econ_stock_days|%s|%s" % [String(sid), k2], 4, 14)
			stock[k2] = float(cons.get(k2, 0.001)) * float(days)

		# Ensure a stable state ownership label for later NPC scoping.
		var prov_id: String = pol.province_id_at(wx, wy)
		var pv: Variant = pol.provinces.get(prov_id, {})
		var owner: String = ""
		if typeof(pv) == TYPE_DICTIONARY:
			owner = String((pv as Dictionary).get("owner_state_id", ""))

		st["world_x"] = wx
		st["world_y"] = wy
		st["population"] = pop
		st["production"] = prod
		st["consumption"] = cons
		st["stockpile"] = stock
		st["prices"] = prices
		st["scarcity"] = scarcity
		st["specialties"] = specialties
		st["home_state_id"] = owner
		st["__autogen_v0"] = true
		econ.settlements[sid] = st
		changed = true
	return changed

