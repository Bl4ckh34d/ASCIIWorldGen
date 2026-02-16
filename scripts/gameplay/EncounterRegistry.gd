extends RefCounted
class_name EncounterRegistry

const _SEASON_UNKNOWN: int = -1
const _SEASON_SPRING: int = 0
const _SEASON_SUMMER: int = 1
const _SEASON_AUTUMN: int = 2
const _SEASON_WINTER: int = 3

const _TOD_NIGHT: int = 0
const _TOD_DAWN: int = 1
const _TOD_DAY: int = 2
const _TOD_DUSK: int = 3

static func ensure_danger_meter_state_inplace(state: Dictionary) -> void:
	# State is persisted in GameState.run_flags. Keep it simple and resilient.
	if typeof(state) != TYPE_DICTIONARY:
		return
	var mv: Variant = state.get("meter", null)
	if typeof(mv) == TYPE_INT or typeof(mv) == TYPE_FLOAT:
		state["meter"] = float(mv)
	else:
		state["meter"] = 0.0
	var tv: Variant = state.get("threshold", null)
	if typeof(tv) == TYPE_INT or typeof(tv) == TYPE_FLOAT:
		state["threshold"] = float(tv)
	else:
		state["threshold"] = 0.0
	var sv: Variant = state.get("step_id", null)
	if typeof(sv) == TYPE_INT or typeof(sv) == TYPE_FLOAT:
		state["step_id"] = int(sv)
	else:
		state["step_id"] = 0
	var ev: Variant = state.get("encounter_index", null)
	if typeof(ev) == TYPE_INT or typeof(ev) == TYPE_FLOAT:
		state["encounter_index"] = int(ev)
	else:
		state["encounter_index"] = 0
	var cv: Variant = state.get("cooldown_steps", null)
	if typeof(cv) == TYPE_INT or typeof(cv) == TYPE_FLOAT:
		state["cooldown_steps"] = int(cv)
	else:
		state["cooldown_steps"] = 0

static func reset_danger_meter(world_seed_hash: int, state: Dictionary, world_x: int, world_y: int, biome_id: int, minute_of_day: int = -1, day_of_year: int = -1) -> void:
	# Called after battles (victory/escape) so the next encounter starts from scratch.
	ensure_danger_meter_state_inplace(state)
	state["meter"] = 0.0
	# Small grace period after returning from battle (FF-like feel).
	state["cooldown_steps"] = 3
	state["threshold"] = _roll_next_threshold(world_seed_hash, int(state.get("encounter_index", 0)), world_x, world_y, biome_id, minute_of_day, day_of_year)

