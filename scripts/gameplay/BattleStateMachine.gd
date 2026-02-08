extends RefCounted
class_name BattleStateMachine

const DeterministicRng = preload("res://scripts/gameplay/DeterministicRng.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")
const SpellCatalog = preload("res://scripts/gameplay/catalog/SpellCatalog.gd")

enum Phase {
	INIT,
	SELECT_COMMANDS,
	RESOLVING,
	RESOLVED,
}

var phase: int = Phase.INIT
var encounter: Dictionary = {}
var opener: String = "normal" # normal|preemptive|back_attack
var turn_index: int = 1

var party: Array[Dictionary] = []
var enemies: Array[Dictionary] = []

var inventory: Dictionary = {}
var _consumed_items: Array[Dictionary] = [] # drained by BattleScene to mutate GameState inventory

var _select_indices: PackedInt32Array = PackedInt32Array()
var _select_pos: int = 0
var _queued_commands: Dictionary = {} # member_id -> cmd_id

var result: Dictionary = {}

func begin(encounter_data: Dictionary, party_state: Variant) -> void:
	encounter = encounter_data.duplicate(true)
	opener = String(encounter.get("opener", "normal"))
	turn_index = 1
	phase = Phase.INIT
	result.clear()
	_consumed_items.clear()
	_party_from_state(party_state)
	_inventory_from_state(party_state)
	_enemies_from_encounter(encounter)
	_reset_selection()
	phase = Phase.SELECT_COMMANDS

func can_accept_input() -> bool:
	return phase == Phase.SELECT_COMMANDS

func current_member() -> Dictionary:
	if _select_pos < 0 or _select_pos >= _select_indices.size():
		return {}
	var idx: int = int(_select_indices[_select_pos])
	if idx < 0 or idx >= party.size():
		return {}
	return party[idx]

func get_state_summary() -> Dictionary:
	var p_hp: int = 0
	var p_hp_max: int = 0
	for m in party:
		p_hp += max(0, int(m.get("hp", 0)))
		p_hp_max += max(0, int(m.get("hp_max", 0)))
	var e_hp: int = 0
	var e_hp_max: int = 0
	for e in enemies:
		e_hp += max(0, int(e.get("hp", 0)))
		e_hp_max += max(0, int(e.get("hp_max", 0)))
	var cur: Dictionary = current_member()
	return {
		"phase": phase,
		"turn_index": turn_index,
		"opener": opener,
		"party_hp": p_hp,
		"party_hp_max": p_hp_max,
		"enemy_hp": e_hp,
		"enemy_hp_max": e_hp_max,
		"party": _actors_summary(party),
		"enemies": _actors_summary(enemies),
		"select_member_id": String(cur.get("id", "")),
		"select_member_name": String(cur.get("name", "")),
	}

func apply_player_command(command_id: String) -> Dictionary:
	if not can_accept_input():
		return {
			"ok": false,
			"logs": PackedStringArray(["Battle already resolved."]),
			"resolved": true,
		}
	var logs: PackedStringArray = PackedStringArray()
	var raw_cmd: String = String(command_id)
	var parsed: Dictionary = _parse_command(raw_cmd)
	var cmd: String = String(parsed.get("cmd", "attack"))
	var cur: Dictionary = current_member()
	if cur.is_empty():
		_resolve(false, false)
		return {"ok": false, "logs": PackedStringArray(["No active party member."]), "resolved": true, "result": result.duplicate(true)}
	var member_id: String = String(cur.get("id", ""))
	if cmd == "flee":
		var flee_out: Dictionary = _attempt_flee()
		logs.append_array(flee_out.get("logs", PackedStringArray()))
		if bool(flee_out.get("resolved", false)):
			return {"ok": true, "logs": logs, "resolved": true, "result": result.duplicate(true)}
		# Flee failed: enemies get a response action, then restart selection.
		logs.append_array(_enemy_only_response())
		_reset_selection()
		turn_index += 1
		return {"ok": true, "logs": logs, "resolved": false, "state": get_state_summary()}
	_queued_commands[member_id] = raw_cmd
	var label_cmd: String = cmd.capitalize()
	var arg: String = String(parsed.get("arg", ""))
	if cmd == "item" and not arg.is_empty():
		label_cmd = "Item (%s)" % arg
	if cmd == "magic" and not arg.is_empty():
		label_cmd = "Magic (%s)" % arg
	logs.append("%s selected %s." % [String(cur.get("name", "Member")), label_cmd])
	_advance_selection()
	if can_accept_input():
		var next_m: Dictionary = current_member()
		logs.append("Choose command for %s." % String(next_m.get("name", "Member")))
		return {"ok": true, "logs": logs, "resolved": false, "state": get_state_summary(), "consumed_items": drain_consumed_items()}
	# Resolve full round once all living members chose actions.
	phase = Phase.RESOLVING
	logs.append_array(_resolve_round())
	if phase == Phase.RESOLVED:
		return {"ok": true, "logs": logs, "resolved": true, "result": result.duplicate(true), "consumed_items": drain_consumed_items()}
	turn_index += 1
	_reset_selection()
	logs.append("Choose command for %s." % String(current_member().get("name", "Member")))
	return {"ok": true, "logs": logs, "resolved": false, "state": get_state_summary(), "consumed_items": drain_consumed_items()}

