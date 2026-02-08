extends Control

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const PoiCatalog = preload("res://scripts/gameplay/catalog/PoiCatalog.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")
const DeterministicRng = preload("res://scripts/gameplay/DeterministicRng.gd")
const WorldTimeStateModel = preload("res://scripts/gameplay/models/WorldTimeState.gd")
const GpuMapView = preload("res://scripts/gameplay/rendering/GpuMapView.gd")

const TAU: float = 6.28318530718
const PI: float = 3.14159265359

@onready var header_label: Label = %HeaderLabel
@onready var gpu_map: Control = %GpuMap
@onready var footer_label: Label = %FooterLabel
@onready var dialogue_popup: PopupPanel = %DialoguePopup
@onready var dialogue_text: Label = %DialogueText
@onready var dialogue_close_button: Button = %DialogueCloseButton

enum Tile {
	WALL = 0,
	FLOOR = 1,
	DOOR = 2,
}

enum Obj {
	NONE = 0,
	BOSS = 1,
	MAIN_CHEST = 2,
	BED = 3,
	TABLE = 4,
	HEARTH = 5,
}

enum Actor {
	NONE = 0,
	MAN = 1,
	WOMAN = 2,
	CHILD = 3,
	SHOPKEEPER = 4,
}

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

var _poi_id: String = ""
var _poi_type: String = "House"
var _boss_defeated: bool = false
var _opened_chests: Dictionary = {}
var _door_pos: Vector2i = Vector2i(1, 1)
var _boss_pos: Vector2i = Vector2i(-1, -1)
var _chest_pos: Vector2i = Vector2i(-1, -1)
var _gpu_view: Object = null
var _player_marker: ColorRect = null
var _npcs: Array[Dictionary] = []
var _npc_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _npc_move_accum: float = 0.0
var _dynamic_refresh_accum: float = 0.0
var _world_seed_hash: int = 1
var _dialogue_pause_active: bool = false
const NPC_MOVE_INTERVAL: float = 0.75
const DYNAMIC_REFRESH_INTERVAL: float = 0.50
const NPC_MAX_DEST_TRIES: int = 24
const NPC_MIN_DEST_DIST: int = 3
const NPC_ASTAR_MAX_ITERS: int = 4096

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	startup_state = get_node_or_null("/root/StartupState")
	scene_router = get_node_or_null("/root/SceneRouter")
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
	_install_menu_overlay()
	_install_world_map_overlay()
	_wire_dialogue_controls()
	_load_poi_instance_state()
	_generate_map()
	_place_player_from_payload_or_entry()
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
		gpu_map.initialize_gpu_rendering(font, font_size, room_w, room_h)
	# Initialize per-view GPU field packer.
	if _gpu_view == null:
		_gpu_view = GpuMapView.new()
		_gpu_view.configure("local_view", room_w, room_h, seed_hash)
	if gpu_map != null and gpu_map is Control:
		if not (gpu_map as Control).resized.is_connected(_on_gpu_map_resized):
			(gpu_map as Control).resized.connect(_on_gpu_map_resized)
	_ensure_player_marker()
	_update_player_marker()
	call_deferred("_update_player_marker")

func _ensure_player_marker() -> void:
	if _player_marker != null or gpu_map == null:
		return
	_player_marker = ColorRect.new()
	_player_marker.color = Color(0.98, 0.90, 0.30, 0.55)
	_player_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_marker.z_index = 200
	_player_marker.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	gpu_map.add_child(_player_marker)

