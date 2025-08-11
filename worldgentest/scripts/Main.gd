# File: res://worldgentest/scripts/Main.gd
extends Control

var play_button: Button
var reset_button: Button
var settings_button: Button
var ascii_map: RichTextLabel
var settings_dialog: Window

var is_running: bool = false
var generator: Object

func _ready() -> void:
	# Resolve nodes based on actual scene structure: TopBar/PlayPause, Reset, Settings
	play_button = get_node_or_null("TopBar/PlayPause")
	reset_button = get_node_or_null("TopBar/Reset")
	settings_button = get_node_or_null("TopBar/Settings")
	settings_dialog = get_node_or_null("SettingsDialog")
	# Create ASCII label under WorldView if not present
	var world_view := get_node_or_null("WorldView")
	ascii_map = get_node_or_null("WorldView/AsciiMap")
	if ascii_map == null and world_view != null:
		ascii_map = RichTextLabel.new()
		ascii_map.name = "AsciiMap"
		ascii_map.fit_content = true
		ascii_map.scroll_active = false
		ascii_map.selection_enabled = false
		ascii_map.bbcode_enabled = true
		world_view.add_child(ascii_map)
		ascii_map.anchor_left = 0
		ascii_map.anchor_top = 0
		ascii_map.anchor_right = 1
		ascii_map.anchor_bottom = 1
		ascii_map.grow_horizontal = Control.GROW_DIRECTION_BOTH
		ascii_map.grow_vertical = Control.GROW_DIRECTION_BOTH

	if play_button:
		play_button.pressed.connect(_on_play_pressed)
	if reset_button:
		reset_button.pressed.connect(_on_reset_pressed)
	if settings_button:
		settings_button.pressed.connect(_on_settings_pressed)
	if settings_dialog and settings_dialog.has_signal("settings_applied"):
		settings_dialog.connect("settings_applied", Callable(self, "_on_settings_applied"))
	# Load generator orchestrator
	generator = load("res://scripts/WorldGenerator.gd").new()
	_reset_view()

func _on_play_pressed() -> void:
	if not is_running:
		is_running = true
		play_button.text = "Pause"
		_generate_and_draw()
	else:
		is_running = false
		play_button.text = "Play"

func _on_reset_pressed() -> void:
	is_running = false
	play_button.text = "Play"
	generator.clear()
	_reset_view()

func _on_settings_pressed() -> void:
	if settings_dialog:
		settings_dialog.popup_centered()

func _on_settings_applied(config: Dictionary) -> void:
	generator.apply_config(config)
	_generate_and_draw()

func _generate_and_draw() -> void:
	if generator == null:
		return
	var grid: PackedByteArray = generator.generate()
	var w: int = int(generator.config.width) if "config" in generator else 0
	var h: int = int(generator.config.height) if "config" in generator else 0
	if ascii_map == null:
		return
	var sb := StringBuilder.new()
	for y in range(h):
		for x in range(w):
			var i := x + y * w
			var land: bool = (i < grid.size()) and (grid[i] != 0)
			sb.append("#" if land else "~")
		sb.append("\n")
	ascii_map.clear()
	ascii_map.append_text(sb.as_string())

func _reset_view() -> void:
	ascii_map.clear()
	ascii_map.append_text("")

class StringBuilder:
	var parts: PackedStringArray = []
	func append(s: String) -> void:
		parts.append(s)
	func as_string() -> String:
		return "".join(parts)
