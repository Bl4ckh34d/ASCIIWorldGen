extends RefCounted
class_name PoliticsSim

const PoliticsStateModel = preload("res://scripts/gameplay/models/PoliticsState.gd")

# Background daily politics tick.
# Scaffolding only: no rules yet, but we keep deterministic hooks and a tick counter.

static func tick_day(_world_seed_hash: int, pol: PoliticsStateModel, abs_day: int) -> void:
	if pol == null:
		return
	# Placeholder for future:
	# - unrest drift
	# - treaty changes
	# - war fronts / province transfers
	# For now, stamp an update marker on any existing entities.
	for sid in pol.states.keys():
		var st: Variant = pol.states.get(sid)
		if typeof(st) != TYPE_DICTIONARY:
			continue
		var s: Dictionary = (st as Dictionary).duplicate(true)
		s["last_update_abs_day"] = abs_day
		pol.states[sid] = s

	for pid in pol.provinces.keys():
		var pv: Variant = pol.provinces.get(pid)
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = (pv as Dictionary).duplicate(true)
		p["last_update_abs_day"] = abs_day
		pol.provinces[pid] = p

