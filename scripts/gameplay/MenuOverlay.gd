extends CanvasLayer

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")
const InventorySlotButton = preload("res://scripts/gameplay/ui/InventorySlotButton.gd")
const MemberRowDropTarget = preload("res://scripts/gameplay/ui/MemberRowDropTarget.gd")
const StatBar = preload("res://scripts/gameplay/ui/StatBar.gd")

signal closed

@onready var root_panel: PanelContainer = %RootPanel
@onready var status_label: Label = %StatusLabel
@onready var tabs: TabContainer = %Tabs
@onready var overview_text: RichTextLabel = %OverviewText
@onready var party_member_list: VBoxContainer = %PartyMemberList
@onready var quests_text: RichTextLabel = %QuestsText
@onready var settings_text: Label = %SettingsText
@onready var encounter_slider: HSlider = %EncounterSlider
@onready var encounter_value_label: Label = %EncounterValue
@onready var text_speed_slider: HSlider = %TextSpeedSlider
@onready var text_speed_value_label: Label = %TextSpeedValue
@onready var auto_battle_check: CheckBox = %AutoBattleCheck
@onready var apply_settings_button: Button = %ApplySettingsButton
@onready var save_slot_option: OptionButton = %SaveSlotOption
@onready var save_button: Button = %SaveButton
@onready var load_button: Button = %LoadButton
@onready var quit_button: Button = %QuitButton
@onready var close_button: Button = %CloseButton

# Inventory v2 (Valheim-like slot bag per member).
@onready var member_list: VBoxContainer = %MemberList
@onready var bag_grid: GridContainer = %BagGrid
@onready var item_details: RichTextLabel = %ItemDetails
@onready var item_context_menu: PopupMenu = %ItemContextMenu
@onready var use_target_popup: PopupPanel = %UseTargetPopup
@onready var use_target_title: Label = %UseTargetTitle
@onready var use_target_list: VBoxContainer = %UseTargetList
@onready var use_target_cancel: Button = %UseTargetCancel

var game_state: Node = null
var game_events: Node = null
var _context_title: String = "Menu"

var _selected_member_id: String = ""
var _selected_slot_idx: int = -1
var _last_action_message: String = ""

var _slot_group: ButtonGroup = ButtonGroup.new()
var _member_rows: Dictionary = {} # member_id -> Control

var _ctx_member_id: String = ""
var _ctx_slot_idx: int = -1
var _use_from_member_id: String = ""
var _use_from_slot_idx: int = -1

const CTX_USE: int = 1
const CTX_EQUIP_TOGGLE: int = 2
const CTX_DROP: int = 3

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	game_events = get_node_or_null("/root/GameEvents")
	visible = false
	set_process_unhandled_input(true)
	if root_panel:
		root_panel.visible = true
	_wire_buttons()
	_wire_settings_controls()
	_wire_save_slots()
	_wire_inventory_v2_controls()
	_apply_tab_titles()
	_connect_game_events()

func _connect_game_events() -> void:
	if game_events == null:
		return
	if game_events.has_signal("party_changed") and not game_events.party_changed.is_connected(_on_party_changed):
		game_events.party_changed.connect(_on_party_changed)
	if game_events.has_signal("inventory_changed") and not game_events.inventory_changed.is_connected(_on_inventory_changed):
		game_events.inventory_changed.connect(_on_inventory_changed)

func _wire_buttons() -> void:
	if save_button and not save_button.pressed.is_connected(_on_save_pressed):
		save_button.pressed.connect(_on_save_pressed)
	if load_button and not load_button.pressed.is_connected(_on_load_pressed):
		load_button.pressed.connect(_on_load_pressed)
	if quit_button and not quit_button.pressed.is_connected(_on_quit_pressed):
		quit_button.pressed.connect(_on_quit_pressed)
	if close_button and not close_button.pressed.is_connected(_on_close_pressed):
		close_button.pressed.connect(_on_close_pressed)
	if apply_settings_button and not apply_settings_button.pressed.is_connected(_on_apply_settings_pressed):
		apply_settings_button.pressed.connect(_on_apply_settings_pressed)

func _wire_inventory_v2_controls() -> void:
	if item_context_menu and not item_context_menu.id_pressed.is_connected(_on_item_context_id_pressed):
		item_context_menu.id_pressed.connect(_on_item_context_id_pressed)
	if use_target_cancel and not use_target_cancel.pressed.is_connected(_on_use_target_cancel_pressed):
		use_target_cancel.pressed.connect(_on_use_target_cancel_pressed)