func _unhandled_input(event: InputEvent) -> void:
	var vp: Viewport = get_viewport()
	# When an overlay is visible, let it consume input first.
	if world_map_overlay != null and world_map_overlay.visible:
		return
	if menu_overlay != null and menu_overlay.visible:
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
		var delta := Vector2i.ZERO
		if event.keycode == KEY_W or event.keycode == KEY_UP:
			delta = Vector2i(0, -1)
		elif event.keycode == KEY_S or event.keycode == KEY_DOWN:
			delta = Vector2i(0, 1)
		elif event.keycode == KEY_A or event.keycode == KEY_LEFT:
			delta = Vector2i(-1, 0)
		elif event.keycode == KEY_D or event.keycode == KEY_RIGHT:
			delta = Vector2i(1, 0)
		if delta != Vector2i.ZERO:
			_move_player(delta)
			if vp:
				vp.set_input_as_handled()

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
	if dialogue_popup != null and dialogue_popup.visible:
		return
	_npc_move_accum += delta
	_dynamic_refresh_accum += delta
	if _npc_move_accum >= NPC_MOVE_INTERVAL:
		_npc_move_accum = 0.0
		if _step_npcs():
			_render_local_map()
			return
	if _dynamic_refresh_accum >= DYNAMIC_REFRESH_INTERVAL:
		_dynamic_refresh_accum = 0.0
		_update_time_visuals()

func _update_time_visuals() -> void:
	if header_label:
		var disp: String = _poi_type
		if disp == "House" and bool(poi_data.get("is_shop", false)):
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
			{"enabled": false},
			float(lon_phi.x),
			float(lon_phi.y),
			0.0
		)

func _move_player(delta: Vector2i) -> void:
	var nx: int = player_x + delta.x
	var ny: int = player_y + delta.y
	if _is_blocked(nx, ny):
		_set_footer("Blocked.")
		return
	# Stepping onto the doorway exits immediately (no "E" required).
	if _tile_at(nx, ny) == Tile.DOOR:
		_return_to_regional()
		return
	if _is_boss_at(nx, ny) and not _boss_defeated:
		_start_dungeon_boss_battle(nx, ny)
		return
	player_x = nx
	player_y = ny
	# Clear transient footer messages on movement.
	if footer_label:
		footer_label.text = ""
	_render_local_map()

func _render_local_map() -> void:
	# Build view fields for GPU renderer (GPU-only visuals).
	var size: int = room_w * room_h
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

	for y in range(room_h):
		for x in range(room_w):
			var idx: int = x + y * room_w
			var t: int = _tile_at(x, y)
			var b: int = 211  # interior floor
			var h: float = 0.06
			if t == Tile.WALL:
				b = 210
				h = 0.20
				elif t == Tile.DOOR:
					b = 212
					h = 0.08
				else:
					var o: int = _obj_at(x, y)
					# NPCs are rendered as gameplay-only biome markers (GPU palette IDs >= 200).
					if o == Obj.NONE and actors.size() == size:
						var ak: int = int(actors[idx])
						match ak:
							Actor.MAN:
								b = 218
								h = 0.11
							Actor.WOMAN:
								b = 219
								h = 0.11
							Actor.CHILD:
								b = 221
								h = 0.10
							Actor.SHOPKEEPER:
								b = 222
								h = 0.11
							_:
								pass
					match o:
						Obj.BOSS:
							b = 214
							h = 0.14
						Obj.MAIN_CHEST:
							b = 213
							h = 0.10
						Obj.BED:
							b = 215
							h = 0.09
						Obj.TABLE:
							b = 216
							h = 0.09
						Obj.HEARTH:
							b = 217
							h = 0.10
						_:
							pass
			height_raw[idx] = h
			biome[idx] = b
			land[idx] = 1
			beach[idx] = 0

			# Mild per-cell variation to avoid flat fills.
			var jt: float = (float(abs(("t|%d|%d|%s" % [x, y, _poi_id]).hash()) % 10000) / 10000.0 - 0.5) * 0.06
			var jm: float = (float(abs(("m|%d|%d|%s" % [x, y, _poi_id]).hash()) % 10000) / 10000.0 - 0.5) * 0.06
			temp[idx] = clamp(0.50 + jt, 0.0, 1.0)
			moist[idx] = clamp(0.50 + jm, 0.0, 1.0)

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
			{"enabled": false},
			float(lon_phi.x),
			float(lon_phi.y),
			0.0
		)
		_update_player_marker()
		if header_label:
			var disp: String = _poi_type
			if disp == "House" and bool(poi_data.get("is_shop", false)):
				disp = "Shop"
			header_label.text = "%s Interior - Tile (%d,%d) - %s" % [
				disp,
				int(poi_data.get("world_x", 0)),
				int(poi_data.get("world_y", 0)),
				_get_time_label(),
			]
		if footer_label:
			if footer_label.text.is_empty():
				footer_label.text = "Move: WASD/Arrows | E: Interact | Door/Q: Exit | M: World Map | Esc/Tab: Menu"

