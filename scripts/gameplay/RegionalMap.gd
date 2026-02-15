extends Control
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const PoiRegistry = preload("res://scripts/gameplay/PoiRegistry.gd")
const EncounterRegistry = preload("res://scripts/gameplay/EncounterRegistry.gd")
const RegionalChunkGenerator = preload("res://scripts/gameplay/RegionalChunkGenerator.gd")
const RegionalChunkCache = preload("res://scripts/gameplay/RegionalChunkCache.gd")
const WorldTimeStateModel = preload("res://scripts/gameplay/models/WorldTimeState.gd")
const GpuMapView = preload("res://scripts/gameplay/rendering/GpuMapView.gd")

const TAU: float = 6.28318530718
const PI: float = 3.14159265359

const REGION_SIZE: int = 96
const VIEW_W: int = 64
const VIEW_H: int = 30
const VIEW_PAD: int = 2
const RENDER_W: int = VIEW_W + VIEW_PAD * 2
const RENDER_H: int = VIEW_H + VIEW_PAD * 2

const MOVE_SPEED_CELLS_PER_SEC: float = 5.0
const MOVE_EPS: float = 0.0001

@onready var header_label: Label = %HeaderLabel
@onready var gpu_map: Control = %GpuMap
@onready var footer_label: Label = %FooterLabel

var game_state: Node = null
var startup_state: Node = null
var scene_router: Node = null
var menu_overlay: CanvasLayer = null
var world_map_overlay: CanvasLayer = null

var world_tile_x: int = 0
var world_tile_y: int = 0
var local_x: int = 48
var local_y: int = 48
var world_width: int = 275
var world_height: int = 62
var world_seed_hash: int = 0
var world_biome_ids: PackedInt32Array = PackedInt32Array()
var _location_biome_override_id: int = -1

var _chunk_gen: RegionalChunkGenerator = null
var _chunk_cache: RegionalChunkCache = null
var _gpu_view: Object = null
var _player_marker: ColorRect = null
var _marker_initialized: bool = false

var _player_gx: float = 0.0
var _player_gy: float = 0.0
var _center_gx: int = 0
var _center_gy: int = 0

const _HEADER_REFRESH_INTERVAL: float = 0.25
const _DYNAMIC_REFRESH_INTERVAL: float = 0.50
const _TRANSITION_PROGRESS_QUANTIZATION_STEPS: int = 200
const _CHUNK_PREFETCH_MARGIN_CHUNKS: int = 1
# Partial edge-only GPU uploads are currently incorrect for the scrolled regional view:
# they do not shift interior texture rows/cols, which can visually pin shading around
# the centered player. Keep CPU incremental sampling, but push full GPU uploads.
const _ENABLE_GPU_PARTIAL_UPLOAD: bool = false
var _header_refresh_accum: float = 0.0
var _dynamic_refresh_accum: float = 0.0
var _transition_signature: String = ""
var _field_cache_valid: bool = false
var _field_origin_x: int = 0
var _field_origin_y: int = 0
var _field_height_raw: PackedFloat32Array = PackedFloat32Array()
var _field_temp: PackedFloat32Array = PackedFloat32Array()
var _field_moist: PackedFloat32Array = PackedFloat32Array()
var _field_biome: PackedInt32Array = PackedInt32Array()
var _field_land: PackedInt32Array = PackedInt32Array()
var _field_beach: PackedInt32Array = PackedInt32Array()
var _field_height_raw_scratch: PackedFloat32Array = PackedFloat32Array()
var _field_temp_scratch: PackedFloat32Array = PackedFloat32Array()
var _field_moist_scratch: PackedFloat32Array = PackedFloat32Array()
var _field_biome_scratch: PackedInt32Array = PackedInt32Array()
var _field_land_scratch: PackedInt32Array = PackedInt32Array()
var _field_beach_scratch: PackedInt32Array = PackedInt32Array()
var _last_redraw_mode: String = ""
var _last_redraw_us: int = 0
var _last_redraw_fresh_cells: int = 0
var _last_redraw_reused_cells: int = 0
var _last_redraw_dx: int = 0
var _last_redraw_dy: int = 0
var _last_gpu_upload_mode: String = ""
var _last_gpu_upload_us: int = 0
const _REDRAW_SAMPLE_WINDOW: int = 240
var _redraw_samples_ms: Array[float] = []

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	startup_state = get_node_or_null("/root/StartupState")
	scene_router = get_node_or_null("/root/SceneRouter")
	_load_location_from_state()
	_init_regional_generation()
	_ensure_valid_spawn()
	_install_menu_overlay()
	_install_world_map_overlay()
	_init_gpu_rendering()
	set_process_unhandled_input(true)
	set_process(true)
	_render_view()
	_apply_scroll_offset()
	call_deferred("_update_player_marker")

func _init_regional_generation() -> void:
	if world_biome_ids.is_empty():
		# Best-effort fallback: try to pull from GameState even if location came from StartupState.
		if game_state != null:
			world_biome_ids = game_state.world_biome_ids
	if world_biome_ids.is_empty():
		# Without a snapshot we can still render, but biome blending will degrade.
		world_biome_ids = PackedInt32Array()
	_chunk_gen = RegionalChunkGenerator.new()
	_chunk_gen.configure(world_seed_hash, world_width, world_height, world_biome_ids, REGION_SIZE)
	if _location_biome_override_id >= 0 and "set_biome_overrides" in _chunk_gen:
		_chunk_gen.set_biome_overrides({
			Vector2i(world_tile_x, world_tile_y): int(_location_biome_override_id),
		})
	_chunk_cache = RegionalChunkCache.new()
	_chunk_cache.configure(_chunk_gen, 32, 256)
	_refresh_regional_transition_overrides(true)

func _ensure_valid_spawn() -> void:
	# If the saved spawn lands on blocked terrain (deep water/cliff), nudge to the nearest open cell.
	if _chunk_cache == null:
		return
	var gx0: int = _wrap_global_x(int(floor(_player_gx)))
	var gy0: int = _clamp_global_y(int(floor(_player_gy)))
	if _chunk_cache.has_method("prefetch_for_view"):
		_chunk_cache.prefetch_for_view(gx0, gy0, 1, 1, 1)
	if not _is_blocked_cell(gx0, gy0):
		return
	var found: bool = false
	var best: Vector2i = Vector2i(gx0, gy0)
	for r in range(1, 17):
		# Scan the square ring.
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var gx: int = _wrap_global_x(gx0 + dx)
				var gy: int = _clamp_global_y(gy0 + dy)
				if not _is_blocked_cell(gx, gy):
					best = Vector2i(gx, gy)
					found = true
					break
			if found:
				break
		if found:
			break
	if not found:
		return
	_player_gx = float(best.x) + 0.5
	_player_gy = float(best.y) + 0.5
	_wrap_player_pos()
	_sync_location_from_player_pos()
	_save_position_to_state()
	if footer_label:
		footer_label.text = "Spawn adjusted to nearest passable terrain."