func _wire_settings_controls() -> void:
	if encounter_slider and not encounter_slider.value_changed.is_connected(_on_encounter_slider_changed):
		encounter_slider.value_changed.connect(_on_encounter_slider_changed)
	if text_speed_slider and not text_speed_slider.value_changed.is_connected(_on_text_speed_slider_changed):
		text_speed_slider.value_changed.connect(_on_text_speed_slider_changed)
	_update_setting_value_labels()

func _wire_save_slots() -> void:
	if save_slot_option == null:
		return
	save_slot_option.clear()
	save_slot_option.add_item("Slot 1", 0)
	save_slot_option.add_item("Slot 2", 1)
	save_slot_option.add_item("Slot 3", 2)
	save_slot_option.select(0)

func _apply_tab_titles() -> void:
	if tabs == null:
		return
	tabs.set_tab_title(0, "Overview")
	tabs.set_tab_title(1, "Party")
	tabs.set_tab_title(2, "Characters")
	# Hide legacy equipment tab (inventory is unified with equipment now).
	if tabs.get_tab_count() > 3:
		tabs.set_tab_hidden(3, true)
	# Hide legacy stats tab (stats are shown in Party tab now).
	if tabs.get_tab_count() > 4:
		tabs.set_tab_hidden(4, true)
	if tabs.get_tab_count() > 5:
		tabs.set_tab_title(5, "Quests")
	if tabs.get_tab_count() > 6:
		tabs.set_tab_title(6, "Settings")

func open_overlay(context_title: String = "Menu") -> void:
	_context_title = context_title
	visible = true
	if status_label:
		status_label.text = "Context: %s" % context_title
	_sync_settings_controls()
	_refresh_all_ui()
	if game_events and game_events.has_signal("menu_opened"):
		game_events.emit_signal("menu_opened", context_title)

func close_overlay() -> void:
	if not visible:
		return
	visible = false
	_last_action_message = ""
	_hide_popups()
	emit_signal("closed")
	if game_events and game_events.has_signal("menu_closed"):
		game_events.emit_signal("menu_closed", _context_title)

func _hide_popups() -> void:
	if item_context_menu and item_context_menu.visible:
		item_context_menu.hide()
	if use_target_popup and use_target_popup.visible:
		use_target_popup.hide()

func _on_party_changed(_party_data: Dictionary) -> void:
	if visible:
		_refresh_inventory_v2()
		_refresh_snapshot()

func _on_inventory_changed(_inventory_data: Dictionary) -> void:
	if visible:
		_refresh_inventory_v2()

func _on_save_pressed() -> void:
	if game_state == null or not game_state.has_method("save_to_path"):
		return
	var ok_save: bool = bool(game_state.save_to_path(_selected_save_path()))
	if settings_text:
		settings_text.text = "Saved." if ok_save else "Save failed."
	if ok_save:
		_refresh_snapshot()

func _on_load_pressed() -> void:
	if game_state == null or not game_state.has_method("load_from_path"):
		return
	var ok_load: bool = bool(game_state.load_from_path(_selected_save_path()))
	if settings_text:
		settings_text.text = "Loaded." if ok_load else "Load failed (missing file/schema mismatch)."
	if ok_load:
		_sync_settings_controls()
		_refresh_all_ui()

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_close_pressed() -> void:
	close_overlay()

func _on_apply_settings_pressed() -> void:
	if game_state == null or not game_state.has_method("apply_settings_patch"):
		return
	var patch: Dictionary = {
		"encounter_rate_multiplier": float(encounter_slider.value) if encounter_slider else 1.0,
		"text_speed": float(text_speed_slider.value) if text_speed_slider else 1.0,
		"auto_battle_enabled": bool(auto_battle_check.button_pressed) if auto_battle_check else false,
	}
	game_state.apply_settings_patch(patch)
	_sync_settings_controls()
	_refresh_snapshot()

func _on_encounter_slider_changed(_value: float) -> void:
	_update_setting_value_labels()

func _on_text_speed_slider_changed(_value: float) -> void:
	_update_setting_value_labels()

