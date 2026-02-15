extends CanvasLayer
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const GpuMapView = preload("res://scripts/gameplay/rendering/GpuMapView.gd")
const WorldTimeStateModel = preload("res://scripts/gameplay/models/WorldTimeState.gd")

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
var _cached_world_seed: int = 0
var _cached_w: int = 0
var _cached_h: int = 0
var _cached_fields: Dictionary = {}
var _snapshot_w: int = 0
var _snapshot_h: int = 0
var _snapshot_seed_hash: int = 1
var _snapshot_biomes: PackedInt32Array = PackedInt32Array()

const MARKER_PLAYER: int = 220
const MARKER_UNKNOWN: int = 254

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	startup_state = get_node_or_null("/root/StartupState")
	game_events = get_node_or_null("/root/GameEvents")
	scene_router = get_node_or_null("/root/SceneRouter")
	visible = false
	set_process_unhandled_input(true)

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
	if event is InputEventKey and event.pressed and not event.echo:
		# Close on M.
		if event.keycode == KEY_M:
			close_overlay()
			if vp:
				vp.set_input_as_handled()
			return
		# Cursor move.
		var dx: int = 0
		var dy: int = 0
		if event.keycode == KEY_LEFT or event.keycode == KEY_A:
			dx = -1
		elif event.keycode == KEY_RIGHT or event.keycode == KEY_D:
			dx = 1
		elif event.keycode == KEY_UP or event.keycode == KEY_W:
			dy = -1
		elif event.keycode == KEY_DOWN or event.keycode == KEY_S:
			dy = 1
		if dx != 0 or dy != 0:
			_move_cursor(dx, dy)
			if vp:
				vp.set_input_as_handled()
			return
		# Fast travel.
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_SPACE:
			_try_fast_travel()
			if vp:
				vp.set_input_as_handled()
			return
	if event.is_action_pressed("ui_cancel"):
		# ui_cancel (Esc) just closes the map overlay.
		close_overlay()
		if vp:
			vp.set_input_as_handled()

func _move_cursor(dx: int, dy: int) -> void:
	if _snapshot_w <= 0 or _snapshot_h <= 0:
		return
	var w: int = max(1, _snapshot_w)
	var h: int = max(1, _snapshot_h)
	_cursor_x = posmod(_cursor_x + dx, max(1, w))
	_cursor_y = clamp(_cursor_y + dy, 0, max(1, h) - 1)
	_refresh()

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

func _refresh() -> void:
	if game_state == null:
		return
	if status_label:
		var time_label: String = String(game_state.get_time_label()) if game_state.has_method("get_time_label") else ""
		status_label.text = "Cursor: (%d,%d) | Time: %s" % [_cursor_x, _cursor_y, time_label]
	_draw_world_map_gpu(false)

func _ensure_gpu_ready() -> bool:
	if gpu_map == null:
		return false
	var w: int = _snapshot_w
	var h: int = _snapshot_h
	if w <= 0 or h <= 0:
		return false
	if "initialize_gpu_rendering" in gpu_map:
		var font: Font = null
		var font_size: int = 16
		if status_label != null:
			font = status_label.get_theme_default_font()
			var hs: int = status_label.get_theme_default_font_size()
			if hs > 0:
				font_size = hs
		gpu_map.initialize_gpu_rendering(font, font_size, w, h)
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
	else:
		_snapshot_w = game_w
		_snapshot_h = game_h
		_snapshot_seed_hash = game_seed
		_snapshot_biomes = game_biomes.duplicate()
	if _snapshot_seed_hash == 0:
		_snapshot_seed_hash = 1
	return true

func _get_snapshot_biome_id(x: int, y: int) -> int:
	if not _is_valid_snapshot(_snapshot_w, _snapshot_h, _snapshot_biomes):
		return -1
	var wx: int = posmod(x, _snapshot_w)
	var wy: int = clamp(y, 0, _snapshot_h - 1)
	var i: int = wx + wy * _snapshot_w
	if i < 0 or i >= _snapshot_biomes.size():
		return -1
	return int(_snapshot_biomes[i])

