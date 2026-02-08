extends Node

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const EncounterRegistry = preload("res://scripts/gameplay/EncounterRegistry.gd")
const PartyStateModel = preload("res://scripts/gameplay/models/PartyState.gd")
const WorldTimeStateModel = preload("res://scripts/gameplay/models/WorldTimeState.gd")
const SettingsStateModel = preload("res://scripts/gameplay/models/SettingsState.gd")
const QuestStateModel = preload("res://scripts/gameplay/models/QuestState.gd")
const WorldFlagsStateModel = preload("res://scripts/gameplay/models/WorldFlagsState.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")

const SAVE_SCHEMA_VERSION: int = 3

var party: PartyStateModel = PartyStateModel.new()
var world_time: WorldTimeStateModel = WorldTimeStateModel.new()
var settings_state: SettingsStateModel = SettingsStateModel.new()
var quest_state: QuestStateModel = QuestStateModel.new()
var world_flags: WorldFlagsStateModel = WorldFlagsStateModel.new()

var world_seed_hash: int = 0
var world_width: int = 0
var world_height: int = 0
var world_biome_ids: PackedInt32Array = PackedInt32Array()

var location: Dictionary = {
	"scene": SceneContracts.STATE_WORLD,
	"world_x": 0,
	"world_y": 0,
	"local_x": 48,
	"local_y": 48,
	"biome_id": -1,
	"biome_name": "",
}

var pending_battle: Dictionary = {}
var pending_poi: Dictionary = {}
var last_battle_result: Dictionary = {}
var run_flags: Dictionary = {}

# In-game realtime clock (separate from world-map simulation TimeSystem).
# We advance `world_time` only while exploring (regional/local), at 1:1 by default.
# 1 real second == 1 in-game second.
const MAX_REALTIME_DELTA_SECONDS: float = 0.25
var _ingame_time_accum_seconds: float = 0.0
var _ui_pause_count: int = 0

var _events: Node = null

func _ready() -> void:
	_events = get_node_or_null("/root/GameEvents")
	_wire_event_pauses()
	if party.members.is_empty():
		party.reset_default_party()
	if world_time.year <= 0:
		world_time.reset_defaults()
	if quest_state.quests.is_empty():
		quest_state.ensure_default_quests()
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_time_advanced()
	_emit_settings_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()
	set_process(true)

func _wire_event_pauses() -> void:
	if _events == null:
		return
	if _events.has_signal("menu_opened") and not _events.menu_opened.is_connected(_on_menu_opened):
		_events.menu_opened.connect(_on_menu_opened)
	if _events.has_signal("menu_closed") and not _events.menu_closed.is_connected(_on_menu_closed):
		_events.menu_closed.connect(_on_menu_closed)

func push_ui_pause(_reason: String = "") -> void:
	_ui_pause_count += 1

func pop_ui_pause(_reason: String = "") -> void:
	_ui_pause_count = max(0, _ui_pause_count - 1)

func _on_menu_opened(_context_title: String) -> void:
	push_ui_pause("menu")

func _on_menu_closed(_context_title: String) -> void:
	pop_ui_pause("menu")

func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if not _should_advance_ingame_realtime():
		# Don't carry fractional seconds across modes.
		_ingame_time_accum_seconds = 0.0
		return
	var dt: float = min(delta, MAX_REALTIME_DELTA_SECONDS)
	var scale: float = 1.0
	if run_flags.has("ingame_time_scale"):
		scale = max(0.0, float(run_flags.get("ingame_time_scale", 1.0)))
	if scale <= 0.0:
		return
	_ingame_time_accum_seconds += dt * scale
	var seconds: int = int(floor(_ingame_time_accum_seconds))
	if seconds <= 0:
		return
	_ingame_time_accum_seconds -= float(seconds)
	advance_world_time_seconds(seconds, "realtime")

func _should_advance_ingame_realtime() -> bool:
	var scene_name: String = String(location.get("scene", SceneContracts.STATE_WORLD))
	if _ui_pause_count > 0:
		return false
	return scene_name == SceneContracts.STATE_REGIONAL or scene_name == SceneContracts.STATE_LOCAL

