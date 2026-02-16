extends RefCounted
class_name EpochSystem

# Coarse civilization epoch scaffold.
# This remains symbolic in v0 and is driven by civilization tech/devastation proxies.

const _EPOCH_IDS: Array = [
	"prehistoric",
	"ancient",
	"medieval",
	"industrial",
	"modern",
	"space_age",
	"singularity",
]

const _EPOCH_MIN_TECH: Array = [
	0.00,
	0.10,
	0.25,
	0.45,
	0.65,
	0.82,
	0.95,
]

const _EPOCH_MAX_TECH: Array = [
	0.10,
	0.25,
	0.45,
	0.65,
	0.82,
	0.95,
	1.00,
]

static func classify(humans_emerged: bool, tech_level: float, devastation: float) -> Dictionary:
	tech_level = clamp(float(tech_level), 0.0, 1.0)
	devastation = clamp(float(devastation), 0.0, 1.0)
	var idx: int = 0
	if humans_emerged:
		for i in range(_EPOCH_IDS.size()):
			if tech_level >= float(_EPOCH_MIN_TECH[i]):
				idx = i
	var eid: String = String(_EPOCH_IDS[idx])
	var t0: float = float(_EPOCH_MIN_TECH[idx])
	var t1: float = float(_EPOCH_MAX_TECH[idx])
	var p: float = 0.0
	if t1 > t0:
		p = clamp((tech_level - t0) / (t1 - t0), 0.0, 1.0)

	var variant: String = "stable"
	if devastation >= 0.65 and idx >= 3:
		variant = "post_collapse"
	elif devastation >= 0.35:
		variant = "stressed"

	return {
		"epoch_id": eid,
		"epoch_index": idx,
		"epoch_progress": p,
		"epoch_variant": variant,
		"government_hint": government_hint(eid, variant),
		"social_rigidity": social_rigidity_hint(eid, variant),
	}

static func epoch_index_for_id(epoch_id: String) -> int:
	epoch_id = String(epoch_id)
	for i in range(_EPOCH_IDS.size()):
		if String(_EPOCH_IDS[i]) == epoch_id:
			return i
	return 0

static func government_hint(epoch_id: String, variant: String = "stable") -> String:
	epoch_id = String(epoch_id)
	variant = String(variant)
	if variant == "post_collapse":
		return "warlord_federation"
	match epoch_id:
		"prehistoric":
			return "tribal"
		"ancient":
			return "city_state"
		"medieval":
			return "feudal"
		"industrial":
			return "kingdom"
		"modern":
			return "nation_state"
		"space_age":
			return "technocracy"
		"singularity":
			return "post_state"
		_:
			return "tribal"

static func social_rigidity_hint(epoch_id: String, variant: String = "stable") -> float:
	epoch_id = String(epoch_id)
	var base: float = 0.55
	match epoch_id:
		"prehistoric":
			base = 0.70
		"ancient":
			base = 0.78
		"medieval":
			base = 0.82
		"industrial":
			base = 0.68
		"modern":
			base = 0.45
		"space_age":
			base = 0.35
		"singularity":
			base = 0.22
		_:
			base = 0.55
	if String(variant) == "post_collapse":
		base += 0.18
	elif String(variant) == "stressed":
		base += 0.08
	return clamp(base, 0.0, 1.0)

static func roll_shift_delay_days(
	world_seed_hash: int,
	from_epoch_id: String,
	to_epoch_id: String,
	from_variant: String,
	to_variant: String,
	abs_day: int,
	serial: int
) -> int:
	# User direction:
	# - mostly years/decades
	# - very rare fast shifts in months.
	world_seed_hash = 1 if int(world_seed_hash) == 0 else int(world_seed_hash)
	from_epoch_id = String(from_epoch_id)
	to_epoch_id = String(to_epoch_id)
	from_variant = String(from_variant)
	to_variant = String(to_variant)
	abs_day = max(0, int(abs_day))
	serial = max(0, int(serial))
	var key_root: String = "epoch_shift|d=%d|s=%d|%s>%s|%s>%s" % [
		abs_day,
		serial,
		from_epoch_id,
		to_epoch_id,
		from_variant,
		to_variant,
	]
	var same_epoch: bool = from_epoch_id == to_epoch_id
	var roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|roll")
	var out_days: int = 0
	if same_epoch:
		# Variant-only shifts (stable<->stressed<->post_collapse):
		# usually months->years, sometimes very fast.
		if roll < 0.08:
			out_days = DeterministicRng.randi_range(world_seed_hash, key_root + "|fast", 45, 180)
		elif roll < 0.82:
			out_days = DeterministicRng.randi_range(world_seed_hash, key_root + "|mid", 180, 2200)
		else:
			out_days = DeterministicRng.randi_range(world_seed_hash, key_root + "|long", 2200, 5400)
	else:
		var from_idx: int = epoch_index_for_id(from_epoch_id)
		var to_idx: int = epoch_index_for_id(to_epoch_id)
		var jump: int = max(1, abs(to_idx - from_idx))
		if roll < 0.03:
			# Very rare fast shift.
			out_days = DeterministicRng.randi_range(world_seed_hash, key_root + "|fast", 60, 270)
		elif roll < 0.68:
			# Years.
			out_days = DeterministicRng.randi_range(world_seed_hash, key_root + "|years", 4 * 365, 18 * 365)
		else:
			# Decades.
			out_days = DeterministicRng.randi_range(world_seed_hash, key_root + "|decades", 20 * 365, 70 * 365)
		# Larger jumps tend to be slower.
		var jump_mul: float = 1.0 + max(0, jump - 1) * 0.20
		out_days = int(round(float(out_days) * jump_mul))
	return max(30, out_days)

