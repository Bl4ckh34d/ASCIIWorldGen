# File: res://scripts/Main.gd
extends Control

@onready var play_button: Button = $RootVBox/TopBar/PlayButton
@onready var reset_button: Button = $RootVBox/TopBar/ResetButton
@onready var settings_button: Button = $RootVBox/TopBar/SettingsButton
@onready var ascii_map: RichTextLabel = %AsciiMap
@onready var settings_dialog: Window = $SettingsDialog

var is_running: bool = false
var generator: WorldGenerator = WorldGenerator.new()

func _ready() -> void:
	play_button.pressed.connect(_on_play_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	if settings_dialog.has_signal("settings_applied"):
		settings_dialog.connect("settings_applied", Callable(self, "_on_settings_applied"))
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
	var grid: PackedByteArray = generator.generate()
	var w: int = generator.config.width
	var h: int = generator.config.height
	var sb := StringBuilder.new()
	for y in h:
		for x in w:
			var i := x + y * w
			var land: bool = grid[i] != 0
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