func reset_run() -> void:
	party.reset_default_party()
	world_time.reset_defaults()
	settings_state.reset_defaults()
	quest_state.reset_defaults()
	world_flags.reset_defaults()
	world_seed_hash = 0
	world_width = 0
	world_height = 0
	world_biome_ids = PackedInt32Array()
	location = {
		"scene": SceneContracts.STATE_WORLD,
		"world_x": 0,
		"world_y": 0,
		"local_x": 48,
		"local_y": 48,
		"biome_id": -1,
		"biome_name": "",
	}
	pending_battle.clear()
	pending_poi.clear()
	last_battle_result.clear()
	run_flags.clear()
	_ingame_time_accum_seconds = 0.0
	_ui_pause_count = 0
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_time_advanced()
	_emit_location_changed()
	_emit_settings_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()

func initialize_world_snapshot(width: int, height: int, seed_hash: int, biome_ids: PackedInt32Array) -> void:
	world_width = max(1, width)
	world_height = max(1, height)
	world_seed_hash = seed_hash
	world_biome_ids = biome_ids.duplicate()
	if _events and _events.has_signal("world_snapshot_updated"):
		_events.emit_signal("world_snapshot_updated", world_width, world_height, world_seed_hash)

func has_world_snapshot() -> bool:
	return world_width > 0 and world_height > 0 and world_biome_ids.size() == world_width * world_height

func get_world_biome_id(x: int, y: int) -> int:
	if not has_world_snapshot():
		return int(location.get("biome_id", -1))
	var wx: int = posmod(x, world_width)
	var wy: int = clamp(y, 0, world_height - 1)
	var i: int = wx + wy * world_width
	if i < 0 or i >= world_biome_ids.size():
		return int(location.get("biome_id", -1))
	return world_biome_ids[i]

func set_location(scene_name: String, world_x: int, world_y: int, local_x: int, local_y: int, biome_id: int = -1, biome_name: String = "") -> void:
	# UI pauses are transient; don't let them leak across scene changes.
	var next_scene: String = String(scene_name)
	if next_scene != SceneContracts.STATE_REGIONAL and next_scene != SceneContracts.STATE_LOCAL:
		_ui_pause_count = 0
	location["scene"] = scene_name
	location["world_x"] = world_x
	location["world_y"] = world_y
	location["local_x"] = local_x
	location["local_y"] = local_y
	if biome_id >= 0:
		location["biome_id"] = biome_id
	if not biome_name.is_empty():
		location["biome_name"] = biome_name
	_emit_location_changed()

func get_location() -> Dictionary:
	return location.duplicate(true)

func mark_regional_step() -> void:
	if _events and _events.has_signal("regional_step_taken"):
		_events.emit_signal("regional_step_taken", get_location())

func ensure_encounter_meter_state() -> Dictionary:
	var v: Variant = run_flags.get("encounter_meter_state")
	if typeof(v) != TYPE_DICTIONARY:
		v = {}
		run_flags["encounter_meter_state"] = v
	var st: Dictionary = v
	EncounterRegistry.ensure_danger_meter_state_inplace(st)
	return st

func reset_encounter_meter_after_battle(encounter_ctx: Dictionary = {}) -> void:
	# FF-style: after any battle, reset the step-based encounter meter.
	var st: Dictionary = ensure_encounter_meter_state()
	var wx: int = int(location.get("world_x", 0))
	var wy: int = int(location.get("world_y", 0))
	var biome_id: int = int(location.get("biome_id", -1))
	if typeof(encounter_ctx) == TYPE_DICTIONARY and not encounter_ctx.is_empty():
		wx = int(encounter_ctx.get("world_x", wx))
		wy = int(encounter_ctx.get("world_y", wy))
		if encounter_ctx.has("biome_id"):
			biome_id = int(encounter_ctx.get("biome_id", biome_id))
	if biome_id < 0:
		biome_id = get_world_biome_id(wx, wy)
	var minute: int = int(world_time.minute_of_day) if world_time != null else -1
	EncounterRegistry.reset_danger_meter(world_seed_hash, st, wx, wy, biome_id, minute)

func advance_world_time(minutes: int, _reason: String = "") -> void:
	world_time.advance_minutes(max(0, minutes))
	_emit_time_advanced()

