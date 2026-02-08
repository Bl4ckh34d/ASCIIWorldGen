extends Control

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const BattleStateMachine = preload("res://scripts/gameplay/BattleStateMachine.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")
const SpellCatalog = preload("res://scripts/gameplay/catalog/SpellCatalog.gd")

@onready var battle_info_label: Label = %BattleInfoLabel
@onready var battle_log: RichTextLabel = %BattleLog
@onready var party_label: Label = %PartyLabel
@onready var enemy_label: Label = %EnemyLabel
@onready var result_panel: PanelContainer = %ResultPanel
@onready var result_label: Label = %ResultLabel
@onready var continue_button: Button = %ContinueButton
@onready var attack_button: Button = %AttackButton
@onready var magic_button: Button = %MagicButton
@onready var item_button: Button = %ItemButton
@onready var flee_button: Button = %FleeButton
@onready var sub_menu_panel: PanelContainer = %SubMenuPanel
@onready var sub_menu_title: Label = %SubMenuTitle
@onready var sub_menu_list: ItemList = %SubMenuList
@onready var sub_menu_target_option: OptionButton = %SubMenuTargetOption
@onready var sub_menu_confirm_button: Button = %SubMenuConfirmButton
@onready var sub_menu_cancel_button: Button = %SubMenuCancelButton
@onready var sub_menu_hint: Label = %SubMenuHint

var game_state: Node = null
var startup_state: Node = null
var scene_router: Node = null
var battle_data: Dictionary = {}
var machine: BattleStateMachine = BattleStateMachine.new()
var _outcome_applied: bool = false
var _reward_logs: PackedStringArray = PackedStringArray()
var _submenu_mode: String = "" # "" | "item"
var _submenu_target_ids: PackedStringArray = PackedStringArray()

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	startup_state = get_node_or_null("/root/StartupState")
	scene_router = get_node_or_null("/root/SceneRouter")
	battle_data = _consume_battle_payload()
	if battle_data.is_empty():
		battle_data = {
			"world_x": 0,
			"world_y": 0,
			"local_x": 48,
			"local_y": 48,
			"biome_id": 7,
			"biome_name": "Grassland",
			"enemy_group": "Wild Beasts",
			"enemy_power": 8,
			"enemy_hp": 30,
			"enemy_count": 1,
			"rewards": {"exp": 18, "gold": 9, "items": []},
		}
	# Mark gameplay mode so realtime timekeeping can pause during battles.
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(
			SceneContracts.STATE_BATTLE,
			int(battle_data.get("world_x", 0)),
			int(battle_data.get("world_y", 0)),
			int(battle_data.get("local_x", 48)),
			int(battle_data.get("local_y", 48)),
			int(battle_data.get("biome_id", -1)),
			String(battle_data.get("biome_name", ""))
		)
	var party_state: Variant = null
	if game_state != null:
		party_state = game_state.party
	machine.begin(battle_data, party_state)
	_wire_buttons()
	if result_panel:
		result_panel.visible = false
	if sub_menu_panel:
		sub_menu_panel.visible = false
	_refresh_header()
	if enemy_label:
		var grp: String = String(battle_data.get("enemy_group", "Wild Beasts"))
		var cnt: int = max(1, int(battle_data.get("enemy_count", 1)))
		enemy_label.text = "Enemies\n%s x%d" % [grp, cnt]
	var opener: String = String(battle_data.get("opener", "normal"))
	if opener == "preemptive":
		_append_log("Preemptive strike!")
	elif opener == "back_attack":
		_append_log("Ambushed from behind!")
	_append_log("Enemies appeared: %s" % String(battle_data.get("enemy_group", "Wild Beasts")))
	var st0: Dictionary = machine.get_state_summary()
	var who: String = String(st0.get("select_member_name", "Party"))
	_append_log("Choose command for %s: Attack, Magic, Item, or Flee" % who)
	_apply_auto_battle_if_enabled()
	_refresh_panels()
	set_process_unhandled_input(true)