static func step_danger_meter_and_maybe_trigger(
	world_seed_hash: int,
	state: Dictionary,
	world_x: int,
	world_y: int,
	local_x: int,
	local_y: int,
	biome_id: int,
	biome_name: String,
	encounter_rate_multiplier: float = 1.0,
	minute_of_day: int = -1,
	day_of_year: int = -1
) -> Dictionary:
	# FF-style: meter fills each step, triggers when it crosses a randomized threshold.
	# All randomness is deterministic from (world_seed_hash + encounter_index + step_id).
	ensure_danger_meter_state_inplace(state)
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
	var time_ctx: Dictionary = _build_time_context(minute_of_day, day_of_year)
	var tod_bucket: int = int(time_ctx.get("tod_bucket", _TOD_DAY))
	var season_bucket: int = int(time_ctx.get("season_bucket", _SEASON_UNKNOWN))
	var step_id: int = int(state.get("step_id", 0)) + 1
	state["step_id"] = step_id
	if biome_id == 0 or biome_id == 1:
		return {}
	var cooldown_steps: int = max(0, int(state.get("cooldown_steps", 0)))
	if cooldown_steps > 0:
		state["cooldown_steps"] = cooldown_steps - 1
		return {}
	var enc_index: int = max(0, int(state.get("encounter_index", 0)))
	if float(state.get("threshold", 0.0)) <= 0.0:
		state["threshold"] = _roll_next_threshold(world_seed_hash, enc_index, world_x, world_y, biome_id, minute_of_day, day_of_year)
	var gain: float = _danger_gain_for_biome(biome_id)
	gain *= _tod_gain_multiplier(tod_bucket)
	gain *= _season_gain_multiplier(biome_id, season_bucket)
	gain *= clamp(encounter_rate_multiplier, 0.10, 2.00)
	# Per-step gain jitter to avoid overly regular cadence.
	var gain_key: String = "enc_gain|%d|%d|%d|%d|%d|tod=%d|sea=%d|s=%d" % [world_x, world_y, local_x, local_y, biome_id, tod_bucket, season_bucket, step_id]
	var jitter: float = lerp(0.85, 1.15, DeterministicRng.randf01(world_seed_hash, gain_key))
	gain *= jitter
	state["meter"] = float(state.get("meter", 0.0)) + gain
	if float(state["meter"]) < float(state.get("threshold", 1.0)):
		return {}

	# Trigger encounter and prepare next cycle.
	state["meter"] = 0.0
	state["encounter_index"] = enc_index + 1
	state["threshold"] = _roll_next_threshold(world_seed_hash, int(state["encounter_index"]), world_x, world_y, biome_id, minute_of_day, day_of_year)

	var key_root: String = "enc|%d|%d|%d|%d|%d|i=%d|tod=%d|sea=%d" % [world_x, world_y, local_x, local_y, biome_id, enc_index, tod_bucket, season_bucket]
	return _build_encounter_from_key(world_seed_hash, key_root, world_x, world_y, local_x, local_y, biome_id, biome_name, time_ctx, encounter_rate_multiplier)

static func roll_step_encounter(
	world_seed_hash: int,
	world_x: int,
	world_y: int,
	local_x: int,
	local_y: int,
	biome_id: int,
	biome_name: String,
	encounter_rate_multiplier: float = 1.0,
	minute_of_day: int = -1,
	day_of_year: int = -1
) -> Dictionary:
	if biome_id == 0 or biome_id == 1:
		return {}
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
	var time_ctx: Dictionary = _build_time_context(minute_of_day, day_of_year)
	var tod_bucket: int = int(time_ctx.get("tod_bucket", _TOD_DAY))
	var season_bucket: int = int(time_ctx.get("season_bucket", _SEASON_UNKNOWN))
	var chance: float = 0.040
	if _is_forest_biome(biome_id):
		chance = 0.090
	elif _is_mountain_biome(biome_id):
		chance = 0.070
	elif _is_desert_biome(biome_id):
		chance = 0.060
	chance *= _tod_gain_multiplier(tod_bucket)
	chance *= _season_gain_multiplier(biome_id, season_bucket)
	chance = clamp(chance * clamp(encounter_rate_multiplier, 0.10, 2.00), 0.0, 0.95)
	var key_root: String = "enc|%d|%d|%d|%d|%d|tod=%d|sea=%d" % [world_x, world_y, local_x, local_y, biome_id, tod_bucket, season_bucket]
	var roll: float = DeterministicRng.randf01(world_seed_hash, key_root)
	if roll > chance:
		return {}
	return _build_encounter_from_key(world_seed_hash, key_root, world_x, world_y, local_x, local_y, biome_id, biome_name, time_ctx, encounter_rate_multiplier)

