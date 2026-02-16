extends RefCounted
class_name PoliticsEventLayer

const EVENT_INTERVAL_DAYS: int = 7
const MAX_EVENT_LOG: int = 256
const MAX_ACTIVE_WARS: int = 24
const MAX_TREATIES: int = 96
const MAX_TERRITORY_EVENTS_PER_TICK: int = 1
const BORDER_TRANSFER_BASE_WEEKLY_CHANCE: float = 0.04
const BORDER_TRANSFER_MAX_WEEKLY_CHANCE: float = 0.35
const REBEL_THRESHOLD_UNREST: float = 0.55
const REBEL_CHANCE_BASELINE_UNREST: float = 0.50
const REBEL_CHANCE_SCALE: float = 0.45
const REBEL_CHANCE_CAP: float = 0.45
const ALLOW_COLLAPSED_STATE_REACTIVATION: bool = true

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
			var aa: Array = states_v as Array
			if aa.size() >= 2:
				a = String(aa[0])
				b = String(aa[1])
	return PackedStringArray([a, b])

static func _is_active_status(status: String) -> bool:
	status = String(status).to_lower()
	return not (status == "ended" or status == "broken" or status == "expired" or status == "void")

static func _find_active_relation_index(relations: Array, a: String, b: String, kind_contains: String = "") -> int:
	var key: String = _pair_key(a, b)
	if key.is_empty():
		return -1
	kind_contains = String(kind_contains).to_lower()
	for i in range(relations.size()):
		var v: Variant = relations[i]
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = v as Dictionary
		var p: PackedStringArray = _relation_pair_from_dict(d)
		if _pair_key(String(p[0]), String(p[1])) != key:
			continue
		var status: String = String(d.get("status", "active"))
		if not _is_active_status(status):
			continue
		if not kind_contains.is_empty():
			var k: String = String(d.get("type", d.get("kind", ""))).to_lower()
			if k.find(kind_contains) < 0:
				continue
		return i
	return -1

static func _avg_unrest_for_state(pol: PoliticsStateModel, state_id: String) -> float:
	if pol == null or state_id.is_empty():
		return 0.0
	var sum_u: float = 0.0
	var n: int = 0
	for pv in pol.provinces.values():
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = pv as Dictionary
		if String(p.get("owner_state_id", "")) != state_id:
			continue
		sum_u += clamp(float(p.get("unrest", 0.0)), 0.0, 1.0)
		n += 1
	if n <= 0:
		return 0.08
	return clamp(sum_u / float(n), 0.0, 1.0)

static func _append_event(pol: PoliticsStateModel, day: int, event_type: String, payload: Dictionary) -> void:
	if pol == null:
		return
	var ev: Dictionary = {
		"abs_day": int(day),
		"type": String(event_type),
	}
	for k in payload.keys():
		ev[k] = payload[k]
	pol.event_log.append(ev)
	while pol.event_log.size() > MAX_EVENT_LOG:
		pol.event_log.remove_at(0)

static func _break_treaties_for_pair(pol: PoliticsStateModel, a: String, b: String, day: int) -> bool:
	if pol == null:
		return false
	var changed: bool = false
	var key: String = _pair_key(a, b)
	for i in range(pol.treaties.size()):
		var v: Variant = pol.treaties[i]
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (v as Dictionary).duplicate(true)
		var p: PackedStringArray = _relation_pair_from_dict(d)
		if _pair_key(String(p[0]), String(p[1])) != key:
			continue
		if not _is_active_status(String(d.get("status", "active"))):
			continue
		d["status"] = "broken"
		d["end_abs_day"] = int(day)
		pol.treaties[i] = d
		changed = true
	return changed

static func _declare_war(pol: PoliticsStateModel, a: String, b: String, day: int) -> void:
	pol.wars.append({
		"state_a_id": String(a),
		"state_b_id": String(b),
		"status": "active",
		"start_abs_day": int(day),
	})

static func _end_war(pol: PoliticsStateModel, a: String, b: String, day: int) -> bool:
	if pol == null:
		return false
	var idx: int = _find_active_relation_index(pol.wars, a, b)
	if idx < 0:
		return false
	var d: Dictionary = (pol.wars[idx] as Dictionary).duplicate(true)
	d["status"] = "ended"
	d["end_abs_day"] = int(day)
	pol.wars[idx] = d
	return true