func _update_setting_value_labels() -> void:
	if encounter_value_label and encounter_slider:
		encounter_value_label.text = "x%.2f" % float(encounter_slider.value)
	if text_speed_value_label and text_speed_slider:
		text_speed_value_label.text = "x%.2f" % float(text_speed_slider.value)

func _sync_settings_controls() -> void:
	if game_state == null or not game_state.has_method("get_settings_snapshot"):
		return
	var settings_data: Dictionary = game_state.get_settings_snapshot()
	if encounter_slider:
		encounter_slider.set_block_signals(true)
		encounter_slider.value = float(settings_data.get("encounter_rate_multiplier", 1.0))
		encounter_slider.set_block_signals(false)
	if text_speed_slider:
		text_speed_slider.set_block_signals(true)
		text_speed_slider.value = float(settings_data.get("text_speed", 1.0))
		text_speed_slider.set_block_signals(false)
	if auto_battle_check:
		auto_battle_check.button_pressed = bool(settings_data.get("auto_battle_enabled", false))
	_update_setting_value_labels()

func _selected_save_path() -> String:
	var slot_idx: int = 0
	if save_slot_option != null:
		slot_idx = save_slot_option.selected
	return SceneContracts.save_slot_path(slot_idx)

func _refresh_snapshot() -> void:
	if game_state == null or not game_state.has_method("get_menu_snapshot"):
		_set_text(overview_text, PackedStringArray(["No game state available."]))
		return
	var snap: Dictionary = game_state.get_menu_snapshot()
	_set_text(overview_text, snap.get("overview_lines", PackedStringArray()))
	_refresh_party_tab()
	_set_text(quests_text, snap.get("quest_lines", PackedStringArray()))
	if settings_text:
		settings_text.text = "\n".join(_to_lines(snap.get("settings_lines", PackedStringArray())))

func _refresh_all_ui() -> void:
	_refresh_snapshot()
	_refresh_inventory_v2()

func _set_text(target: RichTextLabel, lines_variant: Variant) -> void:
	if target == null:
		return
	var lines: PackedStringArray = _to_lines(lines_variant)
	target.text = "-" if lines.is_empty() else "\n".join(lines)

func _to_lines(lines_variant: Variant) -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	if typeof(lines_variant) == TYPE_PACKED_STRING_ARRAY:
		lines = lines_variant
	elif typeof(lines_variant) == TYPE_ARRAY:
		for item in lines_variant:
			lines.append(String(item))
	return lines

func _refresh_party_tab() -> void:
	if party_member_list == null:
		return
	for child in party_member_list.get_children():
		child.queue_free()
	var members: Array = _party_members()
	if members.is_empty():
		var empty := Label.new()
		empty.text = "No party members."
		party_member_list.add_child(empty)
		return
	for entry in members:
		if entry == null:
			continue
		var row := PanelContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(0, 98)
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 10)
		margin.add_theme_constant_override("margin_right", 10)
		margin.add_theme_constant_override("margin_top", 10)
		margin.add_theme_constant_override("margin_bottom", 10)
		row.add_child(margin)
		var vbox := VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 4)
		margin.add_child(vbox)

		var name_label := Label.new()
		name_label.text = "%s (Lv %d)" % [String(entry.display_name), int(entry.level)]
		vbox.add_child(name_label)

		var hp_label := Label.new()
		hp_label.text = "HP %d/%d" % [int(entry.hp), int(entry.max_hp)]
		vbox.add_child(hp_label)
		var hp := StatBar.new()
		hp.kind = "hp"
		hp.set_values(int(entry.hp), int(entry.max_hp), "hp")
		vbox.add_child(hp)

		var mp_label := Label.new()
		mp_label.text = "MP %d/%d" % [int(entry.mp), int(entry.max_mp)]
		vbox.add_child(mp_label)
		var mp := StatBar.new()
		mp.kind = "mp"
		mp.set_values(int(entry.mp), int(entry.max_mp), "mp")
		vbox.add_child(mp)

		var stats_label := Label.new()
		stats_label.text = "STR %d  DEF %d  AGI %d  INT %d" % [
			int(entry.strength),
			int(entry.defense),
			int(entry.agility),
			int(entry.intellect),
		]
		vbox.add_child(stats_label)

		party_member_list.add_child(row)

func _party_members() -> Array:
	if game_state == null:
		return []
	var p: Variant = game_state.get("party")
	if p == null:
		return []
	return p.members

