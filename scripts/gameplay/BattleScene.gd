extends Control

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const BattleStateMachine = preload("res://scripts/gameplay/BattleStateMachine.gd")
const DeterministicRng = preload("res://scripts/gameplay/DeterministicRng.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")
const SpellCatalog = preload("res://scripts/gameplay/catalog/SpellCatalog.gd")
const WorldTimeStateModel = preload("res://scripts/gameplay/models/WorldTimeState.gd")
const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")
const BiomePalette = preload("res://scripts/style/BiomePalette.gd")

@onready var bg_rect: ColorRect = $BG
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
var _bg_time_accum: float = 0.0
var _biome_palette: Object = null
var _command_buttons: Array[Button] = []
var _command_base_text: Dictionary = {} # Button -> base label (without pointer)

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	startup_state = get_node_or_null("/root/StartupState")
	scene_router = get_node_or_null("/root/SceneRouter")
	_biome_palette = BiomePalette.new()
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
	_init_command_menu()
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
	set_process(true)
	_init_battle_background()

func _init_command_menu() -> void:
	_command_buttons = []
	_command_base_text.clear()
	for b in [attack_button, magic_button, item_button, flee_button]:
		if b == null:
			continue
		_command_buttons.append(b)
		_command_base_text[b] = String(b.text)
		b.focus_mode = Control.FOCUS_ALL
		if not b.focus_entered.is_connected(_on_command_focus_entered):
			b.focus_entered.connect(_on_command_focus_entered)
	call_deferred("_focus_default_command")

func _focus_default_command() -> void:
	if attack_button != null and not attack_button.disabled:
		attack_button.grab_focus()
	_update_command_menu_visuals()

func _on_command_focus_entered() -> void:
	_update_command_menu_visuals()

func _update_command_menu_visuals() -> void:
	var vp: Viewport = get_viewport()
	var focused: Control = vp.gui_get_focus_owner() if vp else null
	for b in _command_buttons:
		if b == null:
			continue
		var base: String = String(_command_base_text.get(b, b.text))
		var label: String = base.to_upper()
		var prefix: String = "> " if focused == b else "  "
		b.text = prefix + label

func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	_bg_time_accum += delta
	_update_battle_background()

func _init_battle_background() -> void:
	if bg_rect == null:
		return
	var shader: Shader = load("res://shaders/rendering/battle_background.gdshader")
	if shader == null:
		return
	# Ensure shader output isn't tinted by the ColorRect's base color.
	bg_rect.color = Color(1, 1, 1, 1)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	bg_rect.material = mat
	_update_battle_background(true)

func _update_battle_background(force_static: bool = false) -> void:
	if bg_rect == null:
		return
	var mat: ShaderMaterial = bg_rect.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("u_time", float(Time.get_ticks_msec()) / 1000.0)
	var biome_id: int = int(battle_data.get("biome_id", int(BiomeClassifier.Biome.GRASSLAND)))
	mat.set_shader_parameter("u_kind", _battle_bg_kind_for_biome(biome_id))
	var pal: Variant = _biome_palette
	if pal == null:
		pal = BiomePalette.new()
	var c: Color = pal.color_for_biome(biome_id, false)
	mat.set_shader_parameter("u_biome_color", Vector3(c.r, c.g, c.b))
	mat.set_shader_parameter("u_time_of_day", _time_of_day01())

	var wthr: Dictionary = _weather_for_battle(biome_id)
	mat.set_shader_parameter("u_cloud_coverage", float(wthr.get("cloud_coverage", 0.4)))
	mat.set_shader_parameter("u_rain", float(wthr.get("rain", 0.0)))

	if force_static:
		# Place moons deterministically per battle.
		_set_moons(mat)

func _time_of_day01() -> float:
	if game_state != null and game_state.get("world_time") != null:
		var wt = game_state.world_time
		var sod: int = int(wt.second_of_day) if ("second_of_day" in wt) else int(wt.minute_of_day) * 60
		sod = clamp(sod, 0, WorldTimeStateModel.SECONDS_PER_DAY - 1)
		return float(sod) / float(WorldTimeStateModel.SECONDS_PER_DAY)
	return 0.5

