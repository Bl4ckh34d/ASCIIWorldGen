extends RefCounted
class_name TradeRouteSeeder

# v0 route scaffolding:
# Build a stable, coarse graph over settlements so later economy systems can push trade flows.
# This does not affect the current compute tick yet; it is persistence + determinism plumbing.

static func _wrap_dx(w: int, ax: int, bx: int) -> int:
	var dx_raw: int = abs(int(ax) - int(bx))
	return min(dx_raw, w - dx_raw) if w > 0 else dx_raw

static func _pair_key(a: String, b: String) -> String:
	a = String(a)
	b = String(b)
	if a.is_empty() or b.is_empty() or a == b:
		return ""
	if a < b:
		return "%s|%s" % [a, b]
	return "%s|%s" % [b, a]

static func _relation_pair_from_dict(d: Dictionary) -> PackedStringArray:
	var a: String = String(d.get("state_a_id", ""))
	var b: String = String(d.get("state_b_id", ""))
	if a.is_empty() or b.is_empty():
		a = String(d.get("a", ""))
		b = String(d.get("b", ""))
	if a.is_empty() or b.is_empty():
		a = String(d.get("state_a", ""))
		b = String(d.get("state_b", ""))
	if a.is_empty() or b.is_empty():
		a = String(d.get("party_a", ""))
		b = String(d.get("party_b", ""))
	if a.is_empty() or b.is_empty():
		var states_v: Variant = d.get("states", [])
		if typeof(states_v) == TYPE_ARRAY:
			var states_a: Array = states_v as Array
			if states_a.size() >= 2:
				a = String(states_a[0])
				b = String(states_a[1])
	return PackedStringArray([a, b])

static func _build_relation_sets(pol: PoliticsStateModel) -> Dictionary:
	var wars: Dictionary = {}
	var treaties: Dictionary = {}
	var alliances: Dictionary = {}
	if pol == null:
		return {"wars": wars, "treaties": treaties, "alliances": alliances}

	for v in pol.wars:
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var p: PackedStringArray = _relation_pair_from_dict(v as Dictionary)
		var key: String = _pair_key(String(p[0]), String(p[1]))
		if not key.is_empty():
			wars[key] = true

	for v in pol.treaties:
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = v as Dictionary
		var p: PackedStringArray = _relation_pair_from_dict(d)
		var key: String = _pair_key(String(p[0]), String(p[1]))
		if key.is_empty():
			continue
		var status: String = String(d.get("status", "active")).to_lower()
		if status == "ended" or status == "broken" or status == "expired" or status == "void":
			continue
		treaties[key] = true
		var kind: String = String(d.get("type", d.get("kind", ""))).to_lower()
		if kind.find("alliance") >= 0 or kind == "allied" or kind == "ally":
			alliances[key] = true
	return {"wars": wars, "treaties": treaties, "alliances": alliances}