func drain_consumed_items() -> Array[Dictionary]:
	if _consumed_items.is_empty():
		return []
	var out: Array[Dictionary] = _consumed_items.duplicate(true)
	_consumed_items.clear()
	return out

func _actors_summary(actors: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for a in actors:
		out.append({
			"id": String(a.get("id", "")),
			"name": String(a.get("name", "")),
			"hp": int(a.get("hp", 0)),
			"hp_max": int(a.get("hp_max", 0)),
			"mp": int(a.get("mp", 0)),
			"mp_max": int(a.get("mp_max", 0)),
			"alive": int(a.get("hp", 0)) > 0,
		})
	return out

func _party_from_state(party_state: Variant) -> void:
	party.clear()
	if party_state == null:
		party = [
			{"id": "hero", "name": "Hero", "hp": 42, "hp_max": 42, "agi": 7, "str": 8, "def": 6, "int": 6},
		]
		return
	# We accept either PartyStateModel or a plain Dictionary snapshot.
	if typeof(party_state) == TYPE_DICTIONARY:
		var members: Array = party_state.get("members", [])
		for entry in members:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var eq_bonus: Dictionary = _sum_equipment_bonuses_from_dict(entry.get("equipment", {}))
			var idv: String = String(entry.get("member_id", "member"))
			party.append({
				"id": idv,
				"name": String(entry.get("display_name", idv)),
				"hp": int(entry.get("hp", 30)),
				"hp_max": int(entry.get("max_hp", 30)),
				"mp": int(entry.get("mp", 0)),
				"mp_max": int(entry.get("max_mp", 0)),
				"str": int(entry.get("strength", 6)) + int(eq_bonus.get("strength", 0)),
				"def": int(entry.get("defense", 5)) + int(eq_bonus.get("defense", 0)),
				"agi": int(entry.get("agility", 6)) + int(eq_bonus.get("agility", 0)),
				"int": int(entry.get("intellect", 6)) + int(eq_bonus.get("intellect", 0)),
			})
		return
	# PartyStateModel instance: prefer converting to a Dictionary snapshot.
	if typeof(party_state) == TYPE_OBJECT and party_state != null and party_state.has_method("to_dict"):
		_party_from_state(party_state.to_dict())
	if party.is_empty():
		party = [
			{"id": "hero", "name": "Hero", "hp": 42, "hp_max": 42, "agi": 7, "str": 8, "def": 6, "int": 6},
		]

func _inventory_from_state(party_state: Variant) -> void:
	inventory.clear()
	if party_state == null:
		return
	if typeof(party_state) == TYPE_DICTIONARY:
		inventory = party_state.get("inventory", {}).duplicate(true)
		return
	if typeof(party_state) == TYPE_OBJECT and party_state != null and party_state.has_method("to_dict"):
		_inventory_from_state(party_state.to_dict())

func _sum_equipment_bonuses_from_dict(equipment: Variant) -> Dictionary:
	var bonus: Dictionary = {
		"strength": 0,
		"defense": 0,
		"agility": 0,
		"intellect": 0,
	}
	if typeof(equipment) != TYPE_DICTIONARY:
		return bonus
	var eq: Dictionary = equipment
	for slot in ["weapon", "armor", "accessory"]:
		var item_name: String = String(eq.get(slot, ""))
		if item_name.is_empty():
			continue
		var item_data: Dictionary = ItemCatalog.get_item(item_name)
		var stats: Dictionary = item_data.get("stat_bonuses", {})
		for k in stats.keys():
			var key: String = String(k)
			if bonus.has(key):
				bonus[key] = int(bonus.get(key, 0)) + int(stats.get(k, 0))
	return bonus

func _parse_command(raw_cmd: String) -> Dictionary:
	var cmd: String = String(raw_cmd).strip_edges()
	if cmd.is_empty():
		return {"cmd": "attack", "arg": "", "target": ""}
	var parts: PackedStringArray = cmd.split(":", false, 1)
	var root: String = String(parts[0]).to_lower()
	var arg: String = ""
	var target: String = ""
	if parts.size() >= 2:
		var rest: String = String(parts[1]).strip_edges()
		var at_parts: PackedStringArray = rest.split("@", false, 1)
		arg = String(at_parts[0]).strip_edges()
		if at_parts.size() >= 2:
			target = String(at_parts[1]).strip_edges()
	return {"cmd": root, "arg": arg, "target": target}

func _enemies_from_encounter(enc: Dictionary) -> void:
	enemies.clear()
	var group: String = String(enc.get("enemy_group", "Enemies"))
	var count: int = max(1, int(enc.get("enemy_count", 1)))
	var power: int = max(4, int(enc.get("enemy_power", 8)))
	var total_hp: int = max(10, int(enc.get("enemy_hp", 24)))
	var base_hp: int = int(ceil(float(total_hp) / float(count)))
	for i in range(count):
		var hp_i: int = base_hp
		if i == count - 1:
			# Keep sum close to total_hp.
			hp_i = max(1, total_hp - base_hp * (count - 1))
		enemies.append({
			"id": "enemy_%d" % i,
			"name": "%s %d" % [group, i + 1] if count > 1 else group,
			"hp": hp_i,
			"hp_max": hp_i,
			"power": power,
			"agi": 6 + int(round(float(power) * 0.35)),
		})

func _reset_selection() -> void:
	_select_indices = PackedInt32Array()
	for i in range(party.size()):
		var m: Dictionary = party[i]
		if int(m.get("hp", 0)) > 0:
			_select_indices.append(i)
	_select_pos = 0
	_queued_commands.clear()
	if _select_indices.is_empty():
		_resolve(false, false)

func _advance_selection() -> void:
	_select_pos += 1
	while _select_pos < _select_indices.size():
		var idx: int = int(_select_indices[_select_pos])
		if idx >= 0 and idx < party.size() and int(party[idx].get("hp", 0)) > 0:
			return
		_select_pos += 1
	phase = Phase.RESOLVING

func _resolve_round() -> PackedStringArray:
	var logs: PackedStringArray = PackedStringArray()
	# Build an initiative-ordered list of actions.
	var actions: Array[Dictionary] = []
	var action_i: int = 0
	# Party actions.
	for i in range(party.size()):
		var m: Dictionary = party[i]
		if int(m.get("hp", 0)) <= 0:
			continue
		var mid: String = String(m.get("id", ""))
		var cmd: String = String(_queued_commands.get(mid, "attack"))
		var parsed_cmd: Dictionary = _parse_command(cmd)
		actions.append({
			"side": "party",
			"idx": i,
			"cmd": String(parsed_cmd.get("cmd", "attack")),
			"arg": String(parsed_cmd.get("arg", "")),
			"target": String(parsed_cmd.get("target", "")),
			"init": int(m.get("agi", 6)) + int(round(_roll("pinit|turn=%d|%d" % [turn_index, action_i]) * 5.0)),
		})
		action_i += 1
	# Enemy actions.
	var enemies_act: bool = true
	if opener == "preemptive" and turn_index == 1:
		enemies_act = false
	if enemies_act:
		for j in range(enemies.size()):
			var e: Dictionary = enemies[j]
			if int(e.get("hp", 0)) <= 0:
				continue
			actions.append({
				"side": "enemy",
				"idx": j,
				"cmd": "attack",
				"init": int(e.get("agi", 6)) + int(round(_roll("einit|turn=%d|%d" % [turn_index, action_i]) * 5.0)),
			})
			action_i += 1

	# Sort by init desc; for back-attack on turn 1, break ties heavily for enemies.
	actions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ia: int = int(a.get("init", 0))
		var ib: int = int(b.get("init", 0))
		if ia == ib and opener == "back_attack" and turn_index == 1:
			return String(a.get("side", "")) == "enemy"
		return ia > ib
	)

	for act in actions:
		if phase == Phase.RESOLVED:
			break
		var side: String = String(act.get("side", ""))
		if side == "party":
			logs.append_array(_apply_party_action(int(act.get("idx", 0)), String(act.get("cmd", "attack")), String(act.get("arg", "")), String(act.get("target", ""))))
		else:
			logs.append_array(_apply_enemy_action(int(act.get("idx", 0))))
		_check_terminal()
		if phase == Phase.RESOLVED:
			break

	# Cleanup for next round.
	_queued_commands.clear()
	if phase != Phase.RESOLVED:
		phase = Phase.SELECT_COMMANDS
	return logs

