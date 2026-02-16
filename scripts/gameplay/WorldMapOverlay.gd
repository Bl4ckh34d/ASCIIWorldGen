extends CanvasLayer


signal closed

@onready var status_label: Label = %StatusLabel
@onready var gpu_map: Control = %GpuMap
@onready var footer_label: Label = %FooterLabel

var game_state: Node = null
var startup_state: Node = null
var game_events: Node = null
var scene_router: Node = null

var _cursor_x: int = 0
var _cursor_y: int = 0
var _gpu_view: Object = null
var _gpu_view_w: int = 0
var _gpu_view_h: int = 0
var _gpu_view_seed: int = 0
var _renderer_was_reinitialized: bool = false
var _cached_world_seed: int = 0
var _cached_w: int = 0
var _cached_h: int = 0
var _cached_fields: Dictionary = {}
var _snapshot_w: int = 0
var _snapshot_h: int = 0
var _snapshot_seed_hash: int = 1
var _snapshot_biomes: PackedInt32Array = PackedInt32Array()
var _snapshot_height_raw: PackedFloat32Array = PackedFloat32Array()
var _snapshot_temp: PackedFloat32Array = PackedFloat32Array()
var _snapshot_moist: PackedFloat32Array = PackedFloat32Array()
var _snapshot_land_mask: PackedByteArray = PackedByteArray()
var _snapshot_beach_mask: PackedByteArray = PackedByteArray()
var _snapshot_cloud_cover: PackedFloat32Array = PackedFloat32Array()
var _snapshot_wind_u: PackedFloat32Array = PackedFloat32Array()
var _snapshot_wind_v: PackedFloat32Array = PackedFloat32Array()

const MARKER_PLAYER: int = 220
const MARKER_UNKNOWN: int = 254

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	startup_state = get_node_or_null("/root/StartupState")
	game_events = get_node_or_null("/root/GameEvents")
	scene_router = get_node_or_null("/root/SceneRouter")
	visible = false
	set_process_unhandled_input(true)
	var on_map_input := Callable(self, "_on_gpu_map_gui_input")
	if gpu_map != null and not gpu_map.gui_input.is_connected(on_map_input):
		gpu_map.gui_input.connect(on_map_input)

func open_overlay() -> void:
	if game_state != null and game_state.has_method("ensure_world_snapshot_integrity"):
		game_state.ensure_world_snapshot_integrity()
	if not _resolve_world_snapshot():
		return
	var loc: Dictionary = {}
	if game_state != null and game_state.has_method("get_location"):
		loc = game_state.get_location()
	if loc.is_empty() and startup_state != null:
		loc = {
			"world_x": int(startup_state.selected_world_tile.x),
			"world_y": int(startup_state.selected_world_tile.y),
		}
	_cursor_x = int(loc.get("world_x", 0))
	_cursor_y = int(loc.get("world_y", 0))
	_cursor_x = posmod(_cursor_x, max(1, _snapshot_w))
	_cursor_y = clamp(_cursor_y, 0, max(1, _snapshot_h) - 1)
	visible = true
	_draw_world_map_gpu(true)
	_refresh()
	if game_events and game_events.has_signal("menu_opened"):
		game_events.emit_signal("menu_opened", "World Map")

func close_overlay() -> void:
	if not visible:
		return
	visible = false
	emit_signal("closed")
	if game_events and game_events.has_signal("menu_closed"):
		game_events.emit_signal("menu_closed", "World Map")

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var vp: Viewport = get_viewport()
	if event is InputEventKey and event.pressed:
		var key_event: InputEventKey = event
		# Close on M.
		if key_event.keycode == KEY_M and not key_event.echo:
			close_overlay()
			if vp:
				vp.set_input_as_handled()
			return
		# Cursor move.
		var dx: int = 0
		var dy: int = 0
		if key_event.keycode == KEY_LEFT or key_event.keycode == KEY_A:
			dx = -1
		elif key_event.keycode == KEY_RIGHT or key_event.keycode == KEY_D:
			dx = 1
		elif key_event.keycode == KEY_UP or key_event.keycode == KEY_W:
			dy = -1
		elif key_event.keycode == KEY_DOWN or key_event.keycode == KEY_S:
			dy = 1
		if dx != 0 or dy != 0:
			var step: int = 4
			if key_event.ctrl_pressed:
				step = 64
			elif key_event.shift_pressed:
				step = 16
			_move_cursor(dx * step, dy * step)
			if vp:
				vp.set_input_as_handled()
			return
		# Fast travel.
		if not key_event.echo and (key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER or key_event.keycode == KEY_SPACE):
			_try_fast_travel()
			if vp:
				vp.set_input_as_handled()
			return
	if event.is_action_pressed("ui_cancel"):
		# ui_cancel (Esc) just closes the map overlay.
		close_overlay()
		if vp:
			vp.set_input_as_handled()