func advance_world_time_seconds(seconds: int, _reason: String = "") -> void:
	world_time.advance_seconds(max(0, seconds))
	_emit_time_advanced()

func queue_battle(encounter_data: Dictionary) -> void:
	pending_battle = encounter_data.duplicate(true)
	if _events and _events.has_signal("battle_started"):
		_events.emit_signal("battle_started", pending_battle.duplicate(true))

func consume_pending_battle() -> Dictionary:
	if pending_battle.is_empty():
		return {}
	var out: Dictionary = pending_battle.duplicate(true)
	pending_battle.clear()
	return out

func queue_poi(poi_data: Dictionary) -> void:
	pending_poi = poi_data.duplicate(true)
	register_poi_discovery(poi_data)
	if _events and _events.has_signal("poi_entered"):
		_events.emit_signal("poi_entered", pending_poi.duplicate(true))

func consume_pending_poi() -> Dictionary:
	if pending_poi.is_empty():
		return {}
	var out: Dictionary = pending_poi.duplicate(true)
	pending_poi.clear()
	return out

func register_poi_discovery(poi_data: Dictionary) -> void:
	world_flags.register_poi_discovery(poi_data)
	_emit_world_flags_changed()

func mark_world_tile_visited(world_x: int, world_y: int) -> void:
	world_flags.mark_world_tile_visited(world_x, world_y)
	_emit_world_flags_changed()

func is_world_tile_visited(world_x: int, world_y: int) -> bool:
	return world_flags.is_world_tile_visited(world_x, world_y)

func get_poi_instance_state(poi_id: String) -> Dictionary:
	return world_flags.get_poi_instance_state(poi_id)

func apply_poi_instance_patch(poi_id: String, patch: Dictionary) -> void:
	world_flags.apply_poi_instance_patch(poi_id, patch)
	_emit_world_flags_changed()

func is_poi_boss_defeated(poi_id: String) -> bool:
	return world_flags.is_poi_boss_defeated(poi_id)

func mark_poi_cleared(poi_id: String) -> void:
	world_flags.mark_poi_cleared(poi_id)
	_emit_world_flags_changed()

func is_poi_cleared(poi_id: String) -> bool:
	return world_flags.is_poi_cleared(poi_id)

func apply_battle_result(result_data: Dictionary) -> Dictionary:
	last_battle_result = result_data.duplicate(true)
	world_flags.register_battle_result(result_data)
	var enc_for_reset: Dictionary = result_data.get("encounter", {})
	if typeof(enc_for_reset) != TYPE_DICTIONARY:
		enc_for_reset = {}
	reset_encounter_meter_after_battle(enc_for_reset)
	# Apply party HP/MP changes from battle.
	var after_list: Variant = result_data.get("party_after", [])
	if typeof(after_list) == TYPE_ARRAY:
		var hp_map: Dictionary = {}
		var mp_map: Dictionary = {}
		for entry in after_list:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var idv: String = String(entry.get("id", ""))
			if idv.is_empty():
				continue
			hp_map[idv] = int(entry.get("hp", 0))
			mp_map[idv] = int(entry.get("mp", 0))
		for member in party.members:
			if member == null:
				continue
			var mid: String = String(member.member_id)
			if hp_map.has(mid):
				member.hp = clamp(int(hp_map[mid]), 0, member.max_hp)
			if mp_map.has(mid):
				member.mp = clamp(int(mp_map[mid]), 0, member.max_mp)
	var logs: PackedStringArray = PackedStringArray()
	if bool(result_data.get("victory", false)):
		var rewards: Dictionary = result_data.get("rewards", {})
		logs = party.grant_rewards(rewards)
		last_battle_result["reward_logs"] = logs
		# Dungeon boss clears the dungeon POI.
		var enc: Dictionary = result_data.get("encounter", {})
		var battle_kind: String = String(enc.get("battle_kind", ""))
		if battle_kind == "dungeon_boss":
			var poi_id: String = String(enc.get("poi_id", ""))
			if not poi_id.is_empty():
				world_flags.apply_poi_instance_patch(poi_id, {"boss_defeated": true})
				world_flags.mark_poi_cleared(poi_id)
		# Scaffold quest progression: complete the starter quest on first victory.
		if quest_state.quests.has("quest_first_steps"):
			var q: Dictionary = quest_state.quests["quest_first_steps"]
			if int(q.get("status", QuestStateModel.QuestStatus.ACTIVE)) == QuestStateModel.QuestStatus.ACTIVE:
				quest_state.set_status("quest_first_steps", QuestStateModel.QuestStatus.COMPLETED)
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()
	if _events and _events.has_signal("battle_resolved"):
		_events.emit_signal("battle_resolved", last_battle_result.duplicate(true))
	return {
		"reward_logs": logs,
	}