static func _active_relation_counts_for_state(pol: PoliticsStateModel, state_id: String) -> Dictionary:
	state_id = String(state_id)
	var wars_n: int = 0
	var treaties_n: int = 0
	var alliances_n: int = 0
	if pol == null or state_id.is_empty():
		return {
			"wars": wars_n,
			"treaties": treaties_n,
			"alliances": alliances_n,
		}
	for wv in pol.wars:
		if typeof(wv) != TYPE_DICTIONARY:
			continue
		var wd: Dictionary = wv as Dictionary
		if not _is_active_status(String(wd.get("status", "active"))):
			continue
		var wp: PackedStringArray = _relation_pair_from_dict(wd)
		if String(wp[0]) == state_id or String(wp[1]) == state_id:
			wars_n += 1
	for tv in pol.treaties:
		if typeof(tv) != TYPE_DICTIONARY:
			continue
		var td: Dictionary = tv as Dictionary
		if not _is_active_status(String(td.get("status", "active"))):
			continue
		var tp: PackedStringArray = _relation_pair_from_dict(td)
		if String(tp[0]) != state_id and String(tp[1]) != state_id:
			continue
		treaties_n += 1
		var tk: String = String(td.get("type", td.get("kind", ""))).to_lower()
		if tk.find("alliance") >= 0 or tk == "allied" or tk == "ally":
			alliances_n += 1
	return {
		"wars": wars_n,
		"treaties": treaties_n,
		"alliances": alliances_n,
	}

static func _target_government_for_state(
	world_seed_hash: int,
	day: int,
	state_id: String,
	current_gov: String,
	desired_gov: String,
	epoch_id: String,
	epoch_variant: String,
	unrest: float,
	war_count: int,
	treaty_count: int,
	alliance_count: int
) -> String:
	state_id = String(state_id)
	current_gov = String(current_gov)
	desired_gov = String(desired_gov)
	epoch_id = String(epoch_id)
	epoch_variant = String(epoch_variant)
	var unrest_c: float = clamp(float(unrest), 0.0, 1.0)
	var target: String = desired_gov if not desired_gov.is_empty() else current_gov
	var eidx: int = EpochSystem.epoch_index_for_id(epoch_id)

	# Post-collapse worlds favor hard power structures under pressure.
	if epoch_variant == "post_collapse" and (war_count > 0 or unrest_c >= 0.45):
		if eidx <= 2:
			target = "warlord_federation"
		else:
			target = "emergency_regime"

	# Persistent war pressure pushes towards emergency/military governance.
	if war_count >= 2 and unrest_c >= 0.35:
		if eidx >= 4:
			target = "emergency_regime"
		else:
			target = "military_rule"

	# Dense peaceful diplomacy can nudge modern+ states to federate.
	if war_count == 0 and unrest_c <= 0.22 and eidx >= 4 and (alliance_count >= 2 or treaty_count >= 3):
		var fed_roll: float = DeterministicRng.randf01(world_seed_hash, "pol_gov_fed|%d|%s" % [day, state_id])
		if fed_roll < 0.60:
			target = "federal_union"

	# Recover from emergency in stable conditions.
	if (current_gov == "emergency_regime" or current_gov == "military_rule") and war_count == 0 and unrest_c <= 0.20:
		var rec_roll: float = DeterministicRng.randf01(world_seed_hash, "pol_gov_recover|%d|%s" % [day, state_id])
		if rec_roll < 0.75:
			target = desired_gov if not desired_gov.is_empty() else "nation_state"

	return target

