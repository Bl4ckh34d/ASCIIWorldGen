extends Control
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const PoiCatalog = preload("res://scripts/gameplay/catalog/PoiCatalog.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")
const DeterministicRng = preload("res://scripts/gameplay/DeterministicRng.gd")
const EncounterRegistry = preload("res://scripts/gameplay/EncounterRegistry.gd")
const WorldTimeStateModel = preload("res://scripts/gameplay/models/WorldTimeState.gd")
const GpuMapView = preload("res://scripts/gameplay/rendering/GpuMapView.gd")
const LocalAreaGenerator = preload("res://scripts/gameplay/local/LocalAreaGenerator.gd")
const LocalAreaTiles = preload("res://scripts/gameplay/local/LocalAreaTiles.gd")

const TAU: float = 6.28318530718
const PI: float = 3.14159265359

const MOVE_SPEED_CELLS_PER_SEC: float = 5.0
const MOVE_EPS: float = 0.0001
const DUNGEON_ENCOUNTER_SAFE_STEPS_NEAR_DOOR: int = 5
const VIEW_W_DEFAULT: int = 64
const VIEW_H_DEFAULT: int = 30
const VIEW_PAD: int = 2
const DUNGEON_FOG_REVEAL_RADIUS: int = 7
const MARKER_PLAYER: int = 220

@onready var header_label: Label = %HeaderLabel
@onready var gpu_map: Control = %GpuMap
@onready var footer_label: Label = %FooterLabel
@onready var dialogue_popup: PopupPanel = %DialoguePopup
@onready var dialogue_text: Label = %DialogueText
@onready var dialogue_close_button: Button = %DialogueCloseButton

const Tile = LocalAreaTiles.Tile
const Obj = LocalAreaTiles.Obj
const Actor = LocalAreaTiles.Actor

var game_state: Node = null
var startup_state: Node = null
var scene_router: Node = null
var menu_overlay: CanvasLayer = null
var world_map_overlay: CanvasLayer = null
var poi_data: Dictionary = {}
var room_w: int = 40
var room_h: int = 22
var tiles: PackedByteArray = PackedByteArray()
var objects: PackedByteArray = PackedByteArray()
var actors: PackedByteArray = PackedByteArray()
var player_x: int = 2
var player_y: int = 2
var _player_fx: float = 2.0
var _player_fy: float = 2.0

var _poi_id: String = ""
var _poi_type: String = "House"
var _boss_defeated: bool = false
var _opened_chests: Dictionary = {}
var _door_pos: Vector2i = Vector2i(1, 1)
var _boss_pos: Vector2i = Vector2i(-1, -1)
var _chest_pos: Vector2i = Vector2i(-1, -1)
var _gpu_view: Object = null
var _npcs: Array[Dictionary] = []
var _npc_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _npc_move_accum: float = 0.0
var _npc_activity: Dictionary = {}
var _dynamic_refresh_accum: float = 0.0
var _dungeon_seen: PackedByteArray = PackedByteArray()
var _world_seed_hash: int = 1
var _dialogue_pause_active: bool = false
var _dungeon_steps_since_entry: int = 0
var _view_w: int = 0
var _view_h: int = 0
var _render_w: int = 0
var _render_h: int = 0
var _view_origin_x: int = 0
var _view_origin_y: int = 0
var _render_origin_x: int = 0
var _render_origin_y: int = 0
var _anchor_player_x: int = 2
var _anchor_player_y: int = 2
var _local_gen: Object = LocalAreaGenerator.new()
var _shop_popup: PopupPanel = null
var _shop_title_label: Label = null
var _shop_gold_label: Label = null
var _shop_mode_buy_button: Button = null
var _shop_mode_sell_button: Button = null
var _shop_list: ItemList = null
var _shop_details_label: Label = null
var _shop_action_button: Button = null
var _shop_close_button: Button = null
var _shop_mode: String = "buy"
var _shop_stock: Array[Dictionary] = []
var _shop_pause_active: bool = false
const NPC_MOVE_INTERVAL: float = 0.75
const DYNAMIC_REFRESH_INTERVAL: float = 0.50
const NPC_MAX_DEST_TRIES: int = 24
const NPC_MIN_DEST_DIST: int = 3
const NPC_ASTAR_MAX_ITERS: int = 4096

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	startup_state = get_node_or_null("/root/StartupState")
	scene_router = get_node_or_null("/root/SceneRouter")
	if game_state != null and game_state.has_method("ensure_world_snapshot_integrity"):
		game_state.ensure_world_snapshot_integrity()
	poi_data = _consume_poi_payload()
	if poi_data.is_empty():
		poi_data = {
			"type": "House",
			"world_x": 0,
			"world_y": 0,
			"local_x": 48,
			"local_y": 48,
			"biome_id": 7,
			"biome_name": "Grassland",
		}
	_poi_type = String(poi_data.get("type", "House"))
	_poi_id = String(poi_data.get("id", ""))
	_configure_dimensions_for_poi()
	_world_seed_hash = _get_world_seed_hash()
	_npc_rng.seed = abs(int(("npc_rng|" + _poi_id).hash()) ^ _world_seed_hash)
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(
			"local",
			int(poi_data.get("world_x", 0)),
			int(poi_data.get("world_y", 0)),
			int(poi_data.get("local_x", 48)),
			int(poi_data.get("local_y", 48)),
			int(poi_data.get("biome_id", 7)),
			String(poi_data.get("biome_name", ""))
		)
	if game_state != null and game_state.has_method("set_local_rest_context"):
		# v0 scaffold: houses/shops are valid rest spots; dungeons are not.
		game_state.set_local_rest_context(_poi_type == "House", _poi_type)
	_install_menu_overlay()
	_install_world_map_overlay()
	_wire_dialogue_controls()
	_ensure_shop_ui()
	_load_poi_instance_state()
	_refresh_npc_activity_context()
	_generate_map()
	_place_player_from_payload_or_entry()
	_sync_player_float_from_cell()
	_reveal_dungeon_fog_around_player()
	_dungeon_steps_since_entry = 0
	_init_gpu_rendering()
	set_process_unhandled_input(true)
	set_process(true)
	_render_local_map()

func _wire_dialogue_controls() -> void:
	if dialogue_popup:
		dialogue_popup.visible = false
	if dialogue_close_button and not dialogue_close_button.pressed.is_connected(_close_dialogue):
		dialogue_close_button.pressed.connect(_close_dialogue)

func _open_dialogue(text_value: String) -> void:
	if dialogue_text:
		dialogue_text.text = text_value
	if dialogue_popup != null:
		# PopupPanel handles positioning; use a fixed size for now.
		dialogue_popup.popup_centered(Vector2i(560, 220))
		if dialogue_close_button:
			dialogue_close_button.grab_focus()
	if game_state != null and game_state.has_method("push_ui_pause") and not _dialogue_pause_active:
		game_state.push_ui_pause("dialogue")
		_dialogue_pause_active = true

func _close_dialogue() -> void:
	if dialogue_popup != null:
		dialogue_popup.hide()
	if game_state != null and game_state.has_method("pop_ui_pause") and _dialogue_pause_active:
		game_state.pop_ui_pause("dialogue")
	_dialogue_pause_active = false

func _ensure_shop_ui() -> void:
	if _shop_popup != null:
		return
	_shop_popup = PopupPanel.new()
	_shop_popup.name = "ShopPopup"
	_shop_popup.visible = false
	_shop_popup.exclusive = true
	add_child(_shop_popup)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_shop_popup.add_child(margin)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(700, 410)
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	_shop_title_label = Label.new()
	_shop_title_label.text = "Shop"
	_shop_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_shop_title_label)
	_shop_gold_label = Label.new()
	_shop_gold_label.text = "Gold: 0"
	header.add_child(_shop_gold_label)

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	root.add_child(mode_row)
	_shop_mode_buy_button = Button.new()
	_shop_mode_buy_button.text = "Buy"
	mode_row.add_child(_shop_mode_buy_button)
	_shop_mode_sell_button = Button.new()
	_shop_mode_sell_button.text = "Sell"
	mode_row.add_child(_shop_mode_sell_button)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	root.add_child(body)

	_shop_list = ItemList.new()
	_shop_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shop_list.select_mode = ItemList.SELECT_SINGLE
	body.add_child(_shop_list)

	var rhs := VBoxContainer.new()
	rhs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rhs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rhs.custom_minimum_size = Vector2(260, 0)
	rhs.add_theme_constant_override("separation", 8)
	body.add_child(rhs)
	_shop_details_label = Label.new()
	_shop_details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_shop_details_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_details_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shop_details_label.text = "Select an item."
	rhs.add_child(_shop_details_label)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	root.add_child(footer)
	_shop_action_button = Button.new()
	_shop_action_button.text = "Buy"
	footer.add_child(_shop_action_button)
	_shop_close_button = Button.new()
	_shop_close_button.text = "Close"
	footer.add_child(_shop_close_button)

	if not _shop_mode_buy_button.pressed.is_connected(_on_shop_mode_buy_pressed):
		_shop_mode_buy_button.pressed.connect(_on_shop_mode_buy_pressed)
	if not _shop_mode_sell_button.pressed.is_connected(_on_shop_mode_sell_pressed):
		_shop_mode_sell_button.pressed.connect(_on_shop_mode_sell_pressed)
	if not _shop_list.item_selected.is_connected(_on_shop_item_selected):
		_shop_list.item_selected.connect(_on_shop_item_selected)
	if not _shop_action_button.pressed.is_connected(_on_shop_action_pressed):
		_shop_action_button.pressed.connect(_on_shop_action_pressed)
	if not _shop_close_button.pressed.is_connected(_on_shop_close_pressed):
		_shop_close_button.pressed.connect(_on_shop_close_pressed)

func _shop_is_open() -> bool:
	return _shop_popup != null and _shop_popup.visible