func _apply_party_action(party_idx: int, cmd: String, arg: String = "", target_id: String = "") -> PackedStringArray:
	var logs: PackedStringArray = PackedStringArray()
	if party_idx < 0 or party_idx >= party.size():
		return logs
	var actor: Dictionary = party[party_idx]
	if int(actor.get("hp", 0)) <= 0:
		return logs
	var actor_name: String = String(actor.get("name", "Member"))
	if cmd == "item":
		var item_name: String = arg
		if item_name.is_empty():
			item_name = _pick_default_consumable()
		if item_name.is_empty():
			logs.append("%s has no usable items." % actor_name)
			return logs
		if int(inventory.get(item_name, 0)) <= 0:
			logs.append("%s tried to use %s, but you don't have any left." % [actor_name, item_name])
			return logs
		var item: Dictionary = ItemCatalog.get_item(item_name)
		var effect: Dictionary = item.get("use_effect", {})
		if String(item.get("kind", "")) != "consumable" or effect.is_empty():
			logs.append("%s tried to use %s, but it had no effect." % [actor_name, item_name])
			_consume_item(item_name, 1)
			return logs
		var tgt_idx: int = party_idx
		if not target_id.is_empty():
			var picked: int = _find_party_index_by_id(target_id)
			if picked >= 0 and picked < party.size() and int(party[picked].get("hp", 0)) > 0:
				tgt_idx = picked
		var tgt: Dictionary = party[tgt_idx]
		var tgt_name: String = String(tgt.get("name", "Member"))
		if String(effect.get("type", "")) == "heal_hp":
			var amount: int = max(1, int(effect.get("amount", 10)))
			var hp_before: int = int(tgt.get("hp", 0))
			var hp_after: int = clamp(hp_before + amount, 0, int(tgt.get("hp_max", 1)))
			tgt["hp"] = hp_after
			party[tgt_idx] = tgt
			_consume_item(item_name, 1)
			if hp_after == hp_before:
				logs.append("%s uses %s on %s, but nothing happened." % [actor_name, item_name, tgt_name])
			else:
				logs.append("%s uses %s on %s (+%d HP)." % [actor_name, item_name, tgt_name, hp_after - hp_before])
			return logs
		logs.append("%s uses %s on %s, but nothing happened." % [actor_name, item_name, tgt_name])
		_consume_item(item_name, 1)
		return logs
	if cmd == "magic":
		var spell_name: String = arg
		if spell_name.is_empty():
			spell_name = "Fire"
		var spell: Dictionary = SpellCatalog.get_spell(spell_name)
		if spell.is_empty():
			logs.append("%s tried to cast magic, but nothing happened." % actor_name)
			return logs
		var mp_cost: int = max(0, int(spell.get("mp_cost", 0)))
		var mp_now: int = int(actor.get("mp", 0))
		if mp_now < mp_cost:
			logs.append("%s tried to cast %s, but lacks MP." % [actor_name, spell_name])
			cmd = "attack"
		else:
			actor["mp"] = mp_now - mp_cost
			party[party_idx] = actor
			var tgt_kind: String = String(spell.get("target", "enemy"))
			if tgt_kind == "party":
				var tgt_idx2: int = party_idx
				if not target_id.is_empty():
					var picked2: int = _find_party_index_by_id(target_id)
					if picked2 >= 0 and picked2 < party.size() and int(party[picked2].get("hp", 0)) > 0:
						tgt_idx2 = picked2
				var tgt2: Dictionary = party[tgt_idx2]
				var tgt_name2: String = String(tgt2.get("name", "Member"))
				if String(spell.get("kind", "")) == "heal_hp":
					var amount2: int = max(1, int(spell.get("amount", 10)))
					var intv2: int = int(actor.get("int", 6))
					var heal_j: int = int(round(_roll("heal|%s|turn=%d" % [String(actor.get("id", "")), turn_index]) * 4.0))
					var heal: int = amount2 + int(round(float(intv2) * 0.35)) + heal_j
					var before2: int = int(tgt2.get("hp", 0))
					var after2: int = clamp(before2 + heal, 0, int(tgt2.get("hp_max", 1)))
					tgt2["hp"] = after2
					party[tgt_idx2] = tgt2
					if after2 == before2:
						logs.append("%s casts %s on %s, but nothing happened." % [actor_name, spell_name, tgt_name2])
					else:
						logs.append("%s casts %s on %s (+%d HP)." % [actor_name, spell_name, tgt_name2, after2 - before2])
					return logs
				logs.append("%s casts %s on %s, but nothing happened." % [actor_name, spell_name, tgt_name2])
				return logs
			# enemy target by default
			var tgt_e: int = _first_alive_enemy()
			if not target_id.is_empty():
				var picked_e: int = _find_enemy_index_by_id(target_id)
				if picked_e >= 0 and picked_e < enemies.size() and int(enemies[picked_e].get("hp", 0)) > 0:
					tgt_e = picked_e
			if tgt_e < 0:
				return logs
			if String(spell.get("kind", "")) == "damage":
				var tgt3: Dictionary = enemies[tgt_e]
				var dmg_base: int = max(1, int(spell.get("power", 6)))
				var intv3: int = int(actor.get("int", 6))
				var jitter3: int = int(round(_roll("sdmg|%s|turn=%d" % [String(actor.get("id", "")), turn_index]) * 4.0))
				var dmg3: int = max(1, dmg_base + int(round(float(intv3) * 0.75)) + jitter3)
				tgt3["hp"] = max(0, int(tgt3.get("hp", 0)) - dmg3)
				enemies[tgt_e] = tgt3
				logs.append("%s casts %s for %d damage." % [actor_name, spell_name, dmg3])
				if int(tgt3.get("hp", 0)) <= 0:
					logs.append("%s was defeated." % String(tgt3.get("name", "Enemy")))
				return logs
			logs.append("%s casts %s, but nothing happened." % [actor_name, spell_name])
			return logs
	var target_idx: int = _first_alive_enemy()
	if target_idx < 0:
		return logs
	var dmg: int = _calc_party_damage(actor, cmd)
	var tgt: Dictionary = enemies[target_idx]
	tgt["hp"] = max(0, int(tgt.get("hp", 0)) - dmg)
	enemies[target_idx] = tgt
	logs.append("%s uses %s for %d damage." % [actor_name, cmd.capitalize(), dmg])
	if int(tgt.get("hp", 0)) <= 0:
		logs.append("%s was defeated." % String(tgt.get("name", "Enemy")))
	return logs