static func _tick_government_evolution_day(world_seed_hash: int, day: int, pol: PoliticsStateModel, mult: Dictionary = {}) -> bool:
	if pol == null:
		return false
	var epoch_id_default: String = String(mult.get("epoch_id", "prehistoric"))
	var epoch_variant_default: String = String(mult.get("epoch_variant", "stable"))
	var shifted: bool = false
	var state_ids: PackedStringArray = PackedStringArray()
	for sid_v in pol.states.keys():
		state_ids.append(String(sid_v))
	state_ids.sort()

	for sid_v in state_ids:
		var state_id: String = String(sid_v)
		var sv: Variant = pol.states.get(state_id, {})
		if typeof(sv) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = (sv as Dictionary).duplicate(true)
		var cur_gov: String = String(st.get("government", ""))
		var desired_gov: String = String(st.get("government_desired", st.get("government_hint", "")))
		var epoch_id: String = String(st.get("epoch", epoch_id_default))
		var epoch_variant: String = String(st.get("epoch_variant", epoch_variant_default))
		if desired_gov.is_empty():
			desired_gov = EpochSystem.government_hint(epoch_id, epoch_variant)
			st["government_desired"] = desired_gov
		if cur_gov.is_empty():
			cur_gov = desired_gov if not desired_gov.is_empty() else "tribal"
			st["government"] = cur_gov

		if not VariantCasts.to_bool(st.get("government_auto", true)):
			pol.states[state_id] = st
			continue

		var rel: Dictionary = _active_relation_counts_for_state(pol, state_id)
		var war_count: int = int(rel.get("wars", 0))
		var treaty_count: int = int(rel.get("treaties", 0))
		var alliance_count: int = int(rel.get("alliances", 0))
		var unrest: float = _avg_unrest_for_state(pol, state_id)
		var target_gov: String = _target_government_for_state(
			world_seed_hash,
			day,
			state_id,
			cur_gov,
			desired_gov,
			epoch_id,
			epoch_variant,
			unrest,
			war_count,
			treaty_count,
			alliance_count
		)
		if target_gov.is_empty():
			target_gov = desired_gov

		var pending_target: String = String(st.get("government_target", ""))
		var pending_due: int = int(st.get("government_shift_due_abs_day", -1))

		if target_gov == cur_gov:
			if not pending_target.is_empty() or pending_due >= 0:
				st["government_target"] = ""
				st["government_shift_due_abs_day"] = -1
				st["government_shift_reason"] = ""
		elif pending_target != target_gov or pending_due < int(day):
			var serial: int = max(0, int(st.get("government_shift_serial", 0))) + 1
			var delay_days: int = EpochSystem.roll_government_shift_delay_days(
				world_seed_hash,
				state_id,
				cur_gov,
				target_gov,
				day,
				serial
			)
			st["government_shift_serial"] = serial
			st["government_target"] = target_gov
			st["government_shift_due_abs_day"] = int(day) + max(45, delay_days)
			st["government_shift_started_abs_day"] = int(day)
			st["government_shift_reason"] = "epoch_pressure"
			st["government_shift_from"] = cur_gov

		pending_target = String(st.get("government_target", ""))
		pending_due = int(st.get("government_shift_due_abs_day", -1))
		if not pending_target.is_empty() and pending_due >= 0 and int(day) >= pending_due and pending_target != cur_gov:
			var prev_gov: String = cur_gov
			st["government"] = pending_target
			st["government_target"] = ""
			st["government_shift_due_abs_day"] = -1
			st["government_shift_reason"] = ""
			st["last_government_shift_abs_day"] = int(day)
			shifted = true
			_append_event(pol, day, "government_shift", {
				"state_id": state_id,
				"from_government": prev_gov,
				"to_government": pending_target,
				"epoch_id": epoch_id,
				"epoch_variant": epoch_variant,
			})
		pol.states[state_id] = st
	return shifted

static func _province_ids_for_state(pol: PoliticsStateModel, state_id: String) -> Array:
	var out: Array = []
	state_id = String(state_id)
	if pol == null or state_id.is_empty():
		return out
	for pid in pol.provinces.keys():
		var pv: Variant = pol.provinces.get(pid, {})
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = pv as Dictionary
		if String(p.get("owner_state_id", "")) == state_id:
			out.append(String(pid))
	out.sort()
	return out

static func _province_neighbor_ids(pol: PoliticsStateModel, province_id: String) -> Array:
	var out: Array = []
	if pol == null:
		return out
	var parts: PackedStringArray = String(province_id).split("|")
	if parts.size() < 3:
		return out
	var px: int = int(parts[1])
	var py: int = int(parts[2])
	var gw: int = max(1, int(pol.province_grid_w))
	var gh: int = max(1, int(pol.province_grid_h))
	if gw <= 0 or gh <= 0:
		return out
	var neighbors: Array = [
		Vector2i(posmod(px - 1, gw), py),
		Vector2i(posmod(px + 1, gw), py),
		Vector2i(px, py - 1),
		Vector2i(px, py + 1),
	]
	for n in neighbors:
		var nx: int = int(n.x)
		var ny: int = int(n.y)
		if ny < 0 or ny >= gh:
			continue
		out.append("province|%d|%d" % [nx, ny])
	return out