func _apply_auto_battle_if_enabled() -> void:
	if game_state == null or not game_state.has_method("get_settings_snapshot"):
		return
	var settings_data: Dictionary = game_state.get_settings_snapshot()
	if not bool(settings_data.get("auto_battle_enabled", false)):
		return
	var safety: int = 0
	while machine.can_accept_input() and safety < 16:
		safety += 1
		_apply_command("attack")
		if machine.phase == BattleStateMachine.Phase.RESOLVED:
			break

func _consume_battle_payload() -> Dictionary:
	if game_state != null and game_state.has_method("consume_pending_battle"):
		var data_from_state: Dictionary = game_state.consume_pending_battle()
		if not data_from_state.is_empty():
			return data_from_state
	if startup_state != null and startup_state.has_method("consume_battle"):
		return startup_state.consume_battle()
	return {}

func _wire_buttons() -> void:
	if attack_button and not attack_button.pressed.is_connected(_on_attack_pressed):
		attack_button.pressed.connect(_on_attack_pressed)
	if magic_button and not magic_button.pressed.is_connected(_on_magic_pressed):
		magic_button.pressed.connect(_on_magic_pressed)
	if item_button and not item_button.pressed.is_connected(_on_item_pressed):
		item_button.pressed.connect(_on_item_pressed)
	if flee_button and not flee_button.pressed.is_connected(_on_flee_pressed):
		flee_button.pressed.connect(_on_flee_pressed)
	if continue_button and not continue_button.pressed.is_connected(_on_continue_pressed):
		continue_button.pressed.connect(_on_continue_pressed)
	if sub_menu_confirm_button and not sub_menu_confirm_button.pressed.is_connected(_on_sub_menu_confirm_pressed):
		sub_menu_confirm_button.pressed.connect(_on_sub_menu_confirm_pressed)
	if sub_menu_cancel_button and not sub_menu_cancel_button.pressed.is_connected(_on_sub_menu_cancel_pressed):
		sub_menu_cancel_button.pressed.connect(_on_sub_menu_cancel_pressed)
	if sub_menu_list and not sub_menu_list.item_selected.is_connected(_on_sub_menu_item_selected):
		sub_menu_list.item_selected.connect(_on_sub_menu_item_selected)

func _refresh_header() -> void:
	if battle_info_label == null:
		return
	var state: Dictionary = machine.get_state_summary()
	battle_info_label.text = "Battle (%d,%d) %s | Turn %d | Party HP %d/%d | Enemy HP %d/%d" % [
		int(battle_data.get("world_x", 0)),
		int(battle_data.get("world_y", 0)),
		String(battle_data.get("biome_name", "Unknown")),
		int(state.get("turn_index", 1)),
		int(state.get("party_hp", 0)),
		int(state.get("party_hp_max", 0)),
		int(state.get("enemy_hp", 0)),
		int(state.get("enemy_hp_max", 0)),
	]

func _append_log(text_line: String) -> void:
	if battle_log == null:
		return
	if battle_log.text.is_empty():
		battle_log.text = text_line
	else:
		battle_log.text += "\n" + text_line

func _apply_command(command_id: String) -> void:
	if not machine.can_accept_input():
		return
	var out: Dictionary = machine.apply_player_command(command_id)
	var logs: PackedStringArray = out.get("logs", PackedStringArray())
	for line in logs:
		_append_log(String(line))
	var consumes: Variant = out.get("consumed_items", [])
	if game_state != null and game_state.has_method("consume_inventory_items") and typeof(consumes) == TYPE_ARRAY:
		game_state.consume_inventory_items(consumes)
	_refresh_header()
	_refresh_panels()
	if bool(out.get("resolved", false)):
		_show_result_panel(machine.result)

func _on_attack_pressed() -> void:
	_apply_command("attack")

func _on_magic_pressed() -> void:
	_open_magic_submenu()

func _on_item_pressed() -> void:
	_open_item_submenu()

func _on_flee_pressed() -> void:
	_apply_command("flee")

