extends SceneTree
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const PoliticsEventLayer = preload("res://scripts/gameplay/sim/PoliticsEventLayer.gd")
const PoliticsStateModel = preload("res://scripts/gameplay/models/PoliticsState.gd")

func _init() -> void:
	var failures: PackedStringArray = PackedStringArray()
	_check_locked_constants(failures)
	_check_rebellion_rules(failures)
	_check_border_transfer_events(failures)
	_check_collapsed_state_reactivation(failures)
	if failures.is_empty():
		print("[POL-REG] PASS")
		quit(0)
		return
	for f in failures:
		push_error("[POL-REG] " + String(f))
	quit(1)

func _check_locked_constants(failures: PackedStringArray) -> void:
	if not is_equal_approx(PoliticsEventLayer.BORDER_TRANSFER_BASE_WEEKLY_CHANCE, 0.04):
		failures.append("BORDER_TRANSFER_BASE_WEEKLY_CHANCE changed from 0.04")
	if not is_equal_approx(PoliticsEventLayer.REBEL_THRESHOLD_UNREST, 0.55):
		failures.append("REBEL_THRESHOLD_UNREST changed from 0.55")
	if not VariantCasts.to_bool(PoliticsEventLayer.ALLOW_COLLAPSED_STATE_REACTIVATION):
		failures.append("ALLOW_COLLAPSED_STATE_REACTIVATION must stay true")

func _check_rebellion_rules(failures: PackedStringArray) -> void:
	var seed: int = 987654321
	var below_threshold: PoliticsStateModel = _build_model()
	_set_unrest(below_threshold, "province|0|0", 0.54)
	_set_unrest(below_threshold, "province|1|0", 0.40)
	PoliticsEventLayer._tick_territory_events_day(seed, 70, below_threshold, {})
	if not _find_last_event(below_threshold, "province_rebelled").is_empty():
		failures.append("Rebellion triggered below unrest threshold")

	var seen_rebellion: bool = false
	for day in range(1, 1025):
		var pol: PoliticsStateModel = _build_model()
		_set_unrest(pol, "province|0|0", 0.95)
		_set_unrest(pol, "province|1|0", 0.40)
		PoliticsEventLayer._tick_territory_events_day(seed, day, pol, {})
		var ev: Dictionary = _find_last_event(pol, "province_rebelled")
		if ev.is_empty():
			continue
		seen_rebellion = true
		if String(ev.get("province_id", "")) != "province|0|0":
			failures.append("Rebellion did not target top-unrest province")
		break
	if not seen_rebellion:
		failures.append("No rebellion observed in regression window")

func _check_border_transfer_events(failures: PackedStringArray) -> void:
	var seed: int = 424242
	var seen_transfer: bool = false
	for day in range(1, 2049):
		var pol: PoliticsStateModel = _build_model()
		_set_unrest(pol, "province|0|0", 0.95)
		_set_unrest(pol, "province|1|0", 0.05)
		pol.wars.append({
			"state_a_id": "state|a",
			"state_b_id": "state|b",
			"status": "active",
			"start_abs_day": 0,
		})
		PoliticsEventLayer._tick_territory_events_day(seed, day, pol, {"war_chance_mul": 1.0})
		var ev: Dictionary = _find_last_event(pol, "province_transferred")
		if ev.is_empty():
			continue
		seen_transfer = true
		if String(ev.get("province_id", "")) != "province|0|0":
			failures.append("Border transfer picked unexpected province")
		if String(ev.get("from_state_id", "")) != "state|a" or String(ev.get("to_state_id", "")) != "state|b":
			failures.append("Border transfer winner/loser mapping changed")
		if String(ev.get("cause", "")) != "war_pressure":
			failures.append("Border transfer cause changed from war_pressure")
		break
	if not seen_transfer:
		failures.append("No border transfer observed in regression window")

func _check_collapsed_state_reactivation(failures: PackedStringArray) -> void:
	var pol: PoliticsStateModel = _build_model()
	_set_owner(pol, "province|1|0", "state|a")
	PoliticsEventLayer._mark_collapsed_states(pol, 100)
	var b0: Dictionary = pol.states.get("state|b", {})
	if String(b0.get("status", "")) != "collapsed":
		failures.append("State B did not collapse when it lost all provinces")
	if not pol.states.has("state|b"):
		failures.append("Collapsed state was removed instead of preserved")
	_set_owner(pol, "province|1|0", "state|b")
	PoliticsEventLayer._mark_collapsed_states(pol, 107)
	var b1: Dictionary = pol.states.get("state|b", {})
	if String(b1.get("status", "")) != "active":
		failures.append("Collapsed state did not reactivate after regaining land")
	if _find_last_event(pol, "state_reactivated").is_empty():
		failures.append("Missing state_reactivated event on reactivation")

func _build_model() -> PoliticsStateModel:
	var pol := PoliticsStateModel.new()
	pol.reset_defaults()
	pol.province_grid_w = 2
	pol.province_grid_h = 1
	pol.ensure_state("state|a", {"name": "A", "status": "active"})
	pol.ensure_state("state|b", {"name": "B", "status": "active"})
	pol.ensure_province("province|0|0", {"owner_state_id": "state|a", "unrest": 0.10})
	pol.ensure_province("province|1|0", {"owner_state_id": "state|b", "unrest": 0.10})
	return pol

func _set_unrest(pol: PoliticsStateModel, province_id: String, unrest: float) -> void:
	if pol == null:
		return
	var pv: Variant = pol.provinces.get(province_id, {})
	if typeof(pv) != TYPE_DICTIONARY:
		return
	var p: Dictionary = (pv as Dictionary).duplicate(true)
	p["unrest"] = clamp(float(unrest), 0.0, 1.0)
	pol.provinces[province_id] = p

func _set_owner(pol: PoliticsStateModel, province_id: String, owner_state_id: String) -> void:
	if pol == null:
		return
	var pv: Variant = pol.provinces.get(province_id, {})
	if typeof(pv) != TYPE_DICTIONARY:
		return
	var p: Dictionary = (pv as Dictionary).duplicate(true)
	p["owner_state_id"] = String(owner_state_id)
	pol.provinces[province_id] = p

func _find_last_event(pol: PoliticsStateModel, event_type: String) -> Dictionary:
	if pol == null:
		return {}
	for i in range(pol.event_log.size() - 1, -1, -1):
		var v: Variant = pol.event_log[i]
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var ev: Dictionary = v as Dictionary
		if String(ev.get("type", "")) == event_type:
			return ev
	return {}