func _refresh_regional_transition_overrides(force: bool = false) -> bool:
	if _chunk_gen == null:
		return false
	var raw: Dictionary = {}
	if game_state != null and game_state.has_method("get_regional_biome_transition_overrides"):
		raw = game_state.get_regional_biome_transition_overrides(world_tile_x, world_tile_y, 1)
	var parsed: Dictionary = {}
	for kv in raw.keys():
		var key: String = String(kv)
		var parts: PackedStringArray = key.split(",", false)
		if parts.size() != 2:
			continue
		var wx: int = int(parts[0])
		var wy: int = int(parts[1])
		var vv: Variant = raw.get(kv, {})
		if typeof(vv) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = vv as Dictionary
		parsed[Vector2i(wx, wy)] = {
			"from_biome": int(d.get("from_biome", -1)),
			"to_biome": int(d.get("to_biome", -1)),
			"progress": clamp(float(d.get("progress", 1.0)), 0.0, 1.0),
		}
	var sig_parts: Array[String] = []
	for pk in parsed.keys():
		var pxy: Vector2i = pk
		var d2: Dictionary = parsed[pk]
		sig_parts.append("%d,%d:%d>%d@%03d" % [
			pxy.x,
			pxy.y,
			int(d2.get("from_biome", -1)),
			int(d2.get("to_biome", -1)),
			int(round(clamp(float(d2.get("progress", 1.0)), 0.0, 1.0) * float(_TRANSITION_PROGRESS_QUANTIZATION_STEPS))),
		])
	sig_parts.sort()
	var sig: String = "|".join(sig_parts)
	if not force and sig == _transition_signature:
		return false
	_transition_signature = sig
	if "set_biome_transition_overrides" in _chunk_gen:
		_chunk_gen.set_biome_transition_overrides(parsed)
	if _chunk_cache != null and _chunk_cache.has_method("invalidate_all"):
		_chunk_cache.invalidate_all()
	_field_cache_valid = false
	return true

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
		gpu_map.initialize_gpu_rendering(font, font_size, RENDER_W, RENDER_H)
		if "set_display_window" in gpu_map:
			gpu_map.set_display_window(VIEW_W, VIEW_H, float(VIEW_PAD), float(VIEW_PAD))
	# Initialize per-view GPU field packer.
	if _gpu_view == null:
		_gpu_view = GpuMapView.new()
		_gpu_view.configure("regional_view", RENDER_W, RENDER_H, world_seed_hash)
	if gpu_map != null and gpu_map is Control:
		if not (gpu_map as Control).resized.is_connected(_on_gpu_map_resized):
			(gpu_map as Control).resized.connect(_on_gpu_map_resized)
	_ensure_player_marker()
	_update_player_marker()

func _ensure_player_marker() -> void:
	if _player_marker != null or gpu_map == null:
		return
	_player_marker = ColorRect.new()
	_player_marker.color = Color(0.98, 0.90, 0.30, 0.50)
	_player_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_marker.z_index = 200
	_player_marker.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	gpu_map.add_child(_player_marker)

func _load_location_from_state() -> void:
	if game_state != null and game_state.has_method("ensure_world_snapshot_integrity"):
		game_state.ensure_world_snapshot_integrity()
	var game_has_snapshot: bool = false
	if game_state != null and game_state.has_method("has_world_snapshot"):
		game_has_snapshot = VariantCasts.to_bool(game_state.has_world_snapshot())
	if game_state != null and game_state.has_method("get_location"):
		var loc: Dictionary = game_state.get_location()
		world_tile_x = int(loc.get("world_x", world_tile_x))
		world_tile_y = int(loc.get("world_y", world_tile_y))
		local_x = int(loc.get("local_x", local_x))
		local_y = int(loc.get("local_y", local_y))
		_location_biome_override_id = int(loc.get("biome_id", -1))
		world_width = max(1, int(game_state.world_width)) if game_has_snapshot else world_width
		world_height = max(1, int(game_state.world_height)) if game_has_snapshot else world_height
		world_seed_hash = int(game_state.world_seed_hash)
		if game_has_snapshot:
			world_biome_ids = game_state.world_biome_ids
	if not game_has_snapshot and startup_state != null:
		world_tile_x = int(startup_state.selected_world_tile.x)
		world_tile_y = int(startup_state.selected_world_tile.y)
		local_x = int(startup_state.regional_local_pos.x)
		local_y = int(startup_state.regional_local_pos.y)
		_location_biome_override_id = int(startup_state.selected_world_tile_biome_id)
		world_width = max(1, int(startup_state.world_width)) if int(startup_state.world_width) > 0 else world_width
		world_height = max(1, int(startup_state.world_height)) if int(startup_state.world_height) > 0 else world_height
		world_seed_hash = int(startup_state.world_seed_hash)
		world_biome_ids = startup_state.world_biome_ids
	if world_seed_hash == 0:
		world_seed_hash = 1
	world_tile_x = posmod(world_tile_x, world_width)
	world_tile_y = clamp(world_tile_y, 0, world_height - 1)
	local_x = clamp(local_x, 0, REGION_SIZE - 1)
	local_y = clamp(local_y, 0, REGION_SIZE - 1)
	var gx0: int = world_tile_x * REGION_SIZE + local_x
	var gy0: int = world_tile_y * REGION_SIZE + local_y
	_player_gx = float(_wrap_global_x(gx0))
	_player_gy = float(_clamp_global_y(gy0))
	_center_gx = int(floor(_player_gx))
	_center_gy = int(floor(_player_gy))
	_save_position_to_state()

func _unhandled_input(event: InputEvent) -> void:
	var vp: Viewport = get_viewport()
	# When an overlay is visible, let it consume input first.
	if world_map_overlay != null and world_map_overlay.visible:
		return
	if menu_overlay != null and menu_overlay.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F5:
			_try_quick_save()
			if vp:
				vp.set_input_as_handled()
			return
		if event.keycode == KEY_F9:
			_try_quick_load()
			if vp:
				vp.set_input_as_handled()
			return
		if event.keycode == KEY_M:
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
		if event.keycode == KEY_E:
			_try_enter_poi()
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
		menu_overlay.open_overlay("Regional Map")

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
	# Ensure the player marker is visible even if layout happens after _ready().
	if not _marker_initialized:
		_update_player_marker()
	# Pause movement while overlays are open.
	if world_map_overlay != null and world_map_overlay.visible:
		_apply_scroll_offset()
		_update_fixed_lonlat_uniform()
		return
	if menu_overlay != null and menu_overlay.visible:
		_apply_scroll_offset()
		_update_fixed_lonlat_uniform()
		return
	var dir: Vector2i = _read_move_dir()
	if dir != Vector2i.ZERO:
		_move_continuous(dir, delta)
	_apply_scroll_offset()
	_update_fixed_lonlat_uniform()
	_tick_time_visuals(delta)

func _tick_time_visuals(delta: float) -> void:
	if delta <= 0.0:
		return
	_header_refresh_accum += delta
	_dynamic_refresh_accum += delta
	if _header_refresh_accum >= _HEADER_REFRESH_INTERVAL:
		_header_refresh_accum = 0.0
		_update_header_text()
	if _dynamic_refresh_accum >= _DYNAMIC_REFRESH_INTERVAL:
		_dynamic_refresh_accum = 0.0
		if _refresh_regional_transition_overrides(false):
			_render_view()
		else:
			_update_dynamic_layers()