func _on_gpu_map_gui_input(event: InputEvent) -> void:
	if not visible:
		return
	var vp: Viewport = get_viewport()
	var mouse_pos: Vector2 = vp.get_mouse_position() if vp != null else Vector2.ZERO
	if event is InputEventMouseMotion:
		if _set_cursor_from_screen_pos(mouse_pos):
			if vp:
				vp.set_input_as_handled()
			return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if _set_cursor_from_screen_pos(mouse_pos):
				_try_fast_travel()
				if vp:
					vp.set_input_as_handled()
				return

func _move_cursor(dx: int, dy: int) -> void:
	if _snapshot_w <= 0 or _snapshot_h <= 0:
		return
	var w: int = max(1, _snapshot_w)
	var h: int = max(1, _snapshot_h)
	_cursor_x = posmod(_cursor_x + dx, max(1, w))
	_cursor_y = clamp(_cursor_y + dy, 0, max(1, h) - 1)
	_refresh(true)

func _set_cursor_from_screen_pos(screen_pos: Vector2) -> bool:
	if gpu_map == null or _snapshot_w <= 0 or _snapshot_h <= 0:
		return false
	var rect: Rect2 = gpu_map.get_global_rect()
	if not rect.has_point(screen_pos):
		return false
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return false
	var local: Vector2 = screen_pos - rect.position
	var u: float = clamp(local.x / rect.size.x, 0.0, 0.999999)
	var v: float = clamp(local.y / rect.size.y, 0.0, 0.999999)
	var x: int = int(floor(u * float(_snapshot_w)))
	var y: int = int(floor(v * float(_snapshot_h)))
	x = clamp(x, 0, _snapshot_w - 1)
	y = clamp(y, 0, _snapshot_h - 1)
	if x == _cursor_x and y == _cursor_y:
		return true
	_cursor_x = x
	_cursor_y = y
	_refresh(true)
	return true

func _try_fast_travel() -> void:
	if scene_router == null:
		return
	if game_state != null and game_state.has_method("is_world_tile_visited") and not VariantCasts.to_bool(game_state.is_world_tile_visited(_cursor_x, _cursor_y)):
		_set_footer("Cannot fast travel: tile not visited.")
		return
	var biome_id: int = _get_snapshot_biome_id(_cursor_x, _cursor_y)
	if biome_id < 0 and game_state != null and game_state.has_method("get_world_biome_id"):
		biome_id = int(game_state.get_world_biome_id(_cursor_x, _cursor_y))
	if biome_id == 0 or biome_id == 1:
		_set_footer("Cannot fast travel to ocean/ice.")
		return
	var loc: Dictionary = {}
	if game_state != null and game_state.has_method("get_location"):
		loc = game_state.get_location()
	var cur_x: int = int(loc.get("world_x", 0))
	var cur_y: int = int(loc.get("world_y", 0))
	var w: int = max(1, _snapshot_w)
	var dx_wrap: int = abs(_cursor_x - cur_x)
	if w > 0:
		dx_wrap = min(dx_wrap, w - dx_wrap)
	var dy: int = abs(_cursor_y - cur_y)
	var dist: int = dx_wrap + dy
	var travel_minutes: int = max(5, dist * 60)
	if game_state != null and game_state.has_method("advance_world_time"):
		game_state.advance_world_time(travel_minutes, "fast_travel")
	close_overlay()
	if scene_router.has_method("goto_regional"):
		scene_router.goto_regional(_cursor_x, _cursor_y, 48, 48, biome_id, "")

func _refresh(cursor_only: bool = false) -> void:
	if game_state == null:
		return
	if status_label:
		var time_label: String = String(game_state.get_time_label()) if game_state.has_method("get_time_label") else ""
		var land_pct: int = int(round((1.0 - _ocean_fraction(_snapshot_biomes)) * 100.0))
		status_label.text = "Cursor: (%d,%d) | Time: %s | Land: %d%%" % [_cursor_x, _cursor_y, time_label, land_pct]
	if cursor_only:
		if gpu_map != null and gpu_map.has_method("set_hover_cell"):
			gpu_map.set_hover_cell(_cursor_x, _cursor_y)
		return
	_draw_world_map_gpu(false)