static func rebuild(
	world_seed_hash: int,
	world_w: int,
	world_h: int,
	econ: EconomyStateModel,
	pol: PoliticsStateModel = null,
	max_neighbors: int = 3
) -> bool:
	if econ == null:
		return false
	world_w = max(1, int(world_w))
	world_h = max(1, int(world_h))
	max_neighbors = clamp(int(max_neighbors), 1, 8)

	var rel: Dictionary = _build_relation_sets(pol)
	var rel_wars: Dictionary = rel.get("wars", {})
	var rel_treaties: Dictionary = rel.get("treaties", {})
	var rel_alliances: Dictionary = rel.get("alliances", {})

	var nodes: Array[Dictionary] = []
	for sid in econ.settlements.keys():
		var v: Variant = econ.settlements.get(sid, {})
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = v as Dictionary
		var state_id: String = String(st.get("home_state_id", st.get("state_id", st.get("owner_state_id", ""))))
		var state_epoch: String = "prehistoric"
		var state_variant: String = "stable"
		var state_government: String = ""
		if pol != null and not state_id.is_empty():
			var sv: Variant = pol.states.get(state_id, {})
			if typeof(sv) == TYPE_DICTIONARY:
				var sd: Dictionary = sv as Dictionary
				state_epoch = String(sd.get("epoch", sd.get("epoch_id", state_epoch)))
				state_variant = String(sd.get("epoch_variant", state_variant))
				state_government = String(sd.get("government", sd.get("government_hint", "")))
		var epoch_trade_mul: float = EpochSystem.trade_route_capacity_multiplier(
			state_epoch,
			state_variant,
			state_government
		)
		nodes.append({
			"id": String(sid),
			"x": posmod(int(st.get("world_x", 0)), world_w),
			"y": clamp(int(st.get("world_y", 0)), 0, world_h - 1),
			"pop": float(st.get("population", 0.0)),
			"state_id": state_id,
			"epoch_id": state_epoch,
			"epoch_variant": state_variant,
			"government": state_government,
			"trade_mul": epoch_trade_mul,
		})
	nodes.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	var node_by_id: Dictionary = {}
	for n in nodes:
		node_by_id[String(n.get("id", ""))] = n
	if nodes.size() <= 1:
		econ.routes = []
		return true

	var edges: Dictionary = {} # "a|b" -> edge dict
	for i in range(nodes.size()):
		var a: Dictionary = nodes[i]
		var ax: int = int(a.get("x", 0))
		var ay: int = int(a.get("y", 0))
		var aid: String = String(a.get("id", ""))
		var a_state: String = String(a.get("state_id", ""))

		# Find nearest neighbors (manhattan with X wrap). Deterministic tie-break with id hash.
		var dists: Array[Dictionary] = []
		for j in range(nodes.size()):
			if j == i:
				continue
			var b: Dictionary = nodes[j]
			var bx: int = int(b.get("x", 0))
			var by: int = int(b.get("y", 0))
			var bid: String = String(b.get("id", ""))
			var b_state: String = String(b.get("state_id", ""))

			var treaty_bonus: float = 0.0
			var relation_cap_mul: float = 1.0
			if not a_state.is_empty() and not b_state.is_empty() and a_state != b_state:
				var rel_key: String = _pair_key(a_state, b_state)
				if not rel_key.is_empty() and rel_wars.has(rel_key):
					# User decision: no trade at war.
					continue
				# User decision: prefer treaties/alliances.
				if not rel_key.is_empty() and rel_alliances.has(rel_key):
					treaty_bonus = 4.0
					relation_cap_mul = 1.35
				elif not rel_key.is_empty() and rel_treaties.has(rel_key):
					treaty_bonus = 2.0
					relation_cap_mul = 1.15
				else:
					relation_cap_mul = 0.95
			elif not a_state.is_empty() and a_state == b_state:
				relation_cap_mul = 1.10

			var d: int = _wrap_dx(world_w, ax, bx) + abs(ay - by)
			var tie: int = abs(int(("route_tie|%s|%s" % [aid, bid]).hash()) ^ int(world_seed_hash))
			var score: float = float(d) - treaty_bonus
			dists.append({"id": bid, "d": d, "score": score, "tie": tie, "cap_mul": relation_cap_mul})
		dists.sort_custom(func(u, v):
			var su: float = float(u.get("score", 0.0))
			var sv: float = float(v.get("score", 0.0))
			if abs(su - sv) > 0.0001:
				return su < sv
			var tu: int = int(u.get("tie", 0))
			var tv: int = int(v.get("tie", 0))
			if tu != tv:
				return tu < tv
			return String(u.get("id", "")) < String(v.get("id", ""))
		)

		for k in range(min(max_neighbors, dists.size())):
			var bid2: String = String(dists[k].get("id", ""))
			if bid2.is_empty() or bid2 == aid:
				continue
			var a0: String = aid
			var b0: String = bid2
			if b0 < a0:
				var tmp: String = a0
				a0 = b0
				b0 = tmp
			var key: String = "%s|%s" % [a0, b0]
			if edges.has(key):
				continue
			var dist: int = int(dists[k].get("d", 0))
			var cap_base: float = 1.0 / (1.0 + float(dist))
			# Capacity proxy: larger settlements sustain more throughput.
			var pop_a: float = float(a.get("pop", 0.0))
			var pop_b: float = 0.0
			var mul_a: float = max(0.0, float(a.get("trade_mul", 1.0)))
			var mul_b: float = 1.0
			var b_node_v: Variant = node_by_id.get(bid2, {})
			if typeof(b_node_v) == TYPE_DICTIONARY:
				var b_node: Dictionary = b_node_v as Dictionary
				pop_b = float(b_node.get("pop", 0.0))
				mul_b = max(0.0, float(b_node.get("trade_mul", 1.0)))
			var epoch_mul: float = sqrt(mul_a * mul_b)
			var cap_mul: float = float(dists[k].get("cap_mul", 1.0))
			var cap: float = cap_base * (0.25 + sqrt(max(0.0, min(pop_a, pop_b))) * 0.01) * cap_mul * epoch_mul
			edges[key] = {
				"a": a0,
				"b": b0,
				"dist": dist,
				"capacity": cap,
				"epoch_capacity_mul": epoch_mul,
			}

	# Persist as stable array.
	var out_edges: Array = []
	for k in edges.keys():
		out_edges.append(edges[k])
	out_edges.sort_custom(func(u, v):
		var ua: String = String(u.get("a", ""))
		var va: String = String(v.get("a", ""))
		if ua != va:
			return ua < va
		return String(u.get("b", "")) < String(v.get("b", ""))
	)
	econ.routes = out_edges
	return true