func _open_shop() -> void:
	_close_dialogue()
	_ensure_shop_ui()
	if _shop_popup == null:
		_open_dialogue("Shop UI unavailable.")
		return
	if _shop_stock.is_empty():
		_shop_stock = _build_shop_stock()
	_set_shop_mode("buy")
	_refresh_shop_gold_label()
	_refresh_shop_list()
	_shop_popup.popup_centered(Vector2i(760, 470))
	if _shop_action_button != null:
		_shop_action_button.grab_focus()
	if game_state != null and game_state.has_method("push_ui_pause") and not _shop_pause_active:
		game_state.push_ui_pause("shop")
		_shop_pause_active = true

func _close_shop() -> void:
	if _shop_popup != null:
		_shop_popup.hide()
	if game_state != null and game_state.has_method("pop_ui_pause") and _shop_pause_active:
		game_state.pop_ui_pause("shop")
	_shop_pause_active = false

func _shop_seed_key(tag: String) -> String:
	return "shop|%s|%s|%d|%d|%s" % [
		_poi_id,
		_poi_type,
		int(poi_data.get("world_x", 0)),
		int(poi_data.get("world_y", 0)),
		tag
	]

func _item_market_mul(item_name: String) -> Dictionary:
	if game_state != null and game_state.has_method("get_item_market_price_multipliers"):
		return game_state.get_item_market_price_multipliers(
			item_name,
			int(poi_data.get("world_x", 0)),
			int(poi_data.get("world_y", 0))
		)
	return {"buy_mul": 1.0, "sell_mul": 0.45}

func _refresh_npc_activity_context() -> void:
	_npc_activity = {}
	if game_state != null and game_state.has_method("get_local_npc_activity_multipliers"):
		_npc_activity = game_state.get_local_npc_activity_multipliers(
			int(poi_data.get("world_x", 0)),
			int(poi_data.get("world_y", 0)),
			String(poi_data.get("political_state_id", ""))
		)
	if typeof(_npc_activity) != TYPE_DICTIONARY:
		_npc_activity = {}

func _npc_density_mul() -> float:
	return clamp(float(_npc_activity.get("density_mul", 1.0)), 0.25, 2.00)

func _npc_move_interval_seconds() -> float:
	var move_mul: float = clamp(float(_npc_activity.get("move_interval_mul", 1.0)), 0.50, 3.00)
	return max(0.08, NPC_MOVE_INTERVAL * move_mul)

func _npc_disposition_epoch_shift() -> float:
	return clamp(float(_npc_activity.get("disposition_shift", 0.0)), -0.90, 0.50)

func _scale_npc_count(base_count: int, density_mul: float, seed_key: String) -> int:
	base_count = max(0, int(base_count))
	density_mul = max(0.0, float(density_mul))
	var scaled_f: float = float(base_count) * density_mul
	var out: int = max(0, int(floor(scaled_f)))
	var frac: float = clamp(scaled_f - float(out), 0.0, 1.0)
	if frac > 0.0 and DeterministicRng.randf01(_world_seed_hash, seed_key) < frac:
		out += 1
	return out

func _npc_kind_roll(seed_key: String) -> int:
	var r: float = DeterministicRng.randf01(_world_seed_hash, seed_key)
	if r < 0.45:
		return Actor.MAN
	if r < 0.90:
		return Actor.WOMAN
	return Actor.CHILD

func _npc_role_social_rank(role: String, kind: int) -> float:
	role = String(role).to_lower()
	if kind == Actor.CHILD:
		return 0.20
	match role:
		"shopkeeper":
			return 0.62
		"customer":
			return 0.46
		_:
			return 0.40

func _build_shop_stock() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var item_ids: Array[String] = ["Potion", "Herb", "Bomb", "Bronze Sword", "Leather Armor"]
	for item_id in item_ids:
		if not ItemCatalog.has_item(item_id):
			continue
		var item: Dictionary = ItemCatalog.get_item(item_id)
		var value: int = max(1, int(item.get("value", 10)))
		var stackable: bool = VariantCasts.to_bool(item.get("stackable", true))
		var qty: int = 1
		if stackable:
			qty = 2 + DeterministicRng.randi_range(_world_seed_hash, _shop_seed_key("qty|" + item_id), 0, 7)
		else:
			qty = 1 + DeterministicRng.randi_range(_world_seed_hash, _shop_seed_key("qty|" + item_id), 0, 1)
		if item_id == "Potion":
			qty = max(qty, 3)
		var markup_jitter: float = DeterministicRng.randf01(_world_seed_hash, _shop_seed_key("mk|" + item_id))
		var markup: float = 1.00 + markup_jitter * 0.18
		var market: Dictionary = _item_market_mul(item_id)
		var buy_mul: float = clamp(float(market.get("buy_mul", 1.0)), 0.20, 6.00)
		var sell_mul: float = clamp(float(market.get("sell_mul", 0.45)), 0.05, 2.00)
		var buy_price: int = max(1, int(round(float(value) * buy_mul * markup)))
		var sell_price: int = max(1, int(floor(float(value) * sell_mul)))
		out.append({
			"item_name": item_id,
			"qty": qty,
			"buy_price": buy_price,
			"sell_price": sell_price,
			"kind": String(item.get("kind", "")),
		})
	return out

func _find_shop_stock_idx(item_name: String) -> int:
	for i in range(_shop_stock.size()):
		var v: Variant = _shop_stock[i]
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = v as Dictionary
		if String(d.get("item_name", "")) == item_name:
			return i
	return -1

func _set_shop_mode(mode: String) -> void:
	mode = String(mode).to_lower()
	if mode != "sell":
		mode = "buy"
	_shop_mode = mode
	if _shop_mode_buy_button != null:
		_shop_mode_buy_button.disabled = (_shop_mode == "buy")
	if _shop_mode_sell_button != null:
		_shop_mode_sell_button.disabled = (_shop_mode == "sell")
	if _shop_action_button != null:
		_shop_action_button.text = "Buy" if _shop_mode == "buy" else "Sell"
	if _shop_title_label != null:
		_shop_title_label.text = "Shop - %s" % ("Buying" if _shop_mode == "buy" else "Selling")

func _refresh_shop_gold_label() -> void:
	if _shop_gold_label == null:
		return
	var gold: int = 0
	if game_state != null and game_state.get("party") != null:
		gold = int(game_state.party.gold)
	_shop_gold_label.text = "Gold: %d" % gold

func _refresh_shop_list() -> void:
	if _shop_list == null:
		return
	_shop_list.clear()
	if _shop_mode == "buy":
		for entry in _shop_stock:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = entry as Dictionary
			var qty: int = max(0, int(d.get("qty", 0)))
			if qty <= 0:
				continue
			var item_name: String = String(d.get("item_name", ""))
			var price: int = max(1, int(d.get("buy_price", 1)))
			var idx: int = _shop_list.get_item_count()
			_shop_list.add_item("%s  %dg  (x%d)" % [item_name, price, qty])
			_shop_list.set_item_metadata(idx, {
				"mode": "buy",
				"item_name": item_name,
				"price": price,
				"qty": qty,
			})
	else:
		if game_state != null and game_state.get("party") != null and game_state.party.has_method("rebuild_inventory_view"):
			game_state.party.rebuild_inventory_view()
		var inv: Dictionary = {}
		if game_state != null and game_state.get("party") != null:
			inv = game_state.party.inventory
		var names: Array[String] = []
		for key in inv.keys():
			var item_name: String = String(key)
			if item_name.is_empty() or int(inv.get(key, 0)) <= 0:
				continue
			names.append(item_name)
		names.sort()
		for item_name2 in names:
			var count: int = int(inv.get(item_name2, 0))
			var item2: Dictionary = ItemCatalog.get_item(item_name2)
			if item2.is_empty():
				continue
			var market: Dictionary = _item_market_mul(item_name2)
			var sell_mul: float = clamp(float(market.get("sell_mul", 0.45)), 0.05, 2.00)
			var sell_price: int = max(1, int(floor(float(item2.get("value", 1)) * sell_mul)))
			var idx2: int = _shop_list.get_item_count()
			_shop_list.add_item("%s  x%d  (+%dg)" % [item_name2, count, sell_price])
			_shop_list.set_item_metadata(idx2, {
				"mode": "sell",
				"item_name": item_name2,
				"price": sell_price,
				"qty": count,
			})
	if _shop_list.get_item_count() <= 0:
		var msg: String = "(out of stock)" if _shop_mode == "buy" else "(nothing to sell)"
		_shop_list.add_item(msg)
		_shop_list.set_item_disabled(0, true)
	else:
		_shop_list.select(0)
	_refresh_shop_details()

func _selected_shop_entry() -> Dictionary:
	if _shop_list == null:
		return {}
	var sel: PackedInt32Array = _shop_list.get_selected_items()
	if sel.is_empty():
		return {}
	var idx: int = int(sel[0])
	var v: Variant = _shop_list.get_item_metadata(idx)
	if typeof(v) != TYPE_DICTIONARY:
		return {}
	return (v as Dictionary).duplicate(true)

func _refresh_shop_details() -> void:
	if _shop_details_label == null:
		return
	var entry: Dictionary = _selected_shop_entry()
	if entry.is_empty():
		_shop_details_label.text = "Select an item."
		return
	var item_name: String = String(entry.get("item_name", ""))
	var item: Dictionary = ItemCatalog.get_item(item_name)
	var desc: String = String(item.get("description", ""))
	var price: int = int(entry.get("price", 0))
	var qty: int = int(entry.get("qty", 0))
	if _shop_mode == "buy":
		_shop_details_label.text = "%s\n\n%s\n\nPrice: %d gold\nStock: %d\nAction: Buy one." % [item_name, desc, price, qty]
	else:
		_shop_details_label.text = "%s\n\n%s\n\nSell Value: %d gold\nOwned: %d\nAction: Sell one." % [item_name, desc, price, qty]

func _notify_party_and_inventory_changed() -> void:
	if game_state == null:
		return
	if game_state.has_method("_emit_party_changed"):
		game_state._emit_party_changed()
	if game_state.has_method("_emit_inventory_changed"):
		game_state._emit_inventory_changed()