static func _build_encounter_from_key(
	world_seed_hash: int,
	key_root: String,
	world_x: int,
	world_y: int,
	local_x: int,
	local_y: int,
	biome_id: int,
	biome_name: String,
	time_ctx: Dictionary,
	encounter_rate_multiplier: float
) -> Dictionary:
	var is_night: bool = VariantCasts.to_bool(time_ctx.get("is_night", false))
	var tod_bucket: int = int(time_ctx.get("tod_bucket", _TOD_DAY))
	var season_bucket: int = int(time_ctx.get("season_bucket", _SEASON_UNKNOWN))
	var season_name: String = String(time_ctx.get("season_name", "Unknown"))
	var minute: int = int(time_ctx.get("minute_of_day", 12 * 60))
	var day_idx: int = int(time_ctx.get("day_of_year", -1))
	var opener_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|opener")
	var opener: String = "normal"
	if opener_roll <= 0.08:
		opener = "preemptive"
	elif opener_roll <= (0.20 if is_night or tod_bucket == _TOD_DUSK else 0.14):
		opener = "back_attack"
	var enemy_seed_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|enemy")
	var enemy_data: Dictionary = EnemyCatalog.encounter_for_biome(biome_id, enemy_seed_roll, time_ctx)
	var enemy_group: String = String(enemy_data.get("group", "Wild Beasts"))
	var enemy_profile_id: String = String(enemy_data.get("profile_id", ""))
	var enemy_tags: Array[String] = []
	var tv: Variant = enemy_data.get("tags", [])
	if typeof(tv) == TYPE_ARRAY or typeof(tv) == TYPE_PACKED_STRING_ARRAY:
		for tag_v in tv:
			var tag_s: String = String(tag_v).strip_edges().to_lower()
			if tag_s.is_empty():
				continue
			enemy_tags.append(tag_s)
	var enemy_resist: Dictionary = {}
	var rv: Variant = enemy_data.get("resist", {})
	if typeof(rv) == TYPE_DICTIONARY:
		enemy_resist = (rv as Dictionary).duplicate(true)
	var enemy_actions: Array[Dictionary] = []
	var av: Variant = enemy_data.get("actions", [])
	if typeof(av) == TYPE_ARRAY:
		for act_v in av:
			if typeof(act_v) != TYPE_DICTIONARY:
				continue
			enemy_actions.append((act_v as Dictionary).duplicate(true))
	var count_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|count")
	var enemy_count: int = 1
	if count_roll <= 0.20:
		enemy_count = 3
	elif count_roll <= 0.55:
		enemy_count = 2
	var pack_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|pack")
	if enemy_count < 3 and pack_roll <= _pack_bonus_chance(biome_id, tod_bucket, season_bucket):
		enemy_count += 1
	var enemy_power: int = max(4, int(enemy_data.get("power", 8))) + DeterministicRng.randi_range(world_seed_hash, key_root + "|pow", 0, 4)
	enemy_power += _power_bonus_for_context(biome_id, tod_bucket, season_bucket)
	enemy_power = max(4, enemy_power)
	var enemy_base_hp: int = max(16, int(enemy_data.get("base_hp", 28)))
	var exp_reward: int = 14 + enemy_power * 2
	var gold_reward: int = 8 + DeterministicRng.randi_range(world_seed_hash, key_root + "|gold", 0, 12)
	var items: Array = _roll_item_rewards(world_seed_hash, key_root, enemy_power, tod_bucket, season_bucket)
	var flee_chance: float = 0.55
	if _is_forest_biome(biome_id):
		flee_chance = 0.48
	elif _is_mountain_biome(biome_id):
		flee_chance = 0.34
	elif _is_desert_biome(biome_id):
		flee_chance = 0.50
	elif biome_id == 10 or biome_id == 23:
		flee_chance = 0.42
	flee_chance *= _flee_context_multiplier(biome_id, tod_bucket, season_bucket)
	flee_chance = clamp(flee_chance, 0.05, 0.95)
	# Encounter rate multiplier should not affect composition directly, but keep it in the seed key for determinism
	# across different settings if players change encounter rate mid-run.
	return {
		"encounter_seed_key": "%s|rate=%.2f" % [key_root, float(clamp(encounter_rate_multiplier, 0.10, 2.00))],
		"world_x": world_x,
		"world_y": world_y,
		"local_x": local_x,
		"local_y": local_y,
		"biome_id": biome_id,
		"biome_name": biome_name,
		"return_scene": "regional",
		"is_night": is_night,
		"time_bucket": _tod_bucket_name(tod_bucket),
		"season_bucket": season_bucket,
		"season_name": season_name,
		"minute_of_day": minute,
		"day_of_year": day_idx,
		"enemy_profile_id": enemy_profile_id,
		"enemy_tags": enemy_tags,
		"enemy_resist": enemy_resist,
		"enemy_actions": enemy_actions,
		"opener": opener,
		"enemy_group": enemy_group,
		"enemy_count": enemy_count,
		"enemy_power": enemy_power,
		"enemy_hp": (enemy_base_hp + enemy_power * 2) * enemy_count,
		"flee_chance": flee_chance,
		"rewards": {
			"exp": exp_reward,
			"gold": gold_reward,
			"items": items,
		}
	}