static func _province_touches_state(pol: PoliticsStateModel, province_id: String, state_id: String) -> bool:
	state_id = String(state_id)
	if pol == null or state_id.is_empty():
		return false
	var neigh: Array = _province_neighbor_ids(pol, province_id)
	for npid_v in neigh:
		var npid: String = String(npid_v)
		var nv: Variant = pol.provinces.get(npid, {})
		if typeof(nv) != TYPE_DICTIONARY:
			continue
		var nd: Dictionary = nv as Dictionary
		if String(nd.get("owner_state_id", "")) == state_id:
			return true
	return false

static func _pick_border_transfer_province(world_seed_hash: int, day: int, pol: PoliticsStateModel, state_id: String, target_winner: String = "") -> String:
	var ids: Array = _province_ids_for_state(pol, state_id)
	if ids.is_empty():
		return ""
	var best_id: String = ""
	var best_score: float = -999.0
	for pid_v in ids:
		var pid: String = String(pid_v)
		if not String(target_winner).is_empty() and not _province_touches_state(pol, pid, String(target_winner)):
			continue
		var pv: Variant = pol.provinces.get(pid, {})
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = pv as Dictionary
		var unrest: float = clamp(float(p.get("unrest", 0.0)), 0.0, 1.0)
		var tie: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_border_pick|%d|%s" % [day, pid])
		var score: float = unrest * 0.80 + tie * 0.20
		if score > best_score:
			best_score = score
			best_id = pid
	return best_id

static func _build_rebel_state_id(pol: PoliticsStateModel, province_id: String, day: int) -> String:
	var px: int = 0
	var py: int = 0
	var parts: PackedStringArray = String(province_id).split("|")
	if parts.size() >= 3:
		px = int(parts[1])
		py = int(parts[2])
	var base_id: String = "state|rebel|%d|%d|%d" % [px, py, int(day)]
	var sid: String = base_id
	var serial: int = 0
	while pol != null and pol.states.has(sid):
		serial += 1
		sid = "%s|%d" % [base_id, serial]
	return sid

static func _spawn_rebel_state_for_province(_world_seed_hash: int, day: int, pol: PoliticsStateModel, province_id: String, owner_state_id: String) -> String:
	if pol == null:
		return ""
	province_id = String(province_id)
	owner_state_id = String(owner_state_id)
	var pv: Variant = pol.provinces.get(province_id, {})
	if typeof(pv) != TYPE_DICTIONARY:
		return ""
	var prov: Dictionary = (pv as Dictionary).duplicate(true)

	var owner_epoch: String = "prehistoric"
	var owner_variant: String = "stable"
	var owner_rigidity: float = 0.6
	var desired_gov: String = "city_state"
	if not owner_state_id.is_empty():
		var ov: Variant = pol.states.get(owner_state_id, {})
		if typeof(ov) == TYPE_DICTIONARY:
			var owner: Dictionary = ov as Dictionary
			owner_epoch = String(owner.get("epoch", owner_epoch))
			owner_variant = String(owner.get("epoch_variant", owner_variant))
			owner_rigidity = clamp(float(owner.get("social_rigidity", owner_rigidity)), 0.0, 1.0)
			desired_gov = String(owner.get("government_desired", owner.get("government", desired_gov)))

	var gov_now: String = "city_state"
	if owner_variant == "post_collapse":
		gov_now = "warlord_federation"
	elif EpochSystem.epoch_index_for_id(owner_epoch) >= 4:
		gov_now = "emergency_regime"
	elif EpochSystem.epoch_index_for_id(owner_epoch) <= 1:
		gov_now = "tribal"

	var sid: String = _build_rebel_state_id(pol, province_id, day)
	pol.ensure_state(sid, {
		"name": "Rebel State %s" % province_id,
		"government": gov_now,
		"government_auto": true,
		"government_desired": desired_gov,
		"government_target": "",
		"government_shift_due_abs_day": -1,
		"government_shift_serial": 0,
		"epoch": owner_epoch,
		"epoch_variant": owner_variant,
		"social_rigidity": owner_rigidity,
		"origin_state_id": owner_state_id,
		"founded_abs_day": int(day),
		"status": "active",
	})

	prov["owner_state_id"] = sid
	prov["unrest"] = clamp(float(prov.get("unrest", 0.0)) * 0.72 + 0.16, 0.0, 1.0)
	prov["rebelled_abs_day"] = int(day)
	prov["origin_state_id"] = owner_state_id
	pol.provinces[province_id] = prov
	return sid