func _apply_enemy_action(enemy_idx: int) -> PackedStringArray:
	var logs: PackedStringArray = PackedStringArray()
	if enemy_idx < 0 or enemy_idx >= enemies.size():
		return logs
	var e: Dictionary = enemies[enemy_idx]
	if int(e.get("hp", 0)) <= 0:
		return logs
	var target_idx: int = _pick_alive_party_target(enemy_idx)
	if target_idx < 0:
		return logs
	var dmg: int = _calc_enemy_damage(e)
	var tgt: Dictionary = party[target_idx]
	tgt["hp"] = max(0, int(tgt.get("hp", 0)) - dmg)
	party[target_idx] = tgt
	logs.append("%s hits %s for %d damage." % [String(e.get("name", "Enemy")), String(tgt.get("name", "Member")), dmg])
	if int(tgt.get("hp", 0)) <= 0:
		logs.append("%s was knocked out." % String(tgt.get("name", "Member")))
	return logs

func _attempt_flee() -> Dictionary:
	var logs: PackedStringArray = PackedStringArray()
	var flee_chance: float = clamp(float(encounter.get("flee_chance", 0.45)), 0.0, 0.95)
	# Back-attack makes fleeing harder on turn 1.
	if opener == "back_attack" and turn_index == 1:
		flee_chance *= 0.70
	var roll: float = _roll("flee|turn=%d" % turn_index)
	if roll <= flee_chance:
		logs.append("You fled successfully.")
		_resolve(false, true)
		return {"resolved": true, "logs": logs}
	logs.append("Flee failed.")
	return {"resolved": false, "logs": logs}