func _update_dynamic_layers() -> void:
	if _gpu_view == null or gpu_map == null:
		return
	var solar: Dictionary = _get_solar_params()
	# Keep solar basis anchored to the currently centered world cell so relief/cloud
	# shading remains world-space stable while smooth camera scroll offsets change.
	var lon_phi: Vector2 = _get_fixed_lon_phi(_center_gx, _center_gy)
	var half_w: int = VIEW_W / 2
	var half_h: int = VIEW_H / 2
	var origin_x: int = _center_gx - half_w - VIEW_PAD
	var origin_y: int = _center_gy - half_h - VIEW_PAD
	var clouds: Dictionary = _build_cloud_params(origin_x, origin_y)
	_gpu_view.update_dynamic_layers(
		gpu_map,
		solar,
		clouds,
		float(lon_phi.x),
		float(lon_phi.y),
		0.0
	)
	_publish_regional_cache_stats(-1)

func _update_header_text() -> void:
	if header_label == null:
		return
	var biome_id: int = _get_world_biome_id(world_tile_x, world_tile_y)
	header_label.text = "Regional Map - Tile (%d, %d) - %s - local (%d,%d) - %s" % [
		world_tile_x,
		world_tile_y,
		_biome_name_for_id(biome_id),
		local_x,
		local_y,
		_get_time_label(),
	]

func _read_move_dir() -> Vector2i:
	# Real-time movement (supports diagonals).
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
	var sx: int = int(sign(dx))
	var sy: int = int(sign(dy))
	return Vector2i(sx, sy)

func _move_continuous(dir: Vector2i, delta: float) -> void:
	if dir == Vector2i.ZERO:
		return
	var t_rem: float = max(0.0, delta)
	if t_rem <= 0.0:
		return
	var dv: Vector2 = Vector2(float(dir.x), float(dir.y))
	if dv.length_squared() <= 0.0001:
		return
	# Normalize diagonal movement so speed is consistent.
	var v: Vector2 = dv.normalized() * MOVE_SPEED_CELLS_PER_SEC
	var safety: int = 0
	while t_rem > 0.0 and safety < 32:
		safety += 1
		var gx_int: int = _wrap_global_x(int(floor(_player_gx)))
		var gy_int: int = _clamp_global_y(int(floor(_player_gy)))
		gx_int = _wrap_global_x(gx_int)
		gy_int = _clamp_global_y(gy_int)

		var tx: float = 1e30
		var ty: float = 1e30
		var fx: float = _player_gx - floor(_player_gx)
		var fy: float = _player_gy - floor(_player_gy)

		if abs(v.x) > 0.000001:
			if v.x > 0.0:
				tx = ((floor(_player_gx) + 1.0) - _player_gx) / v.x
			else:
				tx = fx / (-v.x)  # can be 0 when exactly on a boundary
		if abs(v.y) > 0.000001:
			if v.y > 0.0:
				ty = ((floor(_player_gy) + 1.0) - _player_gy) / v.y
			else:
				ty = fy / (-v.y)

		var step_time: float = min(t_rem, min(tx, ty))
		var hit_x: bool = tx <= step_time + 0.000001
		var hit_y: bool = ty <= step_time + 0.000001

		# If we're exactly on a boundary in a negative direction, allow immediate crossing.
		if step_time > 0.0:
			_player_gx += v.x * step_time
			_player_gy += v.y * step_time
			_wrap_player_pos()
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
		if not _try_cross_boundary_any(gx_int, gy_int, Vector2i(sx, sy)):
			break

func _try_cross_boundary_any(gx_int: int, gy_int: int, step_dir: Vector2i) -> bool:
	# Returns true if movement can continue within this frame.
	var sx: int = step_dir.x
	var sy: int = step_dir.y

	# Corner crossing: try diagonal first, then slide.
	if sx != 0 and sy != 0:
		# If Y is clamped, we cannot enter the diagonal row; fall back to X-only.
		var gy_diag: int = _clamp_global_y(gy_int + sy)
		if gy_diag == gy_int:
			return _try_cross_boundary_any(gx_int, gy_int, Vector2i(sx, 0))
		var gx_x: int = _wrap_global_x(gx_int + sx)
		var gy_y: int = _clamp_global_y(gy_int + sy)
		var gx_diag: int = _wrap_global_x(gx_int + sx)

		# Prevent corner-cutting: diagonal requires both adjacent orthogonal cells to be passable.
		var can_x: bool = _can_enter_cell(gx_int, gy_int, gx_x, gy_int)
		var can_y: bool = _can_enter_cell(gx_int, gy_int, gx_int, gy_y)
		if can_x and can_y and _can_enter_cell(gx_int, gy_int, gx_diag, gy_diag):
			_set_pos_after_boundary(gx_int, gy_int, sx, sy, true, true)
			return _on_entered_new_cell()
		# Slide along X if possible (keep Y inside current cell).
		if can_x:
			_set_pos_after_boundary(gx_int, gy_int, sx, sy, true, false)
			return _on_entered_new_cell()
		# Slide along Y if possible (keep X inside current cell).
		if can_y:
			_set_pos_after_boundary(gx_int, gy_int, sx, sy, false, true)
			return _on_entered_new_cell()
		# Blocked: remain inside current cell near the corner.
		_set_pos_after_boundary(gx_int, gy_int, sx, sy, false, false)
		if footer_label:
			footer_label.text = "Blocked terrain."
		return false

	# Single-axis crossing.
	if sx != 0:
		var gx_next: int = _wrap_global_x(gx_int + sx)
		if not _can_enter_cell(gx_int, gy_int, gx_next, gy_int):
			_set_pos_after_boundary(gx_int, gy_int, sx, 0, false, false)
			if footer_label:
				footer_label.text = "Blocked terrain."
			return false
		_set_pos_after_boundary(gx_int, gy_int, sx, 0, true, false)
		return _on_entered_new_cell()

	if sy != 0:
		var gy_next: int = _clamp_global_y(gy_int + sy)
		# Clamp means "cannot go further" at top/bottom.
		if gy_next == gy_int:
			_set_pos_after_boundary(gx_int, gy_int, 0, sy, false, false)
			if footer_label:
				footer_label.text = "You cannot go further in that direction."
			return false
		if not _can_enter_cell(gx_int, gy_int, gx_int, gy_next):
			_set_pos_after_boundary(gx_int, gy_int, 0, sy, false, false)
			if footer_label:
				footer_label.text = "Blocked terrain."
			return false
		_set_pos_after_boundary(gx_int, gy_int, 0, sy, false, true)
		return _on_entered_new_cell()

	return true

func _can_enter_cell(gx_from: int, gy_from: int, gx_to: int, gy_to: int) -> bool:
	if gx_to == gx_from and gy_to == gy_from:
		return false
	if _crosses_world_tile_boundary(gx_from, gy_from, gx_to, gy_to):
		var to_tile: Vector2i = _world_tile_from_global(gx_to, gy_to)
		if not _is_world_tile_enterable(to_tile.x, to_tile.y):
			return false
		# Edge cliffs are allowed to exist visually, but we should not hard-lock players inside
		# a macro tile when crossing into another enterable land tile.
		return true
	if _is_blocked_cell(gx_to, gy_to):
		# Regional chunks can mark macro-tile outer rings as blocked for cliff visuals.
		# Keep those cliffs render-only on land macro tiles so traversal is not trapped.
		if _is_macro_seam_edge_cell(gx_to, gy_to):
			var to_tile: Vector2i = _world_tile_from_global(gx_to, gy_to)
			if _is_world_tile_enterable(to_tile.x, to_tile.y):
				return true
		return false
	return true