func _return_to_regional() -> void:
	_close_dialogue()
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
	# NPCs block movement (talk from adjacent tiles).
	if actors.size() == room_w * room_h:
		if int(actors[_idx(x, y)]) != Actor.NONE:
			return true
	# Basic furniture blocks; boss/chest remain passable for now.
	var o: int = _obj_at(x, y)
	if o == Obj.BED or o == Obj.TABLE or o == Obj.HEARTH:
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
		_boss_defeated = bool(st.get("boss_defeated", false))
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
	_npcs.clear()
	match _poi_type:
		"Dungeon":
			_generate_dungeon()
		_:
			_generate_house()

func _place_player_at_entry() -> void:
	player_x = clamp(_door_pos.x - 1, 1, room_w - 2)
	player_y = clamp(_door_pos.y, 1, room_h - 2)

func _place_player_from_payload_or_entry() -> void:
	# Returning from battle can include an interior position.
	var ix: int = int(poi_data.get("interior_x", -1))
	var iy: int = int(poi_data.get("interior_y", -1))
	if ix >= 0 and iy >= 0 and _in_bounds(ix, iy) and not _is_blocked(ix, iy) and _tile_at(ix, iy) != Tile.DOOR:
		player_x = ix
		player_y = iy
		return
	_place_player_at_entry()

func _carve_room(x0: int, y0: int, x1: int, y1: int) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x <= 0 or y <= 0 or x >= room_w - 1 or y >= room_h - 1:
				continue
			tiles[_idx(x, y)] = Tile.FLOOR

func _carve_hall(x0: int, y0: int, x1: int, y1: int) -> void:
	var x: int = x0
	var y: int = y0
	while x != x1:
		if _in_bounds(x, y):
			tiles[_idx(x, y)] = Tile.FLOOR
		x += 1 if x1 > x else -1
	while y != y1:
		if _in_bounds(x, y):
			tiles[_idx(x, y)] = Tile.FLOOR
		y += 1 if y1 > y else -1
	if _in_bounds(x, y):
		tiles[_idx(x, y)] = Tile.FLOOR

func _generate_house() -> void:
	_carve_room(2, 2, room_w - 3, room_h - 3)
	_door_pos = Vector2i(room_w - 2, int(room_h / 2))
	tiles[_idx(_door_pos.x, _door_pos.y)] = Tile.DOOR
	# Minimal furniture.
	objects[_idx(4, 4)] = Obj.BED
	objects[_idx(6, 6)] = Obj.TABLE
	objects[_idx(5, room_h - 5)] = Obj.HEARTH
	_spawn_house_npcs(bool(poi_data.get("is_shop", false)))

func _generate_dungeon() -> void:
	# Two-room dungeon: entrance room (right) -> corridor -> boss room (left).
	var mid_y: int = int(room_h / 2)
	_door_pos = Vector2i(room_w - 2, mid_y)
	tiles[_idx(_door_pos.x, _door_pos.y)] = Tile.DOOR
	_carve_room(room_w - 14, 3, room_w - 3, room_h - 4)
	_carve_room(2, 3, 14, room_h - 4)
	_carve_hall(14, mid_y, room_w - 14, mid_y)
	_boss_pos = Vector2i(8, mid_y)
	_chest_pos = Vector2i(10, mid_y)
	if not _boss_defeated:
		objects[_idx(_boss_pos.x, _boss_pos.y)] = Obj.BOSS
	# Chest always exists, but stays locked until boss is defeated. Open state persists.
	if not bool(_opened_chests.get("main", false)):
		objects[_idx(_chest_pos.x, _chest_pos.y)] = Obj.MAIN_CHEST