func _find_member_by_id(member_id: String) -> Variant:
	for m in _party_members():
		if m == null:
			continue
		if String(m.member_id) == member_id:
			return m
	return null

func _refresh_inventory_v2() -> void:
	var members: Array = _party_members()
	if members.is_empty():
		_selected_member_id = ""
		_selected_slot_idx = -1
		_build_member_list([])
		_build_bag_grid(null)
		_set_item_details_for_empty()
		return
	if _selected_member_id.is_empty() or _find_member_by_id(_selected_member_id) == null:
		_selected_member_id = String(members[0].member_id)
	_selected_slot_idx = int(_selected_slot_idx)
	_build_member_list(members)
	var member: Variant = _find_member_by_id(_selected_member_id)
	_build_bag_grid(member)
	_refresh_item_details()

func _build_member_list(members: Array) -> void:
	if member_list == null:
		return
	for child in member_list.get_children():
		child.queue_free()
	_member_rows.clear()
	for entry in members:
		if entry == null:
			continue
		var member_id: String = String(entry.member_id)
		var row := MemberRowDropTarget.new()
		row.member_id = member_id
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(0, 62)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_on_member_row_gui_input.bind(member_id))
		if not row.item_dropped.is_connected(_on_member_row_item_dropped):
			row.item_dropped.connect(_on_member_row_item_dropped)

		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 8)
		margin.add_theme_constant_override("margin_right", 8)
		margin.add_theme_constant_override("margin_top", 8)
		margin.add_theme_constant_override("margin_bottom", 8)
		row.add_child(margin)

		var vbox := VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 4)
		margin.add_child(vbox)

		var name_label := Label.new()
		name_label.text = String(entry.display_name)
		vbox.add_child(name_label)

		var hp := StatBar.new()
		hp.kind = "hp"
		hp.set_values(int(entry.hp), int(entry.max_hp), "hp")
		vbox.add_child(hp)

		var mp := StatBar.new()
		mp.kind = "mp"
		mp.set_values(int(entry.mp), int(entry.max_mp), "mp")
		vbox.add_child(mp)

		member_list.add_child(row)
		_member_rows[member_id] = row
	_update_member_list_selection_visuals()