func apply_settings_patch(patch: Dictionary) -> void:
	settings_state.apply_patch(patch)
	_emit_settings_changed()

func get_settings_snapshot() -> Dictionary:
	return settings_state.to_dict()

func get_encounter_rate_multiplier() -> float:
	return clamp(settings_state.encounter_rate_multiplier, 0.10, 2.00)

func get_menu_snapshot() -> Dictionary:
	var inventory_lines: PackedStringArray = PackedStringArray()
	for key in party.inventory.keys():
		var item_name: String = String(key)
		var item_data: Dictionary = ItemCatalog.get_item(item_name)
		var kind: String = String(item_data.get("kind", "item"))
		inventory_lines.append("%s x%d (%s)" % [item_name, int(party.inventory[key]), kind])
	if inventory_lines.is_empty():
		inventory_lines.append("(empty)")
	var overview_lines: PackedStringArray = PackedStringArray()
	overview_lines.append("Time: %s" % world_time.format_compact())
	overview_lines.append("Seed: %d" % world_seed_hash)
	overview_lines.append("Location: (%d,%d) local(%d,%d)" % [
		int(location.get("world_x", 0)),
		int(location.get("world_y", 0)),
		int(location.get("local_x", 48)),
		int(location.get("local_y", 48)),
	])
	for line in world_flags.summary_lines():
		overview_lines.append(String(line))
	return {
		"overview_lines": overview_lines,
		"time": world_time.format_compact(),
		"party_lines": party.summary_lines(4),
		"inventory_lines": inventory_lines,
		"equipment_lines": party.equipment_lines(4),
		"stats_lines": party.stat_lines(4),
		"quest_lines": quest_state.summary_lines(14),
		"settings_lines": settings_state.summary_lines(),
		"flags_lines": world_flags.summary_lines(),
		"gold": party.gold,
	}

func get_time_label() -> String:
	return world_time.format_compact()

func get_party_power() -> int:
	return party.total_power()

func use_consumable(item_name: String, member_id: String) -> Dictionary:
	item_name = String(item_name)
	member_id = String(member_id)
	if item_name.is_empty():
		return {"ok": false, "message": "No item selected."}
	if member_id.is_empty():
		return {"ok": false, "message": "No party member selected."}
	if int(party.inventory.get(item_name, 0)) <= 0:
		return {"ok": false, "message": "Item is not in inventory."}
	var item: Dictionary = ItemCatalog.get_item(item_name)
	if item.is_empty():
		return {"ok": false, "message": "Unknown item."}
	if String(item.get("kind", "")) != "consumable":
		return {"ok": false, "message": "That item cannot be used here."}
	var effect: Dictionary = item.get("use_effect", {})
	if effect.is_empty():
		return {"ok": false, "message": "Item has no usable effect."}
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	var effect_type: String = String(effect.get("type", ""))
	if effect_type == "heal_hp":
		var amount: int = max(1, int(effect.get("amount", 10)))
		var hp_before: int = int(member.hp)
		var hp_after: int = clamp(hp_before + amount, 0, int(member.max_hp))
		if not party.remove_item(item_name, 1):
			return {"ok": false, "message": "Failed to consume item."}
		member.hp = hp_after
		_emit_party_changed()
		_emit_inventory_changed()
		if hp_after == hp_before:
			return {
				"ok": true,
				"message": "%s used %s, but nothing happened." % [String(member.display_name), item_name],
			}
		return {
			"ok": true,
			"message": "%s used %s (+%d HP)." % [String(member.display_name), item_name, hp_after - hp_before],
		}
	return {"ok": false, "message": "Unsupported item effect."}