func _ensure_gpu_ready() -> bool:
	if gpu_map == null:
		return false
	_renderer_was_reinitialized = false
	var w: int = _snapshot_w
	var h: int = _snapshot_h
	if w <= 0 or h <= 0:
		return false
	if gpu_map.has_method("initialize_gpu_rendering"):
		# Do not gate on `is_ready()`: that check expects CPU-managed textures and can
		# report false in GPU-override paths, causing expensive re-init every refresh.
		var need_init: bool = false
		if gpu_map.has_method("is_using_gpu_rendering") and not VariantCasts.to_bool(gpu_map.is_using_gpu_rendering()):
			need_init = true
		if gpu_map.has_method("get_map_dimensions"):
			var dims: Vector2i = gpu_map.get_map_dimensions()
			if dims.x != w or dims.y != h:
				need_init = true
		else:
			need_init = true
		if need_init:
			var font: Font = null
			var font_size: int = 16
			if status_label != null:
				font = status_label.get_theme_default_font()
				var hs: int = status_label.get_theme_default_font_size()
				if hs > 0:
					font_size = hs
			gpu_map.initialize_gpu_rendering(font, font_size, w, h)
			_renderer_was_reinitialized = true
		if gpu_map.has_method("set_cloud_rendering_params"):
			# Keep cloud shadows visible on the in-game world map.
			gpu_map.set_cloud_rendering_params(0.28, 0.0, Vector2(1.9, 1.25))
		if gpu_map.has_method("set_water_rendering_params"):
			# World map view: keep solar reflection, disable animated wave wobble.
			gpu_map.set_water_rendering_params(0.0)
	# Create per-view GPU packing helper.
	if _gpu_view == null:
		_gpu_view = GpuMapView.new()
	if _gpu_view == null:
		return false
	if _gpu_view_w != w or _gpu_view_h != h or _gpu_view_seed != _snapshot_seed_hash:
		_gpu_view.configure("world_overlay", w, h, _snapshot_seed_hash)
		_gpu_view_w = w
		_gpu_view_h = h
		_gpu_view_seed = _snapshot_seed_hash
	return true

func _is_valid_snapshot(width: int, height: int, biomes: PackedInt32Array) -> bool:
	return width > 0 and height > 0 and biomes.size() == width * height

func _ocean_fraction(biomes: PackedInt32Array) -> float:
	if biomes.is_empty():
		return 1.0
	var ocean_count: int = 0
	for b in biomes:
		var bid: int = int(b)
		if bid == 0 or bid == 1:
			ocean_count += 1
	return float(ocean_count) / float(biomes.size())

func _snapshot_biome_at(width: int, height: int, biomes: PackedInt32Array, x: int, y: int) -> int:
	if not _is_valid_snapshot(width, height, biomes):
		return -1
	var wx: int = posmod(x, width)
	var wy: int = clamp(y, 0, height - 1)
	var idx: int = wx + wy * width
	if idx < 0 or idx >= biomes.size():
		return -1
	return int(biomes[idx])

func _prefer_startup_snapshot_for_location(
	game_w: int,
	game_h: int,
	game_biomes: PackedInt32Array,
	startup_w: int,
	startup_h: int,
	startup_biomes: PackedInt32Array
) -> bool:
	var loc: Dictionary = {}
	if game_state != null and game_state.has_method("get_location"):
		loc = game_state.get_location()
	var wx: int = int(loc.get("world_x", -1))
	var wy: int = int(loc.get("world_y", -1))
	var expected_bid: int = int(loc.get("biome_id", -1))
	if wx >= 0 and wy >= 0 and expected_bid > 1:
		var game_here: int = _snapshot_biome_at(game_w, game_h, game_biomes, wx, wy)
		var startup_here: int = _snapshot_biome_at(startup_w, startup_h, startup_biomes, wx, wy)
		if game_here <= 1 and startup_here > 1:
			return true
		if game_here > 1 and startup_here <= 1:
			return false
	return false