func _day_index_0_364() -> int:
	if game_state != null and game_state.get("world_time") != null:
		var wt = game_state.world_time
		var day_index: int = max(0, int(wt.day) - 1)
		for m in range(1, int(wt.month)):
			day_index += WorldTimeStateModel.days_in_month(m)
		return clamp(day_index, 0, 364)
	return 0

func _weather_for_battle(biome_id: int) -> Dictionary:
	var wx: int = int(battle_data.get("world_x", 0))
	var wy: int = int(battle_data.get("world_y", 0))
	var seed: int = int(game_state.world_seed_hash) if game_state != null and int(game_state.world_seed_hash) != 0 else 1
	var d: int = _day_index_0_364()
	var key: String = "wthr|%d|%d|d=%d" % [wx, wy, d]
	var base: float = DeterministicRng.randf01(seed, key)
	var humidity: float = _humidity_for_biome(biome_id)
	var cloud_coverage: float = clamp(0.20 + 0.70 * base + (humidity - 0.5) * 0.20, 0.0, 1.0)
	# Rain: require high humidity + high cloud coverage.
	var rain: float = 0.0
	if cloud_coverage > 0.72 and humidity > 0.55:
		rain = clamp((cloud_coverage - 0.72) / 0.28, 0.0, 1.0) * clamp((humidity - 0.55) / 0.45, 0.0, 1.0)
	# Cold biomes bias toward snow/clear skies (no rain for now).
	if biome_id == BiomeClassifier.Biome.ICE_SHEET or biome_id == BiomeClassifier.Biome.GLACIER or biome_id == BiomeClassifier.Biome.ALPINE:
		rain = 0.0
	return {"cloud_coverage": cloud_coverage, "rain": rain}

func _humidity_for_biome(biome_id: int) -> float:
	match biome_id:
		BiomeClassifier.Biome.RAINFOREST, BiomeClassifier.Biome.TROPICAL_FOREST:
			return 0.85
		BiomeClassifier.Biome.SWAMP, BiomeClassifier.Biome.FROZEN_MARSH:
			return 0.80
		BiomeClassifier.Biome.TEMPERATE_FOREST, BiomeClassifier.Biome.BOREAL_FOREST, BiomeClassifier.Biome.CONIFER_FOREST, BiomeClassifier.Biome.FROZEN_FOREST:
			return 0.65
		BiomeClassifier.Biome.DESERT_SAND, BiomeClassifier.Biome.WASTELAND, BiomeClassifier.Biome.SALT_DESERT, BiomeClassifier.Biome.DESERT_ICE:
			return 0.18
		BiomeClassifier.Biome.ICE_SHEET, BiomeClassifier.Biome.GLACIER:
			return 0.30
		_:
			return 0.45

func _battle_bg_kind_for_biome(biome_id: int) -> int:
	# See shader uniform `u_kind`.
	match biome_id:
		BiomeClassifier.Biome.BEACH:
			return 5
		BiomeClassifier.Biome.SWAMP, BiomeClassifier.Biome.FROZEN_MARSH:
			return 6
		BiomeClassifier.Biome.MOUNTAINS, BiomeClassifier.Biome.ALPINE, BiomeClassifier.Biome.GLACIER:
			return 3
		BiomeClassifier.Biome.HILLS, BiomeClassifier.Biome.FROZEN_HILLS, BiomeClassifier.Biome.SCORCHED_HILLS:
			return 2
		BiomeClassifier.Biome.DESERT_SAND, BiomeClassifier.Biome.WASTELAND, BiomeClassifier.Biome.SALT_DESERT, BiomeClassifier.Biome.DESERT_ICE:
			return 4
		BiomeClassifier.Biome.TROPICAL_FOREST, BiomeClassifier.Biome.BOREAL_FOREST, BiomeClassifier.Biome.CONIFER_FOREST, BiomeClassifier.Biome.TEMPERATE_FOREST, BiomeClassifier.Biome.RAINFOREST, BiomeClassifier.Biome.FROZEN_FOREST, BiomeClassifier.Biome.SCORCHED_FOREST:
			return 1
		BiomeClassifier.Biome.ICE_SHEET:
			return 7
		_:
			return 0