func _set_pos_after_boundary(gx_int: int, gy_int: int, sx: int, sy: int, cross_x: bool, cross_y: bool) -> void:
	# When not crossing an axis at a boundary hit, nudge inside the current cell to prevent floor() from
	# jumping into the neighbor without collision checks.
	if sx > 0:
		_player_gx = float(gx_int + 1) + (MOVE_EPS if cross_x else -MOVE_EPS)
	elif sx < 0:
		_player_gx = float(gx_int) + (-MOVE_EPS if cross_x else MOVE_EPS)

	if sy > 0:
		_player_gy = float(gy_int + 1) + (MOVE_EPS if cross_y else -MOVE_EPS)
	elif sy < 0:
		_player_gy = float(gy_int) + (-MOVE_EPS if cross_y else MOVE_EPS)

	_wrap_player_pos()

func _on_entered_new_cell() -> bool:
	var prev_cx: int = _center_gx
	var prev_cy: int = _center_gy
	_sync_location_from_player_pos()
	if _center_gx == prev_cx and _center_gy == prev_cy:
		return true
	_save_position_to_state()
	_refresh_regional_transition_overrides(false)
	if footer_label:
		footer_label.text = ""
	# Stepping onto a POI tile enters immediately (no "E" required).
	if _poi_info_at(world_tile_x, world_tile_y, local_x, local_y).size() > 0:
		_try_enter_poi()
		return false
	if _roll_encounter_if_needed():
		return false
	if not _render_view_incremental(prev_cx, prev_cy):
		_render_view()
	return true

func _dist_to_next_boundary(dir: Vector2i) -> float:
	if dir.x > 0:
		return (floor(_player_gx) + 1.0) - _player_gx
	if dir.x < 0:
		return _player_gx - floor(_player_gx)
	if dir.y > 0:
		return (floor(_player_gy) + 1.0) - _player_gy
	if dir.y < 0:
		return _player_gy - floor(_player_gy)
	return 0.0

func _wrap_player_pos() -> void:
	var period_x: float = float(max(1, world_width * REGION_SIZE))
	if period_x > 0.0:
		_player_gx = fposmod(_player_gx, period_x)
	var max_y: float = float(world_height * REGION_SIZE) - MOVE_EPS
	_player_gy = clamp(_player_gy, 0.0, max_y)

func _snap_to_boundary(gx_int: int, gy_int: int, dir: Vector2i) -> void:
	if dir.x > 0:
		_player_gx = float(gx_int + 1) - MOVE_EPS
	elif dir.x < 0:
		_player_gx = float(gx_int) + MOVE_EPS
	elif dir.y > 0:
		_player_gy = float(gy_int + 1) - MOVE_EPS
	elif dir.y < 0:
		_player_gy = float(gy_int) + MOVE_EPS

func _cross_boundary(gx_int: int, gy_int: int, dir: Vector2i) -> void:
	# Move just inside the neighbor cell to avoid boundary floor flicker.
	if dir.x > 0:
		_player_gx = float(gx_int + 1) + MOVE_EPS
	elif dir.x < 0:
		_player_gx = float(gx_int) - MOVE_EPS
	elif dir.y > 0:
		_player_gy = float(gy_int + 1) + MOVE_EPS
	elif dir.y < 0:
		_player_gy = float(gy_int) - MOVE_EPS

func _is_blocked_cell(gx: int, gy: int) -> bool:
	if _chunk_cache == null:
		return false
	var cell: Dictionary = _chunk_cache.get_cell(gx, gy)
	var f: int = int(cell.get("flags", 0))
	return (f & RegionalChunkGenerator.FLAG_BLOCKED) != 0

func _sync_location_from_player_pos() -> void:
	var gx_int: int = _wrap_global_x(int(floor(_player_gx)))
	var gy_int: int = _clamp_global_y(int(floor(_player_gy)))
	_center_gx = gx_int
	_center_gy = gy_int
	var new_world_x: int = int(gx_int / REGION_SIZE)
	var new_world_y: int = int(gy_int / REGION_SIZE)
	world_tile_x = posmod(new_world_x, world_width)
	world_tile_y = clamp(new_world_y, 0, world_height - 1)
	local_x = gx_int - new_world_x * REGION_SIZE
	local_y = gy_int - new_world_y * REGION_SIZE

func _apply_scroll_offset() -> void:
	if gpu_map == null:
		return
	if not ("set_scroll_offset_cells" in gpu_map):
		return
	var fx: float = _player_gx - floor(_player_gx)
	var fy: float = _player_gy - floor(_player_gy)
	# Guard against tiny negative values from float error.
	fx = clamp(fx, 0.0, 0.999999)
	fy = clamp(fy, 0.0, 0.999999)
	gpu_map.set_scroll_offset_cells(fx, fy)

func _update_fixed_lonlat_uniform() -> void:
	if gpu_map == null:
		return
	if not ("set_fixed_lonlat" in gpu_map):
		return
	var lon_phi: Vector2 = _get_fixed_lon_phi(_center_gx, _center_gy)
	gpu_map.set_fixed_lonlat(true, float(lon_phi.x), float(lon_phi.y))

func _world_tile_from_global(gx: int, gy: int) -> Vector2i:
	var gxw: int = _wrap_global_x(gx)
	var gyc: int = _clamp_global_y(gy)
	var wx: int = int(gxw / REGION_SIZE)
	var wy: int = int(gyc / REGION_SIZE)
	return Vector2i(posmod(wx, world_width), clamp(wy, 0, world_height - 1))

func _crosses_world_tile_boundary(gx_from: int, gy_from: int, gx_to: int, gy_to: int) -> bool:
	var a: Vector2i = _world_tile_from_global(gx_from, gy_from)
	var b: Vector2i = _world_tile_from_global(gx_to, gy_to)
	return a.x != b.x or a.y != b.y

func _is_world_tile_enterable(wx: int, wy: int) -> bool:
	var biome_id: int = _get_world_biome_id(wx, wy)
	return not _is_macro_ocean_biome(biome_id)

func _is_macro_seam_edge_cell(gx: int, gy: int) -> bool:
	var gxw: int = _wrap_global_x(gx)
	var gyc: int = _clamp_global_y(gy)
	var lx: int = posmod(gxw, REGION_SIZE)
	var ly: int = posmod(gyc, REGION_SIZE)
	return lx == 0 or lx == REGION_SIZE - 1 or ly == 0 or ly == REGION_SIZE - 1

func _is_macro_ocean_biome(biome_id: int) -> bool:
	# World-map hard-blocked macro biomes.
	return biome_id == 0 or biome_id == 1

func _move_player(delta: Vector2i) -> void:
	var gx0: int = world_tile_x * REGION_SIZE + local_x
	var gy0: int = world_tile_y * REGION_SIZE + local_y
	var gx1: int = gx0 + delta.x
	var gy1: int = gy0 + delta.y
	gx1 = _wrap_global_x(gx1)
	gy1 = _clamp_global_y(gy1)
	if gx1 == gx0 and gy1 == gy0:
		if footer_label:
			footer_label.text = "You cannot go further in that direction."
		return
	if _chunk_cache != null:
		var cell: Dictionary = _chunk_cache.get_cell(gx1, gy1)
		var f: int = int(cell.get("flags", 0))
		if (f & RegionalChunkGenerator.FLAG_BLOCKED) != 0:
			if footer_label:
				footer_label.text = "Blocked terrain."
			return
	_player_gx = float(gx1)
	_player_gy = float(gy1)
	_center_gx = gx1
	_center_gy = gy1
	var new_world_x: int = int(gx1 / REGION_SIZE)
	var new_world_y: int = int(gy1 / REGION_SIZE)
	world_tile_x = posmod(new_world_x, world_width)
	world_tile_y = clamp(new_world_y, 0, world_height - 1)
	local_x = gx1 - new_world_x * REGION_SIZE
	local_y = gy1 - new_world_y * REGION_SIZE
	_save_position_to_state()
	if _roll_encounter_if_needed():
		return
	_render_view()
	_apply_scroll_offset()

