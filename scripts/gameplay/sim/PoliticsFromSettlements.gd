extends RefCounted
class_name PoliticsFromSettlements

# v0: derive coarse state ownership from extracted settlements (cities as capitals).
# Ownership is assigned at the province-grid level (not per world-tile conquest).


static func _capitals_from_settlements(settlements: Dictionary) -> Array[Dictionary]:
	var caps: Array[Dictionary] = []
	for sid in settlements.keys():
		var v: Variant = settlements.get(sid, {})
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = v as Dictionary
		var level: String = String(st.get("level", ""))
		if level != "city":
			continue
		caps.append({
			"settlement_id": String(st.get("id", sid)),
			"x": int(st.get("world_x", 0)),
			"y": int(st.get("world_y", 0)),
			"pop": float(st.get("pop_est", 0.0)),
		})
	caps.sort_custom(func(a, b):
		var pa: float = float(a.get("pop", 0.0))
		var pb: float = float(b.get("pop", 0.0))
		if abs(pa - pb) > 0.0001:
			return pa > pb
		return String(a.get("settlement_id", "")) < String(b.get("settlement_id", ""))
	)
	return caps

static func apply(
	_world_seed_hash: int,
	world_w: int,
	world_h: int,
	pol: PoliticsStateModel,
	settlement_state: SettlementStateModel
) -> bool:
	if pol == null or settlement_state == null:
		return false
	var w: int = max(0, int(world_w))
	var h: int = max(0, int(world_h))
	if w <= 0 or h <= 0:
		return false
	var s: int = max(1, int(pol.province_size_world_tiles))
	var grid_w: int = int(ceil(float(w) / float(s)))
	var grid_h: int = int(ceil(float(h) / float(s)))
	pol.province_grid_w = grid_w
	pol.province_grid_h = grid_h

	var caps: Array[Dictionary] = _capitals_from_settlements(settlement_state.settlements)
	if caps.is_empty():
		# Not enough civ complexity yet; keep seeded politics.
		return false

	# Limit number of city-states for v0 scaffolding.
	if caps.size() > 16:
		caps = caps.slice(0, 16)

	var changed: bool = false

	# Ensure states exist for capitals, and carve local enclaves around them.
	var claimed: Dictionary = {} # province_id -> true
	for c in caps:
		var sx: int = int(c.get("x", 0))
		var sy: int = int(c.get("y", 0))
		var pop_est: float = float(c.get("pop", 0.0))
		var sid: String = "state|city|%d|%d" % [sx, sy]
		var cap_px: int = int(floor(float(sx) / float(s)))
		var cap_py: int = int(floor(float(sy) / float(s)))
		var cap_prov: String = "province|%d|%d" % [cap_px, cap_py]
		var prev_owner: String = ""
		var cap_old_v: Variant = pol.provinces.get(cap_prov, {})
		if typeof(cap_old_v) == TYPE_DICTIONARY:
			prev_owner = String((cap_old_v as Dictionary).get("owner_state_id", ""))
		var state_pre_exists: bool = pol.states.has(sid)
		pol.ensure_state(sid, {
			"name": "State %d,%d" % [sx, sy],
			"capital_world_x": sx,
			"capital_world_y": sy,
			"tier": "city_state",
			"enclave_of_state_id": prev_owner,
		})
		if not state_pre_exists:
			changed = true

		# User decision: city-states carve out a local area while host state remains around it.
		var radius_prov: int = 0
		if pop_est >= 300.0:
			radius_prov = 2
		elif pop_est >= 120.0:
			radius_prov = 1

		for dy in range(-radius_prov, radius_prov + 1):
			for dx in range(-radius_prov, radius_prov + 1):
				if abs(dx) + abs(dy) > radius_prov:
					continue
				var px: int = posmod(cap_px + dx, grid_w)
				var py: int = clamp(cap_py + dy, 0, grid_h - 1)
				var prov_id: String = "province|%d|%d" % [px, py]
				if claimed.has(prov_id):
					continue
				claimed[prov_id] = true
				var unrest_keep: float = 0.0
				var owner_prev: String = ""
				var pv_old: Variant = pol.provinces.get(prov_id, {})
				if typeof(pv_old) == TYPE_DICTIONARY:
					var p_old: Dictionary = pv_old as Dictionary
					unrest_keep = float(p_old.get("unrest", 0.0))
					owner_prev = String(p_old.get("owner_state_id", ""))
				pol.ensure_province(prov_id, {
					"owner_state_id": sid,
					"unrest": unrest_keep,
					"is_city_state_core": true,
					"host_state_id_prev": owner_prev,
				})
				if owner_prev != sid:
					changed = true
	return changed