func _unhandled_input(event: InputEvent) -> void:
	var vp: Viewport = get_viewport()
	if event.is_action_pressed("ui_cancel"):
		if _submenu_mode != "":
			_close_submenu()
			if vp:
				vp.set_input_as_handled()
			return
	if event is InputEventKey and event.pressed and not event.echo:
		if _submenu_mode != "" and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
			_on_sub_menu_confirm_pressed()
			if vp:
				vp.set_input_as_handled()
			return

func _show_result_panel(result_data: Dictionary) -> void:
	if result_panel:
		result_panel.visible = true
	if attack_button: attack_button.disabled = true
	if magic_button: magic_button.disabled = true
	if item_button: item_button.disabled = true
	if flee_button: flee_button.disabled = true
	if result_label == null:
		return
	_apply_outcome_if_needed(result_data)
	if bool(result_data.get("victory", false)):
		if _reward_logs.is_empty():
			var rewards: Dictionary = result_data.get("rewards", {})
			result_label.text = "Victory!\nEXP +%d\nGold +%d" % [int(rewards.get("exp", 0)), int(rewards.get("gold", 0))]
		else:
			result_label.text = "Victory!\n\n%s" % "\n".join(_reward_logs)
	elif bool(result_data.get("escaped", false)):
		result_label.text = "Escaped safely."
	else:
		result_label.text = "Defeat.\nGame Over."

func _open_item_submenu() -> void:
	if sub_menu_panel == null or sub_menu_list == null:
		_append_log("Item menu UI is missing.")
		return
	if not machine.can_accept_input():
		return
	_submenu_mode = "item"
	if sub_menu_title:
		sub_menu_title.text = "Items"
	if sub_menu_hint:
		sub_menu_hint.text = "Select an item and a target. Enter confirms. Esc cancels."
	_refresh_item_list()
	_refresh_target_options()
	sub_menu_panel.visible = true
	_set_command_buttons_enabled(false)

func _open_magic_submenu() -> void:
	if sub_menu_panel == null or sub_menu_list == null:
		_append_log("Magic menu UI is missing.")
		return
	if not machine.can_accept_input():
		return
	var cur: Dictionary = machine.current_member()
	var member_id: String = String(cur.get("id", ""))
	var spells: PackedStringArray = SpellCatalog.spells_for_member(member_id)
	if spells.is_empty():
		_append_log("%s has no spells." % String(cur.get("name", "Member")))
		return
	_submenu_mode = "magic"
	if sub_menu_title:
		sub_menu_title.text = "Magic"
	if sub_menu_hint:
		sub_menu_hint.text = "Select a spell and a target. Enter confirms. Esc cancels."
	_refresh_spell_list(spells)
	_refresh_magic_targets_for_selected_spell()
	sub_menu_panel.visible = true
	_set_command_buttons_enabled(false)

func _close_submenu() -> void:
	_submenu_mode = ""
	if sub_menu_panel:
		sub_menu_panel.visible = false
	_set_command_buttons_enabled(true)

func _set_command_buttons_enabled(enabled: bool) -> void:
	if attack_button: attack_button.disabled = not enabled
	if magic_button: magic_button.disabled = not enabled
	if item_button: item_button.disabled = not enabled
	if flee_button: flee_button.disabled = not enabled

func _refresh_item_list() -> void:
	sub_menu_list.clear()
	if game_state == null or game_state.get("party") == null:
		sub_menu_list.add_item("(no party)")
		sub_menu_list.set_item_disabled(0, true)
		return
	var inv: Dictionary = game_state.party.inventory
	var names: Array[String] = []
	for key in inv.keys():
		var item_name: String = String(key)
		var count: int = int(inv.get(key, 0))
		if count <= 0:
			continue
		var item: Dictionary = ItemCatalog.get_item(item_name)
		if String(item.get("kind", "")) != "consumable":
			continue
		names.append(item_name)
	names.sort()
	if names.is_empty():
		sub_menu_list.add_item("(no consumables)")
		sub_menu_list.set_item_disabled(0, true)
		return
	for item_name in names:
		var count: int = int(inv.get(item_name, 0))
		var label: String = "%s x%d" % [item_name, count] if count > 1 else item_name
		var idx: int = sub_menu_list.get_item_count()
		sub_menu_list.add_item(label)
		sub_menu_list.set_item_metadata(idx, item_name)
	if sub_menu_list.get_item_count() > 0:
		sub_menu_list.select(0)