func _enemy_only_response() -> PackedStringArray:
	var logs: PackedStringArray = PackedStringArray()
	for j in range(enemies.size()):
		if int(enemies[j].get("hp", 0)) <= 0:
			continue
		logs.append_array(_apply_enemy_action(j))
		_check_terminal()
		if phase == Phase.RESOLVED:
			break
	return logs

func _first_alive_enemy() -> int:
	for i in range(enemies.size()):
		if int(enemies[i].get("hp", 0)) > 0:
			return i
	return -1

func _pick_alive_party_target(enemy_idx: int) -> int:
	var alive: PackedInt32Array = PackedInt32Array()
	for i in range(party.size()):
		if int(party[i].get("hp", 0)) > 0:
			alive.append(i)
	if alive.is_empty():
		return -1
	var pick: int = int(floor(_roll("etgt|%d|turn=%d" % [enemy_idx, turn_index]) * float(alive.size())))
	pick = clamp(pick, 0, alive.size() - 1)
	return int(alive[pick])

func _calc_party_damage(actor: Dictionary, cmd: String) -> int:
	var strv: int = int(actor.get("str", 6))
	var intv: int = int(actor.get("int", 6))
	var base: int = 2 + int(round(float(strv) * 0.55))
	if cmd == "magic":
		base = 3 + int(round(float(intv) * 0.70))
	var jitter: int = int(round(_roll("pdmg|%s|turn=%d" % [String(actor.get("id", "")), turn_index]) * 4.0))
	return max(1, base + jitter)