static func economy_multipliers(epoch_id: String, variant: String = "stable") -> Dictionary:
	epoch_id = String(epoch_id)
	variant = String(variant)
	var prod_scale: float = 1.0
	var cons_scale: float = 1.0
	var scarcity_scale: float = 1.0
	var price_speed: float = 1.0
	match epoch_id:
		"prehistoric":
			prod_scale = 0.75
			cons_scale = 0.95
			scarcity_scale = 1.20
			price_speed = 1.18
		"ancient":
			prod_scale = 0.85
			cons_scale = 1.00
			scarcity_scale = 1.10
			price_speed = 1.10
		"medieval":
			prod_scale = 0.92
			cons_scale = 1.02
			scarcity_scale = 1.00
			price_speed = 1.00
		"industrial":
			prod_scale = 1.05
			cons_scale = 1.05
			scarcity_scale = 0.92
			price_speed = 0.92
		"modern":
			prod_scale = 1.12
			cons_scale = 1.08
			scarcity_scale = 0.84
			price_speed = 0.84
		"space_age":
			prod_scale = 1.22
			cons_scale = 1.10
			scarcity_scale = 0.74
			price_speed = 0.76
		"singularity":
			prod_scale = 1.35
			cons_scale = 1.08
			scarcity_scale = 0.62
			price_speed = 0.68
		_:
			prod_scale = 1.0
			cons_scale = 1.0
			scarcity_scale = 1.0
			price_speed = 1.0
	if variant == "stressed":
		prod_scale *= 0.92
		cons_scale *= 1.06
		scarcity_scale *= 1.12
		price_speed *= 1.10
	elif variant == "post_collapse":
		prod_scale *= 0.72
		cons_scale *= 1.12
		scarcity_scale *= 1.35
		price_speed *= 1.28
	return {
		"prod_scale": clamp(prod_scale, 0.25, 3.00),
		"cons_scale": clamp(cons_scale, 0.25, 3.00),
		"scarcity_scale": clamp(scarcity_scale, 0.35, 3.50),
		"price_speed": clamp(price_speed, 0.35, 3.00),
	}

static func politics_multipliers(epoch_id: String, variant: String = "stable") -> Dictionary:
	epoch_id = String(epoch_id)
	variant = String(variant)
	var war_mul: float = 1.0
	var treaty_mul: float = 1.0
	var peace_mul: float = 1.0
	var unrest_mul: float = 1.0
	var unrest_decay_scale: float = 1.0
	var unrest_drift: float = 0.0
	match epoch_id:
		"prehistoric":
			war_mul = 1.35
			treaty_mul = 0.72
			peace_mul = 0.90
			unrest_mul = 1.10
		"ancient":
			war_mul = 1.28
			treaty_mul = 0.78
			peace_mul = 0.92
			unrest_mul = 1.08
		"medieval":
			war_mul = 1.15
			treaty_mul = 0.88
			peace_mul = 0.98
			unrest_mul = 1.04
		"industrial":
			war_mul = 1.00
			treaty_mul = 1.00
			peace_mul = 1.00
			unrest_mul = 1.00
		"modern":
			war_mul = 0.84
			treaty_mul = 1.16
			peace_mul = 1.14
			unrest_mul = 0.94
		"space_age":
			war_mul = 0.76
			treaty_mul = 1.24
			peace_mul = 1.20
			unrest_mul = 0.90
		"singularity":
			war_mul = 0.68
			treaty_mul = 1.28
			peace_mul = 1.24
			unrest_mul = 0.86
		_:
			pass
	if variant == "stressed":
		war_mul *= 1.18
		treaty_mul *= 0.88
		peace_mul *= 0.92
		unrest_mul *= 1.14
		unrest_decay_scale *= 0.84
		unrest_drift += 0.0004
	elif variant == "post_collapse":
		war_mul *= 1.36
		treaty_mul *= 0.70
		peace_mul *= 0.78
		unrest_mul *= 1.30
		unrest_decay_scale *= 0.62
		unrest_drift += 0.0012
	return {
		"war_chance_mul": clamp(war_mul, 0.25, 3.00),
		"treaty_chance_mul": clamp(treaty_mul, 0.25, 3.00),
		"peace_chance_mul": clamp(peace_mul, 0.25, 3.00),
		"unrest_mul": clamp(unrest_mul, 0.40, 3.00),
		"unrest_decay_scale": clamp(unrest_decay_scale, 0.10, 3.00),
		"unrest_drift": clamp(unrest_drift, -0.01, 0.01),
	}