func _save_position_to_state() -> void:
	var biome_id: int = _get_world_biome_id(world_tile_x, world_tile_y)
	var biome_name: String = _biome_name_for_id(biome_id)
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location("regional", world_tile_x, world_tile_y, local_x, local_y, biome_id, biome_name)
		if game_state.has_method("mark_world_tile_visited"):
			game_state.mark_world_tile_visited(world_tile_x, world_tile_y)
		if game_state.has_method("mark_regional_step"):
			game_state.mark_regional_step()
	if startup_state != null:
		if startup_state.has_method("set_selected_world_tile"):
			startup_state.set_selected_world_tile(world_tile_x, world_tile_y, biome_id, biome_name, local_x, local_y)

func _roll_encounter_if_needed() -> bool:
	var biome_id: int = _get_world_biome_id(world_tile_x, world_tile_y)
	# Prefer the blended regional biome at the player's exact cell (seamless edges).
	var gx: int = _wrap_global_x(world_tile_x * REGION_SIZE + local_x)
	var gy: int = _clamp_global_y(world_tile_y * REGION_SIZE + local_y)
	if _chunk_cache != null:
		var cell: Dictionary = _chunk_cache.get_cell(gx, gy)
		if typeof(cell) == TYPE_DICTIONARY and cell.has("biome"):
			biome_id = int(cell.get("biome", biome_id))
	var biome_name: String = _biome_name_for_id(biome_id)
	var minute_of_day: int = -1
	var day_of_year: int = -1
	if game_state != null and game_state.get("world_time") != null:
		var wt: Object = game_state.world_time
		minute_of_day = int(wt.minute_of_day) if "minute_of_day" in wt else -1
		if "abs_day_index" in wt:
			day_of_year = posmod(int(wt.abs_day_index()), 365)
	var meter_state: Dictionary = {}
	if game_state != null and game_state.has_method("ensure_encounter_meter_state"):
		meter_state = game_state.ensure_encounter_meter_state()
	elif game_state != null and typeof(game_state.get("run_flags")) == TYPE_DICTIONARY:
		var rf: Dictionary = game_state.run_flags
		var v: Variant = rf.get("encounter_meter_state")
		if typeof(v) != TYPE_DICTIONARY:
			v = {}
			rf["encounter_meter_state"] = v
		meter_state = v
		EncounterRegistry.ensure_danger_meter_state_inplace(meter_state)
	var encounter_rate_mul: float = _get_encounter_rate_multiplier()
	if game_state != null and game_state.has_method("get_epoch_encounter_rate_multiplier"):
		encounter_rate_mul *= float(game_state.get_epoch_encounter_rate_multiplier())
	var encounter: Dictionary = EncounterRegistry.step_danger_meter_and_maybe_trigger(
		world_seed_hash,
		meter_state,
		world_tile_x,
		world_tile_y,
		local_x,
		local_y,
		biome_id,
		biome_name,
		encounter_rate_mul,
		minute_of_day,
		day_of_year
	)
	if encounter.is_empty():
		return false
	if game_state != null and game_state.has_method("apply_epoch_gameplay_to_encounter"):
		encounter = game_state.apply_epoch_gameplay_to_encounter(encounter)
	if scene_router != null and scene_router.has_method("goto_battle"):
		scene_router.goto_battle(encounter)
	else:
		if game_state != null and game_state.has_method("queue_battle"):
			game_state.queue_battle(encounter)
		if startup_state != null and startup_state.has_method("queue_battle"):
			startup_state.queue_battle(encounter)
		get_tree().change_scene_to_file(SceneContracts.SCENE_BATTLE)
	return true

func _try_enter_poi() -> void:
	var poi_info: Dictionary = _poi_info_at(world_tile_x, world_tile_y, local_x, local_y)
	if poi_info.is_empty():
		footer_label.text = "No point of interest here. Step onto a POI marker to enter."
		return
	var payload: Dictionary = {
		"type": String(poi_info.get("type", "POI")),
		"id": String(poi_info.get("id", "")),
		"seed_key": String(poi_info.get("seed_key", "")),
		"is_shop": VariantCasts.to_bool(poi_info.get("is_shop", false)),
		"world_x": world_tile_x,
		"world_y": world_tile_y,
		"local_x": local_x,
		"local_y": local_y,
		"biome_id": _get_world_biome_id(world_tile_x, world_tile_y),
		"biome_name": _biome_name_for_id(_get_world_biome_id(world_tile_x, world_tile_y)),
	}
	if game_state != null and game_state.has_method("register_poi_discovery"):
		game_state.register_poi_discovery(payload)
	if scene_router != null and scene_router.has_method("goto_local"):
		scene_router.goto_local(payload)
	else:
		if game_state != null and game_state.has_method("queue_poi"):
			game_state.queue_poi(payload)
			if game_state.has_method("set_location"):
				game_state.set_location("local", world_tile_x, world_tile_y, local_x, local_y, int(payload["biome_id"]), String(payload["biome_name"]))
		if startup_state != null and startup_state.has_method("queue_poi"):
			startup_state.queue_poi(payload)
		get_tree().change_scene_to_file(SceneContracts.SCENE_LOCAL_AREA)

func _render_view() -> void:
	_render_view_full()

func _render_view_incremental(prev_center_x: int, prev_center_y: int) -> bool:
	if _chunk_cache == null or not _field_cache_valid:
		return false
	var dx: int = _wrapped_center_delta_x(_center_gx, prev_center_x)
	var dy: int = _center_gy - prev_center_y
	if abs(dx) > 1 or abs(dy) > 1:
		return false
	var t0_us: int = Time.get_ticks_usec()
	_ensure_field_buffers()
	var half_w: int = VIEW_W / 2
	var half_h: int = VIEW_H / 2
	var origin_x: int = _center_gx - half_w - VIEW_PAD
	var origin_y: int = _center_gy - half_h - VIEW_PAD
	var prefetch_generated: int = -1
	if _chunk_cache.has_method("prefetch_for_view"):
		prefetch_generated = int(_chunk_cache.prefetch_for_view(origin_x, origin_y, RENDER_W, RENDER_H, _CHUNK_PREFETCH_MARGIN_CHUNKS))
	var fresh_cells: int = 0

	for sy in range(RENDER_H):
		for sx in range(RENDER_W):
			var dst_idx: int = sx + sy * RENDER_W
			var src_x: int = sx + dx
			var src_y: int = sy + dy
			if src_x >= 0 and src_x < RENDER_W and src_y >= 0 and src_y < RENDER_H:
				var src_idx: int = src_x + src_y * RENDER_W
				_field_height_raw_scratch[dst_idx] = _field_height_raw[src_idx]
				_field_temp_scratch[dst_idx] = _field_temp[src_idx]
				_field_moist_scratch[dst_idx] = _field_moist[src_idx]
				_field_biome_scratch[dst_idx] = _field_biome[src_idx]
				_field_land_scratch[dst_idx] = _field_land[src_idx]
				_field_beach_scratch[dst_idx] = _field_beach[src_idx]
				continue
			var gx: int = _wrap_global_x(origin_x + sx)
			var gy: int = _clamp_global_y(origin_y + sy)
			var cell: Dictionary = _chunk_cache.get_cell(gx, gy)
			fresh_cells += 1
			_write_field_cell(
				dst_idx,
				gx,
				gy,
				cell,
				_field_height_raw_scratch,
				_field_temp_scratch,
				_field_moist_scratch,
				_field_biome_scratch,
				_field_land_scratch,
				_field_beach_scratch
			)
	_swap_field_buffers()
	_field_origin_x = origin_x
	_field_origin_y = origin_y
	_field_cache_valid = true
	var total_cells: int = RENDER_W * RENDER_H
	_last_redraw_mode = "incremental"
	_last_redraw_us = Time.get_ticks_usec() - t0_us
	_last_redraw_fresh_cells = fresh_cells
	_last_redraw_reused_cells = max(0, total_cells - fresh_cells)
	_last_redraw_dx = dx
	_last_redraw_dy = dy
	_record_redraw_sample(float(_last_redraw_us) / 1000.0)
	_present_field_buffers(origin_x, origin_y, prefetch_generated, true, dx, dy)
	return true