func equip_item(item_name: String, member_id: String) -> Dictionary:
	item_name = String(item_name)
	member_id = String(member_id)
	if item_name.is_empty():
		return {"ok": false, "message": "No item selected."}
	if member_id.is_empty():
		return {"ok": false, "message": "No party member selected."}
	var item: Dictionary = ItemCatalog.get_item(item_name)
	if item.is_empty():
		return {"ok": false, "message": "Unknown item."}
	var slot: String = String(item.get("equip_slot", ""))
	if slot.is_empty():
		var kind: String = String(item.get("kind", ""))
		if kind == "weapon" or kind == "armor" or kind == "accessory":
			slot = kind
	if slot != "weapon" and slot != "armor" and slot != "accessory":
		return {"ok": false, "message": "That item cannot be equipped."}
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	member.ensure_bag()
	var bag_idx: int = _find_member_bag_slot_with_item(member, item_name)
	if bag_idx < 0:
		return {"ok": false, "message": "Item must be in %s's inventory." % String(member.display_name)}
	var equipped_now: String = String(member.equipment.get(slot, ""))
	if equipped_now == item_name:
		# Toggle off.
		return unequip_slot(member_id, slot)
	# Unequip old item in this slot (clears bag marker too).
	if not equipped_now.is_empty():
		_clear_member_bag_equipped_marker(member, slot)
	# Equip new item: keep it in bag, but mark slot as equipped.
	_clear_member_bag_equipped_marker(member, slot)
	var slot_data: Dictionary = member.get_bag_slot(bag_idx)
	slot_data["equipped_slot"] = slot
	member.set_bag_slot(bag_idx, slot_data)
	member.equipment[slot] = item_name
	_emit_party_changed()
	_emit_inventory_changed()
	return {
		"ok": true,
		"message": "%s equipped %s (%s)." % [String(member.display_name), item_name, slot.capitalize()],
	}

func unequip_slot(member_id: String, slot: String) -> Dictionary:
	member_id = String(member_id)
	slot = String(slot).to_lower()
	if member_id.is_empty():
		return {"ok": false, "message": "No party member selected."}
	if slot != "weapon" and slot != "armor" and slot != "accessory":
		return {"ok": false, "message": "Invalid equipment slot."}
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	var equipped_now: String = String(member.equipment.get(slot, ""))
	if equipped_now.is_empty():
		return {"ok": false, "message": "%s has nothing equipped in %s." % [String(member.display_name), slot]}
	member.equipment[slot] = ""
	_clear_member_bag_equipped_marker(member, slot)
	_emit_party_changed()
	_emit_inventory_changed()
	return {
		"ok": true,
		"message": "%s unequipped %s." % [String(member.display_name), equipped_now],
	}

func consume_inventory_items(consumes: Array) -> void:
	# Used by battle system to apply item consumption once actions resolve.
	if consumes.is_empty():
		return
	var changed: bool = false
	for entry in consumes:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var item_name: String = String(entry.get("name", ""))
		var count: int = max(1, int(entry.get("count", 1)))
		if item_name.is_empty():
			continue
		if party.remove_item(item_name, count):
			changed = true
	if changed:
		_emit_inventory_changed()