static func _hash01(seed: int, x: int, y: int) -> float:
	# Cheap deterministic hash -> [0..1].
	var v: int = int(seed)
	v = int(v ^ (x * 374761393))
	v = int(v ^ (y * 668265263))
	v = int((v ^ (v >> 13)) * 1274126177)
	v = int(v ^ (v >> 16))
	var u: int = v & 0xFFFF
	return float(u) / 65535.0

func _build_world_overlay_fields() -> Dictionary:
	var w: int = _snapshot_w
	var h: int = _snapshot_h
	var size: int = w * h
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
	height_raw.resize(size)
	temp.resize(size)
	moist.resize(size)
	biome.resize(size)
	land.resize(size)
	beach.resize(size)

	var seed_hash: int = _snapshot_seed_hash
	if seed_hash == 0:
		seed_hash = 1

	for y in range(h):
		var lat_signed: float = 0.0
		if h > 1:
			lat_signed = 0.5 - (float(y) / float(h - 1)) # +0.5 north .. -0.5 south
		var lat_abs: float = abs(lat_signed) * 2.0 # 0 equator .. 1 poles
		for x in range(w):
			var idx: int = x + y * w
			var bid: int = int(biomes[idx])
			var is_ocean_or_ice: bool = (bid == 0 or bid == 1)
			var n: float = _hash01(seed_hash, x, y)
			var is_land_tile: bool = not is_ocean_or_ice
			var out_biome: int = bid
			if x == px and y == py:
				out_biome = MARKER_PLAYER
				is_land_tile = true

			# Fake macro fields (GPU-only render still; these are just inputs).
			var h_raw: float = (-0.70 + n * 0.10) if not is_land_tile else (0.12 + n * 0.50)
			height_raw[idx] = h_raw
			land[idx] = 1 if is_land_tile else 0
			beach[idx] = 0
			biome[idx] = out_biome

			# Temperature as lat gradient + small noise.
			var t0: float = clamp(1.0 - lat_abs, 0.0, 1.0)
			temp[idx] = clamp(t0 * 0.85 + n * 0.15, 0.0, 1.0)
			# Moisture: low-frequency-ish noise.
			var m0: float = _hash01(seed_hash ^ 0x51D3, x / 2, y / 2)
			moist[idx] = clamp(m0, 0.0, 1.0)

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
	need_rebuild = need_rebuild or (_cached_world_seed != seed_hash) or (_cached_w != w) or (_cached_h != h) or _cached_fields.is_empty()
	if need_rebuild:
		_cached_fields = _build_world_overlay_fields()
		_cached_world_seed = seed_hash
		_cached_w = w
		_cached_h = h
	else:
		# Cursor moves should not rebuild or re-upload any base textures.
		if "set_hover_cell" in gpu_map:
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
		"sim_days": sim_days,
		"scale": 0.045,
		"wind_x": 0.12,
		"wind_y": 0.05,
		"coverage": 0.55,
		"contrast": 1.35,
	}

	if _gpu_view != null and "update_and_draw" in _gpu_view:
		_gpu_view.update_and_draw(gpu_map, _cached_fields, solar, clouds, 0.0, 0.0, 0.0)
	# World map uses spherical lon/lat (no fixed override).
	if "set_fixed_lonlat" in gpu_map:
		gpu_map.set_fixed_lonlat(false, 0.0, 0.0)
	# Cursor highlight.
	if "set_hover_cell" in gpu_map:
		gpu_map.set_hover_cell(_cursor_x, _cursor_y)

func _set_footer(text_value: String) -> void:
	if footer_label:
		footer_label.text = text_value

func _exit_tree() -> void:
	if _gpu_view != null and "cleanup" in _gpu_view:
		_gpu_view.cleanup()
	_gpu_view = null
	_gpu_view_w = 0
	_gpu_view_h = 0
	_gpu_view_seed = 0