func _resolve_world_snapshot() -> bool:
	var game_w: int = 0
	var game_h: int = 0
	var game_seed: int = 1
	var game_biomes: PackedInt32Array = PackedInt32Array()
	if game_state != null and game_state.has_method("has_world_snapshot") and VariantCasts.to_bool(game_state.has_world_snapshot()):
		game_w = int(game_state.world_width)
		game_h = int(game_state.world_height)
		game_seed = int(game_state.world_seed_hash)
		game_biomes = game_state.world_biome_ids

	var startup_w: int = 0
	var startup_h: int = 0
	var startup_seed: int = 1
	var startup_biomes: PackedInt32Array = PackedInt32Array()
	if startup_state != null and startup_state.has_method("has_world_snapshot") and VariantCasts.to_bool(startup_state.has_world_snapshot()):
		startup_w = int(startup_state.world_width)
		startup_h = int(startup_state.world_height)
		startup_seed = int(startup_state.world_seed_hash)
		startup_biomes = startup_state.world_biome_ids

	var game_ok: bool = _is_valid_snapshot(game_w, game_h, game_biomes)
	var startup_ok: bool = _is_valid_snapshot(startup_w, startup_h, startup_biomes)
	if not game_ok and not startup_ok:
		return false

	var use_startup: bool = false
	if not game_ok and startup_ok:
		use_startup = true
	elif game_ok and startup_ok:
		use_startup = _prefer_startup_snapshot_for_location(
			game_w,
			game_h,
			game_biomes,
			startup_w,
			startup_h,
			startup_biomes
		)
		if not use_startup:
			# Guard against stale all-ocean snapshots in GameState.
			var game_ocean_frac: float = _ocean_fraction(game_biomes)
			var startup_ocean_frac: float = _ocean_fraction(startup_biomes)
			if game_ocean_frac >= 0.995 and startup_ocean_frac < game_ocean_frac:
				use_startup = true

	if use_startup:
		_snapshot_w = startup_w
		_snapshot_h = startup_h
		_snapshot_seed_hash = startup_seed
		_snapshot_biomes = startup_biomes.duplicate()
		_snapshot_height_raw = _state_f32_snapshot(startup_state, "world_height_raw", startup_w * startup_h)
		_snapshot_temp = _state_f32_snapshot(startup_state, "world_temperature", startup_w * startup_h)
		_snapshot_moist = _state_f32_snapshot(startup_state, "world_moisture", startup_w * startup_h)
		_snapshot_land_mask = _state_u8_snapshot(startup_state, "world_land_mask", startup_w * startup_h)
		_snapshot_beach_mask = _state_u8_snapshot(startup_state, "world_beach_mask", startup_w * startup_h)
		_snapshot_cloud_cover = _state_f32_snapshot(startup_state, "world_cloud_cover", startup_w * startup_h)
		_snapshot_wind_u = _state_f32_snapshot(startup_state, "world_wind_u", startup_w * startup_h)
		_snapshot_wind_v = _state_f32_snapshot(startup_state, "world_wind_v", startup_w * startup_h)
	else:
		_snapshot_w = game_w
		_snapshot_h = game_h
		_snapshot_seed_hash = game_seed
		_snapshot_biomes = game_biomes.duplicate()
		_snapshot_height_raw = _state_f32_snapshot(game_state, "world_height_raw", game_w * game_h)
		_snapshot_temp = _state_f32_snapshot(game_state, "world_temperature", game_w * game_h)
		_snapshot_moist = _state_f32_snapshot(game_state, "world_moisture", game_w * game_h)
		_snapshot_land_mask = _state_u8_snapshot(game_state, "world_land_mask", game_w * game_h)
		_snapshot_beach_mask = _state_u8_snapshot(game_state, "world_beach_mask", game_w * game_h)
		_snapshot_cloud_cover = _state_f32_snapshot(game_state, "world_cloud_cover", game_w * game_h)
		_snapshot_wind_u = _state_f32_snapshot(game_state, "world_wind_u", game_w * game_h)
		_snapshot_wind_v = _state_f32_snapshot(game_state, "world_wind_v", game_w * game_h)
	var snapshot_cell_count: int = _snapshot_w * _snapshot_h
	var peer_state: Node = game_state if use_startup else startup_state
	if _snapshot_height_raw.size() != snapshot_cell_count:
		_snapshot_height_raw = _state_f32_snapshot(peer_state, "world_height_raw", snapshot_cell_count)
	if _snapshot_temp.size() != snapshot_cell_count:
		_snapshot_temp = _state_f32_snapshot(peer_state, "world_temperature", snapshot_cell_count)
	if _snapshot_moist.size() != snapshot_cell_count:
		_snapshot_moist = _state_f32_snapshot(peer_state, "world_moisture", snapshot_cell_count)
	if _snapshot_land_mask.size() != snapshot_cell_count:
		_snapshot_land_mask = _state_u8_snapshot(peer_state, "world_land_mask", snapshot_cell_count)
	if _snapshot_beach_mask.size() != snapshot_cell_count:
		_snapshot_beach_mask = _state_u8_snapshot(peer_state, "world_beach_mask", snapshot_cell_count)
	if _snapshot_cloud_cover.size() != snapshot_cell_count:
		_snapshot_cloud_cover = _state_f32_snapshot(peer_state, "world_cloud_cover", snapshot_cell_count)
	if _snapshot_wind_u.size() != snapshot_cell_count:
		_snapshot_wind_u = _state_f32_snapshot(peer_state, "world_wind_u", snapshot_cell_count)
	if _snapshot_wind_v.size() != snapshot_cell_count:
		_snapshot_wind_v = _state_f32_snapshot(peer_state, "world_wind_v", snapshot_cell_count)
	if _snapshot_seed_hash == 0:
		_snapshot_seed_hash = 1
	return true