func _shop_try_buy(entry: Dictionary) -> void:
	if game_state == null or game_state.get("party") == null:
		_set_footer("Shop unavailable.")
		return
	var item_name: String = String(entry.get("item_name", ""))
	var price: int = max(1, int(entry.get("price", 1)))
	var idx: int = _find_shop_stock_idx(item_name)
	if idx < 0:
		_set_footer("That item is unavailable.")
		return
	var stock: Dictionary = _shop_stock[idx]
	var qty: int = max(0, int(stock.get("qty", 0)))
	if qty <= 0:
		_set_footer("Out of stock.")
		return
	var party = game_state.party
	var gold_before: int = int(party.gold)
	if gold_before < price:
		_set_footer("Not enough gold.")
		return
	party.gold = gold_before - price
	var overflow: int = 0
	if party.has_method("add_item_auto"):
		overflow = int(party.add_item_auto(item_name, 1))
	else:
		party.add_item(item_name, 1)
	if overflow > 0:
		party.gold = gold_before
		_set_footer("Inventory full.")
		return
	stock["qty"] = qty - 1
	_shop_stock[idx] = stock
	_notify_party_and_inventory_changed()
	_refresh_shop_gold_label()
	_refresh_shop_list()
	_set_footer("Bought %s for %d gold." % [item_name, price])

func _shop_try_sell(entry: Dictionary) -> void:
	if game_state == null or game_state.get("party") == null:
		_set_footer("Shop unavailable.")
		return
	var item_name: String = String(entry.get("item_name", ""))
	var price: int = max(1, int(entry.get("price", 1)))
	var party = game_state.party
	if not party.remove_item(item_name, 1, false):
		_set_footer("Cannot sell equipped or missing item.")
		return
	party.gold = int(party.gold) + price
	_notify_party_and_inventory_changed()
	_refresh_shop_gold_label()
	_refresh_shop_list()
	_set_footer("Sold %s for %d gold." % [item_name, price])

func _on_shop_mode_buy_pressed() -> void:
	_set_shop_mode("buy")
	_refresh_shop_list()

func _on_shop_mode_sell_pressed() -> void:
	_set_shop_mode("sell")
	_refresh_shop_list()

func _on_shop_item_selected(_idx: int) -> void:
	_refresh_shop_details()

func _on_shop_action_pressed() -> void:
	var entry: Dictionary = _selected_shop_entry()
	if entry.is_empty():
		_set_footer("Select an item.")
		return
	var mode: String = String(entry.get("mode", _shop_mode))
	if mode == "sell":
		_shop_try_sell(entry)
	else:
		_shop_try_buy(entry)

func _on_shop_close_pressed() -> void:
	_close_shop()

func _consume_poi_payload() -> Dictionary:
	if game_state != null and game_state.has_method("consume_pending_poi"):
		var from_state: Dictionary = game_state.consume_pending_poi()
		if not from_state.is_empty():
			return from_state
	if startup_state != null and startup_state.has_method("consume_poi"):
		return startup_state.consume_poi()
	return {}

func _install_menu_overlay() -> void:
	var packed: PackedScene = load(SceneContracts.SCENE_MENU_OVERLAY)
	if packed == null:
		return
	menu_overlay = packed.instantiate() as CanvasLayer
	if menu_overlay == null:
		return
	add_child(menu_overlay)

func _install_world_map_overlay() -> void:
	var packed: PackedScene = load(SceneContracts.SCENE_WORLD_MAP_OVERLAY)
	if packed == null:
		return
	world_map_overlay = packed.instantiate() as CanvasLayer
	if world_map_overlay == null:
		return
	add_child(world_map_overlay)

func _init_gpu_rendering() -> void:
	if gpu_map == null:
		return
	_configure_view_window()
	var seed_hash: int = 1
	if game_state != null and int(game_state.world_seed_hash) != 0:
		seed_hash = int(game_state.world_seed_hash)
	elif startup_state != null and int(startup_state.world_seed_hash) != 0:
		seed_hash = int(startup_state.world_seed_hash)
	# Initialize GPU ASCII renderer.
	if "initialize_gpu_rendering" in gpu_map:
		var font: Font = get_theme_default_font()
		if font == null and header_label != null:
			font = header_label.get_theme_default_font()
		var font_size: int = get_theme_default_font_size()
		if header_label != null:
			var hs: int = header_label.get_theme_default_font_size()
			if hs > 0:
				font_size = hs
		gpu_map.initialize_gpu_rendering(font, font_size, _render_w, _render_h)
		if "set_display_window" in gpu_map:
			gpu_map.set_display_window(_view_w, _view_h, float(VIEW_PAD), float(VIEW_PAD))
	# Initialize per-view GPU field packer.
	if _gpu_view == null:
		_gpu_view = GpuMapView.new()
		_gpu_view.configure("local_view", _render_w, _render_h, seed_hash)
	if gpu_map != null and gpu_map is Control:
		if not (gpu_map as Control).resized.is_connected(_on_gpu_map_resized):
			(gpu_map as Control).resized.connect(_on_gpu_map_resized)
	_apply_scroll_offset()
	_update_fixed_lonlat_uniform()

func _configure_view_window() -> void:
	_view_w = max(1, min(room_w, VIEW_W_DEFAULT))
	_view_h = max(1, min(room_h, VIEW_H_DEFAULT))
	_render_w = _view_w + VIEW_PAD * 2
	_render_h = _view_h + VIEW_PAD * 2
	_update_view_window_origin()

func _update_view_window_origin() -> void:
	if _view_w <= 0 or _view_h <= 0:
		return
	var cx: int = int(floor(_player_fx))
	var cy: int = int(floor(_player_fy))
	var half_w: int = _view_w / 2
	var half_h: int = _view_h / 2
	var max_x: int = max(0, room_w - _view_w)
	var max_y: int = max(0, room_h - _view_h)
	_view_origin_x = clamp(cx - half_w, 0, max_x)
	_view_origin_y = clamp(cy - half_h, 0, max_y)
	_render_origin_x = _view_origin_x - VIEW_PAD
	_render_origin_y = _view_origin_y - VIEW_PAD

func _actor_marker_for_kind(kind: int) -> int:
	match kind:
		Actor.MAN:
			return LocalAreaTiles.MARKER_NPC_MAN
		Actor.WOMAN:
			return LocalAreaTiles.MARKER_NPC_WOMAN
		Actor.CHILD:
			return LocalAreaTiles.MARKER_NPC_CHILD
		Actor.SHOPKEEPER:
			return LocalAreaTiles.MARKER_NPC_SHOPKEEPER
		_:
			return -1

func _apply_scroll_offset() -> void:
	if gpu_map == null:
		return
	if not ("set_scroll_offset_cells" in gpu_map):
		return
	var off: Vector2 = _current_scroll_offset_cells()
	gpu_map.set_scroll_offset_cells(float(off.x), float(off.y))

func _current_scroll_offset_cells() -> Vector2:
	var fx: float = _player_fx - floor(_player_fx)
	var fy: float = _player_fy - floor(_player_fy)
	fx = clamp(fx, 0.0, 0.999999)
	fy = clamp(fy, 0.0, 0.999999)
	var max_x: int = max(0, room_w - _view_w)
	var max_y: int = max(0, room_h - _view_h)
	if _view_origin_x <= 0 or _view_origin_x >= max_x:
		fx = 0.0
	if _view_origin_y <= 0 or _view_origin_y >= max_y:
		fy = 0.0
	return Vector2(fx, fy)

func _unhandled_input(event: InputEvent) -> void:
	var vp: Viewport = get_viewport()
	# When an overlay is visible, let it consume input first.
	if world_map_overlay != null and world_map_overlay.visible:
		return
	if menu_overlay != null and menu_overlay.visible:
		return
	if _shop_is_open():
		if event.is_action_pressed("ui_cancel"):
			_close_shop()
			if vp:
				vp.set_input_as_handled()
			return
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE:
				_close_shop()
				if vp:
					vp.set_input_as_handled()
				return
			if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
				_on_shop_action_pressed()
				if vp:
					vp.set_input_as_handled()
				return
		return
	if dialogue_popup != null and dialogue_popup.visible:
		if event.is_action_pressed("ui_cancel"):
			_close_dialogue()
			if vp:
				vp.set_input_as_handled()
			return
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE or event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_SPACE:
				_close_dialogue()
				if vp:
					vp.set_input_as_handled()
				return
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		_toggle_world_map()
		if vp:
			vp.set_input_as_handled()
		return
	if _is_menu_toggle_event(event):
		_toggle_menu()
		if vp:
			vp.set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q:
			_return_to_regional()
			if vp:
				vp.set_input_as_handled()
			return
		if event.keycode == KEY_E:
			_try_interact()
			if vp:
				vp.set_input_as_handled()
			return