func move_bag_item(from_member_id: String, from_idx: int, to_member_id: String, to_idx: int) -> Dictionary:
	from_member_id = String(from_member_id)
	to_member_id = String(to_member_id)
	if from_member_id.is_empty() or to_member_id.is_empty():
		return {"ok": false, "message": "Invalid party member."}
	var from_member: Variant = _find_member_by_id(from_member_id)
	var to_member: Variant = _find_member_by_id(to_member_id)
	if from_member == null or to_member == null:
		return {"ok": false, "message": "Party member not found."}
	from_member.ensure_bag()
	to_member.ensure_bag()
	if from_idx < 0 or from_idx >= from_member.bag.size():
		return {"ok": false, "message": "Invalid source slot."}
	if to_idx < 0 or to_idx >= to_member.bag.size():
		return {"ok": false, "message": "Invalid target slot."}
	if from_member_id == to_member_id and from_idx == to_idx:
		return {"ok": false, "message": "Same slot."}
	var a: Dictionary = from_member.get_bag_slot(from_idx)
	var b: Dictionary = to_member.get_bag_slot(to_idx)
	if String(a.get("name", "")).is_empty() or int(a.get("count", 0)) <= 0:
		return {"ok": false, "message": "Source slot is empty."}
	var a_equipped: String = String(a.get("equipped_slot", ""))
	var b_equipped: String = String(b.get("equipped_slot", ""))
	if from_member_id != to_member_id and (not a_equipped.is_empty() or not b_equipped.is_empty()):
		return {"ok": false, "message": "Unequip items before moving between characters."}
	# Merge if same item and stackable.
	var a_name: String = String(a.get("name", ""))
	var b_name: String = String(b.get("name", ""))
	if from_member_id == to_member_id:
		# Intra-bag moves can carry equipped marker without breaking anything.
		pass
	if a_name == b_name and not a_name.is_empty():
		var item: Dictionary = ItemCatalog.get_item(a_name)
		if bool(item.get("stackable", true)) and a_equipped.is_empty() and b_equipped.is_empty():
			var total: int = max(0, int(a.get("count", 0))) + max(0, int(b.get("count", 0)))
			b["count"] = total
			to_member.set_bag_slot(to_idx, b)
			from_member.set_bag_slot(from_idx, {})
			party.rebuild_inventory_view()
			_emit_inventory_changed()
			return {"ok": true, "message": "Stacked."}
	# Swap.
	from_member.set_bag_slot(from_idx, b)
	to_member.set_bag_slot(to_idx, a)
	party.rebuild_inventory_view()
	_emit_inventory_changed()
	_emit_party_changed()
	return {"ok": true, "message": "Moved."}

func drop_bag_item(member_id: String, idx: int) -> Dictionary:
	member_id = String(member_id)
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	member.ensure_bag()
	if idx < 0 or idx >= member.bag.size():
		return {"ok": false, "message": "Invalid slot."}
	var slot: Dictionary = member.get_bag_slot(idx)
	var name: String = String(slot.get("name", ""))
	var count: int = int(slot.get("count", 0))
	if name.is_empty() or count <= 0:
		return {"ok": false, "message": "Empty slot."}
	if not String(slot.get("equipped_slot", "")).is_empty():
		return {"ok": false, "message": "Unequip before dropping."}
	member.set_bag_slot(idx, {})
	party.rebuild_inventory_view()
	_emit_inventory_changed()
	return {"ok": true, "message": "Dropped %s." % name}

func toggle_equip_bag_item(member_id: String, idx: int) -> Dictionary:
	member_id = String(member_id)
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	member.ensure_bag()
	if idx < 0 or idx >= member.bag.size():
		return {"ok": false, "message": "Invalid slot."}
	var slot_data: Dictionary = member.get_bag_slot(idx)
	var item_name: String = String(slot_data.get("name", ""))
	if item_name.is_empty() or int(slot_data.get("count", 0)) <= 0:
		return {"ok": false, "message": "Empty slot."}
	var item: Dictionary = ItemCatalog.get_item(item_name)
	if item.is_empty():
		return {"ok": false, "message": "Unknown item."}
	var equip_slot: String = String(item.get("equip_slot", ""))
	if equip_slot.is_empty():
		var kind: String = String(item.get("kind", ""))
		if kind == "weapon" or kind == "armor" or kind == "accessory":
			equip_slot = kind
	if equip_slot != "weapon" and equip_slot != "armor" and equip_slot != "accessory":
		return {"ok": false, "message": "That item cannot be equipped."}
	var equipped_now: String = String(member.equipment.get(equip_slot, ""))
	if equipped_now == item_name and String(slot_data.get("equipped_slot", "")) == equip_slot:
		return unequip_slot(member_id, equip_slot)
	# Unequip previous, then equip this slot.
	if not equipped_now.is_empty():
		_clear_member_bag_equipped_marker(member, equip_slot)
	member.equipment[equip_slot] = item_name
	_clear_member_bag_equipped_marker(member, equip_slot)
	slot_data["equipped_slot"] = equip_slot
	member.set_bag_slot(idx, slot_data)
	_emit_party_changed()
	_emit_inventory_changed()
	return {"ok": true, "message": "%s equipped %s." % [String(member.display_name), item_name]}