func _render_view_full() -> void:
	if _chunk_cache == null:
		_field_cache_valid = false
		return
	var t0_us: int = Time.get_ticks_usec()
	_ensure_field_buffers()
	var half_w: int = VIEW_W / 2
	var half_h: int = VIEW_H / 2
	var gx0: int = _center_gx
	var gy0: int = _center_gy
	var origin_x: int = gx0 - half_w - VIEW_PAD
	var origin_y: int = gy0 - half_h - VIEW_PAD
	var prefetch_generated: int = -1
	if _chunk_cache != null and _chunk_cache.has_method("prefetch_for_view"):
		prefetch_generated = int(_chunk_cache.prefetch_for_view(origin_x, origin_y, RENDER_W, RENDER_H, _CHUNK_PREFETCH_MARGIN_CHUNKS))
	for sy in range(RENDER_H):
		for sx in range(RENDER_W):
			var gx_raw: int = origin_x + sx
			var gy_raw: int = origin_y + sy
			var gx: int = _wrap_global_x(gx_raw)
			var gy: int = _clamp_global_y(gy_raw)
			var idx: int = sx + sy * RENDER_W

			var cell: Dictionary = _chunk_cache.get_cell(gx, gy) if _chunk_cache != null else {}
			_write_field_cell(
				idx,
				gx,
				gy,
				cell,
				_field_height_raw,
				_field_temp,
				_field_moist,
				_field_biome,
				_field_land,
				_field_beach
			)
	_field_origin_x = origin_x
	_field_origin_y = origin_y
	_field_cache_valid = true
	_last_redraw_mode = "full"
	_last_redraw_us = Time.get_ticks_usec() - t0_us
	_last_redraw_fresh_cells = RENDER_W * RENDER_H
	_last_redraw_reused_cells = 0
	_last_redraw_dx = 0
	_last_redraw_dy = 0
	_record_redraw_sample(float(_last_redraw_us) / 1000.0)
	_present_field_buffers(origin_x, origin_y, prefetch_generated, false, 0, 0)

func _ensure_field_buffers() -> void:
	var size: int = RENDER_W * RENDER_H
	if _field_height_raw.size() != size:
		_field_height_raw.resize(size)
		_field_temp.resize(size)
		_field_moist.resize(size)
		_field_biome.resize(size)
		_field_land.resize(size)
		_field_beach.resize(size)
	if _field_height_raw_scratch.size() != size:
		_field_height_raw_scratch.resize(size)
		_field_temp_scratch.resize(size)
		_field_moist_scratch.resize(size)
		_field_biome_scratch.resize(size)
		_field_land_scratch.resize(size)
		_field_beach_scratch.resize(size)

func _write_field_cell(
	idx: int,
	gx: int,
	gy: int,
	cell: Dictionary,
	out_height_raw: PackedFloat32Array,
	out_temp: PackedFloat32Array,
	out_moist: PackedFloat32Array,
	out_biome: PackedInt32Array,
	out_land: PackedInt32Array,
	out_beach: PackedInt32Array
) -> void:
	var ground: int = int(cell.get("ground", RegionalChunkGenerator.Ground.GRASS))
	var h: float = float(cell.get("height_raw", 0.0))
	var b: int = int(cell.get("biome", _get_world_biome_id(int(gx / REGION_SIZE), int(gy / REGION_SIZE))))

	var is_water: bool = (ground == RegionalChunkGenerator.Ground.WATER_DEEP) or (ground == RegionalChunkGenerator.Ground.WATER_SHALLOW)
	var is_land_cell: int = 0 if is_water else 1
	var is_beach_cell: int = 1 if ground == RegionalChunkGenerator.Ground.SAND else 0

	# POI markers (render-only) so houses/dungeons remain visible in GPU mode.
	var poi_type: String = String(cell.get("poi_type", ""))
	if not poi_type.is_empty():
		if poi_type == "House":
			b = 200
			is_land_cell = 1
			is_beach_cell = 0
		elif poi_type == "Dungeon":
			var poi_id: String = String(cell.get("poi_id", ""))
			var cleared: bool = _is_poi_cleared(poi_id)
			b = 202 if cleared else 201
			is_land_cell = 1
			is_beach_cell = 0

	out_height_raw[idx] = h
	out_biome[idx] = b
	out_land[idx] = is_land_cell
	out_beach[idx] = is_beach_cell

	var base_t: float = _visual_temp_for_biome(b)
	var base_m: float = _visual_moist_for_biome(b)
	var jt: float = (_rand01_xy(gx, gy, 11) - 0.5) * 0.10
	var jm: float = (_rand01_xy(gx, gy, 29) - 0.5) * 0.10
	out_temp[idx] = clamp(base_t + jt, 0.0, 1.0)
	out_moist[idx] = clamp(base_m + jm, 0.0, 1.0)

func _swap_field_buffers() -> void:
	var tmp_h: PackedFloat32Array = _field_height_raw
	_field_height_raw = _field_height_raw_scratch
	_field_height_raw_scratch = tmp_h
	var tmp_t: PackedFloat32Array = _field_temp
	_field_temp = _field_temp_scratch
	_field_temp_scratch = tmp_t
	var tmp_m: PackedFloat32Array = _field_moist
	_field_moist = _field_moist_scratch
	_field_moist_scratch = tmp_m
	var tmp_b: PackedInt32Array = _field_biome
	_field_biome = _field_biome_scratch
	_field_biome_scratch = tmp_b
	var tmp_l: PackedInt32Array = _field_land
	_field_land = _field_land_scratch
	_field_land_scratch = tmp_l
	var tmp_beach: PackedInt32Array = _field_beach
	_field_beach = _field_beach_scratch
	_field_beach_scratch = tmp_beach