func _set_moons(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	var wx: int = int(battle_data.get("world_x", 0))
	var wy: int = int(battle_data.get("world_y", 0))
	var seed: int = int(game_state.world_seed_hash) if game_state != null and int(game_state.world_seed_hash) != 0 else 1
	var moon_count: int = 0
	var moon_seed_val: float = 0.0
	if startup_state != null:
		moon_count = clamp(int(startup_state.get("moon_count")), 0, 3)
		moon_seed_val = float(startup_state.get("moon_seed"))
	var d: int = _day_index_0_364()
	var base: int = int(abs(int(moon_seed_val * 1000.0))) + d
	var moons: Array[Vector4] = []
	for i in range(moon_count):
		var kroot: String = "moon|%d|%d|%d" % [i, wx, wy]
		var mx: float = lerp(0.18, 0.82, DeterministicRng.randf01(seed, kroot + "|x"))
		var my: float = lerp(0.10, 0.32, DeterministicRng.randf01(seed, kroot + "|y"))
		var mr: float = lerp(0.035, 0.070, DeterministicRng.randf01(seed, kroot + "|r"))
		var period: float = float(18 + i * 9)
		var phase: float = fposmod(float(base + i * 7) / period, 1.0)
		var bright: float = 0.35 + 0.65 * (0.5 - 0.5 * cos(phase * TAU))
		moons.append(Vector4(mx, my, mr, bright))
	mat.set_shader_parameter("u_moon0", moons[0] if moons.size() > 0 else Vector4(-1, -1, 0, 0))
	mat.set_shader_parameter("u_moon1", moons[1] if moons.size() > 1 else Vector4(-1, -1, 0, 0))
	mat.set_shader_parameter("u_moon2", moons[2] if moons.size() > 2 else Vector4(-1, -1, 0, 0))

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
	# FF-like command navigation when not in a submenu.
	if _submenu_mode == "" and machine.can_accept_input() and (result_panel == null or not result_panel.visible):
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_UP:
				_cycle_command_focus(-1)
				if vp:
					vp.set_input_as_handled()
				return
			if event.keycode == KEY_DOWN:
				_cycle_command_focus(1)
				if vp:
					vp.set_input_as_handled()
				return
	if event is InputEventKey and event.pressed and not event.echo:
		if _submenu_mode != "" and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
			_on_sub_menu_confirm_pressed()
			if vp:
				vp.set_input_as_handled()
			return

func _cycle_command_focus(delta: int) -> void:
	if _command_buttons.is_empty():
		return
	var vp: Viewport = get_viewport()
	var focused: Control = vp.gui_get_focus_owner() if vp else null
	var idx: int = _command_buttons.find(focused)
	if idx < 0:
		idx = 0
	var n: int = _command_buttons.size()
	for _i in range(n):
		idx = posmod(idx + delta, n)
		var b: Button = _command_buttons[idx]
		if b == null or b.disabled:
			continue
		b.grab_focus()
		break
	_update_command_menu_visuals()

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
	_refresh_item_targets_for_selected_item()
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
	if enabled:
		call_deferred("_focus_default_command")
	else:
		_update_command_menu_visuals()

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
	var prefer: String = ""
	if int(inv.get("Potion", 0)) > 0:
		prefer = "Potion"
	elif int(inv.get("Herb", 0)) > 0:
		prefer = "Herb"
	var prefer_idx: int = -1
	for item_name in names:
		var count: int = int(inv.get(item_name, 0))
		var label: String = "%s x%d" % [item_name, count] if count > 1 else item_name
		var idx: int = sub_menu_list.get_item_count()
		sub_menu_list.add_item(label)
		sub_menu_list.set_item_metadata(idx, item_name)
		if prefer_idx < 0 and item_name == prefer:
			prefer_idx = idx
	if sub_menu_list.get_item_count() > 0:
		sub_menu_list.select(prefer_idx if prefer_idx >= 0 else 0)

func _refresh_target_options() -> void:
	_submenu_target_ids = PackedStringArray()
	if sub_menu_target_option:
		sub_menu_target_option.clear()
	var st: Dictionary = machine.get_state_summary()
	var want_id: String = String(st.get("select_member_id", ""))
	var want_idx: int = -1
	var party_list: Array = st.get("party", [])
	for entry in party_list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if int(entry.get("hp", 0)) <= 0:
			continue
		_submenu_target_ids.append(String(entry.get("id", "")))
		if want_idx < 0 and String(entry.get("id", "")) == want_id:
			want_idx = _submenu_target_ids.size() - 1
		if sub_menu_target_option:
			sub_menu_target_option.add_item(String(entry.get("name", "Member")), _submenu_target_ids.size() - 1)
	if sub_menu_target_option:
		if want_idx >= 0 and want_idx < _submenu_target_ids.size():
			sub_menu_target_option.select(want_idx)
		else:
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

func _refresh_item_targets_for_selected_item() -> void:
	var item_name: String = _selected_submenu_item_name()
	if item_name.is_empty():
		_refresh_target_options()
		return
	var item: Dictionary = ItemCatalog.get_item(item_name)
	var effect: Dictionary = item.get("use_effect", {})
	var tgt: String = String(effect.get("target", item.get("target", ""))).to_lower()
	if tgt.is_empty():
		var t: String = String(effect.get("type", ""))
		tgt = "enemy" if t == "damage" else "party"
	if tgt == "enemy":
		_refresh_enemy_target_options()
	elif tgt == "any":
		_refresh_any_target_options()
	else:
		_refresh_target_options()

func _refresh_any_target_options() -> void:
	_submenu_target_ids = PackedStringArray()
	if sub_menu_target_option:
		sub_menu_target_option.clear()
	var st: Dictionary = machine.get_state_summary()
	var want_id: String = String(st.get("select_member_id", ""))
	var want_idx: int = -1
	var party_list: Array = st.get("party", [])
	for entry in party_list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if int(entry.get("hp", 0)) <= 0:
			continue
		var idv: String = String(entry.get("id", ""))
		_submenu_target_ids.append(idv)
		if want_idx < 0 and idv == want_id:
			want_idx = _submenu_target_ids.size() - 1
		if sub_menu_target_option:
			sub_menu_target_option.add_item("Ally: %s" % String(entry.get("name", "Member")), _submenu_target_ids.size() - 1)
	var enemy_list: Array = st.get("enemies", [])
	for entry2 in enemy_list:
		if typeof(entry2) != TYPE_DICTIONARY:
			continue
		if int(entry2.get("hp", 0)) <= 0:
			continue
		_submenu_target_ids.append(String(entry2.get("id", "")))
		if sub_menu_target_option:
			sub_menu_target_option.add_item("Enemy: %s" % String(entry2.get("name", "Enemy")), _submenu_target_ids.size() - 1)
	if sub_menu_target_option and _submenu_target_ids.size() > 0:
		sub_menu_target_option.select(want_idx if want_idx >= 0 else 0)

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
	elif _submenu_mode == "item":
		_refresh_item_targets_for_selected_item()

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
			# Fallback path: still pass the POI payload (including interior_x/y) to the next scene.
			if not return_poi.is_empty():
				if game_state != null and game_state.has_method("queue_poi"):
					game_state.queue_poi(return_poi)
				if startup_state != null and startup_state.has_method("queue_poi"):
					startup_state.queue_poi(return_poi)
			get_tree().change_scene_to_file(SceneContracts.SCENE_LOCAL_AREA)
		return
	if scene_router != null and scene_router.has_method("goto_regional"):
		scene_router.goto_regional(world_x, world_y, local_x, local_y, biome_id, biome_name)
	else:
		get_tree().change_scene_to_file(SceneContracts.SCENE_REGIONAL_MAP)