func _on_member_row_gui_input(event: InputEvent, member_id: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_select_member(member_id)
		var vp: Viewport = get_viewport()
		if vp:
			vp.set_input_as_handled()

func _select_member(member_id: String) -> void:
	member_id = String(member_id)
	if member_id.is_empty() or member_id == _selected_member_id:
		return
	_selected_member_id = member_id
	_selected_slot_idx = -1
	_last_action_message = ""
	_refresh_inventory_v2()

func _on_member_row_item_dropped(target_member_id: String, drag_data: Dictionary) -> void:
	if typeof(drag_data) != TYPE_DICTIONARY:
		return
	target_member_id = String(target_member_id)
	var from_id: String = String(drag_data.get("from_member_id", ""))
	var from_idx: int = int(drag_data.get("from_idx", -1))
	if from_id.is_empty() or from_idx < 0 or target_member_id.is_empty():
		return
	if game_state == null:
		return
	var res: Dictionary = {}
	if from_id == target_member_id:
		# Dragging onto the same character uses the item on them (consumables only).
		if game_state.has_method("use_consumable_from_bag_slot"):
			res = game_state.use_consumable_from_bag_slot(from_id, from_idx, target_member_id)
	else:
		# Dragging onto another character gives the item (auto-place into their bag).
		if game_state.has_method("give_bag_item"):
			res = game_state.give_bag_item(from_id, from_idx, target_member_id)
	_last_action_message = String(res.get("message", "")) if typeof(res) == TYPE_DICTIONARY else ""
	if from_id != target_member_id:
		_selected_member_id = target_member_id
		_selected_slot_idx = -1
	_refresh_inventory_v2()

func _update_member_list_selection_visuals() -> void:
	for k in _member_rows.keys():
		var mid: String = String(k)
		var node: Variant = _member_rows[k]
		if node == null:
			continue
		var panel: PanelContainer = node
		panel.modulate = Color(1, 1, 1, 1) if mid == _selected_member_id else Color(1, 1, 1, 0.7)

func _build_bag_grid(member: Variant) -> void:
	if bag_grid == null:
		return
	for child in bag_grid.get_children():
		child.queue_free()
	_slot_group = ButtonGroup.new()
	if member == null:
		return
	member.ensure_bag()
	var cols: int = max(1, int(member.bag_cols))
	bag_grid.columns = cols
	for i in range(member.bag.size()):
		var slot_data: Dictionary = member.get_bag_slot(i)
		var slot := InventorySlotButton.new()
		slot.button_group = _slot_group
		slot.configure(_selected_member_id, i, slot_data)
		slot.slot_selected.connect(_on_bag_slot_selected)
		slot.context_requested.connect(_on_bag_slot_context_requested)
		if i == _selected_slot_idx:
			slot.button_pressed = true
		bag_grid.add_child(slot)

func _on_bag_slot_selected(member_id: String, slot_idx: int) -> void:
	_selected_member_id = String(member_id)
	_selected_slot_idx = int(slot_idx)
	_last_action_message = ""
	_refresh_item_details()

func _on_bag_slot_context_requested(member_id: String, slot_idx: int, global_pos: Vector2) -> void:
	_ctx_member_id = String(member_id)
	_ctx_slot_idx = int(slot_idx)
	_selected_member_id = _ctx_member_id
	_selected_slot_idx = _ctx_slot_idx
	_refresh_inventory_v2()
	_open_item_context_menu(global_pos)

func _open_item_context_menu(global_pos: Vector2) -> void:
	if item_context_menu == null:
		return
	var member: Variant = _find_member_by_id(_ctx_member_id)
	if member == null:
		return
	member.ensure_bag()
	var slot_data: Dictionary = member.get_bag_slot(_ctx_slot_idx)
	var item_name: String = String(slot_data.get("name", ""))
	var count: int = int(slot_data.get("count", 0))
	item_context_menu.clear()
	if not item_name.is_empty() and count > 0:
		var item: Dictionary = ItemCatalog.get_item(item_name)
		var kind: String = String(item.get("kind", "item"))
		if kind == "consumable":
			item_context_menu.add_item("Use", CTX_USE)
		var equip_slot: String = String(item.get("equip_slot", ""))
		if equip_slot.is_empty():
			if kind == "weapon" or kind == "armor" or kind == "accessory":
				equip_slot = kind
		if equip_slot == "weapon" or equip_slot == "armor" or equip_slot == "accessory":
			var cur_eq: String = String(member.equipment.get(equip_slot, ""))
			var is_equipped: bool = (cur_eq == item_name and String(slot_data.get("equipped_slot", "")) == equip_slot)
			item_context_menu.add_item("Unequip" if is_equipped else "Equip", CTX_EQUIP_TOGGLE)
		item_context_menu.add_item("Drop", CTX_DROP)
	else:
		item_context_menu.add_item("(empty)", 0)
		item_context_menu.set_item_disabled(0, true)
	item_context_menu.position = Vector2i(int(global_pos.x), int(global_pos.y))
	item_context_menu.popup()

func _on_item_context_id_pressed(id: int) -> void:
	match int(id):
		CTX_USE:
			_open_use_target_popup()
		CTX_EQUIP_TOGGLE:
			_do_equip_toggle()
		CTX_DROP:
			_do_drop()

func _do_equip_toggle() -> void:
	if game_state == null or not game_state.has_method("toggle_equip_bag_item"):
		return
	var out: Dictionary = game_state.toggle_equip_bag_item(_ctx_member_id, _ctx_slot_idx)
	_last_action_message = String(out.get("message", ""))
	_refresh_inventory_v2()

func _do_drop() -> void:
	if game_state == null or not game_state.has_method("drop_bag_item"):
		return
	var out: Dictionary = game_state.drop_bag_item(_ctx_member_id, _ctx_slot_idx)
	_last_action_message = String(out.get("message", ""))
	_refresh_inventory_v2()

func _open_use_target_popup() -> void:
	if use_target_popup == null or use_target_list == null:
		return
	_use_from_member_id = _ctx_member_id
	_use_from_slot_idx = _ctx_slot_idx
	_build_use_target_list()
	use_target_popup.popup_centered()

func _build_use_target_list() -> void:
	for child in use_target_list.get_children():
		child.queue_free()
	var from_member: Variant = _find_member_by_id(_use_from_member_id)
	var item_name: String = ""
	if from_member != null:
		from_member.ensure_bag()
		item_name = String(from_member.get_bag_slot(_use_from_slot_idx).get("name", ""))
	if use_target_title:
		use_target_title.text = "Use %s" % (item_name if not item_name.is_empty() else "Item")
	for entry in _party_members():
		if entry == null:
			continue
		var target_id: String = String(entry.member_id)
		var row := PanelContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(0, 56)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_on_use_target_row_gui_input.bind(target_id))
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 8)
		margin.add_theme_constant_override("margin_right", 8)
		margin.add_theme_constant_override("margin_top", 8)
		margin.add_theme_constant_override("margin_bottom", 8)
		row.add_child(margin)
		var vbox := VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 4)
		margin.add_child(vbox)
		var name_label := Label.new()
		name_label.text = String(entry.display_name)
		vbox.add_child(name_label)
		var hp := StatBar.new()
		hp.kind = "hp"
		hp.set_values(int(entry.hp), int(entry.max_hp), "hp")
		vbox.add_child(hp)
		var mp := StatBar.new()
		mp.kind = "mp"
		mp.set_values(int(entry.mp), int(entry.max_mp), "mp")
		vbox.add_child(mp)
		use_target_list.add_child(row)

