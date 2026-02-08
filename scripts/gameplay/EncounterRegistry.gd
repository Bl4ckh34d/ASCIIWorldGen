extends RefCounted
class_name EncounterRegistry

const DeterministicRng = preload("res://scripts/gameplay/DeterministicRng.gd")
const EnemyCatalog = preload("res://scripts/gameplay/catalog/EnemyCatalog.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")

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

static func reset_danger_meter(world_seed_hash: int, state: Dictionary, world_x: int, world_y: int, biome_id: int, minute_of_day: int = -1) -> void:
	# Called after battles (victory/escape) so the next encounter starts from scratch.
	ensure_danger_meter_state_inplace(state)
	state["meter"] = 0.0
	# Small grace period after returning from battle (FF-like feel).
	state["cooldown_steps"] = 3
	state["threshold"] = _roll_next_threshold(world_seed_hash, int(state.get("encounter_index", 0)), world_x, world_y, biome_id, minute_of_day)

static func step_danger_meter_and_maybe_trigger(world_seed_hash: int, state: Dictionary, world_x: int, world_y: int, local_x: int, local_y: int, biome_id: int, biome_name: String, encounter_rate_multiplier: float = 1.0, minute_of_day: int = -1) -> Dictionary:
	# FF-style: meter fills each step, triggers when it crosses a randomized threshold.
	# All randomness is deterministic from (world_seed_hash + encounter_index + step_id).
	ensure_danger_meter_state_inplace(state)
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
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
		state["threshold"] = _roll_next_threshold(world_seed_hash, enc_index, world_x, world_y, biome_id, minute_of_day)
	var m: int = posmod(minute_of_day, 24 * 60) if minute_of_day >= 0 else 12 * 60
	var is_night: bool = (m < 6 * 60) or (m >= 20 * 60)
	var gain: float = _danger_gain_for_biome(biome_id)
	if is_night:
		gain *= 1.15
	gain *= clamp(encounter_rate_multiplier, 0.10, 2.00)
	# Per-step gain jitter to avoid overly regular cadence.
	var gain_key: String = "enc_gain|%d|%d|%d|%d|%d|s=%d" % [world_x, world_y, local_x, local_y, biome_id, step_id]
	var jitter: float = lerp(0.85, 1.15, DeterministicRng.randf01(world_seed_hash, gain_key))
	gain *= jitter
	state["meter"] = float(state.get("meter", 0.0)) + gain
	if float(state["meter"]) < float(state.get("threshold", 1.0)):
		return {}

	# Trigger encounter and prepare next cycle.
	state["meter"] = 0.0
	state["encounter_index"] = enc_index + 1
	state["threshold"] = _roll_next_threshold(world_seed_hash, int(state["encounter_index"]), world_x, world_y, biome_id, minute_of_day)

	var key_root: String = "enc|%d|%d|%d|%d|%d|i=%d" % [world_x, world_y, local_x, local_y, biome_id, enc_index]
	return _build_encounter_from_key(world_seed_hash, key_root, world_x, world_y, local_x, local_y, biome_id, biome_name, is_night, encounter_rate_multiplier)