func _present_field_buffers(
	origin_x: int,
	origin_y: int,
	prefetch_generated: int = -1,
	allow_partial_upload: bool = false,
	upload_dx: int = 0,
	upload_dy: int = 0
) -> void:
	var solar: Dictionary = _get_solar_params()
	var lon_phi: Vector2 = _get_fixed_lon_phi(_center_gx, _center_gy)
	var clouds: Dictionary = _build_cloud_params(origin_x, origin_y)
	if _gpu_view != null and gpu_map != null:
		var field_payload: Dictionary = {
			"height_raw": _field_height_raw,
			"temp": _field_temp,
			"moist": _field_moist,
			"biome": _field_biome,
			"land": _field_land,
			"beach": _field_beach,
		}
		var used_partial_upload: bool = false
		var t0_upload_us: int = Time.get_ticks_usec()
		if _ENABLE_GPU_PARTIAL_UPLOAD and allow_partial_upload and "update_and_draw_partial" in _gpu_view:
			used_partial_upload = VariantCasts.to_bool(_gpu_view.update_and_draw_partial(
				gpu_map,
				field_payload,
				{"dx": upload_dx, "dy": upload_dy},
				solar,
				clouds,
				float(lon_phi.x),
				float(lon_phi.y),
				0.0
			))
		if not used_partial_upload:
			_gpu_view.update_and_draw(
				gpu_map,
				field_payload,
				solar,
				clouds,
				float(lon_phi.x),
				float(lon_phi.y),
				0.0
			)
		_last_gpu_upload_us = Time.get_ticks_usec() - t0_upload_us
		_last_gpu_upload_mode = "partial" if used_partial_upload else "full"
		_update_player_marker()
		_update_header_text()
		if footer_label != null:
			var poi_hint: String = _nearby_poi_hint()
			var base_hint: String = "Move: WASD/Arrows (diagonals OK) | Step on POI to enter | M: World Map | Esc/Tab: Menu | F5 save | F9 load"
			footer_label.text = poi_hint if not poi_hint.is_empty() else base_hint
	else:
		_last_gpu_upload_mode = ""
		_last_gpu_upload_us = 0
	_publish_regional_cache_stats(prefetch_generated)

func _record_redraw_sample(ms: float) -> void:
	if ms < 0.0:
		return
	_redraw_samples_ms.append(ms)
	var max_samples: int = max(16, _REDRAW_SAMPLE_WINDOW)
	if _redraw_samples_ms.size() > max_samples:
		_redraw_samples_ms.pop_front()