static func npc_multipliers(epoch_id: String, variant: String = "stable") -> Dictionary:
	epoch_id = String(epoch_id)
	variant = String(variant)
	var eidx: int = epoch_index_for_id(epoch_id)
	var t: float = clamp(float(eidx) / 6.0, 0.0, 1.0)
	var need_gain: float = lerp(1.12, 0.84, t)
	var local_relief: float = lerp(0.92, 1.16, t)
	var remote_stress: float = lerp(1.06, 0.86, t)
	if variant == "stressed":
		need_gain *= 1.12
		local_relief *= 0.92
		remote_stress *= 1.15
	elif variant == "post_collapse":
		need_gain *= 1.30
		local_relief *= 0.78
		remote_stress *= 1.35
	return {
		"need_gain_scale": clamp(need_gain, 0.40, 3.00),
		"local_relief_scale": clamp(local_relief, 0.25, 3.00),
		"remote_stress_scale": clamp(remote_stress, 0.25, 3.00),
	}

static func gameplay_multipliers(epoch_id: String, variant: String = "stable") -> Dictionary:
	# Converts epoch/variant into coarse gameplay-facing knobs.
	# This is intentionally mild in v0 to avoid destabilizing combat/shop balance.
	epoch_id = String(epoch_id)
	variant = String(variant)
	var eidx: int = epoch_index_for_id(epoch_id)
	var t: float = clamp(float(eidx) / 6.0, 0.0, 1.0)

	var encounter_rate: float = lerp(1.10, 0.88, t)
	var encounter_power_mul: float = lerp(0.95, 1.14, t)
	var encounter_hp_mul: float = lerp(0.95, 1.18, t)
	var encounter_power_add: int = int(round(lerp(0.0, 2.0, t)))
	var flee_mul: float = lerp(1.04, 0.90, t)
	var reward_gold_mul: float = lerp(0.86, 1.30, t)
	var reward_exp_mul: float = lerp(0.92, 1.18, t)
	var shop_buy_mul: float = lerp(1.14, 0.92, t)
	var shop_sell_mul: float = lerp(0.40, 0.56, t)

	if variant == "stressed":
		encounter_rate *= 1.10
		encounter_power_mul *= 1.08
		encounter_hp_mul *= 1.06
		flee_mul *= 0.92
		reward_gold_mul *= 1.04
		reward_exp_mul *= 1.03
		shop_buy_mul *= 1.10
		shop_sell_mul *= 0.96
	elif variant == "post_collapse":
		encounter_rate *= 1.24
		encounter_power_mul *= 1.16
		encounter_hp_mul *= 1.15
		encounter_power_add += 1
		flee_mul *= 0.85
		reward_gold_mul *= 1.08
		reward_exp_mul *= 1.06
		shop_buy_mul *= 1.22
		shop_sell_mul *= 0.90

	return {
		"encounter_rate_mul": clamp(encounter_rate, 0.50, 2.00),
		"encounter_power_mul": clamp(encounter_power_mul, 0.70, 2.00),
		"encounter_hp_mul": clamp(encounter_hp_mul, 0.70, 2.50),
		"encounter_power_add": clamp(encounter_power_add, -4, 8),
		"flee_mul": clamp(flee_mul, 0.55, 1.25),
		"reward_gold_mul": clamp(reward_gold_mul, 0.40, 3.00),
		"reward_exp_mul": clamp(reward_exp_mul, 0.40, 3.00),
		"shop_buy_mul": clamp(shop_buy_mul, 0.55, 2.50),
		"shop_sell_mul": clamp(shop_sell_mul, 0.20, 1.20),
	}