func _on_use_target_row_gui_input(event: InputEvent, target_member_id: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_use_item_on_target(target_member_id)
		var vp: Viewport = get_viewport()
		if vp:
			vp.set_input_as_handled()

func _use_item_on_target(target_member_id: String) -> void:
	if game_state == null or not game_state.has_method("use_consumable_from_bag_slot"):
		return
	var out: Dictionary = game_state.use_consumable_from_bag_slot(_use_from_member_id, _use_from_slot_idx, String(target_member_id))
	_last_action_message = String(out.get("message", ""))
	if use_target_popup:
		use_target_popup.hide()
	_refresh_inventory_v2()

func _on_use_target_cancel_pressed() -> void:
	if use_target_popup:
		use_target_popup.hide()

func _set_item_details_for_empty() -> void:
	if item_details:
		item_details.text = "(no party)"

func _refresh_item_details() -> void:
	if item_details == null:
		return
	var member: Variant = _find_member_by_id(_selected_member_id)
	if member == null:
		item_details.text = "Select a character."
		return
	member.ensure_bag()
	if _selected_slot_idx < 0 or _selected_slot_idx >= member.bag.size():
		item_details.text = "Select a slot."
		return
	var slot_data: Dictionary = member.get_bag_slot(_selected_slot_idx)
	var item_name: String = String(slot_data.get("name", ""))
	var count: int = int(slot_data.get("count", 0))
	if item_name.is_empty() or count <= 0:
		item_details.text = "(empty slot)"
		return
	var item: Dictionary = ItemCatalog.get_item(item_name)
	var kind: String = String(item.get("kind", "item"))
	var desc: String = String(item.get("description", ""))
	var lines: PackedStringArray = PackedStringArray()
	lines.append("%s x%d" % [item_name, count] if count > 1 else item_name)
	lines.append("Kind: %s" % kind)
	if not String(slot_data.get("equipped_slot", "")).is_empty():
		lines.append("Equipped: %s" % String(slot_data.get("equipped_slot", "")).capitalize())
	if not desc.is_empty():
		lines.append(desc)
	var use_effect: Dictionary = item.get("use_effect", {})
	if kind == "consumable" and not use_effect.is_empty():
		if String(use_effect.get("type", "")) == "heal_hp":
			lines.append("Effect: Heal %d HP" % int(use_effect.get("amount", 0)))
	var bonuses: Dictionary = item.get("stat_bonuses", {})
	if (kind == "weapon" or kind == "armor" or kind == "accessory") and not bonuses.is_empty():
		lines.append("Bonuses:")
		for k in bonuses.keys():
			lines.append(" - %s %+d" % [String(k), int(bonuses[k])])
	if not _last_action_message.is_empty():
		lines.append("")
		lines.append(_last_action_message)
	item_details.text = "\n".join(lines)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var vp: Viewport = get_viewport()
	if event.is_action_pressed("ui_cancel"):
		if use_target_popup and use_target_popup.visible:
			use_target_popup.hide()
			if vp:
				vp.set_input_as_handled()
			return
		close_overlay()
		if vp:
			vp.set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			close_overlay()
			if vp:
				vp.set_input_as_handled()
			return