func use_consumable_from_bag_slot(from_member_id: String, from_idx: int, target_member_id: String) -> Dictionary:
	from_member_id = String(from_member_id)
	target_member_id = String(target_member_id)
	var from_member: Variant = _find_member_by_id(from_member_id)
	var target: Variant = _find_member_by_id(target_member_id)
	if from_member == null or target == null:
		return {"ok": false, "message": "Party member not found."}
	from_member.ensure_bag()
	if from_idx < 0 or from_idx >= from_member.bag.size():
		return {"ok": false, "message": "Invalid item slot."}
	var slot_data: Dictionary = from_member.get_bag_slot(from_idx)
	var item_name: String = String(slot_data.get("name", ""))
	if item_name.is_empty() or int(slot_data.get("count", 0)) <= 0:
		return {"ok": false, "message": "Empty slot."}
	var item: Dictionary = ItemCatalog.get_item(item_name)
	if String(item.get("kind", "")) != "consumable":
		return {"ok": false, "message": "That item cannot be used."}
	var effect: Dictionary = item.get("use_effect", {})
	var effect_type: String = String(effect.get("type", ""))
	if effect_type == "heal_hp":
		var amount: int = max(1, int(effect.get("amount", 10)))
		var hp_before: int = int(target.hp)
		var hp_after: int = clamp(hp_before + amount, 0, int(target.max_hp))
		# Consume one from this slot.
		var left: int = int(slot_data.get("count", 0)) - 1
		if left <= 0:
			from_member.set_bag_slot(from_idx, {})
		else:
			slot_data["count"] = left
			from_member.set_bag_slot(from_idx, slot_data)
		target.hp = hp_after
		party.rebuild_inventory_view()
		_emit_party_changed()
		_emit_inventory_changed()
		if hp_after == hp_before:
			return {"ok": true, "message": "%s used %s, but nothing happened." % [String(target.display_name), item_name]}
		return {"ok": true, "message": "%s used %s (+%d HP)." % [String(target.display_name), item_name, hp_after - hp_before]}
	return {"ok": false, "message": "Unsupported item effect."}

func _find_member_bag_slot_with_item(member: Variant, item_name: String) -> int:
	if member == null or item_name.is_empty():
		return -1
	member.ensure_bag()
	for i in range(member.bag.size()):
		var slot_data: Dictionary = member.get_bag_slot(i)
		if String(slot_data.get("name", "")) == item_name and int(slot_data.get("count", 0)) > 0:
			return i
	return -1

func _clear_member_bag_equipped_marker(member: Variant, equip_slot: String) -> void:
	if member == null:
		return
	member.ensure_bag()
	for i in range(member.bag.size()):
		var slot_data: Dictionary = member.get_bag_slot(i)
		if String(slot_data.get("equipped_slot", "")) == equip_slot:
			slot_data.erase("equipped_slot")
			member.set_bag_slot(i, slot_data)

func save_to_path(path: String = SceneContracts.SAVE_SLOT_0) -> bool:
	var payload: Dictionary = _to_save_payload()
	var text: String = JSON.stringify(payload, "\t")
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	if _events and _events.has_signal("save_written"):
		_events.emit_signal("save_written", path)
	return true

func load_from_path(path: String = SceneContracts.SAVE_SLOT_0) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var data: Dictionary = parsed
	var version: int = int(data.get("version", 1))
	if version < 1 or version > SAVE_SCHEMA_VERSION:
		return false
	_from_save_payload(data, version)
	# UI pauses/accumulators are transient runtime state; do not restore from saves.
	_ingame_time_accum_seconds = 0.0
	_ui_pause_count = 0
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_time_advanced()
	_emit_location_changed()
	_emit_settings_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()
	if _events and _events.has_signal("save_loaded"):
		_events.emit_signal("save_loaded", path)
	return true