func _state_f32_snapshot(state: Node, prop_name: String, expected_size: int) -> PackedFloat32Array:
	if state == null or expected_size <= 0:
		return PackedFloat32Array()
	var v: Variant = state.get(prop_name)
	if v is PackedFloat32Array:
		var arr: PackedFloat32Array = v
		if arr.size() == expected_size:
			return arr.duplicate()
	return PackedFloat32Array()

func _state_u8_snapshot(state: Node, prop_name: String, expected_size: int) -> PackedByteArray:
	if state == null or expected_size <= 0:
		return PackedByteArray()
	var v: Variant = state.get(prop_name)
	if v is PackedByteArray:
		var arr: PackedByteArray = v
		if arr.size() == expected_size:
			return arr.duplicate()
	return PackedByteArray()

func _get_snapshot_biome_id(x: int, y: int) -> int:
	if not _is_valid_snapshot(_snapshot_w, _snapshot_h, _snapshot_biomes):
		return -1
	var wx: int = posmod(x, _snapshot_w)
	var wy: int = clamp(y, 0, _snapshot_h - 1)
	var i: int = wx + wy * _snapshot_w
	if i < 0 or i >= _snapshot_biomes.size():
		return -1
	return int(_snapshot_biomes[i])

func _build_world_overlay_fields() -> Dictionary:
	var w: int = _snapshot_w
	var h: int = _snapshot_h
	var field_cell_count: int = w * h
	var biomes: PackedInt32Array = _snapshot_biomes
	if not _is_valid_snapshot(w, h, biomes):
		return {}

	var loc: Dictionary = game_state.get_location() if game_state != null and game_state.has_method("get_location") else {}
	var px: int = int(loc.get("world_x", 0))
	var py: int = int(loc.get("world_y", 0))

	var height_raw := PackedFloat32Array()
	var temp := PackedFloat32Array()
	var moist := PackedFloat32Array()
	var biome := PackedInt32Array()
	var land := PackedInt32Array()
	var beach := PackedInt32Array()
	height_raw.resize(field_cell_count)
	temp.resize(field_cell_count)
	moist.resize(field_cell_count)
	biome.resize(field_cell_count)
	land.resize(field_cell_count)
	beach.resize(field_cell_count)

	var have_height: bool = _snapshot_height_raw.size() == field_cell_count
	var have_temp: bool = _snapshot_temp.size() == field_cell_count
	var have_moist: bool = _snapshot_moist.size() == field_cell_count
	var have_land: bool = _snapshot_land_mask.size() == field_cell_count
	var have_beach: bool = _snapshot_beach_mask.size() == field_cell_count

	for y in range(h):
		var lat_signed: float = 0.0
		if h > 1:
			lat_signed = 0.5 - (float(y) / float(h - 1)) # +0.5 north .. -0.5 south
		var lat_abs: float = abs(lat_signed) * 2.0 # 0 equator .. 1 poles
		for x in range(w):
			var idx: int = x + y * w
			var bid: int = int(biomes[idx])
			var is_ocean_or_ice: bool = (bid == 0 or bid == 1)
			var is_land_tile: bool = (int(_snapshot_land_mask[idx]) != 0) if have_land else (not is_ocean_or_ice)
			var out_biome: int = bid
			if x == px and y == py:
				out_biome = MARKER_PLAYER
				is_land_tile = true

			# Use authoritative world fields when available.
			var h_raw: float = _snapshot_height_raw[idx] if have_height else (-0.65 if not is_land_tile else 0.20)
			height_raw[idx] = h_raw
			land[idx] = 1 if is_land_tile else 0
			beach[idx] = 1 if (have_beach and int(_snapshot_beach_mask[idx]) != 0) else 0
			biome[idx] = out_biome

			# Temperature/moisture mirror world map fields when available.
			if have_temp:
				temp[idx] = clamp(_snapshot_temp[idx], 0.0, 1.0)
			else:
				temp[idx] = clamp(1.0 - lat_abs, 0.0, 1.0)
			if have_moist:
				moist[idx] = clamp(_snapshot_moist[idx], 0.0, 1.0)
			else:
				moist[idx] = 0.5

	return {
		"height_raw": height_raw,
		"temp": temp,
		"moist": moist,
		"biome": biome,
		"land": land,
		"beach": beach,
	}