func _is_menu_toggle_event(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and not event.echo:
		return event.keycode == KEY_TAB or event.keycode == KEY_ESCAPE
	if event.is_action_pressed("ui_cancel"):
		return true
	return false

func _toggle_menu() -> void:
	if menu_overlay == null:
		return
	if menu_overlay.visible:
		menu_overlay.close_overlay()
	else:
		menu_overlay.open_overlay("Interior")

func _toggle_world_map() -> void:
	if world_map_overlay == null:
		return
	if world_map_overlay.visible:
		world_map_overlay.close_overlay()
	else:
		world_map_overlay.open_overlay()

func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	# Pause NPCs + visuals while overlays are open (menu/world-map/dialogue).
	if world_map_overlay != null and world_map_overlay.visible:
		return
	if menu_overlay != null and menu_overlay.visible:
		return
	if _shop_is_open():
		return
	if dialogue_popup != null and dialogue_popup.visible:
		return

	var dir: Vector2i = _read_move_dir()
	if dir != Vector2i.ZERO:
		_move_continuous(dir, delta)
	else:
		_clamp_player_float()
	_update_view_window_origin()
	_apply_scroll_offset()
	_update_fixed_lonlat_uniform()

	_npc_move_accum += delta
	_dynamic_refresh_accum += delta
	var npc_interval: float = _npc_move_interval_seconds()
	var did_npc_step: bool = false
	if _npc_move_accum >= npc_interval:
		_npc_move_accum = 0.0
		if _step_npcs():
			_render_local_map()
			did_npc_step = true
	if did_npc_step:
		_update_view_window_origin()
		_apply_scroll_offset()
		_update_fixed_lonlat_uniform()
	if _dynamic_refresh_accum >= DYNAMIC_REFRESH_INTERVAL:
		_dynamic_refresh_accum = 0.0
		_update_time_visuals()

func _read_move_dir() -> Vector2i:
	var dx := 0
	var dy := 0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dx -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dx += 1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dy -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dy += 1
	return Vector2i(int(sign(dx)), int(sign(dy)))

func _move_continuous(dir: Vector2i, delta: float) -> void:
	if dir == Vector2i.ZERO:
		return
	var t_rem: float = max(0.0, delta)
	if t_rem <= 0.0:
		return
	var dv: Vector2 = Vector2(float(dir.x), float(dir.y))
	if dv.length_squared() <= 0.000001:
		return
	var v: Vector2 = dv.normalized() * MOVE_SPEED_CELLS_PER_SEC
	var safety: int = 0
	while t_rem > 0.0 and safety < 32:
		safety += 1
		var base_x: float = floor(_player_fx)
		var base_y: float = floor(_player_fy)
		var tx: float = 1e30
		var ty: float = 1e30
		var fx: float = _player_fx - base_x
		var fy: float = _player_fy - base_y
		if abs(v.x) > 0.000001:
			if v.x > 0.0:
				tx = ((base_x + 1.0) - _player_fx) / v.x
			else:
				tx = fx / (-v.x)
		if abs(v.y) > 0.000001:
			if v.y > 0.0:
				ty = ((base_y + 1.0) - _player_fy) / v.y
			else:
				ty = fy / (-v.y)

		var step_time: float = min(t_rem, min(tx, ty))
		var hit_x: bool = tx <= step_time + 0.000001
		var hit_y: bool = ty <= step_time + 0.000001

		if step_time > 0.0:
			_player_fx += v.x * step_time
			_player_fy += v.y * step_time
			_clamp_player_float()
			t_rem -= step_time

		if not hit_x and not hit_y:
			break

		var sx: int = 0
		var sy: int = 0
		if hit_x:
			sx = 1 if v.x > 0.0 else -1
		if hit_y:
			sy = 1 if v.y > 0.0 else -1
		if sx == 0 and sy == 0:
			break
		if not _step_player_continuous(Vector2i(sx, sy)):
			break

func _step_player_continuous(step: Vector2i) -> bool:
	if step == Vector2i.ZERO:
		return true
	if step.x != 0 and step.y != 0:
		if _move_player(step):
			_set_float_after_cell_step(step)
			return true
		# Prevent corner-cutting while still allowing smooth diagonal key-hold slides.
		if _move_player(Vector2i(step.x, 0)):
			_set_float_after_cell_step(Vector2i(step.x, 0))
			return true
		if _move_player(Vector2i(0, step.y)):
			_set_float_after_cell_step(Vector2i(0, step.y))
			return true
		_snap_float_into_current_cell()
		return false
	if _move_player(step):
		_set_float_after_cell_step(step)
		return true
	_snap_float_into_current_cell()
	return false

func _set_float_after_cell_step(step: Vector2i) -> void:
	# Keep float position just inside the new cell to avoid zero-time re-cross loops.
	if step.x > 0:
		_player_fx = float(player_x) + MOVE_EPS
	elif step.x < 0:
		_player_fx = float(player_x + 1) - MOVE_EPS
	else:
		_player_fx = clamp(_player_fx, float(player_x), float(player_x + 1) - MOVE_EPS)

	if step.y > 0:
		_player_fy = float(player_y) + MOVE_EPS
	elif step.y < 0:
		_player_fy = float(player_y + 1) - MOVE_EPS
	else:
		_player_fy = clamp(_player_fy, float(player_y), float(player_y + 1) - MOVE_EPS)
	_clamp_player_float()

func _clamp_player_float() -> void:
	var max_x: float = float(max(1, room_w)) - MOVE_EPS
	var max_y: float = float(max(1, room_h)) - MOVE_EPS
	_player_fx = clamp(_player_fx, 0.0, max_x)
	_player_fy = clamp(_player_fy, 0.0, max_y)

func _snap_float_into_current_cell() -> void:
	_player_fx = clamp(_player_fx, float(player_x) + MOVE_EPS, float(player_x + 1) - MOVE_EPS)
	_player_fy = clamp(_player_fy, float(player_y) + MOVE_EPS, float(player_y + 1) - MOVE_EPS)
	_clamp_player_float()

func _sync_player_float_from_cell() -> void:
	_player_fx = float(player_x)
	_player_fy = float(player_y)
	_clamp_player_float()

func _update_time_visuals() -> void:
	if header_label:
		var disp: String = _poi_type
		if disp == "House" and VariantCasts.to_bool(poi_data.get("is_shop", false)):
			disp = "Shop"
		header_label.text = "%s Interior - Tile (%d,%d) - %s" % [
			disp,
			int(poi_data.get("world_x", 0)),
			int(poi_data.get("world_y", 0)),
			_get_time_label(),
		]
	if _gpu_view != null and gpu_map != null:
		var solar: Dictionary = _get_solar_params()
		var lon_phi: Vector2 = _get_fixed_lon_phi()
		_gpu_view.update_dynamic_layers(
			gpu_map,
			solar,
			_build_local_cloud_params(),
			float(lon_phi.x),
			float(lon_phi.y),
			0.0
		)

func _move_player(delta: Vector2i) -> bool:
	var nx: int = player_x + delta.x
	var ny: int = player_y + delta.y
	# Prevent corner-cutting: diagonal requires both adjacent orthogonal tiles to be passable.
	# If diagonal is blocked by corners, slide along a valid axis (feels better when holding two keys).
	if delta.x != 0 and delta.y != 0:
		var can_x: bool = not _is_blocked(player_x + delta.x, player_y)
		var can_y: bool = not _is_blocked(player_x, player_y + delta.y)
		if not (can_x and can_y):
			if can_x:
				delta = Vector2i(delta.x, 0)
			elif can_y:
				delta = Vector2i(0, delta.y)
			else:
				_set_footer("Blocked.")
				return false
			nx = player_x + delta.x
			ny = player_y + delta.y
	if _tile_at(nx, ny) == Tile.DOOR:
		_set_footer("At the exit. Press E or Q to leave.")
		return false
	if _is_blocked(nx, ny):
		_set_footer("Blocked.")
		return false
	if _is_boss_at(nx, ny) and not _boss_defeated:
		_start_dungeon_boss_battle(nx, ny)
		return false
	player_x = nx
	player_y = ny
	_dungeon_steps_since_entry += 1
	_reveal_dungeon_fog_around_player()
	# Clear transient footer messages on movement.
	if footer_label:
		footer_label.text = ""
	# Dungeon random encounters: step-based danger meter (FF-like).
	if _poi_type == "Dungeon":
		if _try_roll_dungeon_encounter():
			return false
	_render_local_map()
	return true

func _try_roll_dungeon_encounter() -> bool:
	if _poi_type != "Dungeon":
		return false
	if scene_router == null or not scene_router.has_method("goto_battle"):
		return false
	if _poi_id.is_empty():
		return false
	# Avoid encounters right at the entrance to prevent immediate battles on entry/return.
	if _dungeon_steps_since_entry < DUNGEON_ENCOUNTER_SAFE_STEPS_NEAR_DOOR:
		return false
	# Avoid encounters on/adjacent to the door to keep the exit usable.
	if _adjacent_or_same(player_x, player_y, _door_pos.x, _door_pos.y):
		return false
	# Avoid triggering on the boss cell (boss handles battle explicitly).
	if _is_boss_at(player_x, player_y) and not _boss_defeated:
		return false

	var world_x: int = int(poi_data.get("world_x", 0))
	var world_y: int = int(poi_data.get("world_y", 0))
	var biome_id: int = int(poi_data.get("biome_id", 7))
	var biome_name: String = String(poi_data.get("biome_name", ""))
	var minute: int = -1
	var day_of_year: int = -1
	if game_state != null and game_state.get("world_time") != null:
		var wt: Object = game_state.world_time
		minute = int(wt.minute_of_day) if "minute_of_day" in wt else -1
		if "abs_day_index" in wt:
			day_of_year = posmod(int(wt.abs_day_index()), 365)
	var rate_mul: float = 1.0
	if game_state != null and game_state.has_method("get_encounter_rate_multiplier"):
		rate_mul = float(game_state.get_encounter_rate_multiplier())
	if game_state != null and game_state.has_method("get_epoch_encounter_rate_multiplier"):
		rate_mul *= float(game_state.get_epoch_encounter_rate_multiplier())

	# Per-dungeon meter state persists in run_flags (distinct from the overworld meter).
	var st: Dictionary = {}
	if game_state != null and typeof(game_state.get("run_flags")) == TYPE_DICTIONARY:
		var rf: Dictionary = game_state.run_flags
		var key: String = "dungeon_encounter_meter_state:%s" % _poi_id
		var v: Variant = rf.get(key)
		if typeof(v) != TYPE_DICTIONARY:
			v = {}
			rf[key] = v
		st = v as Dictionary
	EncounterRegistry.ensure_danger_meter_state_inplace(st)
	var enc: Dictionary = EncounterRegistry.step_danger_meter_and_maybe_trigger(
		_world_seed_hash,
		st,
		world_x,
		world_y,
		player_x,
		player_y,
		biome_id,
		biome_name,
		rate_mul,
		minute,
		day_of_year
	)
	if enc.is_empty():
		return false
	if game_state != null and game_state.has_method("apply_epoch_gameplay_to_encounter"):
		enc = game_state.apply_epoch_gameplay_to_encounter(enc)

	# Reset meter with a grace cooldown after returning from battle.
	EncounterRegistry.reset_danger_meter(_world_seed_hash, st, world_x, world_y, biome_id, minute, day_of_year)

	# Override return contract for local interiors.
	var return_poi: Dictionary = poi_data.duplicate(true)
	return_poi["interior_x"] = player_x
	return_poi["interior_y"] = player_y
	# Keep macro position coherent for location/time/logging; interior position rides in return_poi.
	enc["local_x"] = int(poi_data.get("local_x", 48))
	enc["local_y"] = int(poi_data.get("local_y", 48))
	enc["return_scene"] = SceneContracts.STATE_LOCAL
	enc["return_poi"] = return_poi
	enc["battle_kind"] = "dungeon_random"
	enc["poi_id"] = _poi_id
	# Dungeons should feel more dangerous than overworld for the same biome.
	enc["enemy_power"] = int(enc.get("enemy_power", 8)) + 2
	enc["enemy_hp"] = int(enc.get("enemy_hp", 28)) + 10
	enc["flee_chance"] = clamp(float(enc.get("flee_chance", 0.55)) * 0.85, 0.05, 0.95)

	scene_router.goto_battle(enc)
	return true

func _render_local_map() -> void:
	_update_view_window_origin()
	# Build view fields for GPU renderer (GPU-only visuals).
	var size: int = _render_w * _render_h
	var height_raw := PackedFloat32Array()
	var temp := PackedFloat32Array()
	var moist := PackedFloat32Array()
	var biome := PackedInt32Array()
	var land := PackedInt32Array()
	var beach := PackedInt32Array()
	height_raw.resize(size)
	temp.resize(size)
	moist.resize(size)
	biome.resize(size)
	land.resize(size)
	beach.resize(size)

	var is_dungeon: bool = (_poi_type == "Dungeon")
	var poi_biome_id: int = int(poi_data.get("biome_id", 7))
	var base_t: float = _local_visual_temp_for_biome(poi_biome_id)
	var base_m: float = _local_visual_moist_for_biome(poi_biome_id)
	for sy in range(_render_h):
		for sx in range(_render_w):
			var idx: int = sx + sy * _render_w
			var x: int = _render_origin_x + sx
			var y: int = _render_origin_y + sy
			if not _in_bounds(x, y):
				height_raw[idx] = 0.03
				temp[idx] = base_t
				moist[idx] = base_m
				biome[idx] = LocalAreaTiles.MARKER_UNKNOWN if is_dungeon else LocalAreaTiles.MARKER_WALL
				land[idx] = 1
				beach[idx] = 0
				continue
			if is_dungeon and not _is_dungeon_seen(x, y):
				height_raw[idx] = 0.03
				temp[idx] = base_t
				moist[idx] = base_m
				biome[idx] = LocalAreaTiles.MARKER_UNKNOWN
				land[idx] = 1
				beach[idx] = 0
				continue
			var t: int = _tile_at(x, y)
			var b: int = LocalAreaTiles.MARKER_FLOOR
			var h: float = 0.06
			if t == Tile.WALL:
				if is_dungeon:
					b = LocalAreaTiles.MARKER_UNKNOWN
					h = 0.03
				else:
					b = LocalAreaTiles.MARKER_WALL
					h = 0.20
			elif t == Tile.DOOR:
				b = LocalAreaTiles.MARKER_DOOR
				h = 0.08
			else:
				var o: int = _obj_at(x, y)
				match o:
					Obj.BOSS:
						b = LocalAreaTiles.MARKER_BOSS
						h = 0.14
					Obj.MAIN_CHEST:
						b = LocalAreaTiles.MARKER_MAIN_CHEST
						h = 0.10
					Obj.BED:
						b = LocalAreaTiles.MARKER_BED
						h = 0.09
					Obj.TABLE:
						b = LocalAreaTiles.MARKER_TABLE
						h = 0.09
					Obj.HEARTH:
						b = LocalAreaTiles.MARKER_HEARTH
						h = 0.10
					_:
						pass

			if x == player_x and y == player_y:
				b = MARKER_PLAYER
				h = max(h, 0.12)
			elif actors.size() == room_w * room_h:
				var actor_kind: int = int(actors[_idx(x, y)])
				var actor_marker: int = _actor_marker_for_kind(actor_kind)
				if actor_marker >= 200:
					b = actor_marker
					h = max(h, 0.10)

			height_raw[idx] = h
			biome[idx] = b
			land[idx] = 1
			beach[idx] = 0

			# Mild per-cell variation to avoid flat fills.
			var jt: float = (float(abs(("t|%d|%d|%s" % [x, y, _poi_id]).hash()) % 10000) / 10000.0 - 0.5) * 0.06
			var jm: float = (float(abs(("m|%d|%d|%s" % [x, y, _poi_id]).hash()) % 10000) / 10000.0 - 0.5) * 0.06
			temp[idx] = clamp(base_t + jt, 0.0, 1.0)
			moist[idx] = clamp(base_m + jm, 0.0, 1.0)

	var solar: Dictionary = _get_solar_params()
	var lon_phi: Vector2 = _get_fixed_lon_phi()
	if _gpu_view != null and gpu_map != null:
		_gpu_view.update_and_draw(
			gpu_map,
			{
				"height_raw": height_raw,
				"temp": temp,
				"moist": moist,
				"biome": biome,
				"land": land,
				"beach": beach,
			},
			solar,
			_build_local_cloud_params(),
			float(lon_phi.x),
			float(lon_phi.y),
			0.0
		)
		_apply_scroll_offset()
		_update_fixed_lonlat_uniform()
		if header_label:
			var disp: String = _poi_type
			if disp == "House" and VariantCasts.to_bool(poi_data.get("is_shop", false)):
				disp = "Shop"
			header_label.text = "%s Interior - Tile (%d,%d) - %s" % [
				disp,
				int(poi_data.get("world_x", 0)),
				int(poi_data.get("world_y", 0)),
				_get_time_label(),
			]
		if footer_label:
			if footer_label.text.is_empty():
				footer_label.text = "Move: WASD/Arrows (diagonals OK) | E: Interact | Door/Q: Exit | M: World Map | Esc/Tab: Menu | Dungeons: random encounters"

func _return_to_regional() -> void:
	_close_dialogue()
	_close_shop()
	if game_state != null and game_state.has_method("clear_local_rest_context"):
		game_state.clear_local_rest_context()
	var world_x: int = int(poi_data.get("world_x", 0))
	var world_y: int = int(poi_data.get("world_y", 0))
	var local_x: int = int(poi_data.get("local_x", 48))
	var local_y: int = int(poi_data.get("local_y", 48))
	var biome_id: int = int(poi_data.get("biome_id", 7))
	var biome_name: String = String(poi_data.get("biome_name", ""))
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location("regional", world_x, world_y, local_x, local_y, biome_id, biome_name)
	if startup_state != null and startup_state.has_method("set_selected_world_tile"):
		startup_state.set_selected_world_tile(world_x, world_y, biome_id, biome_name, local_x, local_y)
	if scene_router != null and scene_router.has_method("goto_regional"):
		scene_router.goto_regional(world_x, world_y, local_x, local_y, biome_id, biome_name)
	else:
		get_tree().change_scene_to_file(SceneContracts.SCENE_REGIONAL_MAP)

func _get_time_label() -> String:
	if game_state != null and game_state.has_method("get_time_label"):
		return String(game_state.get_time_label())
	return ""

func _get_world_seed_hash() -> int:
	if game_state != null and int(game_state.world_seed_hash) != 0:
		return int(game_state.world_seed_hash)
	if startup_state != null and int(startup_state.world_seed_hash) != 0:
		return int(startup_state.world_seed_hash)
	return 1

func _set_footer(text_value: String) -> void:
	if footer_label:
		footer_label.text = text_value

func _idx(x: int, y: int) -> int:
	return x + y * room_w

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < room_w and y < room_h

func _tile_at(x: int, y: int) -> int:
	if not _in_bounds(x, y):
		return Tile.WALL
	var i: int = _idx(x, y)
	if i < 0 or i >= tiles.size():
		return Tile.WALL
	return int(tiles[i])

func _obj_at(x: int, y: int) -> int:
	if not _in_bounds(x, y):
		return Obj.NONE
	var i: int = _idx(x, y)
	if i < 0 or i >= objects.size():
		return Obj.NONE
	return int(objects[i])

func _is_blocked(x: int, y: int) -> bool:
	if not _in_bounds(x, y):
		return true
	if _tile_at(x, y) == Tile.WALL:
		return true
	# Doors are interaction exits, not walk-through tiles.
	if _tile_at(x, y) == Tile.DOOR:
		return true
	# NPCs block movement (talk from adjacent tiles).
	if actors.size() == room_w * room_h:
		if int(actors[_idx(x, y)]) != Actor.NONE:
			return true
	# Basic furniture and chest are solid; boss tile stays passable to trigger battle-on-contact.
	var o: int = _obj_at(x, y)
	if o == Obj.BED or o == Obj.TABLE or o == Obj.HEARTH or o == Obj.MAIN_CHEST:
		return true
	return false

func _is_boss_at(x: int, y: int) -> bool:
	return x == _boss_pos.x and y == _boss_pos.y

func _load_poi_instance_state() -> void:
	_boss_defeated = false
	_opened_chests = {}
	if _poi_id.is_empty():
		return
	if game_state != null and game_state.has_method("get_poi_instance_state"):
		var st: Dictionary = game_state.get_poi_instance_state(_poi_id)
		_boss_defeated = VariantCasts.to_bool(st.get("boss_defeated", false))
		var ch: Variant = st.get("opened_chests", {})
		if typeof(ch) == TYPE_DICTIONARY:
			_opened_chests = (ch as Dictionary).duplicate(true)

func _save_poi_instance_state() -> void:
	if _poi_id.is_empty():
		return
	if game_state != null and game_state.has_method("apply_poi_instance_patch"):
		game_state.apply_poi_instance_patch(_poi_id, {
			"boss_defeated": _boss_defeated,
			"opened_chests": _opened_chests.duplicate(true),
		})

func _generate_map() -> void:
	tiles.resize(room_w * room_h)
	objects.resize(room_w * room_h)
	actors.resize(room_w * room_h)
	tiles.fill(Tile.WALL)
	objects.fill(Obj.NONE)
	actors.fill(Actor.NONE)
	_dungeon_seen = PackedByteArray()
	_npcs.clear()
	match _poi_type:
		"Dungeon":
			_generate_dungeon()
		_:
			_generate_house()

func _place_player_at_entry() -> void:
	_anchor_player_x = clamp(_door_pos.x - 1, 1, room_w - 2)
	_anchor_player_y = clamp(_door_pos.y, 1, room_h - 2)
	player_x = _anchor_player_x
	player_y = _anchor_player_y

func _place_player_from_payload_or_entry() -> void:
	_anchor_player_x = clamp(_door_pos.x - 1, 1, room_w - 2)
	_anchor_player_y = clamp(_door_pos.y, 1, room_h - 2)
	# Returning from battle can include an interior position.
	var ix: int = int(poi_data.get("interior_x", -1))
	var iy: int = int(poi_data.get("interior_y", -1))
	if ix >= 0 and iy >= 0 and _in_bounds(ix, iy) and not _is_blocked(ix, iy) and _tile_at(ix, iy) != Tile.DOOR:
		player_x = ix
		player_y = iy
		return
	_place_player_at_entry()

func _apply_generated_map(out: Dictionary) -> void:
	if typeof(out) != TYPE_DICTIONARY or out.is_empty():
		return
	var w: int = int(out.get("w", room_w))
	var h: int = int(out.get("h", room_h))
	if w != room_w or h != room_h:
		return
	var t: Variant = out.get("tiles")
	var o: Variant = out.get("objects")
	if t is PackedByteArray and (t as PackedByteArray).size() == room_w * room_h:
		tiles = t
	if o is PackedByteArray and (o as PackedByteArray).size() == room_w * room_h:
		objects = o
	_door_pos = out.get("door_pos", _door_pos)
	_boss_pos = out.get("boss_pos", _boss_pos)
	_chest_pos = out.get("chest_pos", _chest_pos)

func _generate_house() -> void:
	var out: Dictionary = _local_gen.generate_house(_world_seed_hash, _poi_id, room_w, room_h)
	_apply_generated_map(out)
	_spawn_house_npcs(VariantCasts.to_bool(poi_data.get("is_shop", false)))

func _generate_dungeon() -> void:
	# Procedural dungeon with a guaranteed solvable golden path to the boss.
	var out: Dictionary = _local_gen.generate_dungeon(_world_seed_hash, _poi_id, room_w, room_h)
	_apply_generated_map(out)
	_init_dungeon_fog()

	# Apply cleared/open state overrides.
	if _boss_defeated:
		if _in_bounds(_boss_pos.x, _boss_pos.y):
			objects[_idx(_boss_pos.x, _boss_pos.y)] = Obj.NONE
	else:
		if _in_bounds(_boss_pos.x, _boss_pos.y):
			objects[_idx(_boss_pos.x, _boss_pos.y)] = Obj.BOSS
	# Chest always exists, but stays locked until boss is defeated. Open state persists.
	if VariantCasts.to_bool(_opened_chests.get("main", false)):
		if _in_bounds(_chest_pos.x, _chest_pos.y):
			objects[_idx(_chest_pos.x, _chest_pos.y)] = Obj.NONE
	else:
		if _in_bounds(_chest_pos.x, _chest_pos.y):
			objects[_idx(_chest_pos.x, _chest_pos.y)] = Obj.MAIN_CHEST

func _init_dungeon_fog() -> void:
	var size: int = room_w * room_h
	_dungeon_seen = PackedByteArray()
	_dungeon_seen.resize(size)
	_dungeon_seen.fill(0)

func _is_dungeon_seen(x: int, y: int) -> bool:
	if _poi_type != "Dungeon":
		return true
	if not _in_bounds(x, y):
		return false
	var idx: int = _idx(x, y)
	if idx < 0 or idx >= _dungeon_seen.size():
		return false
	return _dungeon_seen[idx] != 0

func _reveal_dungeon_fog_around_player() -> bool:
	if _poi_type != "Dungeon":
		return false
	var size: int = room_w * room_h
	if _dungeon_seen.size() != size:
		_init_dungeon_fog()
	var r: int = max(1, DUNGEON_FOG_REVEAL_RADIUS)
	var r2: int = r * r
	var changed: bool = false
	var x0: int = max(0, player_x - r)
	var x1: int = min(room_w - 1, player_x + r)
	var y0: int = max(0, player_y - r)
	var y1: int = min(room_h - 1, player_y + r)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var dx: int = x - player_x
			var dy: int = y - player_y
			if dx * dx + dy * dy > r2:
				continue
			var idx: int = _idx(x, y)
			if idx < 0 or idx >= _dungeon_seen.size():
				continue
			if _dungeon_seen[idx] == 0:
				_dungeon_seen[idx] = 1
				changed = true
	return changed

func _configure_dimensions_for_poi() -> void:
	var dims: Vector2i = _local_gen.dimensions_for_poi(_poi_type)
	room_w = max(8, int(dims.x))
	room_h = max(8, int(dims.y))

func _spawn_house_npcs(is_shop: bool) -> void:
	if actors.size() != room_w * room_h:
		return
	var key_root: String = "house_npc|%s" % _poi_id
	var density_mul: float = _npc_density_mul()
	if is_shop:
		# Exactly 1 shopkeeper, plus 0..3 customers.
		var keeper_pref: Array[Vector2i] = [
			Vector2i(7, 6),
			Vector2i(7, 7),
			Vector2i(6, 7),
			Vector2i(6, 6),
			Vector2i(5, 6),
		]
		_place_npc(Actor.SHOPKEEPER, key_root + "|keeper", "shopkeeper", keeper_pref)
		var customers_base: int = DeterministicRng.randi_range(_world_seed_hash, key_root + "|cust_n", 0, 3)
		var customers: int = _scale_npc_count(customers_base, density_mul, key_root + "|cust_scale")
		customers = clamp(customers, 0, 5)
		for i in range(customers):
			var kind: int = _npc_kind_roll("%s|cust_kind|i=%d" % [key_root, i])
			_place_npc(kind, "%s|cust|i=%d" % [key_root, i], "customer")
		return

	# Normal house: seed-picked “family constellation” (0..4 residents).
	var occ_roll: float = DeterministicRng.randf01(_world_seed_hash, key_root + "|occ")
	var kinds: Array[int] = []
	if occ_roll < 0.20:
		kinds = []
	elif occ_roll < 0.32:
		kinds = [Actor.MAN]
	elif occ_roll < 0.44:
		kinds = [Actor.WOMAN]
	elif occ_roll < 0.66:
		kinds = [Actor.MAN, Actor.WOMAN]
	elif occ_roll < 0.76:
		kinds = [Actor.MAN, Actor.CHILD]
	elif occ_roll < 0.86:
		kinds = [Actor.WOMAN, Actor.CHILD]
	elif occ_roll < 0.95:
		kinds = [Actor.MAN, Actor.WOMAN, Actor.CHILD]
	else:
		kinds = [Actor.MAN, Actor.WOMAN, Actor.CHILD, Actor.CHILD]
	var residents_target: int = _scale_npc_count(kinds.size(), density_mul, key_root + "|occ_scale")
	residents_target = clamp(residents_target, 0, 6)
	for i in range(residents_target):
		var kind_i: int = Actor.MAN
		if i < kinds.size():
			kind_i = int(kinds[i])
		else:
			kind_i = _npc_kind_roll("%s|occ_extra_kind|i=%d" % [key_root, i])
		_place_npc(kind_i, "%s|occ|i=%d" % [key_root, i], "resident")

func _place_npc(kind: int, seed_tag: String, role: String, preferred: Array[Vector2i] = []) -> void:
	for p in preferred:
		if _can_place_npc(p.x, p.y):
			_register_npc(kind, p.x, p.y, role)
			return
	for t in range(80):
		var x: int = DeterministicRng.randi_range(_world_seed_hash, "%s|x|t=%d" % [seed_tag, t], 2, room_w - 3)
		var y: int = DeterministicRng.randi_range(_world_seed_hash, "%s|y|t=%d" % [seed_tag, t], 2, room_h - 3)
		if _can_place_npc(x, y):
			_register_npc(kind, x, y, role)
			return

func _register_npc(kind: int, x: int, y: int, role: String) -> void:
	if actors.size() != room_w * room_h:
		return
	var idx: int = _idx(x, y)
	if idx < 0 or idx >= actors.size():
		return
	actors[idx] = kind
	var rank: float = _npc_role_social_rank(role, kind)
	var disp_seed: String = "npc_disp|%s|x=%d|y=%d|r=%s" % [_poi_id, x, y, role]
	var base_disp: float = lerp(-0.14, 0.14, DeterministicRng.randf01(_world_seed_hash, disp_seed))
	var role_shift: float = 0.0
	if role == "shopkeeper":
		role_shift = 0.08
	elif role == "customer":
		role_shift = -0.03
	var disposition_bias: float = clamp(base_disp + role_shift + _npc_disposition_epoch_shift(), -0.95, 0.95)
	_npcs.append({
		"kind": kind,
		"x": x,
		"y": y,
		"vx": float(x),
		"vy": float(y),
		"from_x": float(x),
		"from_y": float(y),
		"to_x": float(x),
		"to_y": float(y),
		"anim_t": 1.0,
		"role": role,
		"social_class_rank": rank,
		"disposition_bias": disposition_bias,
		"dest_x": -1,
		"dest_y": -1,
		"path": [],
		"path_i": 0,
	})

func _can_place_npc(x: int, y: int) -> bool:
	if not _in_bounds(x, y):
		return false
	if _tile_at(x, y) != Tile.FLOOR:
		return false
	if _obj_at(x, y) != Obj.NONE:
		return false
	if x == _door_pos.x and y == _door_pos.y:
		return false
	# Avoid spawning directly on the player entry tile.
	var ex: int = clamp(_door_pos.x - 1, 1, room_w - 2)
	var ey: int = clamp(_door_pos.y, 1, room_h - 2)
	if x == ex and y == ey:
		return false
	if actors.size() == room_w * room_h:
		if int(actors[_idx(x, y)]) != Actor.NONE:
			return false
	return true

func _can_npc_move_to(x: int, y: int) -> bool:
	if not _in_bounds(x, y):
		return false
	if _tile_at(x, y) != Tile.FLOOR:
		return false
	if _obj_at(x, y) != Obj.NONE:
		return false
	if x == player_x and y == player_y:
		return false
	if actors.size() == room_w * room_h:
		if int(actors[_idx(x, y)]) != Actor.NONE:
			return false
	return true

func _step_npcs() -> bool:
	if _npcs.is_empty() or actors.size() != room_w * room_h:
		return false
	var moved := false
	for i in range(_npcs.size()):
		var npc: Dictionary = _npcs[i]
		var kind: int = int(npc.get("kind", Actor.NONE))
		if kind == Actor.NONE or kind == Actor.SHOPKEEPER:
			continue
		var x: int = int(npc.get("x", 0))
		var y: int = int(npc.get("y", 0))
		var start := Vector2i(x, y)
		var path: Array = npc.get("path", [])
		var path_i: int = int(npc.get("path_i", 0))
		var dest := Vector2i(int(npc.get("dest_x", -1)), int(npc.get("dest_y", -1)))

		var needs_plan: bool = false
		if dest.x < 0 or dest.y < 0:
			needs_plan = true
		elif typeof(path) != TYPE_ARRAY or path.is_empty() or path_i <= 0 or path_i >= path.size():
			needs_plan = true
		if needs_plan:
			var new_path: Array[Vector2i] = _npc_pick_path(start)
			if new_path.size() < 2:
				continue
			npc["path"] = new_path
			npc["path_i"] = 1
			var goal: Vector2i = new_path[new_path.size() - 1]
			npc["dest_x"] = int(goal.x)
			npc["dest_y"] = int(goal.y)
			path = new_path
			path_i = 1
			dest = goal

		var next: Vector2i = path[path_i]
		if _can_npc_move_to(next.x, next.y):
			actors[_idx(x, y)] = Actor.NONE
			actors[_idx(next.x, next.y)] = kind
			npc["from_x"] = float(x)
			npc["from_y"] = float(y)
			npc["to_x"] = float(next.x)
			npc["to_y"] = float(next.y)
			npc["anim_t"] = 0.0
			npc["vx"] = float(x)
			npc["vy"] = float(y)
			npc["x"] = next.x
			npc["y"] = next.y
			npc["path_i"] = path_i + 1
			moved = true
			if int(npc["path_i"]) >= path.size():
				# Arrived: pick a new destination next tick.
				npc["dest_x"] = -1
				npc["dest_y"] = -1
				npc["path"] = []
				npc["path_i"] = 0
		else:
			# Blocked: try re-pathing to the same destination once; otherwise abandon.
			if dest.x >= 0 and dest.y >= 0 and _can_npc_move_to(dest.x, dest.y):
				var repath: Array[Vector2i] = _astar_path(start, dest)
				if repath.size() >= 2:
					npc["path"] = repath
					npc["path_i"] = 1
				else:
					npc["dest_x"] = -1
					npc["dest_y"] = -1
					npc["path"] = []
					npc["path_i"] = 0
			else:
				npc["dest_x"] = -1
				npc["dest_y"] = -1
				npc["path"] = []
				npc["path_i"] = 0
				npc["anim_t"] = 1.0
				npc["vx"] = float(x)
				npc["vy"] = float(y)

		_npcs[i] = npc
	return moved

func _npc_pick_path(start: Vector2i) -> Array[Vector2i]:
	for _t in range(NPC_MAX_DEST_TRIES):
		var gx: int = _npc_rng.randi_range(2, room_w - 3)
		var gy: int = _npc_rng.randi_range(2, room_h - 3)
		if abs(gx - start.x) + abs(gy - start.y) < NPC_MIN_DEST_DIST:
			continue
		if not _can_npc_move_to(gx, gy):
			continue
		var goal := Vector2i(gx, gy)
		var path: Array[Vector2i] = _astar_path(start, goal)
		if path.size() >= 2:
			return path
	return []

func _astar_path(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	# Lightweight A* for small interior grids.
	if start == goal:
		return [start]
	if not _in_bounds(start.x, start.y) or not _in_bounds(goal.x, goal.y):
		return []
	if not _astar_walkable(goal.x, goal.y, start):
		return []

	var start_id: int = _idx(start.x, start.y)
	var goal_id: int = _idx(goal.x, goal.y)
	var open: Array[int] = [start_id]
	var open_set: Dictionary = {start_id: true}
	var came_from: Dictionary = {}
	var g_score: Dictionary = {start_id: 0}
	var f_score: Dictionary = {start_id: _manhattan(start.x, start.y, goal.x, goal.y)}
	var closed: Dictionary = {}
	var iters: int = 0
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

	while not open.is_empty() and iters < NPC_ASTAR_MAX_ITERS:
		iters += 1
		# Pick open node with lowest f-score.
		var best_idx: int = 0
		var current_id: int = int(open[0])
		var best_f: int = int(f_score.get(current_id, 1 << 30))
		for j in range(1, open.size()):
			var cand_id: int = int(open[j])
			var cand_f: int = int(f_score.get(cand_id, 1 << 30))
			if cand_f < best_f:
				best_f = cand_f
				current_id = cand_id
				best_idx = j
		open.remove_at(best_idx)
		open_set.erase(current_id)

		if current_id == goal_id:
			return _reconstruct_astar_path(came_from, current_id, start_id)

		closed[current_id] = true
		var cx: int = int(current_id % room_w)
		var cy: int = int(current_id / room_w)
		for d in dirs:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if not _astar_walkable(nx, ny, start):
				continue
			var nid: int = _idx(nx, ny)
			if closed.has(nid):
				continue
			var tentative_g: int = int(g_score.get(current_id, 1 << 30)) + 1
			if tentative_g >= int(g_score.get(nid, 1 << 30)):
				continue
			came_from[nid] = current_id
			g_score[nid] = tentative_g
			f_score[nid] = tentative_g + _manhattan(nx, ny, goal.x, goal.y)
			if not open_set.has(nid):
				open.append(nid)
				open_set[nid] = true

	return []

func _astar_walkable(x: int, y: int, start: Vector2i) -> bool:
	# Treat the NPC's start cell as walkable even though it's occupied.
	if x == start.x and y == start.y:
		return true
	if not _in_bounds(x, y):
		return false
	if _tile_at(x, y) != Tile.FLOOR:
		return false
	if _obj_at(x, y) != Obj.NONE:
		return false
	if x == player_x and y == player_y:
		return false
	if actors.size() == room_w * room_h and int(actors[_idx(x, y)]) != Actor.NONE:
		return false
	return true

func _manhattan(ax: int, ay: int, bx: int, by: int) -> int:
	return abs(ax - bx) + abs(ay - by)

func _reconstruct_astar_path(came_from: Dictionary, current_id: int, start_id: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var cur: int = int(current_id)
	var safety: int = 0
	while true:
		out.append(Vector2i(int(cur % room_w), int(cur / room_w)))
		if cur == start_id:
			break
		if not came_from.has(cur):
			return []
		cur = int(came_from[cur])
		safety += 1
		if safety > room_w * room_h + 8:
			return []
	out.reverse()
	return out

func _npc_at_or_adjacent(px: int, py: int) -> Dictionary:
	for npc in _npcs:
		var x: int = int(npc.get("x", -999))
		var y: int = int(npc.get("y", -999))
		if abs(px - x) + abs(py - y) <= 1:
			return npc
	return {}

func _interact_with_npc(npc: Dictionary) -> void:
	var kind: int = int(npc.get("kind", Actor.NONE))
	if kind == Actor.SHOPKEEPER:
		_open_shop()
		return
	var role: String = String(npc.get("role", "resident"))
	var rank: float = clamp(float(npc.get("social_class_rank", _npc_role_social_rank(role, kind))), 0.0, 1.0)
	var home_state_id: String = String(poi_data.get("political_state_id", ""))
	if game_state != null and game_state.has_method("get_political_state_id_at"):
		home_state_id = String(game_state.get_political_state_id_at(int(poi_data.get("world_x", 0)), int(poi_data.get("world_y", 0))))
	var dialogue_line: String = ""
	if game_state != null and game_state.has_method("get_npc_dialogue_line"):
		dialogue_line = String(game_state.get_npc_dialogue_line({
			"npc_id": "local|%s|%d|%d|%d" % [_poi_id, int(npc.get("x", 0)), int(npc.get("y", 0)), kind],
			"kind": kind,
			"role": role,
			"home_state_id": home_state_id,
			"world_x": int(poi_data.get("world_x", 0)),
			"world_y": int(poi_data.get("world_y", 0)),
			"social_class_rank": rank,
			"disposition_bias": float(npc.get("disposition_bias", 0.0)),
		}))
	if not dialogue_line.is_empty():
		_open_dialogue(dialogue_line)
		return
	var lines_man: PackedStringArray = PackedStringArray([
		"Hello.",
		"Stay safe out there.",
	])
	var lines_woman: PackedStringArray = PackedStringArray([
		"Good day.",
		"Did you hear the latest rumors?",
	])
	var lines_child: PackedStringArray = PackedStringArray([
		"...",
		"Hi!",
	])
	var pool: PackedStringArray = lines_man
	if kind == Actor.WOMAN:
		pool = lines_woman
	elif kind == Actor.CHILD:
		pool = lines_child
	var seed_key: String = "npc_line|%s|%d|%d|k=%d" % [_poi_id, int(npc.get("x", 0)), int(npc.get("y", 0)), kind]
	var idx: int = DeterministicRng.randi_range(_world_seed_hash, seed_key, 0, max(0, pool.size() - 1))
	_open_dialogue(String(pool[idx]))

func _try_interact() -> void:
	# NPC interaction (universal E key).
	var npc: Dictionary = _npc_at_or_adjacent(player_x, player_y)
	if not npc.is_empty():
		_interact_with_npc(npc)
		return
	# Door exit.
	if _adjacent_or_same(player_x, player_y, _door_pos.x, _door_pos.y):
		_return_to_regional()
		return
	# Chest interaction.
	if _poi_type == "Dungeon" and _adjacent_or_same(player_x, player_y, _chest_pos.x, _chest_pos.y):
		_try_open_main_chest()
		return
	_set_footer("Nothing to interact with.")

func _try_open_main_chest() -> void:
	if VariantCasts.to_bool(_opened_chests.get("main", false)):
		_set_footer("The chest is empty.")
		return
	if not _boss_defeated:
		_set_footer("A dark force seals the chest.")
		return
	_opened_chests["main"] = true
	objects[_idx(_chest_pos.x, _chest_pos.y)] = Obj.NONE
	_grant_main_treasure()
	_save_poi_instance_state()
	_render_local_map()

func _grant_main_treasure() -> void:
	# Scaffold treasure: small gold + a deterministic item.
	var gold: int = 60
	var item_name: String = "Potion"
	if _poi_id.length() > 0:
		var roll: int = abs(_poi_id.hash()) % 3
		if roll == 0 and ItemCatalog.has_item("Bronze Sword"):
			item_name = "Bronze Sword"
		elif roll == 1 and ItemCatalog.has_item("Leather Armor"):
			item_name = "Leather Armor"
		else:
			item_name = "Potion"
	if game_state != null and game_state.party != null:
		game_state.party.gold += gold
		game_state.party.add_item(item_name, 1)
		if game_state.has_method("_emit_party_changed"):
			game_state._emit_party_changed()
		if game_state.has_method("_emit_inventory_changed"):
			game_state._emit_inventory_changed()
	_set_footer("Treasure found: %s (+%d gold)" % [item_name, gold])

func _start_dungeon_boss_battle(return_x: int, return_y: int) -> void:
	if _poi_type != "Dungeon" or _boss_defeated:
		return
	if scene_router == null or not scene_router.has_method("goto_battle"):
		return
	if _poi_id.is_empty():
		_set_footer("Missing POI id (cannot start boss battle).")
		return
	# Ensure return position is valid inside this POI.
	var rx: int = clamp(return_x, 1, room_w - 2)
	var ry: int = clamp(return_y, 1, room_h - 2)
	if _is_blocked(rx, ry) or _tile_at(rx, ry) == Tile.DOOR:
		rx = player_x
		ry = player_y
	var return_poi: Dictionary = poi_data.duplicate(true)
	return_poi["interior_x"] = rx
	return_poi["interior_y"] = ry
	var encounter_payload: Dictionary = {
		"encounter_seed_key": "boss|%s" % _poi_id,
		"world_x": int(poi_data.get("world_x", 0)),
		"world_y": int(poi_data.get("world_y", 0)),
		"local_x": int(poi_data.get("local_x", 48)),
		"local_y": int(poi_data.get("local_y", 48)),
		"biome_id": int(poi_data.get("biome_id", 7)),
		"biome_name": String(poi_data.get("biome_name", "")),
		"enemy_group": "Dungeon Boss",
		"enemy_power": 14,
		"enemy_hp": 85,
		"flee_chance": 0.0,
		"rewards": {"exp": 60, "gold": 0, "items": []},
		"return_scene": SceneContracts.STATE_LOCAL,
		"return_poi": return_poi,
		"battle_kind": "dungeon_boss",
		"poi_id": _poi_id,
	}
	scene_router.goto_battle(encounter_payload)

func _adjacent_or_same(ax: int, ay: int, bx: int, by: int) -> bool:
	return abs(ax - bx) + abs(ay - by) <= 1

func _exit_tree() -> void:
	_close_dialogue()
	_close_shop()
	if game_state != null and game_state.has_method("clear_local_rest_context"):
		game_state.clear_local_rest_context()
	if _gpu_view != null and "cleanup" in _gpu_view:
		_gpu_view.cleanup()
	_gpu_view = null

func _on_gpu_map_resized() -> void:
	_apply_scroll_offset()
	_update_fixed_lonlat_uniform()

func _update_fixed_lonlat_uniform() -> void:
	if gpu_map == null:
		return
	if not ("set_fixed_lonlat" in gpu_map):
		return
	var lon_phi: Vector2 = _get_fixed_lon_phi()
	gpu_map.set_fixed_lonlat(true, float(lon_phi.x), float(lon_phi.y))

func _build_local_cloud_params() -> Dictionary:
	var biome_id: int = int(poi_data.get("biome_id", 7))
	var moist: float = _local_visual_moist_for_biome(biome_id)
	var temp: float = _local_visual_temp_for_biome(biome_id)
	var ww: int = 275
	var wh: int = 62
	if game_state != null and int(game_state.world_width) > 0 and int(game_state.world_height) > 0:
		ww = int(game_state.world_width)
		wh = int(game_state.world_height)
	elif startup_state != null and int(startup_state.world_width) > 0 and int(startup_state.world_height) > 0:
		ww = int(startup_state.world_width)
		wh = int(startup_state.world_height)
	var region_size: int = 96
	var base_x: int = int(poi_data.get("world_x", 0)) * region_size + int(poi_data.get("local_x", 48))
	var base_y: int = int(poi_data.get("world_y", 0)) * region_size + int(poi_data.get("local_y", 48))
	var origin_global_x: int = base_x + (_render_origin_x - _anchor_player_x)
	var origin_global_y: int = base_y + (_render_origin_y - _anchor_player_y)
	var wind_x: float = 0.08 + (temp - 0.5) * 0.10
	var wind_y: float = 0.03 + (moist - 0.5) * 0.08
	var coverage: float = clamp(0.22 + moist * 0.68, 0.10, 0.95)
	return {
		"enabled": true,
		"origin_x": origin_global_x,
		"origin_y": origin_global_y,
		"world_period_x": max(1, ww * region_size),
		"world_height": max(1, wh * region_size),
		"scale": lerp(0.017, 0.024, moist),
		"wind_x": wind_x,
		"wind_y": wind_y,
		"coverage": coverage,
		"contrast": lerp(1.15, 1.40, coverage),
	}

func _local_visual_temp_for_biome(biome_id: int) -> float:
	if biome_id >= 200:
		return 0.5
	match biome_id:
		1, 5, 20, 22, 23, 24, 29, 30, 33, 34:
			return 0.15
		11, 15:
			return 0.78
		3, 4, 28, 40, 41:
			return 0.82
		10:
			return 0.60
		_:
			return 0.55

func _local_visual_moist_for_biome(biome_id: int) -> float:
	if biome_id >= 200:
		return 0.5
	match biome_id:
		10, 15, 11:
			return 0.80
		3, 4, 28:
			return 0.18
		1, 5, 20, 24:
			return 0.35
		_:
			return 0.55

func _get_solar_params() -> Dictionary:
	var day_of_year: float = 0.0
	var time_of_day: float = 0.0
	var sim_days: float = 0.0
	if game_state != null and game_state.get("world_time") != null:
		var wt = game_state.world_time
		var day_index: int = max(0, int(wt.day) - 1)
		for m in range(1, int(wt.month)):
			day_index += WorldTimeStateModel.days_in_month(m)
		day_index = clamp(day_index, 0, 364)
		day_of_year = float(day_index) / 365.0
		var sod: int = int(wt.second_of_day) if ("second_of_day" in wt) else int(wt.minute_of_day) * 60
		sod = clamp(sod, 0, WorldTimeStateModel.SECONDS_PER_DAY - 1)
		time_of_day = float(sod) / float(WorldTimeStateModel.SECONDS_PER_DAY)
		sim_days = float(max(1, int(wt.year)) - 1) * 365.0 + float(day_index) + time_of_day
	return {
		"day_of_year": day_of_year,
		"time_of_day": time_of_day,
		"sim_days": sim_days,
		"base": 0.008,
		"contrast": 0.992,
		"relief_strength": 0.10,
	}

func _get_fixed_lon_phi() -> Vector2:
	var ww: int = 275
	var wh: int = 62
	if game_state != null and int(game_state.world_width) > 0 and int(game_state.world_height) > 0:
		ww = int(game_state.world_width)
		wh = int(game_state.world_height)
	elif startup_state != null and int(startup_state.world_width) > 0 and int(startup_state.world_height) > 0:
		ww = int(startup_state.world_width)
		wh = int(startup_state.world_height)
	var total_w: float = float(max(1, ww * 96))
	var total_h: float = float(max(2, wh * 96))
	var base_x: float = float(int(poi_data.get("world_x", 0)) * 96 + int(poi_data.get("local_x", 48)))
	var base_y: float = float(int(poi_data.get("world_y", 0)) * 96 + int(poi_data.get("local_y", 48)))
	var gx: float = base_x + (_player_fx - float(_anchor_player_x))
	var gy: float = base_y + (_player_fy - float(_anchor_player_y))
	gx = fposmod(gx, total_w)
	if gx < 0.0:
		gx += total_w
	gy = clamp(gy, 0.0, total_h - 1.0)
	var lon: float = TAU * (gx / total_w)
	var lat_norm: float = 0.5 - (gy / max(1.0, total_h - 1.0))
	var phi: float = lat_norm * PI
	return Vector2(lon, phi)