static func _danger_gain_for_biome(biome_id: int) -> float:
	# Calibrated for a lower encounter cadence on the 1m regional map (at x1.0 rate):
	# default ~200+ steps, forests ~140-180, mountains ~160-210, deserts ~170-220.
	if _is_forest_biome(biome_id):
		return 0.011
	if _is_mountain_biome(biome_id):
		return 0.010
	if _is_desert_biome(biome_id):
		return 0.0095
	return 0.0085

static func _roll_next_threshold(world_seed_hash: int, encounter_index: int, world_x: int, world_y: int, biome_id: int, minute_of_day: int, day_of_year: int = -1) -> float:
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
	encounter_index = max(0, encounter_index)
	var time_ctx: Dictionary = _build_time_context(minute_of_day, day_of_year)
	var tod_bucket: int = int(time_ctx.get("tod_bucket", _TOD_DAY))
	var season_bucket: int = int(time_ctx.get("season_bucket", _SEASON_UNKNOWN))
	var tmin: float = 1.60
	var tmax: float = 2.20
	if _is_forest_biome(biome_id):
		tmin = 1.50
		tmax = 2.10
	elif _is_mountain_biome(biome_id):
		tmin = 1.60
		tmax = 2.40
	elif _is_desert_biome(biome_id):
		tmin = 1.65
		tmax = 2.35
	tmin *= _tod_threshold_multiplier(tod_bucket)
	tmax *= _tod_threshold_multiplier(tod_bucket)
	tmin *= _season_threshold_multiplier(biome_id, season_bucket)
	tmax *= _season_threshold_multiplier(biome_id, season_bucket)
	var key: String = "enc_thr|%d|%d|%d|i=%d|tod=%d|sea=%d" % [world_x, world_y, biome_id, encounter_index, tod_bucket, season_bucket]
	return lerp(tmin, tmax, DeterministicRng.randf01(world_seed_hash, key))

static func _build_time_context(minute_of_day: int, day_of_year: int) -> Dictionary:
	var minute_norm: int = posmod(minute_of_day, 24 * 60) if minute_of_day >= 0 else 12 * 60
	var tod_bucket: int = _TOD_DAY
	if minute_norm < 5 * 60 or minute_norm >= 21 * 60:
		tod_bucket = _TOD_NIGHT
	elif minute_norm < 8 * 60:
		tod_bucket = _TOD_DAWN
	elif minute_norm < 18 * 60:
		tod_bucket = _TOD_DAY
	else:
		tod_bucket = _TOD_DUSK
	var season_bucket: int = _season_bucket_from_day(day_of_year)
	return {
		"minute_of_day": minute_norm,
		"tod_bucket": tod_bucket,
		"is_night": tod_bucket == _TOD_NIGHT,
		"season_bucket": season_bucket,
		"season_name": _season_name(season_bucket),
		"day_of_year": day_of_year if day_of_year >= 0 else -1,
	}

static func _tod_gain_multiplier(tod_bucket: int) -> float:
	match tod_bucket:
		_TOD_NIGHT:
			return 1.16
		_TOD_DAWN:
			return 1.05
		_TOD_DUSK:
			return 1.10
		_:
			return 0.92

static func _tod_threshold_multiplier(tod_bucket: int) -> float:
	match tod_bucket:
		_TOD_NIGHT:
			return 0.96
		_TOD_DAWN:
			return 0.99
		_TOD_DUSK:
			return 0.98
		_:
			return 1.04

