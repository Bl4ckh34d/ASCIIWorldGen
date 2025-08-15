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

func _ready() -> void:
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
	
	# Set the overlay size to match the ASCII map exactly
	custom_minimum_size = Vector2(width * char_w, height * char_h)
	size = custom_minimum_size

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and is_mouse_over:
		_handle_mouse_motion(event.position)

func _handle_mouse_motion(pos: Vector2) -> void:
	if char_width <= 0.0 or char_height <= 0.0:
		return
		
	var x: int = int(pos.x / char_width)
	var y: int = int(pos.y / char_height)
	
	# Clamp to valid coordinates
	x = clamp(x, 0, world_width - 1)
	y = clamp(y, 0, world_height - 1)
	
	# Update cursor position
	var cursor_pos = Vector2(float(x) * char_width, float(y) * char_height)
	cursor_rect.position = cursor_pos
	cursor_rect.size = Vector2(char_width, char_height)
	cursor_rect.visible = true
	
	cursor_label.position = cursor_pos
	cursor_label.size = Vector2(char_width, char_height)
	cursor_label.text = "▓"  # Simple cursor character
	cursor_label.visible = true
	
	# Emit signal for info panel update (non-blocking, deferred)
	call_deferred("_emit_tile_signal", x, y)

func _emit_tile_signal(x: int, y: int) -> void:
	emit_signal("tile_hovered", x, y)

func _on_mouse_entered() -> void:
	is_mouse_over = true
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)

func _on_mouse_exited() -> void:
	is_mouse_over = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	cursor_rect.visible = false
	cursor_label.visible = false
	emit_signal("mouse_exited_map")

func hide_cursor() -> void:
	cursor_rect.visible = false
	cursor_label.visible = false

func apply_font(font: Font) -> void:
	if cursor_label:
		cursor_label.add_theme_font_override("font", font)