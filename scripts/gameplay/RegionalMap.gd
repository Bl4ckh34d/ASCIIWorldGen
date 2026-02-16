extends Control


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
const MARKER_PLAYER: int = 220
const MARKER_TREE_CANOPY: int = 224
const MARKER_SHRUB_CLUSTER: int = 225
const MARKER_BOULDER: int = 226
const MARKER_REEDS: int = 227
const MARKER_PLAYER_UNDER_CANOPY: int = 228

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
var world_river_mask: PackedByteArray = PackedByteArray()
var _location_biome_override_id: int = -1

var _chunk_gen: RegionalChunkGenerator = null
var _chunk_cache: RegionalChunkCache = null
var _gpu_view: Object = null

var _player_gx: float = 0.0
var _player_gy: float = 0.0
var _center_gx: int = 0
var _center_gy: int = 0

const _HEADER_REFRESH_INTERVAL: float = 0.25
const _DYNAMIC_REFRESH_INTERVAL: float = 0.50
const _TRANSITION_PROGRESS_QUANTIZATION_STEPS: int = 200
const _CHUNK_PREFETCH_MARGIN_CHUNKS: int = 1
const _CHUNK_PREFETCH_BUDGET_CHUNKS: int = 4
const _CHUNK_PREFETCH_BUDGET_US: int = 2000
const _CHUNK_WALK_PREFETCH_INTERVAL: float = 0.08
const _CHUNK_WALK_PREFETCH_BUDGET_CHUNKS: int = 2
const _CHUNK_WALK_PREFETCH_BUDGET_US: int = 1200
const _TRANSITION_INVALIDATE_PAD_CELLS: int = 12
# Partial edge-only GPU uploads are currently incorrect for the scrolled regional view:
# they do not shift interior texture rows/cols, which can visually pin shading around
# the centered player. Keep CPU incremental sampling, but push full GPU uploads.
const _ENABLE_GPU_PARTIAL_UPLOAD: bool = false
var _header_refresh_accum: float = 0.0
var _dynamic_refresh_accum: float = 0.0
var _transition_signature: String = ""
var _transition_quantized_tiles: Dictionary = {} # Vector2i -> quantized transition descriptor
var _walk_prefetch_accum: float = 0.0
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
var _house_layout_cache: Dictionary = {} # key -> generated local house layout
var _visible_poi_overrides: Dictionary = {} # "gx,gy" -> poi info (for rendered house footprints)
var _visible_house_wall_blocks: Dictionary = {} # "gx,gy" -> true for rendered house wall cells
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

func _init_regional_generation() -> void:
	_house_layout_cache.clear()
	_visible_poi_overrides.clear()
	_visible_house_wall_blocks.clear()
	_transition_quantized_tiles.clear()
	_walk_prefetch_accum = 0.0
	if world_biome_ids.is_empty():
		# Best-effort fallback: try to pull from GameState even if location came from StartupState.
		if game_state != null:
			world_biome_ids = game_state.world_biome_ids
	if world_river_mask.is_empty():
		if game_state != null:
			var river_v: Variant = game_state.get("world_river_mask")
			if river_v is PackedByteArray:
				world_river_mask = (river_v as PackedByteArray).duplicate()
	if world_river_mask.is_empty() and startup_state != null:
		var startup_river_v: Variant = startup_state.get("world_river_mask")
		if startup_river_v is PackedByteArray:
			world_river_mask = (startup_river_v as PackedByteArray).duplicate()
	if world_biome_ids.is_empty():
		# Without a snapshot we can still render, but biome blending will degrade.
		world_biome_ids = PackedInt32Array()
	var expected_cells: int = world_width * world_height
	if expected_cells <= 0 or world_river_mask.size() != expected_cells:
		world_river_mask = PackedByteArray()
	_chunk_gen = RegionalChunkGenerator.new()
	_chunk_gen.configure(world_seed_hash, world_width, world_height, world_biome_ids, REGION_SIZE, world_river_mask)
	if _location_biome_override_id >= 0 and "set_biome_overrides" in _chunk_gen:
		_chunk_gen.set_biome_overrides({
			Vector2i(world_tile_x, world_tile_y): int(_location_biome_override_id),
		})
	_chunk_cache = RegionalChunkCache.new()
	# Slightly smaller chunks reduce worst-case single-chunk generation spikes while walking.
	_chunk_cache.configure(_chunk_gen, 24, 320)
	if _chunk_cache.has_method("set_prefetch_budget"):
		_chunk_cache.set_prefetch_budget(_CHUNK_PREFETCH_BUDGET_CHUNKS, _CHUNK_PREFETCH_BUDGET_US)
	_refresh_regional_transition_overrides(true)

