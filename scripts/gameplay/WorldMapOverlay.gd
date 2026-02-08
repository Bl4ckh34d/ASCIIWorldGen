extends CanvasLayer

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")

signal closed

@onready var status_label: Label = %StatusLabel
@onready var map_label: RichTextLabel = %MapLabel
@onready var footer_label: Label = %FooterLabel

var game_state: Node = null
var game_events: Node = null
var scene_router: Node = null

var _cursor_x: int = 0
var _cursor_y: int = 0

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	game_events = get_node_or_null("/root/GameEvents")
	scene_router = get_node_or_null("/root/SceneRouter")
	visible = false
	set_process_unhandled_input(true)

func open_overlay() -> void:
	if game_state == null or not game_state.has_method("has_world_snapshot") or not bool(game_state.has_world_snapshot()):
		return
	var loc: Dictionary = game_state.get_location() if game_state.has_method("get_location") else {}
	_cursor_x = int(loc.get("world_x", 0))
	_cursor_y = int(loc.get("world_y", 0))
	visible = true
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
	if game_state == null:
		return
	var w: int = max(1, int(game_state.world_width))
	var h: int = max(1, int(game_state.world_height))
	_cursor_x = posmod(_cursor_x + dx, max(1, w))
	_cursor_y = clamp(_cursor_y + dy, 0, max(1, h) - 1)
	_refresh()

func _try_fast_travel() -> void:
	if game_state == null or scene_router == null:
		return
	if not game_state.has_method("is_world_tile_visited") or not bool(game_state.is_world_tile_visited(_cursor_x, _cursor_y)):
		_set_footer("Cannot fast travel: tile not visited.")
		return
	var biome_id: int = int(game_state.get_world_biome_id(_cursor_x, _cursor_y)) if game_state.has_method("get_world_biome_id") else -1
	if biome_id == 0 or biome_id == 1:
		_set_footer("Cannot fast travel to ocean/ice.")
		return
	var loc: Dictionary = game_state.get_location() if game_state.has_method("get_location") else {}
	var cur_x: int = int(loc.get("world_x", 0))
	var cur_y: int = int(loc.get("world_y", 0))
	var w: int = max(1, int(game_state.world_width))
	var dx_wrap: int = abs(_cursor_x - cur_x)
	if w > 0:
		dx_wrap = min(dx_wrap, w - dx_wrap)
	var dy: int = abs(_cursor_y - cur_y)
	var dist: int = dx_wrap + dy
	var travel_minutes: int = max(5, dist * 60)
	if game_state.has_method("advance_world_time"):
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
	if map_label:
		map_label.text = _render_world_map_bbcode()

func _render_world_map_bbcode() -> String:
	var w: int = int(game_state.world_width)
	var h: int = int(game_state.world_height)
	var biomes: PackedInt32Array = game_state.world_biome_ids
	if w <= 0 or h <= 0 or biomes.size() != w * h:
		return "No world snapshot available."
	var visited: Dictionary = {}
	if game_state.world_flags != null:
		visited = game_state.world_flags.visited_world_tiles
	var loc: Dictionary = game_state.get_location() if game_state.has_method("get_location") else {}
	var px: int = int(loc.get("world_x", 0))
	var py: int = int(loc.get("world_y", 0))
	var lines: PackedStringArray = PackedStringArray()
	for y in range(h):
		var row: String = ""
		for x in range(w):
			var idx: int = x + y * w
			var bid: int = int(biomes[idx])
			var is_player: bool = (x == px and y == py)
			var is_cursor: bool = (x == _cursor_x and y == _cursor_y)
			var key: String = "%d,%d" % [x, y]
			var is_visited: bool = bool(visited.get(key, false))
			var vis: Dictionary = _glyph_for_biome(bid)
			var glyph: String = String(vis.get("glyph", "."))
			var color: String = String(vis.get("color", "#7CB56A"))
			if not is_visited:
				color = "#606060"
			if is_player:
				glyph = "@"
				color = "#FFF5A1"
			elif is_cursor:
				glyph = "X"
				color = "#FBE58B"
			row += "[color=%s]%s[/color]" % [color, glyph]
		lines.append(row)
	return "\n".join(lines)

func _glyph_for_biome(biome_id: int) -> Dictionary:
	# Macro map glyphs (simple).
	if biome_id == 0 or biome_id == 1:
		return {"glyph": "~", "color": "#2A6FB0"}
	if biome_id == 2:
		return {"glyph": "`", "color": "#E4D7A1"}
	if biome_id == 10 or biome_id == 23:
		return {"glyph": ";", "color": "#6A8F5D"}
	if _is_forest_biome(biome_id):
		return {"glyph": "T", "color": "#3C8F52"}
	if _is_mountain_biome(biome_id):
		return {"glyph": "^", "color": "#A2A5AA"}
	if _is_desert_biome(biome_id):
		return {"glyph": "`", "color": "#D9C37A"}
	if biome_id == 16 or biome_id == 34 or biome_id == 41:
		return {"glyph": "n", "color": "#7CA06A"}
	return {"glyph": ".", "color": "#7CB56A"}

func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28

func _set_footer(text_value: String) -> void:
	if footer_label:
		footer_label.text = text_value
