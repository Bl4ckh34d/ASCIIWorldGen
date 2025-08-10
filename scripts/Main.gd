# File: res://scripts/Main.gd
extends Control

@onready var play_button: Button = $RootVBox/TopBar/PlayButton
@onready var reset_button: Button = $RootVBox/TopBar/ResetButton
@onready var settings_button: Button = $RootVBox/TopBar/SettingsButton
@onready var ascii_map: RichTextLabel = %AsciiMap
@onready var info_label: Label = %Info
@onready var settings_dialog: Window = $SettingsDialog
@onready var seed_input: LineEdit = $RootVBox/TopBar/SeedInput
@onready var seed_used_label: Label = $RootVBox/TopBar/SeedUsed
@onready var randomize_check: CheckBox = $RootVBox/TopBar/Randomize
@onready var sea_slider: HSlider = $RootVBox/TopBar/SeaSlider
@onready var sea_value_label: Label = $RootVBox/TopBar/SeaVal

var is_running: bool = false
var generator: Object
const AsciiStyler = preload("res://scripts/style/AsciiStyler.gd")
var highlight_rect: ColorRect
var highlight_label: Label
var last_ascii_text: String = ""
var styler_single: Object
var char_w_cached: float = 0.0
var char_h_cached: float = 0.0
var sea_debounce_timer: Timer
var sea_update_pending: bool = false
var sea_signal_blocked: bool = false