func _calc_enemy_damage(enemy: Dictionary) -> int:
	var powv: int = int(enemy.get("power", 8))
	var base: int = 2 + int(round(float(powv) * 0.60))
	var eid: String = String(enemy.get("id", "e"))
	var jitter: int = int(round(_roll("edmg|%s|turn=%d" % [eid, turn_index]) * 3.0))
	return max(1, base + jitter)

func _check_terminal() -> void:
	if _all_dead(enemies):
		_resolve(true, false)
		return
	if _all_dead(party):
		_resolve(false, false)

func _all_dead(actors: Array[Dictionary]) -> bool:
	for a in actors:
		if int(a.get("hp", 0)) > 0:
			return false
	return true

func _resolve(victory: bool, escaped: bool) -> void:
	phase = Phase.RESOLVED
	result = {
		"victory": victory,
		"escaped": escaped,
		"defeat": (not victory and not escaped),
		"encounter": encounter.duplicate(true),
		"rewards": encounter.get("rewards", {}).duplicate(true) if victory else {},
		"party_after": _party_after_payload(),
	}

func _party_after_payload() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m in party:
		out.append({
			"id": String(m.get("id", "")),
			"hp": int(m.get("hp", 0)),
			"hp_max": int(m.get("hp_max", 0)),
			"mp": int(m.get("mp", 0)),
			"mp_max": int(m.get("mp_max", 0)),
		})
	return out

func _roll(tag: String) -> float:
	var seed_hash: int = int(String(encounter.get("encounter_seed_key", "enc")).hash())
	return DeterministicRng.randf01(seed_hash, "%s" % tag)

func _pick_default_consumable() -> String:
	if int(inventory.get("Potion", 0)) > 0:
		return "Potion"
	if int(inventory.get("Herb", 0)) > 0:
		return "Herb"
	var names: Array = inventory.keys()
	names.sort()
	for n in names:
		var item_name: String = String(n)
		if int(inventory.get(item_name, 0)) <= 0:
			continue
		var item: Dictionary = ItemCatalog.get_item(item_name)
		if String(item.get("kind", "")) == "consumable":
			return item_name
	return ""

func _consume_item(item_name: String, count: int) -> void:
	if item_name.is_empty() or count <= 0:
		return
	var have: int = int(inventory.get(item_name, 0))
	if have <= 0:
		return
	var left: int = have - count
	if left <= 0:
		inventory.erase(item_name)
	else:
		inventory[item_name] = left
	_consumed_items.append({"name": item_name, "count": count})

func _find_party_index_by_id(member_id: String) -> int:
	for i in range(party.size()):
		if String(party[i].get("id", "")) == member_id:
			return i
	return -1

func _find_enemy_index_by_id(enemy_id: String) -> int:
	for i in range(enemies.size()):
		if String(enemies[i].get("id", "")) == enemy_id:
			return i
	return -1