func _refresh_target_options() -> void:
	_submenu_target_ids = PackedStringArray()
	if sub_menu_target_option:
		sub_menu_target_option.clear()
	var st: Dictionary = machine.get_state_summary()
	var party_list: Array = st.get("party", [])
	for entry in party_list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if int(entry.get("hp", 0)) <= 0:
			continue
		_submenu_target_ids.append(String(entry.get("id", "")))
		if sub_menu_target_option:
			sub_menu_target_option.add_item(String(entry.get("name", "Member")), _submenu_target_ids.size() - 1)
	if sub_menu_target_option:
		sub_menu_target_option.select(0)

func _refresh_enemy_target_options() -> void:
	_submenu_target_ids = PackedStringArray()
	if sub_menu_target_option:
		sub_menu_target_option.clear()
	var st: Dictionary = machine.get_state_summary()
	var enemy_list: Array = st.get("enemies", [])
	for entry in enemy_list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if int(entry.get("hp", 0)) <= 0:
			continue
		_submenu_target_ids.append(String(entry.get("id", "")))
		if sub_menu_target_option:
			sub_menu_target_option.add_item(String(entry.get("name", "Enemy")), _submenu_target_ids.size() - 1)
	if sub_menu_target_option:
		sub_menu_target_option.select(0)

func _refresh_spell_list(spells: PackedStringArray) -> void:
	sub_menu_list.clear()
	if spells.is_empty():
		sub_menu_list.add_item("(no spells)")
		sub_menu_list.set_item_disabled(0, true)
		return
	for spell_name in spells:
		var data: Dictionary = SpellCatalog.get_spell(String(spell_name))
		var mp_cost: int = int(data.get("mp_cost", 0))
		var idx: int = sub_menu_list.get_item_count()
		sub_menu_list.add_item("%s  (MP %d)" % [String(spell_name), mp_cost])
		sub_menu_list.set_item_metadata(idx, String(spell_name))
	sub_menu_list.select(0)

func _refresh_magic_targets_for_selected_spell() -> void:
	var spell_name: String = _selected_submenu_item_name()
	if spell_name.is_empty():
		_refresh_target_options()
		return
	var spell: Dictionary = SpellCatalog.get_spell(spell_name)
	var tgt: String = String(spell.get("target", "enemy"))
	if tgt == "party":
		_refresh_target_options()
	else:
		_refresh_enemy_target_options()

func _selected_submenu_item_name() -> String:
	if sub_menu_list == null:
		return ""
	var selected: PackedInt32Array = sub_menu_list.get_selected_items()
	if selected.is_empty():
		return ""
	var idx: int = int(selected[0])
	return String(sub_menu_list.get_item_metadata(idx))

func _selected_submenu_target_id() -> String:
	if sub_menu_target_option == null:
		return ""
	var idx: int = int(sub_menu_target_option.selected)
	if idx < 0 or idx >= _submenu_target_ids.size():
		return ""
	return String(_submenu_target_ids[idx])

func _on_sub_menu_confirm_pressed() -> void:
	if _submenu_mode == "item":
		var item_name: String = _selected_submenu_item_name()
		if item_name.is_empty():
			_append_log("Select an item.")
			return
		var target_id: String = _selected_submenu_target_id()
		var cmd: String = "item:%s" % item_name
		if not target_id.is_empty():
			cmd += "@%s" % target_id
		_close_submenu()
		_apply_command(cmd)
	if _submenu_mode == "magic":
		var spell_name: String = _selected_submenu_item_name()
		if spell_name.is_empty():
			_append_log("Select a spell.")
			return
		var target_id: String = _selected_submenu_target_id()
		var cmd2: String = "magic:%s" % spell_name
		if not target_id.is_empty():
			cmd2 += "@%s" % target_id
		_close_submenu()
		_apply_command(cmd2)

func _on_sub_menu_cancel_pressed() -> void:
	_close_submenu()