func _to_save_payload() -> Dictionary:
	var biome_array: Array = []
	for b in world_biome_ids:
		biome_array.append(int(b))
	return {
		"version": SAVE_SCHEMA_VERSION,
		"world_seed_hash": world_seed_hash,
		"world_width": world_width,
		"world_height": world_height,
		"world_biome_ids": biome_array,
		"location": location.duplicate(true),
		"party": party.to_dict(),
		"world_time": world_time.to_dict(),
		"settings_state": settings_state.to_dict(),
		"quest_state": quest_state.to_dict(),
		"world_flags": world_flags.to_dict(),
		"pending_battle": pending_battle.duplicate(true),
		"pending_poi": pending_poi.duplicate(true),
		"last_battle_result": last_battle_result.duplicate(true),
		"run_flags": run_flags.duplicate(true),
	}

func _from_save_payload(data: Dictionary, version: int = SAVE_SCHEMA_VERSION) -> void:
	world_seed_hash = int(data.get("world_seed_hash", 0))
	world_width = max(0, int(data.get("world_width", 0)))
	world_height = max(0, int(data.get("world_height", 0)))
	world_biome_ids = PackedInt32Array()
	var incoming_biomes: Array = data.get("world_biome_ids", [])
	world_biome_ids.resize(incoming_biomes.size())
	for i in range(incoming_biomes.size()):
		world_biome_ids[i] = int(incoming_biomes[i])
	location = data.get("location", {}).duplicate(true)
	_normalize_location()
	party = PartyStateModel.from_dict(data.get("party", {}))
	world_time = WorldTimeStateModel.from_dict(data.get("world_time", {}))
	if version >= 2:
		settings_state = SettingsStateModel.from_dict(data.get("settings_state", {}))
		quest_state = QuestStateModel.from_dict(data.get("quest_state", {}))
		world_flags = WorldFlagsStateModel.from_dict(data.get("world_flags", {}))
	else:
		settings_state = SettingsStateModel.new()
		settings_state.reset_defaults()
		quest_state = QuestStateModel.new()
		quest_state.reset_defaults()
		world_flags = WorldFlagsStateModel.new()
		world_flags.reset_defaults()
	pending_battle = data.get("pending_battle", {}).duplicate(true)
	pending_poi = data.get("pending_poi", {}).duplicate(true)
	last_battle_result = data.get("last_battle_result", {}).duplicate(true)
	run_flags = data.get("run_flags", {}).duplicate(true)
	_ingame_time_accum_seconds = 0.0

func _emit_location_changed() -> void:
	if _events and _events.has_signal("location_changed"):
		_events.emit_signal("location_changed", get_location())

func _emit_party_changed() -> void:
	if _events and _events.has_signal("party_changed"):
		_events.emit_signal("party_changed", party.to_dict())

func _emit_inventory_changed() -> void:
	if _events and _events.has_signal("inventory_changed"):
		_events.emit_signal("inventory_changed", party.inventory.duplicate(true))

func _emit_time_advanced() -> void:
	if _events and _events.has_signal("time_advanced"):
		_events.emit_signal("time_advanced", world_time.format_compact())

func _emit_settings_changed() -> void:
	if _events and _events.has_signal("settings_changed"):
		_events.emit_signal("settings_changed", settings_state.to_dict())

func _emit_quests_changed() -> void:
	if _events and _events.has_signal("quests_changed"):
		_events.emit_signal("quests_changed", quest_state.to_dict())

func _emit_world_flags_changed() -> void:
	if _events and _events.has_signal("world_flags_changed"):
		_events.emit_signal("world_flags_changed", world_flags.to_dict())

func _normalize_location() -> void:
	location["scene"] = String(location.get("scene", SceneContracts.STATE_WORLD))
	location["world_x"] = int(location.get("world_x", 0))
	location["world_y"] = int(location.get("world_y", 0))
	location["local_x"] = int(location.get("local_x", 48))
	location["local_y"] = int(location.get("local_y", 48))
	location["biome_id"] = int(location.get("biome_id", -1))
	location["biome_name"] = String(location.get("biome_name", ""))

func _find_member_by_id(member_id: String) -> Variant:
	for member in party.members:
		if member == null:
			continue
		if String(member.member_id) == member_id:
			return member
	return null