func _spawn_house_npcs(is_shop: bool) -> void:
	if actors.size() != room_w * room_h:
		return
	var key_root: String = "house_npc|%s" % _poi_id
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
		var customers: int = DeterministicRng.randi_range(_world_seed_hash, key_root + "|cust_n", 0, 3)
		for i in range(customers):
			var r: float = DeterministicRng.randf01(_world_seed_hash, "%s|cust_kind|i=%d" % [key_root, i])
			var kind: int = Actor.MAN
			if r < 0.45:
				kind = Actor.MAN
			elif r < 0.90:
				kind = Actor.WOMAN
			else:
				kind = Actor.CHILD
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
	for i in range(kinds.size()):
		_place_npc(int(kinds[i]), "%s|occ|i=%d" % [key_root, i], "resident")

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
	_npcs.append({
		"kind": kind,
		"x": x,
		"y": y,
		"role": role,
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
	var moved: bool = false
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for i in range(_npcs.size()):
		var npc: Dictionary = _npcs[i]
		var kind: int = int(npc.get("kind", Actor.NONE))
		if kind == Actor.NONE or kind == Actor.SHOPKEEPER:
			continue
		# Not everyone moves every tick.
		if _npc_rng.randf() > 0.65:
			continue
		var x: int = int(npc.get("x", 0))
		var y: int = int(npc.get("y", 0))
		for _attempt in range(4):
			var d: Vector2i = dirs[_npc_rng.randi_range(0, dirs.size() - 1)]
			var nx: int = x + d.x
			var ny: int = y + d.y
			if not _can_npc_move_to(nx, ny):
				continue
			actors[_idx(x, y)] = Actor.NONE
			actors[_idx(nx, ny)] = kind
			npc["x"] = nx
			npc["y"] = ny
			_npcs[i] = npc
			moved = true
			break
	return moved

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
		_open_dialogue("Welcome! (Shop UI not implemented yet.)")
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

func _render_cell_bbcode(x: int, y: int) -> String:
	var t: int = _tile_at(x, y)
	if t == Tile.WALL:
		return "[color=#8D7B68]#[/color]"
	if t == Tile.DOOR:
		return "[color=#C8B28A]+[/color]"
	var o: int = _obj_at(x, y)
	match o:
		Obj.BOSS:
			return "[color=#D26A6A]B[/color]"
		Obj.MAIN_CHEST:
			return "[color=#D8C39E]C[/color]" if _boss_defeated else "[color=#8A7A6A]c[/color]"
		Obj.BED:
			return "[color=#B8AFA1]b[/color]"
		Obj.TABLE:
			return "[color=#B8AFA1]t[/color]"
		Obj.HEARTH:
			return "[color=#C95E3D]h[/color]"
		_:
			return "[color=#6B625A].[/color]"

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
	if bool(_opened_chests.get("main", false)):
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
	if _gpu_view != null and "cleanup" in _gpu_view:
		_gpu_view.cleanup()
	_gpu_view = null

func _on_gpu_map_resized() -> void:
	_update_player_marker()

func _update_player_marker() -> void:
	if _player_marker == null or gpu_map == null:
		return
	if not ("get_cell_size_screen" in gpu_map):
		return
	var cs: Vector2 = gpu_map.get_cell_size_screen()
	if cs.x <= 0.0 or cs.y <= 0.0:
		return
	_player_marker.size = cs
	_player_marker.position = Vector2(float(player_x) * cs.x, float(player_y) * cs.y)

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
	var gx: float = float(posmod(int(poi_data.get("world_x", 0)) * 96 + int(poi_data.get("local_x", 48)), int(total_w)))
	var gy: float = float(clamp(int(poi_data.get("world_y", 0)) * 96 + int(poi_data.get("local_y", 48)), 0, int(total_h) - 1))
	var lon: float = TAU * (gx / total_w)
	var lat_norm: float = 0.5 - (gy / max(1.0, total_h - 1.0))
	var phi: float = lat_norm * PI
	return Vector2(lon, phi)