func _percentile_from_samples(samples: Array[float], p: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var t: float = clamp(p, 0.0, 1.0)
	var idx: int = int(round(t * float(sorted.size() - 1)))
	idx = clamp(idx, 0, sorted.size() - 1)
	return float(sorted[idx])

func _nearby_poi_hint() -> String:
	if _chunk_cache == null:
		return ""
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var gx: int = _wrap_global_x(_center_gx + ox)
			var gy: int = _clamp_global_y(_center_gy + oy)
			var cell: Dictionary = _chunk_cache.get_cell(gx, gy)
			var poi_type: String = String(cell.get("poi_type", ""))
			if not poi_type.is_empty():
				return "Nearby POI: %s (step onto it to enter)." % poi_type
	return ""

func _wrapped_center_delta_x(new_center_x: int, old_center_x: int) -> int:
	var period: int = world_width * REGION_SIZE
	if period <= 0:
		return new_center_x - old_center_x
	var d: int = new_center_x - old_center_x
	var half: int = int(period / 2)
	if d > half:
		d -= period
	elif d < -half:
		d += period
	return d

func _sample_world_cell(offset_x: int, offset_y: int) -> Dictionary:
	# Deprecated: replaced by `_chunk_cache` sampling in `_render_view()`.
	return {}

func _poi_info_at(tx: int, ty: int, lx: int, ly: int) -> Dictionary:
	return PoiRegistry.get_poi_at(world_seed_hash, tx, ty, lx, ly, _get_world_biome_id(tx, ty))

func _is_poi_cleared(poi_id: String) -> bool:
	if poi_id.is_empty():
		return false
	if game_state != null and game_state.has_method("is_poi_cleared"):
		return VariantCasts.to_bool(game_state.is_poi_cleared(poi_id))
	return false

func _get_world_biome_id(x: int, y: int) -> int:
	if game_state != null and game_state.has_method("get_world_biome_id"):
		return int(game_state.get_world_biome_id(x, y))
	if startup_state != null and startup_state.has_method("get_world_biome_id"):
		return int(startup_state.get_world_biome_id(x, y))
	return 7

func _get_time_label() -> String:
	if game_state != null and game_state.has_method("get_time_label"):
		return String(game_state.get_time_label())
	return ""

func _get_encounter_rate_multiplier() -> float:
	if game_state != null and game_state.has_method("get_encounter_rate_multiplier"):
		return float(game_state.get_encounter_rate_multiplier())
	return 1.0

func _build_cloud_params(origin_x: int, origin_y: int) -> Dictionary:
	var biome_id: int = _get_world_biome_id(world_tile_x, world_tile_y)
	if _chunk_cache != null:
		var c: Dictionary = _chunk_cache.get_cell(_center_gx, _center_gy)
		if typeof(c) == TYPE_DICTIONARY and c.has("biome"):
			biome_id = int(c.get("biome", biome_id))
	var moist: float = _visual_moist_for_biome(biome_id)
	var temp: float = _visual_temp_for_biome(biome_id)
	var wind_x: float = 0.08 + (temp - 0.5) * 0.10
	var wind_y: float = 0.03 + (moist - 0.5) * 0.08
	var coverage: float = clamp(0.22 + moist * 0.68, 0.10, 0.95)
	return {
		"enabled": true,
		"origin_x": origin_x,
		"origin_y": origin_y,
		"world_period_x": world_width * REGION_SIZE,
		"world_height": world_height * REGION_SIZE,
		"scale": lerp(0.017, 0.024, moist),
		"wind_x": wind_x,
		"wind_y": wind_y,
		"coverage": coverage,
		"contrast": lerp(1.15, 1.40, coverage),
	}

func _publish_regional_cache_stats(prefetch_generated: int = -1) -> void:
	if game_state == null or _chunk_cache == null:
		return
	if not game_state.has_method("set_regional_cache_stats"):
		return
	var stats: Dictionary = {}
	if _chunk_cache.has_method("get_stats"):
		stats = _chunk_cache.get_stats()
	stats["scene"] = SceneContracts.STATE_REGIONAL
	stats["world_x"] = world_tile_x
	stats["world_y"] = world_tile_y
	stats["local_x"] = local_x
	stats["local_y"] = local_y
	stats["center_gx"] = _center_gx
	stats["center_gy"] = _center_gy
	stats["redraw_mode"] = _last_redraw_mode
	stats["redraw_us"] = _last_redraw_us
	stats["redraw_ms"] = float(_last_redraw_us) / 1000.0
	stats["redraw_fresh_cells"] = _last_redraw_fresh_cells
	stats["redraw_reused_cells"] = _last_redraw_reused_cells
	stats["redraw_dx"] = _last_redraw_dx
	stats["redraw_dy"] = _last_redraw_dy
	stats["gpu_upload_mode"] = _last_gpu_upload_mode
	stats["gpu_upload_us"] = _last_gpu_upload_us
	stats["gpu_upload_ms"] = float(_last_gpu_upload_us) / 1000.0
	stats["redraw_sample_count"] = _redraw_samples_ms.size()
	stats["redraw_p50_ms"] = _percentile_from_samples(_redraw_samples_ms, 0.50)
	stats["redraw_p95_ms"] = _percentile_from_samples(_redraw_samples_ms, 0.95)
	stats["redraw_p99_ms"] = _percentile_from_samples(_redraw_samples_ms, 0.99)
	stats["field_cache_valid"] = _field_cache_valid
	if prefetch_generated >= 0:
		stats["chunks_generated_last_prefetch"] = prefetch_generated
	game_state.set_regional_cache_stats(stats)

func get_last_redraw_stats() -> Dictionary:
	return {
		"mode": _last_redraw_mode,
		"redraw_us": _last_redraw_us,
		"redraw_ms": float(_last_redraw_us) / 1000.0,
		"fresh_cells": _last_redraw_fresh_cells,
		"reused_cells": _last_redraw_reused_cells,
		"dx": _last_redraw_dx,
		"dy": _last_redraw_dy,
		"gpu_upload_mode": _last_gpu_upload_mode,
		"gpu_upload_ms": float(_last_gpu_upload_us) / 1000.0,
	}

func _wrap_global_x(gx: int) -> int:
	var period: int = world_width * REGION_SIZE
	if period <= 0:
		return gx
	return posmod(gx, period)

func _clamp_global_y(gy: int) -> int:
	var max_y: int = world_height * REGION_SIZE - 1
	return clamp(gy, 0, max_y)

func _visual_for_cell(cell: Dictionary) -> Dictionary:
	var ground: int = int(cell.get("ground", RegionalChunkGenerator.Ground.GRASS))
	var obj: int = int(cell.get("obj", RegionalChunkGenerator.Obj.NONE))
	var flags: int = int(cell.get("flags", 0))
	if obj == RegionalChunkGenerator.Obj.TREE:
		return {"glyph": "T", "color": "#3C8F52"}
	if obj == RegionalChunkGenerator.Obj.SHRUB:
		return {"glyph": "\"", "color": "#6FAF6F"}
	if obj == RegionalChunkGenerator.Obj.BOULDER:
		return {"glyph": "o", "color": "#A2A5AA"}
	if obj == RegionalChunkGenerator.Obj.REED:
		return {"glyph": ";", "color": "#6A8F5D"}
	if (flags & RegionalChunkGenerator.FLAG_BLOCKED) != 0 and ground != RegionalChunkGenerator.Ground.WATER_DEEP:
		return {"glyph": "A", "color": "#9A9A9A"}
	match ground:
		RegionalChunkGenerator.Ground.WATER_DEEP:
			return {"glyph": "~", "color": "#2A6FB0"}
		RegionalChunkGenerator.Ground.WATER_SHALLOW:
			return {"glyph": "=", "color": "#2F7AC0"}
		RegionalChunkGenerator.Ground.SAND:
			return {"glyph": "`", "color": "#E4D7A1"}
		RegionalChunkGenerator.Ground.SNOW:
			return {"glyph": "*", "color": "#EAEAEA"}
		RegionalChunkGenerator.Ground.SWAMP:
			return {"glyph": ";", "color": "#6A8F5D"}
		RegionalChunkGenerator.Ground.ROCK:
			return {"glyph": "^", "color": "#A2A5AA"}
		RegionalChunkGenerator.Ground.DIRT:
			return {"glyph": ",", "color": "#8B7A5A"}
		_:
			return {"glyph": ".", "color": "#7CB56A"}

func _try_quick_save() -> void:
	if game_state != null and game_state.has_method("save_to_path"):
		if game_state.save_to_path(SceneContracts.SAVE_SLOT_0):
			footer_label.text = "Saved to %s" % SceneContracts.SAVE_SLOT_0
		else:
			footer_label.text = "Save failed."

func _try_quick_load() -> void:
	if game_state != null and game_state.has_method("load_from_path"):
		if game_state.load_from_path(SceneContracts.SAVE_SLOT_0):
			_load_location_from_state()
			_refresh_regional_transition_overrides(true)
			_render_view()
			_apply_scroll_offset()
			call_deferred("_update_player_marker")
			footer_label.text = "Loaded %s" % SceneContracts.SAVE_SLOT_0
		else:
			footer_label.text = "Load failed (missing file or schema mismatch)."

func _rand01_xy(gx: int, gy: int, salt: int) -> float:
	var n: int = gx * 374761393 + gy * 668265263 + world_seed_hash * 92821 + salt * 715827883
	n = n ^ (n >> 13)
	n = n * 1274126177
	n = n ^ (n >> 16)
	var u: int = n & 0x7fffffff
	return float(u) / 2147483647.0

func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28

func _biome_name_for_id(biome_id: int) -> String:
	match biome_id:
		0:
			return "Ocean"
		1:
			return "Ice Sheet"
		2:
			return "Beach"
		3:
			return "Sand Desert"
		4:
			return "Wasteland"
		5:
			return "Ice Desert"
		6:
			return "Steppe"
		7:
			return "Grassland"
		10:
			return "Swamp"
		11:
			return "Tropical Forest"
		12:
			return "Boreal Forest"
		13:
			return "Conifer Forest"
		14:
			return "Temperate Forest"
		15:
			return "Rainforest"
		16:
			return "Hills"
		18:
			return "Mountains"
		19:
			return "Alpine"
		24:
			return "Glacier"
		28:
			return "Salt Desert"
		_:
			return "Biome %d" % biome_id

func _exit_tree() -> void:
	if _gpu_view != null and "cleanup" in _gpu_view:
		_gpu_view.cleanup()
	_gpu_view = null
	_redraw_samples_ms.clear()
	_last_gpu_upload_mode = ""
	_last_gpu_upload_us = 0
	if game_state != null and game_state.has_method("set_regional_cache_stats"):
		game_state.set_regional_cache_stats({})

func _on_gpu_map_resized() -> void:
	_update_player_marker()
	_apply_scroll_offset()

func _update_player_marker() -> void:
	if _player_marker == null or gpu_map == null:
		return
	# Cell size must use the visible view dimensions, not the padded render dimensions.
	var cs: Vector2 = Vector2(float(gpu_map.size.x) / float(VIEW_W), float(gpu_map.size.y) / float(VIEW_H))
	if cs.x <= 0.0 or cs.y <= 0.0:
		return
	var cx: int = VIEW_W / 2
	var cy: int = VIEW_H / 2
	_player_marker.size = cs
	_player_marker.position = Vector2(float(cx) * cs.x, float(cy) * cs.y)
	_marker_initialized = true

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
		"relief_strength": 0.12,
	}

func _get_fixed_lon_phi(gx_center: int, gy_center: int) -> Vector2:
	return _get_fixed_lon_phi_f(float(gx_center), float(gy_center))

func _get_fixed_lon_phi_f(gx_center: float, gy_center: float) -> Vector2:
	var total_w: float = float(max(1, world_width * REGION_SIZE))
	var total_h: float = float(max(2, world_height * REGION_SIZE))
	var gx: float = fposmod(gx_center, total_w)
	if gx < 0.0:
		gx += total_w
	var gy: float = clamp(gy_center, 0.0, total_h - 1.0)
	var lon: float = TAU * (gx / total_w)
	var lat_norm: float = 0.5 - (gy / max(1.0, total_h - 1.0))
	var phi: float = lat_norm * PI
	return Vector2(lon, phi)

func _visual_temp_for_biome(biome_id: int) -> float:
	# 0..1 visual temperature proxy (only used for shader tint).
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

func _visual_moist_for_biome(biome_id: int) -> float:
	# 0..1 visual moisture proxy (can later drive weather/overcast).
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