static func roll_step_encounter(world_seed_hash: int, world_x: int, world_y: int, local_x: int, local_y: int, biome_id: int, biome_name: String, encounter_rate_multiplier: float = 1.0, minute_of_day: int = -1) -> Dictionary:
	if biome_id == 0 or biome_id == 1:
		return {}
	var chance: float = 0.040
	if _is_forest_biome(biome_id):
		chance = 0.090
	elif _is_mountain_biome(biome_id):
		chance = 0.070
	elif _is_desert_biome(biome_id):
		chance = 0.060
	var is_night: bool = false
	if minute_of_day >= 0:
		var m: int = posmod(minute_of_day, 24 * 60)
		is_night = (m < 6 * 60) or (m >= 20 * 60)
		if is_night:
			# Minimal night modifier: slightly more encounters and tougher groups.
			chance *= 1.15
	chance = clamp(chance * clamp(encounter_rate_multiplier, 0.10, 2.00), 0.0, 0.95)
	var key_root: String = "enc|%d|%d|%d|%d|%d" % [world_x, world_y, local_x, local_y, biome_id]
	var roll: float = DeterministicRng.randf01(world_seed_hash, key_root)
	if roll > chance:
		return {}
	var opener_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|opener")
	var opener: String = "normal"
	if opener_roll <= 0.08:
		opener = "preemptive"
	elif opener_roll <= (0.18 if is_night else 0.14):
		opener = "back_attack"
	var enemy_seed_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|enemy")
	var enemy_data: Dictionary = EnemyCatalog.encounter_for_biome(biome_id, enemy_seed_roll)
	var enemy_group: String = String(enemy_data.get("group", "Wild Beasts"))
	var count_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|count")
	var enemy_count: int = 1
	if count_roll <= 0.20:
		enemy_count = 3
	elif count_roll <= 0.55:
		enemy_count = 2
	var enemy_power: int = max(4, int(enemy_data.get("power", 8))) + DeterministicRng.randi_range(world_seed_hash, key_root + "|pow", 0, 4)
	if is_night:
		enemy_power += 2
	var enemy_base_hp: int = max(16, int(enemy_data.get("base_hp", 28)))
	var exp_reward: int = 14 + enemy_power * 2
	var gold_reward: int = 8 + DeterministicRng.randi_range(world_seed_hash, key_root + "|gold", 0, 12)
	var item_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|item")
	var items: Array = []
	if item_roll <= 0.28:
		if ItemCatalog.has_item("Herb"):
			items.append({"name": "Herb", "count": 1})
	elif item_roll <= 0.38:
		if ItemCatalog.has_item("Potion"):
			items.append({"name": "Potion", "count": 1})
	var flee_chance: float = 0.55
	if _is_forest_biome(biome_id):
		flee_chance = 0.48
	elif _is_mountain_biome(biome_id):
		flee_chance = 0.34
	elif _is_desert_biome(biome_id):
		flee_chance = 0.50
	elif biome_id == 10 or biome_id == 23:
		flee_chance = 0.42
	if is_night:
		flee_chance *= 0.85
	return {
		"encounter_seed_key": key_root,
		"world_x": world_x,
		"world_y": world_y,
		"local_x": local_x,
		"local_y": local_y,
		"biome_id": biome_id,
		"biome_name": biome_name,
		"return_scene": "regional",
		"is_night": is_night,
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

static func _build_encounter_from_key(world_seed_hash: int, key_root: String, world_x: int, world_y: int, local_x: int, local_y: int, biome_id: int, biome_name: String, is_night: bool, encounter_rate_multiplier: float) -> Dictionary:
	var opener_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|opener")
	var opener: String = "normal"
	if opener_roll <= 0.08:
		opener = "preemptive"
	elif opener_roll <= (0.18 if is_night else 0.14):
		opener = "back_attack"
	var enemy_seed_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|enemy")
	var enemy_data: Dictionary = EnemyCatalog.encounter_for_biome(biome_id, enemy_seed_roll)
	var enemy_group: String = String(enemy_data.get("group", "Wild Beasts"))
	var count_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|count")
	var enemy_count: int = 1
	if count_roll <= 0.20:
		enemy_count = 3
	elif count_roll <= 0.55:
		enemy_count = 2
	var enemy_power: int = max(4, int(enemy_data.get("power", 8))) + DeterministicRng.randi_range(world_seed_hash, key_root + "|pow", 0, 4)
	if is_night:
		enemy_power += 2
	var enemy_base_hp: int = max(16, int(enemy_data.get("base_hp", 28)))
	var exp_reward: int = 14 + enemy_power * 2
	var gold_reward: int = 8 + DeterministicRng.randi_range(world_seed_hash, key_root + "|gold", 0, 12)
	var item_roll: float = DeterministicRng.randf01(world_seed_hash, key_root + "|item")
	var items: Array = []
	if item_roll <= 0.28:
		if ItemCatalog.has_item("Herb"):
			items.append({"name": "Herb", "count": 1})
	elif item_roll <= 0.38:
		if ItemCatalog.has_item("Potion"):
			items.append({"name": "Potion", "count": 1})
	var flee_chance: float = 0.55
	if _is_forest_biome(biome_id):
		flee_chance = 0.48
	elif _is_mountain_biome(biome_id):
		flee_chance = 0.34
	elif _is_desert_biome(biome_id):
		flee_chance = 0.50
	elif biome_id == 10 or biome_id == 23:
		flee_chance = 0.42
	if is_night:
		flee_chance *= 0.85
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

static func _roll_next_threshold(world_seed_hash: int, encounter_index: int, world_x: int, world_y: int, biome_id: int, minute_of_day: int) -> float:
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
	encounter_index = max(0, encounter_index)
	var m: int = posmod(minute_of_day, 24 * 60) if minute_of_day >= 0 else 12 * 60
	var is_night: bool = (m < 6 * 60) or (m >= 20 * 60)
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
	if is_night:
		# Slightly shorter thresholds at night on top of gain scaling.
		tmin *= 0.97
		tmax *= 0.97
	var key: String = "enc_thr|%d|%d|%d|i=%d|n=%d" % [world_x, world_y, biome_id, encounter_index, 1 if is_night else 0]
	return lerp(tmin, tmax, DeterministicRng.randf01(world_seed_hash, key))

static func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

static func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

static func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28