func _draw_world_map_gpu(force_rebuild: bool) -> void:
	if game_state == null or gpu_map == null:
		return
	if not _ensure_gpu_ready():
		return
	var w: int = _snapshot_w
	var h: int = _snapshot_h
	var seed_hash: int = _snapshot_seed_hash
	if seed_hash == 0:
		seed_hash = 1
	var need_rebuild: bool = force_rebuild
	need_rebuild = need_rebuild or _renderer_was_reinitialized or (_cached_world_seed != seed_hash) or (_cached_w != w) or (_cached_h != h) or _cached_fields.is_empty()
	if need_rebuild:
		_cached_fields = _build_world_overlay_fields()
		_cached_world_seed = seed_hash
		_cached_w = w
		_cached_h = h
	else:
		# Cursor moves should not rebuild or re-upload any base textures.
		if gpu_map.has_method("set_hover_cell"):
			gpu_map.set_hover_cell(_cursor_x, _cursor_y)
		return
	if _cached_fields.is_empty():
		return

	# Solar parameters from in-game time (fractional).
	var day_of_year: float = 0.0
	var time_of_day: float = 0.0
	var sim_days: float = 0.0
	if game_state.get("world_time") != null:
		var wt = game_state.world_time
		var abs_day: int = wt.abs_day_index()
		day_of_year = float(posmod(abs_day, 365)) / 365.0
		time_of_day = float(wt.second_of_day) / float(WorldTimeStateModel.SECONDS_PER_DAY)
		sim_days = float(abs_day) + time_of_day

	var solar := {
		"day_of_year": day_of_year,
		"time_of_day": time_of_day,
		"sim_days": sim_days,
		"base": 0.02,
		"contrast": 0.98,
		"relief_strength": 0.10,
	}
	var clouds := {
		"enabled": true,
		"origin_x": 0,
		"origin_y": 0,
		"world_period_x": w,
		"world_height": h,
		"seed_xor": 0x1337,
		"scale": 0.045,
		"wind_x": 0.12,
		"wind_y": 0.05,
		"coverage": 0.55,
		"contrast": 1.35,
	}
	var cell_count: int = w * h
	if _snapshot_cloud_cover.size() == cell_count:
		# Use the same cloud field as the world-map snapshot for visual continuity.
		clouds["field"] = _snapshot_cloud_cover
	if _snapshot_wind_u.size() == cell_count and _snapshot_wind_v.size() == cell_count and cell_count > 0:
		var wind_u_sum: float = 0.0
		var wind_v_sum: float = 0.0
		for i in range(cell_count):
			wind_u_sum += _snapshot_wind_u[i]
			wind_v_sum += _snapshot_wind_v[i]
		var inv_count: float = 1.0 / float(cell_count)
		clouds["wind_x"] = wind_u_sum * inv_count
		clouds["wind_y"] = wind_v_sum * inv_count

	if _gpu_view != null and _gpu_view.has_method("update_and_draw"):
		_gpu_view.update_and_draw(gpu_map, _cached_fields, solar, clouds, 0.0, 0.0, 0.0)
	# World map uses spherical lon/lat (no fixed override).
	if gpu_map.has_method("set_fixed_lonlat"):
		gpu_map.set_fixed_lonlat(false, 0.0, 0.0)
	# Cursor highlight.
	if gpu_map.has_method("set_hover_cell"):
		gpu_map.set_hover_cell(_cursor_x, _cursor_y)

func _set_footer(text_value: String) -> void:
	if footer_label:
		footer_label.text = text_value

func _exit_tree() -> void:
	if _gpu_view != null and _gpu_view.has_method("cleanup"):
		_gpu_view.cleanup()
	_gpu_view = null
	_gpu_view_w = 0
	_gpu_view_h = 0
	_gpu_view_seed = 0