func _ensure_valid_spawn() -> void:
	# If the saved spawn lands on blocked terrain (deep water/cliff), nudge to the nearest open cell.
	if _chunk_cache == null:
		return
	var gx0: int = _wrap_global_x(int(floor(_player_gx)))
	var gy0: int = _clamp_global_y(int(floor(_player_gy)))
	if _chunk_cache.has_method("prefetch_for_view"):
		_chunk_cache.prefetch_for_view(gx0, gy0, 1, 1, 1, 12, 4000)
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
	var quantized: Dictionary = {}
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
		var from_biome: int = int(d.get("from_biome", -1))
		var to_biome: int = int(d.get("to_biome", -1))
		var progress: float = clamp(float(d.get("progress", 1.0)), 0.0, 1.0)
		var q_progress: int = int(round(progress * float(_TRANSITION_PROGRESS_QUANTIZATION_STEPS)))
		var tile_key := Vector2i(wx, wy)
		parsed[Vector2i(wx, wy)] = {
			"from_biome": from_biome,
			"to_biome": to_biome,
			"progress": progress,
		}
		quantized[tile_key] = "%d>%d@%03d" % [from_biome, to_biome, q_progress]
	var sig_parts: Array[String] = []
	for pk in quantized.keys():
		var pxy: Vector2i = pk
		sig_parts.append("%d,%d:%s" % [
			pxy.x,
			pxy.y,
			String(quantized.get(pk, "")),
		])
	sig_parts.sort()
	var sig: String = "|".join(sig_parts)
	if not force and sig == _transition_signature:
		return false
	var changed_tiles: Array[Vector2i] = []
	var changed_seen: Dictionary = {}
	if force:
		for qk in quantized.keys():
			if typeof(qk) != TYPE_VECTOR2I:
				continue
			var tk: Vector2i = qk as Vector2i
			if changed_seen.has(tk):
				continue
			changed_seen[tk] = true
			changed_tiles.append(tk)
	else:
		for old_kv in _transition_quantized_tiles.keys():
			if typeof(old_kv) != TYPE_VECTOR2I:
				continue
			var old_key: Vector2i = old_kv as Vector2i
			var old_desc: String = String(_transition_quantized_tiles.get(old_key, ""))
			var new_desc: String = String(quantized.get(old_key, ""))
			if not quantized.has(old_key) or old_desc != new_desc:
				if not changed_seen.has(old_key):
					changed_seen[old_key] = true
					changed_tiles.append(old_key)
		for new_kv in quantized.keys():
			if typeof(new_kv) != TYPE_VECTOR2I:
				continue
			var new_key: Vector2i = new_kv as Vector2i
			var old_desc2: String = String(_transition_quantized_tiles.get(new_key, ""))
			var new_desc2: String = String(quantized.get(new_key, ""))
			if not _transition_quantized_tiles.has(new_key) or old_desc2 != new_desc2:
				if not changed_seen.has(new_key):
					changed_seen[new_key] = true
					changed_tiles.append(new_key)
	_transition_signature = sig
	_transition_quantized_tiles = quantized.duplicate(true)
	if "set_biome_transition_overrides" in _chunk_gen:
		_chunk_gen.set_biome_transition_overrides(parsed)
	if _chunk_cache != null:
		if force:
			if _chunk_cache.has_method("invalidate_all"):
				_chunk_cache.invalidate_all()
		elif not changed_tiles.is_empty():
			if _chunk_cache.has_method("invalidate_for_world_tiles"):
				_chunk_cache.invalidate_for_world_tiles(
					changed_tiles,
					REGION_SIZE,
					world_width,
					world_height,
					_TRANSITION_INVALIDATE_PAD_CELLS
				)
			elif _chunk_cache.has_method("invalidate_all"):
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
		# Regional map uses cloud shadows only (no separate white cloud tile overlay).
		if "set_cloud_overlay_enabled" in gpu_map:
			gpu_map.set_cloud_overlay_enabled(false)
		if "set_cloud_rendering_params" in gpu_map:
			gpu_map.set_cloud_rendering_params(0.30, 0.0, Vector2(1.9, 1.25))
	# Initialize per-view GPU field packer.
	if _gpu_view == null:
		_gpu_view = GpuMapView.new()
		_gpu_view.configure("regional_view", RENDER_W, RENDER_H, world_seed_hash)
	if gpu_map != null and gpu_map is Control:
		if not (gpu_map as Control).resized.is_connected(_on_gpu_map_resized):
			(gpu_map as Control).resized.connect(_on_gpu_map_resized)

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
			var river_v: Variant = game_state.get("world_river_mask")
			if river_v is PackedByteArray:
				world_river_mask = (river_v as PackedByteArray).duplicate()
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
		var startup_river_v: Variant = startup_state.get("world_river_mask")
		if startup_river_v is PackedByteArray:
			world_river_mask = (startup_river_v as PackedByteArray).duplicate()
	if world_seed_hash == 0:
		world_seed_hash = 1
	world_tile_x = posmod(world_tile_x, world_width)
	world_tile_y = clamp(world_tile_y, 0, world_height - 1)
	local_x = clamp(local_x, 0, REGION_SIZE - 1)
	local_y = clamp(local_y, 0, REGION_SIZE - 1)
	_ensure_enterable_world_tile_selection()
	var gx0: int = world_tile_x * REGION_SIZE + local_x
	var gy0: int = world_tile_y * REGION_SIZE + local_y
	_player_gx = float(_wrap_global_x(gx0))
	_player_gy = float(_clamp_global_y(gy0))
	_center_gx = int(floor(_player_gx))
	_center_gy = int(floor(_player_gy))
	_save_position_to_state()