func _ready() -> void:
	generator = load("res://scripts/WorldGenerator.gd").new()
	play_button.pressed.connect(_on_play_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	ascii_map.gui_input.connect(_on_ascii_input)
	_apply_monospace_font()
	ascii_map.mouse_entered.connect(_on_map_enter)
	ascii_map.mouse_exited.connect(_on_map_exit)
	_create_highlight_overlay()
	styler_single = AsciiStyler.new()
	ascii_map.resized.connect(_on_map_resized)
	sea_slider.value_changed.connect(_on_sea_changed)
	_update_sea_label()
	sea_debounce_timer = Timer.new()
	sea_debounce_timer.one_shot = true
	sea_debounce_timer.wait_time = 0.08
	add_child(sea_debounce_timer)
	sea_debounce_timer.timeout.connect(_on_sea_debounce_timeout)
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
	_apply_seed_from_ui()
	var grid: PackedByteArray = generator.generate()
	var w: int = generator.config.width
	var h: int = generator.config.height
	var styler: Object = AsciiStyler.new()
	var ascii_str: String = styler.build_ascii(w, h, generator.last_height, grid, generator.last_turquoise_water, generator.last_turquoise_strength, generator.last_beach, generator.last_water_distance, generator.last_biomes, generator.config.sea_level, generator.config.rng_seed, generator.last_river, generator.last_temperature, generator.config.temp_min_c, generator.config.temp_max_c)
	ascii_map.clear()
	ascii_map.append_text(ascii_str)
	last_ascii_text = ascii_str
	_update_char_size_cache()

func _reset_view() -> void:
	ascii_map.clear()
	ascii_map.append_text("")
	info_label.text = "Hover: -"
	seed_used_label.text = "Used: -"
	last_ascii_text = ""
	_hide_highlight()

func _apply_seed_from_ui() -> void:
	var txt: String = seed_input.text.strip_edges()
	var cfg := {}
	if txt.length() == 0:
		# randomize seed
		cfg["seed"] = null
		generator.apply_config(cfg)
		# reflect used seed back into UI label
		seed_used_label.text = "Used: %d" % generator.config.rng_seed
	else:
		cfg["seed"] = txt
		generator.apply_config(cfg)
		seed_used_label.text = "Used: %d" % generator.config.rng_seed
	# If randomize is on, jitter core params slightly per Play
	if randomize_check and randomize_check.button_pressed:
		var jitter := RandomNumberGenerator.new()
		jitter.seed = int(Time.get_ticks_usec()) ^ int(generator.config.rng_seed)
		var cfg2 := {}
		cfg2["frequency"] = max(0.001, generator.config.frequency * (0.9 + 0.2 * jitter.randf()))
		cfg2["lacunarity"] = generator.config.lacunarity * (0.9 + 0.2 * jitter.randf())
		cfg2["gain"] = clamp(generator.config.gain * (0.85 + 0.3 * jitter.randf()), 0.1, 1.0)
		cfg2["warp"] = max(0.0, generator.config.warp * (0.75 + 0.5 * jitter.randf()))
		# Narrow ocean randomization to 0.30 .. 0.70
		# Sea level range is -1..1; randomize within [-0.35, 0.35]
		cfg2["sea_level"] = -0.35 + 0.70 * jitter.randf()
		# Climate baseline jitter
		cfg2["temp_base_offset"] = (jitter.randf() - 0.5) * 0.10
		cfg2["temp_scale"] = 0.95 + 0.1 * jitter.randf()
		cfg2["moist_base_offset"] = (jitter.randf() - 0.5) * 0.10
		cfg2["moist_scale"] = 0.95 + 0.1 * jitter.randf()
		cfg2["continentality_scale"] = 0.9 + 0.3 * jitter.randf()
		generator.apply_config(cfg2)
		# Reflect randomized sea level to slider without emitting value_changed
		sea_signal_blocked = true
		sea_slider.value = generator.config.sea_level
		sea_signal_blocked = false
		_update_sea_label()
	else:
		# Apply sea level from slider
		var cfg3 := {}
		cfg3["sea_level"] = float(sea_slider.value)
		generator.apply_config(cfg3)
		_update_sea_label()

func _on_sea_changed(v: float) -> void:
	sea_value_label.text = "%.2f" % v
	if sea_signal_blocked:
		return
	# Update only sea level and regenerate without changing current seed/config jitter
	if generator != null:
		# Fast path in generator to avoid recomputing climate/biome unless needed
		if "quick_update_sea_level" in generator:
			generator.quick_update_sea_level(float(v))
		else:
			generator.apply_config({"sea_level": float(v)})
		# Throttle regeneration to keep UI responsive while dragging
		sea_update_pending = true
		if sea_debounce_timer and sea_debounce_timer.is_stopped():
			sea_debounce_timer.start()

func _update_sea_label() -> void:
	sea_value_label.text = "%.2f" % float(sea_slider.value)

func _on_sea_debounce_timeout() -> void:
	if sea_update_pending:
		sea_update_pending = false
		_generate_and_draw_preserve_seed()

func _generate_and_draw_preserve_seed() -> void:
	# If the last change was sea-level only, terrain arrays are already updated
	# but to keep consistent pipeline, regen is safe and quick
	var grid: PackedByteArray = generator.last_is_land if generator.last_is_land.size() == generator.get_width() * generator.get_height() else generator.generate()
	var w: int = generator.config.width
	var h: int = generator.config.height
	var styler: Object = AsciiStyler.new()
	var ascii_str: String = styler.build_ascii(w, h, generator.last_height, grid, generator.last_turquoise_water, generator.last_turquoise_strength, generator.last_beach, generator.last_water_distance, generator.last_biomes, generator.config.sea_level, generator.config.rng_seed, generator.last_river, generator.last_temperature, generator.config.temp_min_c, generator.config.temp_max_c)
	ascii_map.clear()
	ascii_map.append_text(ascii_str)
	last_ascii_text = ascii_str
	_update_char_size_cache()

func _apply_monospace_font() -> void:
	# Use SystemFont to select an installed monospace safely (Godot 4)
	var sys := SystemFont.new()
	sys.font_names = PackedStringArray([
		"Consolas",
		"Lucida Console",
		"Courier New",
		"DejaVu Sans Mono",
		"Noto Sans Mono"
	])
	# Some platforms may fail to resolve; guard against null override
	if sys != null:
		ascii_map.add_theme_font_override("normal_font", sys)
		if highlight_label:
			highlight_label.add_theme_font_override("font", sys)
			highlight_label.add_theme_color_override("font_color", Color(0, 0, 0, 1))

## Styling moved to AsciiStyler

func _on_ascii_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var local: Vector2 = ascii_map.get_local_mouse_position()
		var w: int = generator.get_width()
		var h: int = generator.get_height()
		if char_w_cached <= 0.0 or char_h_cached <= 0.0:
			_update_char_size_cache()
		var x: int = int(local.x / max(1.0, char_w_cached))
		var y: int = int(local.y / max(1.0, char_h_cached))
		if x >= 0 and y >= 0 and x < w and y < h:
			var info: Dictionary = generator.get_cell_info(x, y)
			if info.size() > 0:
				var coords := "Coords: (%d / %d)" % [x, y]
				var meters: float = float(generator.config.height_scale_m) * float(info["height"])
				var htxt := "Height: %.1f m" % meters
				var ttxt: String = "Ocean"
				if info.has("biome_name"):
					ttxt = String(info["biome_name"])
				else:
					ttxt = "Land" if info["is_land"] else "Ocean"
				var humid: float = 0.0
				var temp_c: float = 0.0
				if info.has("humidity"):
					humid = float(info["humidity"])
				if info.has("temp_c"):
					temp_c = float(info["temp_c"])
				var flags: PackedStringArray = []
				if info.get("is_beach", false): flags.append("Beach")
				if info.get("is_river", false): flags.append("River")
				if info.get("is_lava", false): flags.append("Lava")
				var extra := ""
				if flags.size() > 0: extra = " - " + ", ".join(flags)
				info_label.text = "%s - %s - Type: %s - Humidity: %.2f - Temp: %.1f °C%s" % [coords, htxt, ttxt, humid, temp_c, extra]
				_update_highlight_overlay(x, y, char_w_cached, char_h_cached)
			else:
				info_label.text = "Hover: -"
				_hide_highlight()
func _create_highlight_overlay() -> void:
	highlight_rect = ColorRect.new()
	highlight_rect.visible = false
	highlight_rect.color = Color(1, 0, 0, 1)
	highlight_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	highlight_rect.z_index = 1000
	ascii_map.add_child(highlight_rect)

	highlight_label = Label.new()
	highlight_label.visible = false
	highlight_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	highlight_label.z_index = 1001
	highlight_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	highlight_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	highlight_label.add_theme_color_override("font_color", Color(0, 0, 0, 1))
	ascii_map.add_child(highlight_label)

func _update_highlight_overlay(x: int, y: int, char_w: float, char_h: float) -> void:
	if not highlight_rect or not highlight_label:
		return
	var w: int = generator.get_width()
	var h: int = generator.get_height()
	if x < 0 or y < 0 or x >= w or y >= h:
		_hide_highlight()
		return
	highlight_rect.position = Vector2(float(x) * char_w, float(y) * char_h)
	highlight_rect.size = Vector2(char_w, char_h)
	highlight_rect.visible = true

	# derive glyph without splitting the full text each time
	var glyph := _glyph_at(x, y)
	highlight_label.position = highlight_rect.position
	highlight_label.size = highlight_rect.size
	highlight_label.text = glyph
	highlight_label.visible = true

func _hide_highlight() -> void:
	if highlight_rect:
		highlight_rect.visible = false
	if highlight_label:
		highlight_label.visible = false

func _glyph_at(x: int, y: int) -> String:
	var w: int = generator.get_width()
	var h: int = generator.get_height()
	if x < 0 or y < 0 or x >= w or y >= h:
		return ""
	var i: int = x + y * w
	var land: bool = (i < generator.last_is_land.size()) and generator.last_is_land[i] != 0
	var beach_flag: bool = (i < generator.last_beach.size()) and generator.last_beach[i] != 0
	if not land:
		# water glyphs are set by styler
		return "~"
	var biome_id: int = 0
	if i < generator.last_biomes.size():
		biome_id = generator.last_biomes[i]
	# river override
	if i < generator.last_river.size() and generator.last_river[i] != 0 and not beach_flag:
		return "≈"
	if styler_single == null:
		styler_single = AsciiStyler.new()
	return styler_single.glyph_for(x, y, land, biome_id, beach_flag, generator.config.rng_seed)

func _update_char_size_cache() -> void:
	var w: int = generator.get_width()
	var h: int = generator.get_height()
	char_w_cached = 0.0
	char_h_cached = 0.0
	if w > 0 and h > 0:
		var content_w: float = float(ascii_map.get_content_width())
		var content_h: float = float(ascii_map.get_content_height())
		if content_w > 0.0 and content_h > 0.0:
			char_w_cached = content_w / float(w)
			char_h_cached = content_h / float(h)
	if char_w_cached <= 0.0 or char_h_cached <= 0.0:
		var font: Font = ascii_map.get_theme_default_font()
		if font and ascii_map.get_theme_default_font_size() > 0:
			var font_size: int = ascii_map.get_theme_default_font_size()
			var glyph_size: Vector2 = font.get_char_size(65, font_size)
			if glyph_size.x > 0.0 and font.get_height(font_size) > 0.0:
				char_w_cached = float(glyph_size.x)
				char_h_cached = float(font.get_height(font_size))
	if char_w_cached <= 0.0:
		char_w_cached = 8.0
	if char_h_cached <= 0.0:
		char_h_cached = 16.0

func _on_map_resized() -> void:
	_update_char_size_cache()

func _on_map_enter() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)

func _on_map_exit() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_hide_highlight()

class StringBuilder:
	var parts: PackedStringArray = []
	func append(s: String) -> void:
		parts.append(s)
	func as_string() -> String:
		return "".join(parts)