static func _season_gain_multiplier(biome_id: int, season_bucket: int) -> float:
	if season_bucket == _SEASON_UNKNOWN:
		return 1.0
	if _is_forest_biome(biome_id):
		match season_bucket:
			_SEASON_SPRING:
				return 1.08
			_SEASON_SUMMER:
				return 1.12
			_SEASON_AUTUMN:
				return 1.00
			_SEASON_WINTER:
				return 0.86
	if _is_mountain_biome(biome_id):
		match season_bucket:
			_SEASON_SPRING:
				return 1.00
			_SEASON_SUMMER:
				return 1.02
			_SEASON_AUTUMN:
				return 1.06
			_SEASON_WINTER:
				return 1.16
	if _is_desert_biome(biome_id):
		match season_bucket:
			_SEASON_SPRING:
				return 0.96
			_SEASON_SUMMER:
				return 1.18
			_SEASON_AUTUMN:
				return 1.04
			_SEASON_WINTER:
				return 0.90
	if biome_id == 10 or biome_id == 17 or biome_id == 23:
		match season_bucket:
			_SEASON_SPRING:
				return 1.06
			_SEASON_SUMMER:
				return 1.08
			_SEASON_AUTUMN:
				return 1.00
			_SEASON_WINTER:
				return 0.88
	match season_bucket:
		_SEASON_SPRING:
			return 1.02
		_SEASON_SUMMER:
			return 1.04
		_SEASON_AUTUMN:
			return 1.00
		_SEASON_WINTER:
			return 0.94
		_:
			return 1.0

static func _season_threshold_multiplier(biome_id: int, season_bucket: int) -> float:
	var g: float = _season_gain_multiplier(biome_id, season_bucket)
	# Keep threshold modulation mild to avoid large cadence swings.
	return lerp(1.02, 0.98, clamp((g - 0.85) / 0.35, 0.0, 1.0))

static func _power_bonus_for_context(biome_id: int, tod_bucket: int, season_bucket: int) -> int:
	var bonus: int = 0
	match tod_bucket:
		_TOD_NIGHT:
			bonus += 2
		_TOD_DUSK:
			bonus += 1
		_:
			pass
	if season_bucket == _SEASON_WINTER and (_is_forest_biome(biome_id) or _is_mountain_biome(biome_id)):
		bonus += 1
	if season_bucket == _SEASON_SUMMER and _is_desert_biome(biome_id):
		bonus += 1
	return bonus

static func _pack_bonus_chance(biome_id: int, tod_bucket: int, season_bucket: int) -> float:
	var chance: float = 0.0
	match tod_bucket:
		_TOD_NIGHT:
			chance += 0.10
		_TOD_DUSK:
			chance += 0.06
		_TOD_DAWN:
			chance += 0.03
		_:
			pass
	if season_bucket == _SEASON_SUMMER and _is_desert_biome(biome_id):
		chance += 0.07
	if season_bucket == _SEASON_WINTER and _is_mountain_biome(biome_id):
		chance += 0.06
	if season_bucket == _SEASON_SPRING and _is_forest_biome(biome_id):
		chance += 0.04
	return clamp(chance, 0.0, 0.25)

static func _flee_context_multiplier(biome_id: int, tod_bucket: int, season_bucket: int) -> float:
	var mult: float = 1.0
	match tod_bucket:
		_TOD_NIGHT:
			mult *= 0.85
		_TOD_DUSK:
			mult *= 0.92
		_TOD_DAWN:
			mult *= 0.96
		_:
			pass
	if season_bucket == _SEASON_WINTER:
		mult *= 0.93
	if season_bucket == _SEASON_SUMMER and _is_desert_biome(biome_id):
		mult *= 0.90
	return clamp(mult, 0.55, 1.15)

static func _drop_tier_for_encounter(enemy_power: int, tod_bucket: int, season_bucket: int) -> int:
	var tier: int = 1 + int(floor(max(0.0, float(enemy_power - 6)) / 5.0))
	if tod_bucket == _TOD_NIGHT:
		tier += 1
	elif tod_bucket == _TOD_DUSK:
		tier += 1
	if season_bucket == _SEASON_WINTER:
		tier += 1
	return clamp(tier, 1, 4)