func _ensure_enterable_world_tile_selection() -> void:
	if world_width <= 0 or world_height <= 0:
		return
	if _is_world_tile_enterable(world_tile_x, world_tile_y):
		return
	var found: bool = false
	var best := Vector2i(world_tile_x, world_tile_y)
	var search_max: int = max(1, max(world_width, world_height))
	for r in range(1, search_max + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var wx: int = posmod(world_tile_x + dx, world_width)
				var wy: int = clamp(world_tile_y + dy, 0, world_height - 1)
				if not _is_world_tile_enterable(wx, wy):
					continue
				best = Vector2i(wx, wy)
				found = true
				break
			if found:
				break
		if found:
			break
	if not found:
		return
	world_tile_x = best.x
	world_tile_y = best.y
	local_x = REGION_SIZE >> 1
	local_y = REGION_SIZE >> 1
	_location_biome_override_id = -1

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
	_tick_walk_prefetch(delta, dir)
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

func _tick_walk_prefetch(delta: float, move_dir: Vector2i) -> void:
	if delta <= 0.0 or _chunk_cache == null:
		return
	if not _chunk_cache.has_method("prefetch_for_view"):
		return
	_walk_prefetch_accum += delta
	if _walk_prefetch_accum < _CHUNK_WALK_PREFETCH_INTERVAL:
		return
	_walk_prefetch_accum = fposmod(_walk_prefetch_accum, _CHUNK_WALK_PREFETCH_INTERVAL)
	var lookahead_x: int = 0
	var lookahead_y: int = 0
	if move_dir != Vector2i.ZERO:
		lookahead_x = move_dir.x * int(round(float(VIEW_W) * 0.30))
		lookahead_y = move_dir.y * int(round(float(VIEW_H) * 0.30))
	var prefetch_center_x: int = _center_gx + lookahead_x
	var prefetch_center_y: int = _center_gy + lookahead_y
	var half_w: int = int(floor(float(VIEW_W) * 0.5))
	var half_h: int = int(floor(float(VIEW_H) * 0.5))
	var origin_x: int = prefetch_center_x - half_w - VIEW_PAD
	var origin_y: int = prefetch_center_y - half_h - VIEW_PAD
	_chunk_cache.prefetch_for_view(
		origin_x,
		origin_y,
		RENDER_W,
		RENDER_H,
		_CHUNK_PREFETCH_MARGIN_CHUNKS + 1,
		_CHUNK_WALK_PREFETCH_BUDGET_CHUNKS,
		_CHUNK_WALK_PREFETCH_BUDGET_US
	)

func _update_dynamic_layers() -> void:
	if _gpu_view == null or gpu_map == null:
		return
	var solar: Dictionary = _get_solar_params()
	# Keep solar basis anchored to the currently centered world cell so relief/cloud
	# shading remains world-space stable while smooth camera scroll offsets change.
	var lon_phi: Vector2 = _get_fixed_lon_phi(_center_gx, _center_gy)
	var half_w: int = int(floor(float(VIEW_W) * 0.5))
	var half_h: int = int(floor(float(VIEW_H) * 0.5))
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
	var gxw: int = _wrap_global_x(gx)
	var gyc: int = _clamp_global_y(gy)
	var house_key: String = _global_cell_key(gxw, gyc)
	if _visible_house_wall_blocks.has(house_key):
		return true
	if _chunk_cache == null:
		return false
	var cell: Dictionary = _chunk_cache.get_cell(gxw, gyc)
	var f: int = int(cell.get("flags", 0))
	return (f & RegionalChunkGenerator.FLAG_BLOCKED) != 0

func _sync_location_from_player_pos() -> void:
	var gx_int: int = _wrap_global_x(int(floor(_player_gx)))
	var gy_int: int = _clamp_global_y(int(floor(_player_gy)))
	_center_gx = gx_int
	_center_gy = gy_int
	var new_world_x: int = gx_int // REGION_SIZE
	var new_world_y: int = gy_int // REGION_SIZE
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
	var wx: int = gxw // REGION_SIZE
	var wy: int = gyc // REGION_SIZE
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
	if String(poi_info.get("type", "")) == "House" and not VariantCasts.to_bool(poi_info.get("entry_marker", false)):
		footer_label.text = "Use the house door to enter."
		return
	var enter_world_x: int = int(poi_info.get("origin_world_x", world_tile_x))
	var enter_world_y: int = int(poi_info.get("origin_world_y", world_tile_y))
	var enter_local_x: int = int(poi_info.get("origin_local_x", local_x))
	var enter_local_y: int = int(poi_info.get("origin_local_y", local_y))
	var enter_biome_id: int = _get_world_biome_id(enter_world_x, enter_world_y)
	var payload: Dictionary = {
		"type": String(poi_info.get("type", "POI")),
		"id": String(poi_info.get("id", "")),
		"seed_key": String(poi_info.get("seed_key", "")),
		"is_shop": VariantCasts.to_bool(poi_info.get("is_shop", false)),
		"service_type": String(poi_info.get("service_type", "")),
		"faction_id": String(poi_info.get("faction_id", "")),
		"faction_rank_required": int(poi_info.get("faction_rank_required", 0)),
		"world_x": enter_world_x,
		"world_y": enter_world_y,
		"local_x": enter_local_x,
		"local_y": enter_local_y,
		"biome_id": enter_biome_id,
		"biome_name": _biome_name_for_id(enter_biome_id),
	}
	if game_state != null and game_state.has_method("register_poi_discovery"):
		game_state.register_poi_discovery(payload)
	if scene_router != null and scene_router.has_method("goto_local"):
		scene_router.goto_local(payload)
	else:
		if game_state != null and game_state.has_method("queue_poi"):
			game_state.queue_poi(payload)
			if game_state.has_method("set_location"):
				game_state.set_location(
					"local",
					int(payload["world_x"]),
					int(payload["world_y"]),
					int(payload["local_x"]),
					int(payload["local_y"]),
					int(payload["biome_id"]),
					String(payload["biome_name"])
				)
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
		prefetch_generated = int(_chunk_cache.prefetch_for_view(
			origin_x,
			origin_y,
			RENDER_W,
			RENDER_H,
			_CHUNK_PREFETCH_MARGIN_CHUNKS,
			_CHUNK_PREFETCH_BUDGET_CHUNKS,
			_CHUNK_PREFETCH_BUDGET_US
		))
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
	_overlay_house_footprints(
		origin_x,
		origin_y,
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
		prefetch_generated = int(_chunk_cache.prefetch_for_view(
			origin_x,
			origin_y,
			RENDER_W,
			RENDER_H,
			_CHUNK_PREFETCH_MARGIN_CHUNKS,
			_CHUNK_PREFETCH_BUDGET_CHUNKS,
			_CHUNK_PREFETCH_BUDGET_US
		))
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
	_overlay_house_footprints(
		origin_x,
		origin_y,
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
	var field_cell_count: int = RENDER_W * RENDER_H
	if _field_height_raw.size() != field_cell_count:
		_field_height_raw.resize(field_cell_count)
		_field_temp.resize(field_cell_count)
		_field_moist.resize(field_cell_count)
		_field_biome.resize(field_cell_count)
		_field_land.resize(field_cell_count)
		_field_beach.resize(field_cell_count)
	if _field_height_raw_scratch.size() != field_cell_count:
		_field_height_raw_scratch.resize(field_cell_count)
		_field_temp_scratch.resize(field_cell_count)
		_field_moist_scratch.resize(field_cell_count)
		_field_biome_scratch.resize(field_cell_count)
		_field_land_scratch.resize(field_cell_count)
		_field_beach_scratch.resize(field_cell_count)

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
	var climate_biome: int = b

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
	# Render deterministic terrain clutter markers so regional landscapes read less flat.
	var obj_id: int = int(cell.get("obj", RegionalChunkGenerator.Obj.NONE))
	if b < 200 and is_land_cell == 1:
		match obj_id:
			RegionalChunkGenerator.Obj.TREE:
				b = MARKER_TREE_CANOPY
				is_beach_cell = 0
			RegionalChunkGenerator.Obj.SHRUB:
				b = MARKER_SHRUB_CLUSTER
			RegionalChunkGenerator.Obj.BOULDER:
				b = MARKER_BOULDER
				is_beach_cell = 0
			RegionalChunkGenerator.Obj.REED:
				b = MARKER_REEDS

	var is_marker_cell: bool = b >= 200
	var patch_x_a: int = int(floor(float(gx) / 7.0))
	var patch_y_a: int = int(floor(float(gy) / 7.0))
	var patch_x_b: int = int(floor(float(gx) / 19.0))
	var patch_y_b: int = int(floor(float(gy) / 19.0))
	var n_patch_a: float = _rand01_xy(patch_x_a, patch_y_a, 151) - 0.5
	var n_patch_b: float = _rand01_xy(patch_x_b, patch_y_b, 197) - 0.5
	var n_micro_t: float = _rand01_xy(gx, gy, 11) - 0.5
	var n_micro_m: float = _rand01_xy(gx, gy, 29) - 0.5
	var n_micro_h: float = _rand01_xy(gx, gy, 233) - 0.5

	var visual_h: float = h
	if is_land_cell == 1 and not is_marker_cell:
		visual_h = h + n_patch_a * 0.018 + n_patch_b * 0.010 + n_micro_h * 0.006
	elif b == MARKER_TREE_CANOPY or b == MARKER_PLAYER_UNDER_CANOPY:
		visual_h = max(h + n_patch_a * 0.010 + n_micro_h * 0.004, 0.10)
	elif b == MARKER_SHRUB_CLUSTER or b == MARKER_REEDS:
		visual_h = max(h + n_patch_a * 0.008 + n_micro_h * 0.003, 0.06)
	elif b == MARKER_BOULDER:
		visual_h = max(h + n_patch_a * 0.006 + n_micro_h * 0.003, 0.08)
	out_height_raw[idx] = visual_h
	out_biome[idx] = b
	out_land[idx] = is_land_cell
	out_beach[idx] = is_beach_cell

	var base_t: float = _visual_temp_for_biome(climate_biome)
	var base_m: float = _visual_moist_for_biome(climate_biome)
	var elev_bias: float = clamp(h * 0.35, -0.20, 0.20)
	var jt: float = n_patch_a * 0.16 + n_patch_b * 0.10 + n_micro_t * 0.08 + elev_bias * 0.30
	var jm: float = -n_patch_a * 0.10 + n_patch_b * 0.16 + n_micro_m * 0.08 - elev_bias * 0.18
	var jitter_scale: float = 1.0
	if is_land_cell == 0:
		jitter_scale = 0.35
	if is_marker_cell:
		jitter_scale = 0.12
	out_temp[idx] = clamp(base_t + jt * jitter_scale, 0.0, 1.0)
	out_moist[idx] = clamp(base_m + jm * jitter_scale, 0.0, 1.0)

func _house_layout_for_poi(poi: Dictionary) -> Dictionary:
	if typeof(poi) != TYPE_DICTIONARY:
		return {}
	var poi_id: String = String(poi.get("id", ""))
	if poi_id.is_empty():
		return {}
	var is_shop_i: int = 1 if VariantCasts.to_bool(poi.get("is_shop", false)) else 0
	var service_type: String = String(poi.get("service_type", "")).to_lower().strip_edges()
	if service_type.is_empty():
		service_type = "shop" if is_shop_i == 1 else "home"
	var cache_key: String = "%d|%s|%d|%s" % [world_seed_hash, poi_id, is_shop_i, service_type]
	var cached: Variant = _house_layout_cache.get(cache_key, {})
	if typeof(cached) == TYPE_DICTIONARY and not (cached as Dictionary).is_empty():
		return cached as Dictionary
	var layout: Dictionary = LocalAreaGenerator.generate_house_layout(
		world_seed_hash,
		poi_id,
		LocalAreaGenerator.HOUSE_MAP_W,
		LocalAreaGenerator.HOUSE_MAP_H,
		is_shop_i == 1,
		service_type
	)
	if not layout.is_empty():
		_house_layout_cache[cache_key] = layout.duplicate(true)
		if _house_layout_cache.size() > 256:
			var first_key: Variant = _house_layout_cache.keys()[0]
			_house_layout_cache.erase(first_key)
	var out_v: Variant = _house_layout_cache.get(cache_key, layout)
	if typeof(out_v) == TYPE_DICTIONARY:
		return out_v as Dictionary
	return layout

func _global_cell_key(gx: int, gy: int) -> String:
	return "%d,%d" % [_wrap_global_x(gx), _clamp_global_y(gy)]

func _house_layout_fits_dry_terrain(
	anchor_gx: int,
	anchor_gy: int,
	anchor_x: int,
	anchor_y: int,
	tiles: PackedByteArray,
	hw: int,
	hh: int,
	max_global_y: int
) -> bool:
	if _chunk_cache == null:
		return true
	var total_cells: int = 0
	var water_cells: int = 0
	var blocked_cells: int = 0
	var door_ok: bool = false
	for hy in range(hh):
		for hx in range(hw):
			var idx: int = hx + hy * hw
			var tile_id: int = int(tiles[idx])
			if tile_id == int(LocalAreaTiles.Tile.OUTSIDE):
				continue
			var gx_target: int = _wrap_global_x(anchor_gx + (hx - anchor_x))
			var gy_target: int = anchor_gy + (hy - anchor_y)
			if gy_target < 0 or gy_target > max_global_y:
				return false
			var cell: Dictionary = _chunk_cache.get_cell(gx_target, gy_target)
			var ground: int = int(cell.get("ground", RegionalChunkGenerator.Ground.GRASS))
			var flags: int = int(cell.get("flags", 0))
			var is_water: bool = (
				ground == RegionalChunkGenerator.Ground.WATER_DEEP
				or ground == RegionalChunkGenerator.Ground.WATER_SHALLOW
			)
			if is_water:
				water_cells += 1
			if (flags & RegionalChunkGenerator.FLAG_BLOCKED) != 0 and not is_water:
				blocked_cells += 1
			total_cells += 1
			if tile_id == int(LocalAreaTiles.Tile.DOOR):
				door_ok = not is_water and ((flags & RegionalChunkGenerator.FLAG_BLOCKED) == 0)
	if total_cells <= 0:
		return false
	if not door_ok:
		return false
	var water_ratio: float = float(water_cells) / float(total_cells)
	var blocked_ratio: float = float(blocked_cells) / float(total_cells)
	return water_ratio <= 0.08 and blocked_ratio <= 0.18

func _overlay_house_footprints(
	origin_x: int,
	origin_y: int,
	out_height_raw: PackedFloat32Array,
	_out_temp: PackedFloat32Array,
	_out_moist: PackedFloat32Array,
	out_biome: PackedInt32Array,
	out_land: PackedInt32Array,
	out_beach: PackedInt32Array
) -> void:
	_visible_poi_overrides.clear()
	_visible_house_wall_blocks.clear()
	if world_width <= 0 or world_height <= 0:
		return
	var period_x: int = world_width * REGION_SIZE
	if period_x <= 0:
		return
	var max_global_y: int = world_height * REGION_SIZE - 1
	var margin_x: int = 36
	var margin_y: int = 20
	var scan_y0: int = max(0, origin_y - margin_y)
	var scan_y1: int = min(max_global_y, origin_y + RENDER_H - 1 + margin_y)
	var scan_x0: int = origin_x - margin_x
	var scan_x1: int = origin_x + RENDER_W - 1 + margin_x
	var seen_anchor_keys: Dictionary = {}
	var anchors: Array[Dictionary] = []

	for gy_scan in range(scan_y0, scan_y1 + 1):
		var wy_scan: int = clamp(int(floor(float(gy_scan) / float(REGION_SIZE))), 0, world_height - 1)
		var ly_scan: int = gy_scan - wy_scan * REGION_SIZE
		if ly_scan % 12 != 0:
			continue
		for gx_scan in range(scan_x0, scan_x1 + 1):
			var gx_wrapped: int = _wrap_global_x(gx_scan)
			var wx_scan: int = int(floor(float(gx_wrapped) / float(REGION_SIZE)))
			var lx_scan: int = gx_wrapped - wx_scan * REGION_SIZE
			if lx_scan % 12 != 0:
				continue
			var anchor_key: String = "%d,%d" % [gx_wrapped, gy_scan]
			if seen_anchor_keys.has(anchor_key):
				continue
			seen_anchor_keys[anchor_key] = true
			var biome_id: int = _get_world_biome_id(wx_scan, wy_scan)
			var poi: Dictionary = PoiRegistry.get_poi_at(world_seed_hash, wx_scan, wy_scan, lx_scan, ly_scan, biome_id)
			if poi.is_empty() or String(poi.get("type", "")) != "House":
				continue
			anchors.append({
				"gx": gx_wrapped,
				"gy": gy_scan,
				"wx": wx_scan,
				"wy": wy_scan,
				"lx": lx_scan,
				"ly": ly_scan,
				"poi": poi.duplicate(true),
			})

	var origin_wrap_x: int = _wrap_global_x(origin_x)
	for av in anchors:
		if typeof(av) != TYPE_DICTIONARY:
			continue
		var a: Dictionary = av as Dictionary
		var poi_d: Dictionary = a.get("poi", {})
		var layout: Dictionary = _house_layout_for_poi(poi_d)
		if layout.is_empty():
			continue
		var tiles_v: Variant = layout.get("tiles", PackedByteArray())
		if not (tiles_v is PackedByteArray):
			continue
		var tiles: PackedByteArray = tiles_v as PackedByteArray
		var hw: int = int(layout.get("w", LocalAreaGenerator.HOUSE_MAP_W))
		var hh: int = int(layout.get("h", LocalAreaGenerator.HOUSE_MAP_H))
		if hw <= 0 or hh <= 0 or tiles.size() != hw * hh:
			continue
		var door_v: Variant = layout.get("door_pos", Vector2i(0, 0))
		var door_pos: Vector2i = door_v if door_v is Vector2i else Vector2i(0, 0)
		var anchor_x: int = int(layout.get("anchor_x", max(0, door_pos.x - 1)))
		var anchor_y: int = int(layout.get("anchor_y", door_pos.y))
		var agx: int = int(a.get("gx", 0))
		var agy: int = int(a.get("gy", 0))
		var awx: int = int(a.get("wx", 0))
		var awy: int = int(a.get("wy", 0))
		var alx: int = int(a.get("lx", 0))
		var aly: int = int(a.get("ly", 0))
		if not _house_layout_fits_dry_terrain(agx, agy, anchor_x, anchor_y, tiles, hw, hh, max_global_y):
			continue

		for hy in range(hh):
			for hx in range(hw):
				var tidx: int = hx + hy * hw
				var tile_id: int = int(tiles[tidx])
				if tile_id == int(LocalAreaTiles.Tile.OUTSIDE):
					continue
				var is_boundary: bool = false
				for off in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var nx: int = hx + int(off.x)
					var ny: int = hy + int(off.y)
					if nx < 0 or ny < 0 or nx >= hw or ny >= hh:
						is_boundary = true
						break
					var nidx: int = nx + ny * hw
					if int(tiles[nidx]) == int(LocalAreaTiles.Tile.OUTSIDE):
						is_boundary = true
						break
				var marker: int = LocalAreaTiles.MARKER_FLOOR
				var height_hint: float = 0.05
				var is_entry_marker: bool = false
				if tile_id == int(LocalAreaTiles.Tile.DOOR):
					marker = LocalAreaTiles.MARKER_DOOR
					height_hint = 0.08
					is_entry_marker = true
				elif is_boundary:
					marker = LocalAreaTiles.MARKER_WALL
					height_hint = 0.13

				var gx_target: int = _wrap_global_x(agx + (hx - anchor_x))
				var gy_target: int = agy + (hy - anchor_y)
				if gy_target < 0 or gy_target > max_global_y:
					continue
				if is_boundary and not is_entry_marker:
					_visible_house_wall_blocks[_global_cell_key(gx_target, gy_target)] = true
				var sx: int = posmod(gx_target - origin_wrap_x, period_x)
				if sx < 0 or sx >= RENDER_W:
					continue
				var sy: int = gy_target - origin_y
				if sy < 0 or sy >= RENDER_H:
					continue
				var ridx: int = sx + sy * RENDER_W
				if ridx < 0 or ridx >= out_biome.size():
					continue
				out_biome[ridx] = marker
				out_land[ridx] = 1
				out_beach[ridx] = 0
				out_height_raw[ridx] = max(out_height_raw[ridx], height_hint)
				if is_entry_marker:
					var gkey: String = "%d,%d" % [gx_target, gy_target]
					if not _visible_poi_overrides.has(gkey):
						var info: Dictionary = poi_d.duplicate(true)
						info["origin_world_x"] = awx
						info["origin_world_y"] = awy
						info["origin_local_x"] = alx
						info["origin_local_y"] = aly
						info["entry_marker"] = true
						_visible_poi_overrides[gkey] = info

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
		if "set_noise_world_origin" in gpu_map:
			gpu_map.set_noise_world_origin(float(origin_x), float(origin_y))
		var render_biome: PackedInt32Array = _field_biome.duplicate()
		var render_land: PackedInt32Array = _field_land.duplicate()
		var render_beach: PackedInt32Array = _field_beach.duplicate()
		var center_x: int = (VIEW_W >> 1) + VIEW_PAD
		var center_y: int = (VIEW_H >> 1) + VIEW_PAD
		var center_idx: int = center_x + center_y * RENDER_W
		if center_idx >= 0 and center_idx < render_biome.size():
			var player_marker: int = MARKER_PLAYER
			if int(render_biome[center_idx]) == MARKER_TREE_CANOPY:
				player_marker = MARKER_PLAYER_UNDER_CANOPY
			render_biome[center_idx] = player_marker
		if center_idx >= 0 and center_idx < render_land.size():
			# Render-only override: keep player marker visible while wading on shallow water.
			render_land[center_idx] = 1
		if center_idx >= 0 and center_idx < render_beach.size():
			render_beach[center_idx] = 0
		var field_payload: Dictionary = {
			"height_raw": _field_height_raw,
			"temp": _field_temp,
			"moist": _field_moist,
			"biome": render_biome,
			"land": render_land,
			"beach": render_beach,
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
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var gx: int = _wrap_global_x(_center_gx + ox)
			var gy: int = _clamp_global_y(_center_gy + oy)
			var tx: int = int(floor(float(gx) / float(REGION_SIZE)))
			var ty: int = int(floor(float(gy) / float(REGION_SIZE)))
			var lx: int = gx - tx * REGION_SIZE
			var ly: int = gy - ty * REGION_SIZE
			var poi: Dictionary = _poi_info_at(tx, ty, lx, ly)
			if not poi.is_empty():
				var poi_name: String = String(poi.get("type", "POI"))
				if poi_name == "House":
					var svc: String = String(poi.get("service_type", "")).to_lower()
					if svc == "shop":
						poi_name = "Shop"
					elif svc == "inn":
						poi_name = "Inn"
					elif svc == "temple":
						poi_name = "Temple"
					elif svc == "faction_hall":
						poi_name = "Faction Hall"
					elif svc == "town_hall":
						poi_name = "Town Hall"
				return "Nearby POI: %s (step onto it to enter)." % poi_name
	return ""

func _wrapped_center_delta_x(new_center_x: int, old_center_x: int) -> int:
	var period: int = world_width * REGION_SIZE
	if period <= 0:
		return new_center_x - old_center_x
	var d: int = new_center_x - old_center_x
	var half: int = period >> 1
	if d > half:
		d -= period
	elif d < -half:
		d += period
	return d

func _sample_world_cell(_offset_x: int, _offset_y: int) -> Dictionary:
	# Deprecated: replaced by `_chunk_cache` sampling in `_render_view()`.
	return {}

func _get_world_weather_field(field_name: String) -> PackedFloat32Array:
	var world_cell_count: int = world_width * world_height
	if world_cell_count <= 0:
		return PackedFloat32Array()
	if game_state != null:
		var gv: Variant = game_state.get(field_name)
		if gv is PackedFloat32Array:
			var g_arr: PackedFloat32Array = gv
			if g_arr.size() == world_cell_count:
				return g_arr
	if startup_state != null:
		var sv: Variant = startup_state.get(field_name)
		if sv is PackedFloat32Array:
			var s_arr: PackedFloat32Array = sv
			if s_arr.size() == world_cell_count:
				return s_arr
	return PackedFloat32Array()

func _global_to_world_tile_f(gx: float, gy: float) -> Vector2:
	var period_x_cells: float = float(max(1, world_width * REGION_SIZE))
	var span_y_cells: float = float(max(1, world_height * REGION_SIZE))
	var wrapped_x: float = fposmod(gx, period_x_cells)
	if wrapped_x < 0.0:
		wrapped_x += period_x_cells
	var clamped_y: float = clamp(gy, 0.0, span_y_cells - 1.0)
	return Vector2(
		wrapped_x / float(max(1, REGION_SIZE)),
		clamped_y / float(max(1, REGION_SIZE))
	)

func _sample_world_field_point(field: PackedFloat32Array, wx: int, wy: int, fallback: float) -> float:
	var world_cell_count: int = world_width * world_height
	if world_cell_count <= 0 or field.size() != world_cell_count:
		return fallback
	var sx: int = posmod(wx, max(1, world_width))
	var sy: int = clamp(wy, 0, max(1, world_height) - 1)
	var idx: int = sx + sy * world_width
	if idx < 0 or idx >= field.size():
		return fallback
	return float(field[idx])

func _sample_world_field_bilinear(field: PackedFloat32Array, tile_x: float, tile_y: float, fallback: float) -> float:
	var world_cell_count: int = world_width * world_height
	if world_cell_count <= 0 or field.size() != world_cell_count:
		return fallback
	var x0: int = int(floor(tile_x))
	var y0: int = int(floor(tile_y))
	var tx: float = clamp(tile_x - float(x0), 0.0, 1.0)
	var ty: float = clamp(tile_y - float(y0), 0.0, 1.0)
	var v00: float = _sample_world_field_point(field, x0, y0, fallback)
	var v10: float = _sample_world_field_point(field, x0 + 1, y0, fallback)
	var v01: float = _sample_world_field_point(field, x0, y0 + 1, fallback)
	var v11: float = _sample_world_field_point(field, x0 + 1, y0 + 1, fallback)
	var vx0: float = lerp(v00, v10, tx)
	var vx1: float = lerp(v01, v11, tx)
	return lerp(vx0, vx1, ty)

func _sample_world_weather_for_region(
	origin_x: int,
	origin_y: int,
	fallback_cloud_cover: float,
	fallback_wind_x: float,
	fallback_wind_y: float
) -> Dictionary:
	var clouds_field: PackedFloat32Array = _get_world_weather_field("world_cloud_cover")
	var wind_u_field: PackedFloat32Array = _get_world_weather_field("world_wind_u")
	var wind_v_field: PackedFloat32Array = _get_world_weather_field("world_wind_v")
	var center_x: float = float(origin_x) + float(RENDER_W) * 0.5
	var center_y: float = float(origin_y) + float(RENDER_H) * 0.5
	var sx: float = float(RENDER_W) * 0.32
	var sy: float = float(RENDER_H) * 0.32
	var sample_offsets: Array[Vector2] = [
		Vector2(0.0, 0.0),
		Vector2(-sx, -sy),
		Vector2(sx, -sy),
		Vector2(-sx, sy),
		Vector2(sx, sy),
	]
	var cloud_sum: float = 0.0
	var wind_u_sum: float = 0.0
	var wind_v_sum: float = 0.0
	for off in sample_offsets:
		var tile_pos: Vector2 = _global_to_world_tile_f(center_x + off.x, center_y + off.y)
		cloud_sum += _sample_world_field_bilinear(clouds_field, tile_pos.x, tile_pos.y, fallback_cloud_cover)
		wind_u_sum += _sample_world_field_bilinear(wind_u_field, tile_pos.x, tile_pos.y, fallback_wind_x)
		wind_v_sum += _sample_world_field_bilinear(wind_v_field, tile_pos.x, tile_pos.y, fallback_wind_y)
	var denom: float = float(max(1, sample_offsets.size()))
	return {
		"cloud_cover": clamp(cloud_sum / denom, 0.0, 1.0),
		"wind_u": wind_u_sum / denom,
		"wind_v": wind_v_sum / denom,
	}

func _smoothstep01(t: float) -> float:
	var x: float = clamp(t, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func _poi_info_at(tx: int, ty: int, lx: int, ly: int) -> Dictionary:
	var gx: int = _wrap_global_x(tx * REGION_SIZE + lx)
	var gy: int = _clamp_global_y(ty * REGION_SIZE + ly)
	var key: String = "%d,%d" % [gx, gy]
	var vv: Variant = _visible_poi_overrides.get(key, {})
	if typeof(vv) == TYPE_DICTIONARY:
		return (vv as Dictionary).duplicate(true)
	var direct: Dictionary = PoiRegistry.get_poi_at(world_seed_hash, tx, ty, lx, ly, _get_world_biome_id(tx, ty))
	if direct.is_empty():
		return {}
	# Houses should be entered from stamped door markers only.
	if String(direct.get("type", "")) == "House":
		return {}
	return direct

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
	var fallback_wind_x: float = 0.08 + (temp - 0.5) * 0.10
	var fallback_wind_y: float = 0.03 + (moist - 0.5) * 0.08
	var fallback_cloud_cover: float = clamp(0.18 + moist * 0.62, 0.0, 1.0)
	var weather: Dictionary = _sample_world_weather_for_region(
		origin_x,
		origin_y,
		fallback_cloud_cover,
		fallback_wind_x,
		fallback_wind_y
	)
	var cloud_cover: float = clamp(float(weather.get("cloud_cover", fallback_cloud_cover)), 0.0, 1.0)
	var wind_u: float = float(weather.get("wind_u", fallback_wind_x))
	var wind_v: float = float(weather.get("wind_v", fallback_wind_y))
	var wind_vec: Vector2 = Vector2(wind_u, wind_v)
	var wind_x: float = fallback_wind_x
	var wind_y: float = fallback_wind_y
	if wind_vec.length() > 0.0001:
		var wind_dir: Vector2 = wind_vec.normalized()
		var wind_speed: float = clamp(0.06 + wind_vec.length() * 0.03, 0.06, 0.26)
		wind_x = wind_dir.x * wind_speed
		wind_y = wind_dir.y * wind_speed
	var coverage_threshold: float = clamp(1.05 - cloud_cover * 1.08, 0.03, 0.96)
	var overcast_floor: float = _smoothstep01((cloud_cover - 0.56) / 0.34) * 0.97
	var contrast: float = lerp(1.22, 0.74, cloud_cover)
	var cloud_scale: float = lerp(0.014, 0.028, clamp(0.25 + cloud_cover * 0.75, 0.0, 1.0))
	var morph_strength: float = lerp(0.26, 0.52, cloud_cover)
	return {
		"enabled": true,
		"origin_x": origin_x,
		"origin_y": origin_y,
		"world_period_x": world_width * REGION_SIZE,
		"world_height": world_height * REGION_SIZE,
		"scale": cloud_scale,
		"wind_x": wind_x,
		"wind_y": wind_y,
		"coverage": coverage_threshold,
		"contrast": contrast,
		"overcast_floor": clamp(overcast_floor, 0.0, 0.94),
		"morph_strength": morph_strength,
		"sim_days_scale": 512.0,
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
	_apply_scroll_offset()

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