static func _mark_collapsed_states(pol: PoliticsStateModel, day: int) -> bool:
	if pol == null:
		return false
	var counts: Dictionary = {}
	for pv in pol.provinces.values():
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = pv as Dictionary
		var sid: String = String(p.get("owner_state_id", ""))
		if sid.is_empty():
			continue
		counts[sid] = int(counts.get(sid, 0)) + 1

	var changed: bool = false
	var state_ids: PackedStringArray = PackedStringArray()
	for sid_v in pol.states.keys():
		state_ids.append(String(sid_v))
	state_ids.sort()
	for sid_v in state_ids:
		var sid: String = String(sid_v)
		var sv: Variant = pol.states.get(sid, {})
		if typeof(sv) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = (sv as Dictionary).duplicate(true)
		var owned: int = int(counts.get(sid, 0))
		var status: String = String(st.get("status", "active")).to_lower()
		if owned <= 0 and status != "collapsed":
			st["status"] = "collapsed"
			st["collapse_abs_day"] = int(day)
			pol.states[sid] = st
			_append_event(pol, day, "state_collapsed", {"state_id": sid})
			changed = true
		elif ALLOW_COLLAPSED_STATE_REACTIVATION and owned > 0 and status == "collapsed":
			st["status"] = "active"
			st["reactivated_abs_day"] = int(day)
			pol.states[sid] = st
			_append_event(pol, day, "state_reactivated", {"state_id": sid})
			changed = true
	return changed

static func _tick_territory_events_day(world_seed_hash: int, day: int, pol: PoliticsStateModel, mult: Dictionary = {}) -> bool:
	if pol == null:
		return false
	var changed: bool = false
	var unrest_mul: float = clamp(float(mult.get("unrest_mul", 1.0)), 0.1, 4.0)
	var war_mul: float = clamp(float(mult.get("war_chance_mul", 1.0)), 0.1, 4.0)

	var province_ids: PackedStringArray = PackedStringArray()
	for pid_v in pol.provinces.keys():
		province_ids.append(String(pid_v))
	province_ids.sort()

	# Rebellion scaffold: highest-unrest province may splinter into a rebel state.
	var rebel_pid: String = ""
	var rebel_owner: String = ""
	var rebel_unrest: float = -1.0
	for pid_v in province_ids:
		var pid: String = String(pid_v)
		var pv: Variant = pol.provinces.get(pid, {})
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = pv as Dictionary
		var owner: String = String(p.get("owner_state_id", ""))
		if owner.is_empty():
			continue
		var unrest: float = clamp(float(p.get("unrest", 0.0)), 0.0, 1.0)
		var tie: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_rebel_pick|%d|%s" % [day, pid]) * 0.02
		var score: float = unrest + tie
		if score > rebel_unrest:
			rebel_unrest = score
			rebel_pid = pid
			rebel_owner = owner
	if not rebel_pid.is_empty() and rebel_unrest >= REBEL_THRESHOLD_UNREST:
		var rebel_roll: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_rebel_roll|%d|%s" % [day, rebel_pid])
		var rebel_chance: float = clamp(
			(rebel_unrest - REBEL_CHANCE_BASELINE_UNREST) * REBEL_CHANCE_SCALE * unrest_mul,
			0.0,
			REBEL_CHANCE_CAP
		)
		if rebel_roll < rebel_chance:
			var new_sid: String = _spawn_rebel_state_for_province(world_seed_hash, day, pol, rebel_pid, rebel_owner)
			if not new_sid.is_empty():
				_append_event(pol, day, "province_rebelled", {
					"province_id": rebel_pid,
					"from_state_id": rebel_owner,
					"to_state_id": new_sid,
				})
				changed = true

	# Border transfer scaffold: at war, provinces can change owner symbolically.
	var active_wars: Array = []
	for wv in pol.wars:
		if typeof(wv) != TYPE_DICTIONARY:
			continue
		var wd: Dictionary = wv as Dictionary
		if not _is_active_status(String(wd.get("status", "active"))):
			continue
		var wp: PackedStringArray = _relation_pair_from_dict(wd)
		var a: String = String(wp[0])
		var b: String = String(wp[1])
		if a.is_empty() or b.is_empty() or a == b:
			continue
		active_wars.append({"a": a, "b": b})
	if not active_wars.is_empty():
		var border_roll: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_border_roll|%d" % day)
		var border_chance: float = clamp(
			BORDER_TRANSFER_BASE_WEEKLY_CHANCE * war_mul,
			0.0,
			BORDER_TRANSFER_MAX_WEEKLY_CHANCE
		)
		var max_events: int = max(1, int(MAX_TERRITORY_EVENTS_PER_TICK))
		var events_done: int = 0
		while border_roll < border_chance and events_done < max_events and not active_wars.is_empty():
			var wi: int = DeterministicRng.randi_range(world_seed_hash, "pol_evt_border_war_pick|%d|%d" % [day, events_done], 0, active_wars.size() - 1)
			var wr: Dictionary = active_wars[wi] as Dictionary
			var sa: String = String(wr.get("a", ""))
			var sb: String = String(wr.get("b", ""))
			if sa.is_empty() or sb.is_empty() or sa == sb:
				break
			var unrest_a: float = _avg_unrest_for_state(pol, sa)
			var unrest_b: float = _avg_unrest_for_state(pol, sb)
			var winner: String = sa
			var loser: String = sb
			if unrest_b + 0.02 < unrest_a:
				winner = sb
				loser = sa
			elif abs(unrest_a - unrest_b) <= 0.02:
				var tie_roll: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_border_tie|%d|%s|%s" % [day, sa, sb])
				if tie_roll < 0.5:
					winner = sb
					loser = sa
			var transfer_pid: String = _pick_border_transfer_province(world_seed_hash, day, pol, loser, winner)
			if transfer_pid.is_empty():
				break
			var tpv: Variant = pol.provinces.get(transfer_pid, {})
			if typeof(tpv) != TYPE_DICTIONARY:
				break
			var tp: Dictionary = (tpv as Dictionary).duplicate(true)
			var prev_owner: String = String(tp.get("owner_state_id", loser))
			tp["owner_state_id"] = winner
			tp["unrest"] = clamp(float(tp.get("unrest", 0.0)) * 0.86 + 0.10, 0.0, 1.0)
			tp["transferred_abs_day"] = int(day)
			tp["transferred_from_state_id"] = prev_owner
			pol.provinces[transfer_pid] = tp
			_append_event(pol, day, "province_transferred", {
				"province_id": transfer_pid,
				"from_state_id": prev_owner,
				"to_state_id": winner,
				"cause": "war_pressure",
			})
			changed = true
			events_done += 1
			border_roll = DeterministicRng.randf01(world_seed_hash, "pol_evt_border_roll|%d|%d" % [day, events_done])

	var collapse_changed: bool = _mark_collapsed_states(pol, day)
	return changed or collapse_changed