static func _roll_item_rewards(world_seed_hash: int, key_root: String, enemy_power: int, tod_bucket: int, season_bucket: int) -> Array:
	var items: Array = []
	var item_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|item")
	var drop_tier: int = _drop_tier_for_encounter(enemy_power, tod_bucket, season_bucket)
	var consumables: Array[String] = ItemCatalog.items_up_to_tier(drop_tier, ["consumable"])
	var stronger_consumables: Array[String] = ItemCatalog.items_up_to_tier(min(4, drop_tier + 1), ["consumable"])
	var equipment: Array[String] = ItemCatalog.items_up_to_tier(max(1, drop_tier - 1), ["weapon", "armor", "accessory"])
	if item_roll <= 0.32:
		var c_name: String = _pick_item_from_pool(world_seed_hash, key_root + "|item_cons", consumables, "Potion")
		if ItemCatalog.has_item(c_name):
			var ci: Dictionary = ItemCatalog.get_item(c_name)
			var c_count: int = 1
			if VariantCasts.to_bool(ci.get("stackable", true)):
				var extra_max: int = max(0, 2 - int(int(ci.get("tier", 1)) / 2.0))
				c_count = 1 + DeterministicRng.randi_range(world_seed_hash, key_root + "|item_cons_count", 0, extra_max)
			items.append({"name": c_name, "count": max(1, c_count)})
	elif item_roll <= 0.42:
		var c2_name: String = _pick_item_from_pool(world_seed_hash, key_root + "|item_cons_rare", stronger_consumables, "Hi-Potion")
		if ItemCatalog.has_item(c2_name):
			items.append({"name": c2_name, "count": 1})
	elif item_roll <= 0.48 and enemy_power >= 10:
		var e_name: String = _pick_item_from_pool(world_seed_hash, key_root + "|item_equip", equipment, "")
		if not e_name.is_empty() and ItemCatalog.has_item(e_name):
			items.append({"name": e_name, "count": 1})
	return items

static func _pick_item_from_pool(world_seed_hash: int, key: String, pool: Array[String], fallback: String) -> String:
	if pool.is_empty():
		return fallback
	var sorted: Array[String] = pool.duplicate()
	sorted.sort_custom(func(a: String, b: String) -> bool:
		var ia: Dictionary = ItemCatalog.get_item(a)
		var ib: Dictionary = ItemCatalog.get_item(b)
		var ta: int = int(ia.get("tier", 1))
		var tb: int = int(ib.get("tier", 1))
		if ta == tb:
			return a < b
		return ta < tb
	)
	var idx: int = DeterministicRng.randi_range(world_seed_hash, key, 0, sorted.size() - 1)
	var out: String = String(sorted[idx])
	if not ItemCatalog.has_item(out):
		return fallback
	return out

static func _tod_bucket_name(tod_bucket: int) -> String:
	match tod_bucket:
		_TOD_NIGHT:
			return "Night"
		_TOD_DAWN:
			return "Dawn"
		_TOD_DUSK:
			return "Dusk"
		_:
			return "Day"

static func _season_bucket_from_day(day_of_year: int) -> int:
	if day_of_year < 0:
		return _SEASON_UNKNOWN
	var d: int = posmod(day_of_year, 365)
	if d < 91:
		return _SEASON_SPRING
	if d < 182:
		return _SEASON_SUMMER
	if d < 273:
		return _SEASON_AUTUMN
	return _SEASON_WINTER

static func _season_name(season_bucket: int) -> String:
	match season_bucket:
		_SEASON_SPRING:
			return "Spring"
		_SEASON_SUMMER:
			return "Summer"
		_SEASON_AUTUMN:
			return "Autumn"
		_SEASON_WINTER:
			return "Winter"
		_:
			return "Unknown"

static func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

static func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

static func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28
