# File: res://scripts/ui/CursorOverlay.gd
extends Control

## Efficient cursor overlay for the ASCII world map
## Runs in its own process to be lag-resistant during simulation

signal tile_hovered(x: int, y: int)
signal mouse_exited_map()

var world_width: int = 0
var world_height: int = 0
var char_width: float = 0.0
var char_height: float = 0.0

var cursor_rect: ColorRect
var cursor_label: Label
var is_mouse_over: bool = false
var draw_rect_enabled: bool = true
var last_tile_x: int = -1
var last_tile_y: int = -1
var main_cached: Node = null

func _ready() -> void:
	# Cache main node reference for performance
	main_cached = get_tree().get_first_node_in_group("MainRoot")
	
	# Create the cursor visual elements
	cursor_rect = ColorRect.new()
	cursor_rect.visible = false
	cursor_rect.color = Color(1, 0, 0, 0.8)  # Semi-transparent red
	cursor_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor_rect.z_index = 2000
	add_child(cursor_rect)
	
	cursor_label = Label.new()
	cursor_label.visible = false
	cursor_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor_label.z_index = 2001
	cursor_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cursor_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cursor_label.add_theme_color_override("font_color", Color(0, 0, 0, 1))
	add_child(cursor_label)
	
	# Handle mouse events
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

func setup_dimensions(width: int, height: int, char_w: float, char_h: float) -> void:
	world_width = width
	world_height = height
	char_width = char_w
	char_height = char_h
	# no-op debug removed

func set_draw_enabled(enabled: bool) -> void:
	draw_rect_enabled = enabled
	if not enabled:
		cursor_rect.visible = false
		cursor_label.visible = false

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and is_mouse_over:
		_handle_mouse_motion(event.position)

var main: Node = null

func _handle_mouse_motion(pos: Vector2) -> void:
	if char_width <= 0.0 or char_height <= 0.0:
		return

	# Hide when outside actual map content area
	var map_px_w: float = float(world_width) * char_width
	var map_px_h: float = float(world_height) * char_height
	var inside: bool = pos.x >= 0.0 and pos.y >= 0.0 and pos.x < map_px_w and pos.y < map_px_h
	if not inside:
		cursor_rect.visible = false
		cursor_label.visible = false
		# Forward clear to GPU renderer, via cached MainRoot
		if main_cached and main_cached.has_method("_gpu_clear_hover"):
			main_cached._gpu_clear_hover()
		# Emit exit-like signal for info panel clear (only if we were previously inside)
		if last_tile_x >= 0 or last_tile_y >= 0:
			emit_signal("mouse_exited_map")
			last_tile_x = -1
			last_tile_y = -1
		return

	var x: int = int(pos.x / char_width)
	var y: int = int(pos.y / char_height)
	
	# Clamp to valid coordinates
	x = clamp(x, 0, world_width - 1)
	y = clamp(y, 0, world_height - 1)
	
	# Only update if tile changed - major performance optimization
	if x != last_tile_x or y != last_tile_y:
		last_tile_x = x
		last_tile_y = y
		
		# Update cursor position (only if drawing locally) - use exact pixel alignment
		var cursor_pos = Vector2(float(x) * char_width, float(y) * char_height)
		if draw_rect_enabled:
			cursor_rect.position = cursor_pos
			cursor_rect.size = Vector2(char_width, char_height)
			cursor_rect.visible = true
		
		# Emit signal for info panel update (direct call, no defer for better responsiveness)
		emit_signal("tile_hovered", x, y)
		
		# Forward hover to GPU renderer if present for zero-lag overlay
		if main_cached and main_cached.has_method("_gpu_hover_cell"):
			main_cached._gpu_hover_cell(x, y)
	else:
		# Still update cursor visual position for smooth movement within same tile
		if draw_rect_enabled:
			var cursor_pos = Vector2(float(x) * char_width, float(y) * char_height)
			cursor_rect.position = cursor_pos
			cursor_rect.size = Vector2(char_width, char_height)
			cursor_rect.visible = true
	
	# Keep label disabled to reduce per-frame UI work
	cursor_label.visible = false


func _on_mouse_entered() -> void:
	is_mouse_over = true
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)

func _on_mouse_exited() -> void:
	is_mouse_over = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	cursor_rect.visible = false
	cursor_label.visible = false
	emit_signal("mouse_exited_map")
	last_tile_x = -1
	last_tile_y = -1
	if main_cached and main_cached.has_method("_gpu_clear_hover"):
		main_cached._gpu_clear_hover()

func hide_cursor() -> void:
	cursor_rect.visible = false
	cursor_label.visible = false

func apply_font(font: Font) -> void:
	if cursor_label:
		cursor_label.add_theme_font_override("font", font)