static func roll_government_shift_delay_days(
	world_seed_hash: int,
	state_id: String,
	from_government: String,
	to_government: String,
	abs_day: int,
	serial: int
) -> int:
	world_seed_hash = 1 if int(world_seed_hash) == 0 else int(world_seed_hash)
	state_id = String(state_id)
	from_government = String(from_government)
	to_government = String(to_government)
	abs_day = max(0, int(abs_day))
	serial = max(0, int(serial))
	var key_root: String = "gov_shift|d=%d|s=%d|id=%s|%s>%s" % [
		abs_day,
		serial,
		state_id,
		from_government,
		to_government,
	]
	var roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|roll")
	var days: int = 0
	if roll < 0.04:
		# Rare fast reform/coup in months.
		days = DeterministicRng.randi_range(world_seed_hash, key_root + "|fast", 60, 270)
	elif roll < 0.70:
		# Typical years.
		days = DeterministicRng.randi_range(world_seed_hash, key_root + "|years", 3 * 365, 15 * 365)
	else:
		# Slow decades.
		days = DeterministicRng.randi_range(world_seed_hash, key_root + "|decades", 16 * 365, 50 * 365)
	return max(45, days)

static func trade_route_capacity_multiplier(epoch_id: String, variant: String = "stable", government: String = "") -> float:
	epoch_id = String(epoch_id)
	variant = String(variant)
	government = String(government).to_lower()
	var mul: float = 1.0
	match epoch_id:
		"prehistoric":
			mul = 0.55
		"ancient":
			mul = 0.70
		"medieval":
			mul = 0.82
		"industrial":
			mul = 1.00
		"modern":
			mul = 1.15
		"space_age":
			mul = 1.30
		"singularity":
			mul = 1.45
		_:
			mul = 1.0

	if variant == "stressed":
		mul *= 0.88
	elif variant == "post_collapse":
		mul *= 0.62

	if government == "federal_union":
		mul *= 1.08
	elif government == "technocracy":
		mul *= 1.06
	elif government == "emergency_regime":
		mul *= 0.90
	elif government == "military_rule":
		mul *= 0.86
	elif government == "warlord_federation":
		mul *= 0.70
	elif government == "post_state":
		mul *= 1.12

	return clamp(mul, 0.20, 2.50)

static func apply_to_politics(pol: Object, epoch_info: Dictionary) -> bool:
	if pol == null:
		return false
	var changed: bool = false
	var eid: String = String(epoch_info.get("epoch_id", "prehistoric"))
	var eidx: int = int(epoch_info.get("epoch_index", 0))
	var gov_hint: String = String(epoch_info.get("government_hint", "tribal"))
	var rigidity: float = clamp(float(epoch_info.get("social_rigidity", 0.5)), 0.0, 1.0)

	var states: Dictionary = pol.states if "states" in pol else {}
	for sid in states.keys():
		var v: Variant = states.get(sid, {})
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = (v as Dictionary).duplicate(true)
		if String(st.get("epoch", "")) != eid:
			st["epoch"] = eid
			changed = true
		if int(st.get("epoch_index", -1)) != eidx:
			st["epoch_index"] = eidx
			changed = true
		if abs(float(st.get("social_rigidity", -1.0)) - rigidity) > 0.0001:
			st["social_rigidity"] = rigidity
			changed = true
		# Keep authored governments unless explicitly unlocked for auto updates.
		# Auto-governments now shift through the politics event layer over time;
		# do not hard-swap each tick here.
		if VariantCasts.to_bool(st.get("government_auto", true)):
			var cur_gov: String = String(st.get("government", ""))
			if cur_gov.is_empty():
				st["government"] = gov_hint
				changed = true
			if String(st.get("government_desired", "")) != gov_hint:
				st["government_desired"] = gov_hint
				changed = true
			if not st.has("government_shift_due_abs_day"):
				st["government_shift_due_abs_day"] = -1
				changed = true
			if not st.has("government_shift_serial"):
				st["government_shift_serial"] = 0
				changed = true
		states[sid] = st
	if changed and "states" in pol:
		pol.states = states
	return changed

static func apply_to_npcs(npc: Object, epoch_info: Dictionary) -> bool:
	if npc == null:
		return false
	var changed: bool = false
	var eid: String = String(epoch_info.get("epoch_id", "prehistoric"))
	var variant: String = String(epoch_info.get("epoch_variant", "stable"))
	var rigidity: float = clamp(float(epoch_info.get("social_rigidity", 0.5)), 0.0, 1.0)

	var entries: Dictionary = npc.important_npcs if "important_npcs" in npc else {}
	for nid in entries.keys():
		var v: Variant = entries.get(nid, {})
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (v as Dictionary).duplicate(true)
		if String(d.get("epoch", "")) != eid:
			d["epoch"] = eid
			changed = true
		if String(d.get("epoch_variant", "")) != variant:
			d["epoch_variant"] = variant
			changed = true
		if abs(float(d.get("social_rigidity", -1.0)) - rigidity) > 0.0001:
			d["social_rigidity"] = rigidity
			changed = true
		entries[nid] = d
	if changed and "important_npcs" in npc:
		npc.important_npcs = entries
	return changed