static func _tick_event_day(world_seed_hash: int, day: int, pol: PoliticsStateModel, mult: Dictionary = {}) -> bool:
	if pol == null:
		return false
	var states: PackedStringArray = PackedStringArray()
	for k in pol.states.keys():
		states.append(String(k))
	states.sort()
	var changed: bool = false
	if states.size() < 2:
		var gov_changed0: bool = _tick_government_evolution_day(world_seed_hash, day, pol, mult)
		var terr_changed0: bool = _tick_territory_events_day(world_seed_hash, day, pol, mult)
		return gov_changed0 or terr_changed0

	var n: int = states.size()
	var a_idx: int = DeterministicRng.randi_range(world_seed_hash, "pol_evt_a|%d" % day, 0, n - 1)
	var b_base: int = DeterministicRng.randi_range(world_seed_hash, "pol_evt_b|%d" % day, 0, n - 2)
	var b_idx: int = b_base
	if b_idx >= a_idx:
		b_idx += 1
	var a: String = String(states[a_idx])
	var b: String = String(states[b_idx])
	if a == b:
		var gov_changed_same: bool = _tick_government_evolution_day(world_seed_hash, day, pol, mult)
		var terr_changed_same: bool = _tick_territory_events_day(world_seed_hash, day, pol, mult)
		return gov_changed_same or terr_changed_same

	var war_idx: int = _find_active_relation_index(pol.wars, a, b)
	var treaty_idx: int = _find_active_relation_index(pol.treaties, a, b)
	var ally_idx: int = _find_active_relation_index(pol.treaties, a, b, "alliance")
	var war_mul: float = clamp(float(mult.get("war_chance_mul", 1.0)), 0.1, 4.0)
	var treaty_mul: float = clamp(float(mult.get("treaty_chance_mul", 1.0)), 0.1, 4.0)
	var peace_mul: float = clamp(float(mult.get("peace_chance_mul", 1.0)), 0.1, 4.0)
	var unrest_mul: float = clamp(float(mult.get("unrest_mul", 1.0)), 0.1, 4.0)

	if war_idx >= 0:
		var roll_peace: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_peace|%d|%s|%s" % [day, a, b])
		var peace_chance: float = clamp(0.18 * peace_mul, 0.0, 0.95)
		if roll_peace < peace_chance:
			if _end_war(pol, a, b, day):
				changed = true
				_append_event(pol, day, "armistice_signed", {
					"state_a_id": a,
					"state_b_id": b,
				})
				# Small chance to establish a post-war treaty.
				var roll_treaty: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_post_treaty|%d|%s|%s" % [day, a, b])
				if roll_treaty < 0.35 and treaty_idx < 0 and pol.treaties.size() < MAX_TREATIES:
					pol.treaties.append({
						"state_a_id": a,
						"state_b_id": b,
						"type": "trade_pact",
						"status": "active",
						"start_abs_day": int(day),
					})
					_append_event(pol, day, "treaty_signed", {
						"state_a_id": a,
						"state_b_id": b,
						"treaty_type": "trade_pact",
					})
					changed = true
		var gov_changed_war: bool = _tick_government_evolution_day(world_seed_hash, day, pol, mult)
		var terr_changed_war: bool = _tick_territory_events_day(world_seed_hash, day, pol, mult)
		return changed or gov_changed_war or terr_changed_war

	var unrest_a: float = _avg_unrest_for_state(pol, a)
	var unrest_b: float = _avg_unrest_for_state(pol, b)
	var unrest_mean: float = clamp((unrest_a + unrest_b) * 0.5 * unrest_mul, 0.0, 1.0)

	var war_chance: float = (0.02 + unrest_mean * 0.20) * war_mul
	if treaty_idx >= 0:
		war_chance *= 0.50
	if ally_idx >= 0:
		war_chance *= 0.25
	war_chance = clamp(war_chance, 0.0, 0.50)
	var roll_war: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_war|%d|%s|%s" % [day, a, b])
	if roll_war < war_chance and pol.wars.size() < MAX_ACTIVE_WARS:
		_declare_war(pol, a, b, day)
		_break_treaties_for_pair(pol, a, b, day)
		changed = true
		_append_event(pol, day, "war_declared", {
			"state_a_id": a,
			"state_b_id": b,
		})

	var treaty_chance: float = (0.03 + (1.0 - unrest_mean) * 0.08) * treaty_mul
	if ally_idx >= 0:
		treaty_chance = 0.0
	var roll_treaty2: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_treaty|%d|%s|%s" % [day, a, b])
	if treaty_idx < 0 and roll_treaty2 < treaty_chance and pol.treaties.size() < MAX_TREATIES:
		var kind_roll: float = DeterministicRng.randf01(world_seed_hash, "pol_evt_treaty_kind|%d|%s|%s" % [day, a, b])
		var treaty_type: String = "alliance" if kind_roll < 0.30 else "trade_pact"
		pol.treaties.append({
			"state_a_id": a,
			"state_b_id": b,
			"type": treaty_type,
			"status": "active",
			"start_abs_day": int(day),
		})
		_append_event(pol, day, "treaty_signed", {
			"state_a_id": a,
			"state_b_id": b,
			"treaty_type": treaty_type,
		})
		changed = true
	var gov_changed: bool = _tick_government_evolution_day(world_seed_hash, day, pol, mult)
	var terr_changed: bool = _tick_territory_events_day(world_seed_hash, day, pol, mult)
	return changed or gov_changed or terr_changed

static func tick_batched(world_seed_hash: int, from_abs_day: int, to_abs_day: int, pol: PoliticsStateModel, mult: Dictionary = {}) -> bool:
	if pol == null:
		return false
	var from_day: int = int(from_abs_day)
	var to_day: int = int(to_abs_day)
	if to_day <= from_day:
		return false

	var cursor: int = int(pol.last_event_abs_day)
	if cursor < from_day:
		cursor = from_day
	if cursor < 0:
		cursor = 0

	var changed: bool = false
	while cursor + EVENT_INTERVAL_DAYS <= to_day:
		cursor += EVENT_INTERVAL_DAYS
		if _tick_event_day(world_seed_hash, cursor, pol, mult):
			changed = true
	pol.last_event_abs_day = max(int(pol.last_event_abs_day), cursor)
	return changed
