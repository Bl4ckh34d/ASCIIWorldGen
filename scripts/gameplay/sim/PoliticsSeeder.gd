extends RefCounted
class_name PoliticsSeeder

static func seed_full_map_if_needed(world_seed_hash: int, world_w: int, world_h: int, pol: PoliticsStateModel, epoch_id: String = "prehistoric", epoch_variant: String = "stable") -> void:
	if pol == null:
		return
	world_w = max(1, int(world_w))
	world_h = max(1, int(world_h))
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
	epoch_id = String(epoch_id)
	epoch_variant = String(epoch_variant)
	var gov_hint: String = EpochSystem.government_hint(epoch_id, epoch_variant)
	var rigidity: float = EpochSystem.social_rigidity_hint(epoch_id, epoch_variant)

	# If provinces already exist, assume seeded (idempotent).
	if not pol.provinces.is_empty() and not pol.states.is_empty():
		return

	var s: int = max(1, int(pol.province_size_world_tiles))
	var gw: int = int(ceil(float(world_w) / float(s)))
	var gh: int = int(ceil(float(world_h) / float(s)))
	pol.province_grid_w = gw
	pol.province_grid_h = gh

	# Create states lazily as we assign provinces.
	for py in range(gh):
		for px in range(gw):
			var prov_id: String = "province|%d|%d" % [px, py]
			var state_id: String = pol.state_id_for_province_coords(px, py)
			if not pol.states.has(state_id):
				pol.ensure_state(state_id, {
					"name": _state_name(world_seed_hash, state_id),
					"government": gov_hint,
					"government_auto": true,
					"epoch": epoch_id,
					"epoch_variant": epoch_variant,
					"social_rigidity": rigidity,
				})
			# Seed a stable unrest baseline with small variation.
			var u: float = 0.08 + DeterministicRng.randf01(world_seed_hash, "unrest|%s" % prov_id) * 0.18
			pol.ensure_province(prov_id, {
				"px": px,
				"py": py,
				"owner_state_id": state_id,
				"unrest": clamp(u, 0.0, 1.0),
			})

static func _state_name(world_seed_hash: int, state_id: String) -> String:
	var a: Array[String] = ["Ash", "Bright", "Cinder", "Dusk", "Eagle", "Frost", "Gild", "High", "Iron", "Jade", "Keen", "Lion", "Mist", "Night", "Oak", "Pale", "Quartz", "Red", "Stone", "Wyrm"]
	var b: Array[String] = ["Crown", "March", "Realm", "Throne", "Union", "Dominion", "League", "Order"]
	var i0: int = DeterministicRng.randi_range(world_seed_hash, "sn_a|%s" % state_id, 0, a.size() - 1)
	var i1: int = DeterministicRng.randi_range(world_seed_hash, "sn_b|%s" % state_id, 0, b.size() - 1)
	return "%s %s" % [a[i0], b[i1]]