func _on_sub_menu_item_selected(_idx: int) -> void:
	if _submenu_mode == "magic":
		_refresh_magic_targets_for_selected_spell()

func _apply_outcome_if_needed(outcome: Dictionary) -> void:
	if _outcome_applied:
		return
	_outcome_applied = true
	_reward_logs = PackedStringArray()
	if game_state != null and game_state.has_method("apply_battle_result"):
		var applied: Dictionary = game_state.apply_battle_result(outcome)
		_reward_logs = applied.get("reward_logs", PackedStringArray())

func _refresh_panels() -> void:
	var st: Dictionary = machine.get_state_summary()
	if party_label:
		var lines: PackedStringArray = PackedStringArray()
		lines.append("Party")
		var party_list: Array = st.get("party", [])
		var sel_id: String = String(st.get("select_member_id", ""))
		for entry in party_list:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var idv: String = String(entry.get("id", ""))
			var namev: String = String(entry.get("name", "Member"))
			var hpv: int = int(entry.get("hp", 0))
			var hpmax: int = int(entry.get("hp_max", 0))
			var mpv: int = int(entry.get("mp", 0))
			var mpmax: int = int(entry.get("mp_max", 0))
			var prefix: String = "> " if machine.can_accept_input() and idv == sel_id else "  "
			lines.append("%s%s HP %d/%d MP %d/%d" % [prefix, namev, hpv, hpmax, mpv, mpmax])
		party_label.text = "\n".join(lines)
	if enemy_label:
		var elines: PackedStringArray = PackedStringArray()
		elines.append("Enemies")
		var enemy_list: Array = st.get("enemies", [])
		for i in range(enemy_list.size()):
			var entry2: Variant = enemy_list[i]
			if typeof(entry2) != TYPE_DICTIONARY:
				continue
			var name2: String = String(entry2.get("name", "Enemy"))
			var hp2: int = int(entry2.get("hp", 0))
			var hpmax2: int = int(entry2.get("hp_max", 0))
			elines.append("%s %d/%d" % [name2, hp2, hpmax2])
		enemy_label.text = "\n".join(elines)

func _on_continue_pressed() -> void:
	var outcome: Dictionary = machine.result.duplicate(true)
	_apply_outcome_if_needed(outcome)
	if bool(outcome.get("defeat", false)):
		if scene_router != null and scene_router.has_method("goto_game_over"):
			scene_router.goto_game_over()
		else:
			get_tree().change_scene_to_file(SceneContracts.SCENE_GAME_OVER)
		return
	var return_scene: String = String(battle_data.get("return_scene", SceneContracts.STATE_REGIONAL))
	var world_x: int = int(battle_data.get("world_x", 0))
	var world_y: int = int(battle_data.get("world_y", 0))
	var local_x: int = int(battle_data.get("local_x", 48))
	var local_y: int = int(battle_data.get("local_y", 48))
	var biome_id: int = int(battle_data.get("biome_id", 7))
	var biome_name: String = String(battle_data.get("biome_name", ""))
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(return_scene, world_x, world_y, local_x, local_y, biome_id, biome_name)
		if game_state.has_method("advance_world_time"):
			game_state.advance_world_time(20 if bool(outcome.get("victory", false)) else 8, "battle")
	if startup_state != null and startup_state.has_method("set_selected_world_tile"):
		startup_state.set_selected_world_tile(world_x, world_y, biome_id, biome_name, local_x, local_y)
	if return_scene == SceneContracts.STATE_LOCAL:
		var return_poi: Dictionary = battle_data.get("return_poi", {})
		if typeof(return_poi) != TYPE_DICTIONARY:
			return_poi = {}
		if not return_poi.is_empty() and scene_router != null and scene_router.has_method("goto_local"):
			scene_router.goto_local(return_poi)
		else:
			get_tree().change_scene_to_file(SceneContracts.SCENE_LOCAL_AREA)
		return
	if scene_router != null and scene_router.has_method("goto_regional"):
		scene_router.goto_regional(world_x, world_y, local_x, local_y, biome_id, biome_name)
	else:
		get_tree().change_scene_to_file(SceneContracts.SCENE_REGIONAL_MAP)
