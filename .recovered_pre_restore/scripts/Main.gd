# File: res://scripts/Main.gd
extends Control
class_name MainController
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const WorldConstants = preload("res://scripts/core/WorldConstants.gd")
const HighSpeedValidatorScript = preload("res://scripts/core/HighSpeedValidator.gd")
const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const SimulationControllerScript = preload("res://scripts/controllers/SimulationController.gd")
const RenderControllerScript = preload("res://scripts/controllers/RenderController.gd")
const HoverInfoControllerScript = preload("res://scripts/controllers/HoverInfoController.gd")
const SettingsPanelControllerScript = preload("res://scripts/controllers/SettingsPanelController.gd")
const HUDScene = preload("res://scenes/ui/HUD.tscn")

# --- Performance toggles (turn off heavy systems for faster world map) ---
const ENABLE_SEASONAL_CLIMATE: bool = true
const ENABLE_HYDRO: bool = true
const ENABLE_EROSION: bool = true
const ENABLE_CLOUDS: bool = true
const ENABLE_PLATES: bool = true
const ENABLE_BIOMES_TICK: bool = true
const ENABLE_CRYOSPHERE_TICK: bool = true
const ENABLE_VOLCANISM: bool = true
const ENABLE_SOCIETY_CIV_WORLDGEN: bool = true
const GPU_SQUARE_TILES: bool = true
const GPU_AUTO_FIT_TILES: bool = true
const GPU_TILE_SCALE: float = 2.0
const SPEED_PRESETS: Array = [1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0]
const SPEED_CLOUDS_PAUSE_THRESHOLD: float = 100000.0
const SPEED_LIGHT_HEAVY_THROTTLE_THRESHOLD: float = 10000.0
const SPEED_LOD_CLIMATE_MAX_SIM_DAYS: float = 21.0
const SPEED_LOD_HYDRO_MAX_SIM_DAYS: float = 16.0
const SPEED_LOD_EROSION_MAX_SIM_DAYS: float = 18.0
const SPEED_LOD_BIOME_MAX_SIM_DAYS: float = 180.0
const SPEED_LOD_CRYOSPHERE_MAX_SIM_DAYS: float = 20.0
const SPEED_LOD_VOLCANISM_MAX_SIM_DAYS: float = 30.0
const SPEED_LOD_PLATES_MAX_SIM_DAYS: float = 365.0
const HYDRO_CATCHUP_MAX_DAYS: float = 0.5
const EROSION_CATCHUP_MAX_DAYS: float = 0.5
const BIOME_CATCHUP_MAX_DAYS: float = 2.0
const CRYOSPHERE_CATCHUP_MAX_DAYS: float = 0.5
const HYDRO_CATCHUP_EXTRA_RUN_MARGIN: int = 2
const BIOME_MAX_RUNS_PER_TICK: int = 2
const CRYOSPHERE_MAX_RUNS_PER_TICK: int = 2
const HIGH_SPEED_VALIDATION_MIN_SCALE: float = 1000.0
const HIGH_SPEED_VALIDATION_INTERVAL_TICKS: int = 30
const HIGH_SPEED_DEBT_GROWTH_LIMIT: float = 1.20
const HIGH_SPEED_DEBT_ABS_LIMIT_DAYS: float = 365.0
const HIGH_SPEED_SKIP_DELTA_LIMIT: int = 120
const HIGH_SPEED_BUDGET_RATIO_LIMIT: float = 1.15
const HIGH_SPEED_PROGRESS_RATIO_LIMIT: float = 0.55
const HIGH_SPEED_BACKLOG_DAYS_LIMIT: float = 365.0
const STARTUP_ACCLIMATE_STEPS: int = 2
const STARTUP_ACCLIMATE_STEP_DAYS: float = 0.25
const INTRO_SCENE_REVEAL_MIN_DELAY_SEC: float = 0.30
const INTRO_SCENE_REVEAL_MAX_DELAY_SEC: float = 3.00
const SOCIETY_WORLDGEN_BATCH_DAYS_SLOW: int = 7
const SOCIETY_WORLDGEN_BATCH_DAYS_FAST: int = 30
const SOCIETY_WORLDGEN_BATCH_DAYS_HYPER: int = 60
const REGIONAL_MAP_SCENE_PATH: String = SceneContracts.SCENE_REGIONAL_MAP

# UI References - will be set in _initialize_ui_nodes()
var play_button: Button
var reset_button: Button
var step_button: Button
var backstep_button: Button
var randomize_check: CheckBox
var speed_slider: HSlider
var speed_value_label: Label
var top_speed_slider: HSlider
var top_speed_value_label: Label
var top_speed_buttons_bar: HBoxContainer
var simulation_speed_buttons_bar: HFlowContainer
var year_label: Label
var settings_button: Button

var ascii_map: RichTextLabel
var info_label: Label
var cursor_overlay: Control

var hide_button: Button
var bottom_panel: PanelContainer

# Tab containers
var generation_vbox: VBoxContainer
var terrain_vbox: VBoxContainer
var climate_vbox: VBoxContainer
var hydro_vbox: VBoxContainer
var simulation_vbox: VBoxContainer
var systems_vbox: VBoxContainer

var top_bar: HBoxContainer

# UI Controls
var seed_input: LineEdit
var seed_used_label: Label
var sea_slider: HSlider
var sea_value_label: Label
var temp_slider: HSlider
var temp_value_label: Label
var cont_slider: HSlider
var cont_value_label: Label
var step_spin: SpinBox
var noise_octaves_spin: SpinBox
var noise_frequency_spin: SpinBox
var noise_lacunarity_spin: SpinBox
var noise_gain_spin: SpinBox
var noise_warp_spin: SpinBox
var shallow_threshold_spin: SpinBox
var shore_band_spin: SpinBox
var shore_noise_mult_spin: SpinBox
var polar_cap_frac_slider: HSlider
var polar_cap_frac_value_label: Label
var bedrock_view_check: CheckBox
var rivers_enabled_check: CheckBox
var lakes_enabled_check: CheckBox
var river_threshold_spin: SpinBox
var river_delta_widening_check: CheckBox
var season_slider: HSlider
var season_value_label: Label
var ocean_damp_slider: HSlider
var ocean_damp_value_label: Label
var _sim_tick_counter: int = 0
var _seasonal_sys: Object
var _hydro_sys: Object
var _erosion_sys: Object
var _clouds_sys: Object
var _biome_sys: Object
var _cryosphere_sys: Object
var _biome_like_systems: Array = []
var _plates_sys: Object
var _volcanism_sys: Object
var cloud_coupling_check: CheckBox
var rain_strength_slider: HSlider
var evap_strength_slider: HSlider

var is_running: bool = false
var generator: Object
var time_system: Node
var simulation: Node
var _checkpoint_sys: Node
const RandomizeService = preload("res://scripts/ui/RandomizeService.gd")
# Load GPU renderer dynamically to avoid preload issues
var last_ascii_text: String = ""
var char_w_cached: float = 0.0
var char_h_cached: float = 0.0
var sea_debounce_timer: Timer
var sea_update_pending: bool = false
var sea_signal_blocked: bool = false
var sea_last_applied: float = 0.0
var sea_pending_value: float = 0.0
var map_scale: int = 1
var base_width: int = 0
var base_height: int = 0
var tile_cols: int = 0
var tile_rows: int = 0
var desired_tile_px: float = 0.0
var tile_fit_timer: Timer
var lock_aspect: bool = true
var tiles_across_spin: SpinBox
var tiles_down_spin: SpinBox
var lock_aspect_check: CheckBox
var ckpt_interval_spin: SpinBox
var save_ckpt_button: Button
var load_ckpt_button: Button
var scrub_days_spin: SpinBox
var scrub_button: Button
var ckpt_list: OptionButton
var ckpt_refresh_button: Button
var ckpt_load_button: Button
var top_save_ckpt_button: Button
var top_load_ckpt_button: Button
var top_seed_label: Label
var top_time_label: Label
var save_dialog: FileDialog
var load_dialog: FileDialog
var plates_cad: SpinBox

# GPU rendering system
var gpu_ascii_renderer: Control
var use_gpu_rendering: bool = true

# Promote frequently accessed UI controls (created during setup) to class members
var year_len_slider: HSlider
var year_len_value: Label
var fps_spin: SpinBox
var budget_spin: SpinBox
var time_spin: SpinBox
var budget_mode_check: CheckBox
var hydro_spin: SpinBox
var cloud_spin: SpinBox
var biome_spin: SpinBox
var cryosphere_spin: SpinBox

var hover_has_tile: bool = false
var hover_tile_x: int = -1
var hover_tile_y: int = -1
var show_bedrock_view: bool = false
var _selected_speed_scale: float = 1.0
var _last_speed_time_scale: float = 1.0
var _speed_lod_clouds_paused: bool = false
var _top_speed_buttons: Array = []
var _simulation_speed_buttons: Array = []
var _entered_from_intro: bool = false
var _scene_fade_rect: ColorRect = null
var _scene_fade_tween: Tween = null
var _pending_intro_reveal: bool = false
var _intro_reveal_min_delay_elapsed: bool = false
var _intro_reveal_first_tick_seen: bool = false
var _high_speed_validator: HighSpeedValidator = HighSpeedValidatorScript.new()
var _society_day_accum: float = 0.0
var _society_hover_cache: Dictionary = {}
var _simulation_controller: Node = null
var _render_controller: Node = null
var _settings_panel_controller: Node = null
var _hud_scene: CanvasLayer = null
var _hud_last_update_msec: int = 0
const HUD_METRIC_INTERVAL_SEC: float = 0.30

func _initialize_ui_nodes() -> void:
	"""Initialize all UI node references with the new layout"""
	
	# Get main UI elements (support both scene variants via unique name lookup)
	top_bar = get_node_or_null("%TopBar")
	play_button = get_node_or_null("%TopBar/PlayButton")
	reset_button = get_node_or_null("%TopBar/ResetButton")
	step_button = get_node_or_null("%TopBar/StepButton")
	backstep_button = get_node_or_null("%TopBar/BackStepButton")
	randomize_check = get_node_or_null("%TopBar/Randomize")
	top_speed_slider = get_node_or_null("%TopBar/SpeedSlider")
	top_speed_value_label = get_node_or_null("%TopBar/SpeedValue")
	speed_slider = top_speed_slider
	speed_value_label = top_speed_value_label
	year_label = get_node_or_null("%TopBar/YearLabel")
	settings_button = get_node_or_null("%TopBar/SettingsButton")
	
	# Map area
	ascii_map = get_node_or_null("%AsciiMap")
	info_label = get_node_or_null("%Info")
	cursor_overlay = get_node_or_null("%CursorOverlay")
	
	# Bottom panel
	bottom_panel = get_node_or_null("%BottomPanel")
	hide_button = get_node_or_null("%HideButton")
	
	# Tab containers
	generation_vbox = get_node_or_null("%GenerationVBox")
	terrain_vbox = get_node_or_null("%TerrainVBox")
	climate_vbox = get_node_or_null("%ClimateVBox")
	hydro_vbox = get_node_or_null("%HydroVBox")
	simulation_vbox = get_node_or_null("%SimulationVBox")
	systems_vbox = get_node_or_null("%SystemsVBox")
	
	# debug removed
	
	# Connect basic events
	if play_button and not play_button.pressed.is_connected(_on_play_pressed):
		play_button.pressed.connect(_on_play_pressed)
	if reset_button and not reset_button.pressed.is_connected(_on_reset_pressed):
		reset_button.pressed.connect(_on_reset_pressed)
	if step_button and not step_button.pressed.is_connected(_on_step_pressed):
		step_button.pressed.connect(_on_step_pressed)
	if backstep_button and not backstep_button.pressed.is_connected(_on_backstep_pressed):
		backstep_button.pressed.connect(_on_backstep_pressed)
	if settings_button and not settings_button.pressed.is_connected(_on_settings_pressed):
		settings_button.pressed.connect(_on_settings_pressed)
	if hide_button and not hide_button.pressed.is_connected(_on_hide_panel_pressed):
		hide_button.pressed.connect(_on_hide_panel_pressed)
	_install_top_speed_buttons()
	
	# Setup all tab content
	_setup_all_tabs()
	_sync_settings_button_label()
	
	# DISABLE ALL COMPLEX UI SETUP
	# terrain_vbox = get_node_or_null("%TerrainVBox")
	# ... all other UI elements commented out
	
	# debug removed

func _setup_all_tabs() -> void:
	"""Setup content for all tabs with proper organization"""
	_setup_generation_tab()
	_setup_terrain_tab()
	_setup_climate_tab()
	_setup_hydro_tab()
	if simulation_vbox:
		_add_label(simulation_vbox, "Simulation tuning moved to automatic profiles.")
	if systems_vbox:
		_add_label(systems_vbox, "System internals are auto-managed for realism/performance.")

func _setup_generation_tab() -> void:
	"""Setup Generation tab - world creation parameters"""
	if not generation_vbox: return
	
	# Seed controls
	_add_section_header(generation_vbox, "World Seed")
	var seed_container = _add_horizontal_group(generation_vbox)
	_add_label_to_container(seed_container, "Seed:")
	seed_input = _add_line_edit_to_container(seed_container, "")
	seed_input.placeholder_text = "empty = random"
	seed_used_label = _add_label_to_container(generation_vbox, "Used: -")
	
	# Size controls
	_add_section_header(generation_vbox, "World Size")
	tiles_across_spin = _add_label_with_spinbox(generation_vbox, "Tiles Across:", 8, 1024, 1, 275, func(v): _on_tiles_across_changed(v))
	tiles_down_spin = _add_label_with_spinbox(generation_vbox, "Tiles Down:", 8, 1024, 1, 62, func(v): _on_tiles_down_changed(v))
	lock_aspect_check = _add_checkbox(generation_vbox, "Lock Aspect Ratio", true, func(v): _on_lock_aspect_toggled(v))
	_add_label(generation_vbox, "Geomorphology + climate parameters are auto-derived per seed.")

func _setup_terrain_tab() -> void:
	"""Setup Terrain tab - elevation, continents, sea level"""
	if not terrain_vbox: return

	# View controls
	_add_section_header(terrain_vbox, "Map View")
	bedrock_view_check = _add_checkbox(terrain_vbox, "Lithology View", false, func(v): _on_bedrock_view_toggled(v))
	
	# Sea level
	_add_section_header(terrain_vbox, "Sea Level")
	var sea_result = _add_label_with_slider(terrain_vbox, "Sea Level:", -1.0, 1.0, 0.01, 0.0, func(v): _on_sea_level_changed(v))
	sea_slider = sea_result.slider
	sea_value_label = sea_result.value_label
	if sea_slider and sea_slider.has_signal("drag_ended"):
		var cb = Callable(self, "_on_sea_drag_ended")
		if not sea_slider.is_connected("drag_ended", cb):
			sea_slider.connect("drag_ended", cb)
	
	_add_label(terrain_vbox, "Terrain shape controls are seed-driven for realism.")

func _setup_climate_tab() -> void:
	"""Setup Climate tab - weather, precipitation, seasons"""
	if not climate_vbox: return
	_add_label(climate_vbox, "Climate is auto-parameterized from seed and world geometry.")

func _setup_hydro_tab() -> void:
	"""Setup Hydro tab - rivers, lakes, water flow"""
	if not hydro_vbox: return

	_add_section_header(hydro_vbox, "Hydrology Generation")
	rivers_enabled_check = _add_checkbox(hydro_vbox, "Enable Rivers", true, func(_v): _on_hydro_generation_settings_changed())
	lakes_enabled_check = _add_checkbox(hydro_vbox, "Enable Lakes", true, func(_v): _on_hydro_generation_settings_changed())
	_add_label(hydro_vbox, "River thresholds and delta behavior are auto-managed.")

func _setup_simulation_tab() -> void:
	"""Setup Simulation tab - time, checkpoints, GPU rendering"""
	if not simulation_vbox: return
	
	# Time controls
	_add_section_header(simulation_vbox, "Time & Speed")
	year_label = _add_label(simulation_vbox, "Year: 0.00")
	
	var initial_year_length = time_system.get_days_per_year() if time_system else 365.0
	var year_len_result = _add_label_with_slider(simulation_vbox, "Days per Year:", 50.0, 500.0, 1.0, initial_year_length, func(v): _on_year_length_changed(v))
	year_len_slider = year_len_result.slider
	year_len_value = year_len_result.value_label
	
	fps_spin = _add_label_with_spinbox(simulation_vbox, "Simulation FPS:", 1.0, 60.0, 1.0, 60.0, func(v): _on_sim_fps_changed(v))
	var speed_group = _add_horizontal_group(simulation_vbox)
	_add_label_to_container(speed_group, "Speed:")
	simulation_speed_buttons_bar = HFlowContainer.new()
	simulation_speed_buttons_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_group.add_child(simulation_speed_buttons_bar)
	speed_value_label = _add_label_to_container(speed_group, "1x")
	_simulation_speed_buttons = _create_speed_preset_buttons(simulation_speed_buttons_bar, false)
	_update_speed_button_states()
	
	# Step controls
	_add_section_header(simulation_vbox, "Manual Stepping")
	var step_container = _add_horizontal_group(simulation_vbox)
	step_spin = _add_spinbox_to_container(step_container, 1.0, 1440.0, 1.0, 1.0)
	step_spin.value_changed.connect(func(v): _on_step_minutes_changed(v))
	step_button = _add_button_to_container(step_container, "Step")
	step_button.pressed.connect(_on_step_pressed)
	backstep_button = _add_button_to_container(step_container, "Back")
	backstep_button.pressed.connect(_on_backstep_pressed)
	
	# Performance controls
	_add_section_header(simulation_vbox, "Performance")
	budget_spin = _add_label_with_spinbox(simulation_vbox, "Systems/Tick:", 1, 10, 1, 3, func(v): _on_budget_changed(v))
	time_spin = _add_label_with_spinbox(simulation_vbox, "Time/Tick (ms):", 0.0, 20.0, 0.5, 6.0, func(v): _on_time_budget_changed(v))
	budget_mode_check = _add_checkbox(simulation_vbox, "Time Budget Mode", false, func(v): _on_budget_mode_changed(v))
	
	# GPU rendering
	_add_section_header(simulation_vbox, "Rendering")
	var gpu_rendering_indicator = _add_checkbox(simulation_vbox, "GPU Rendering (Required)", true, Callable())
	if gpu_rendering_indicator:
		gpu_rendering_indicator.disabled = true
		gpu_rendering_indicator.tooltip_text = "GPU-only rendering is always enabled."
	
	# Checkpoints
	_add_section_header(simulation_vbox, "Checkpoints")
	ckpt_interval_spin = _add_label_with_spinbox(simulation_vbox, "Interval (days):", 0.5, 60.0, 0.5, 5.0, func(v): _on_checkpoint_interval_changed(v))
	
	var ckpt_container = _add_horizontal_group(simulation_vbox)
	save_ckpt_button = _add_button_to_container(ckpt_container, "Save")
	save_ckpt_button.pressed.connect(_on_save_checkpoint_pressed)
	load_ckpt_button = _add_button_to_container(ckpt_container, "Load")
	load_ckpt_button.pressed.connect(_on_load_checkpoint_pressed)
	ckpt_refresh_button = _add_button_to_container(ckpt_container, "Refresh")
	ckpt_refresh_button.pressed.connect(_on_refresh_checkpoints_pressed)
	
	# Scrubbing
	var scrub_container = _add_horizontal_group(simulation_vbox)
	_add_label_to_container(scrub_container, "Scrub to day:")
	scrub_days_spin = _add_spinbox_to_container(scrub_container, 0.0, 100000.0, 0.1, 0.0)
	scrub_button = _add_button_to_container(scrub_container, "Go")
	scrub_button.pressed.connect(_on_scrub_pressed)

func _setup_systems_tab() -> void:
	"""Setup Systems tab - system cadences and timings"""
	if not systems_vbox: return
	
	_add_section_header(systems_vbox, "System Update Frequencies")
	_add_label(systems_vbox, "Control how often each system updates")
	
	# Climate system (always 1 - runs every tick)
	var clim_spin = _add_label_with_spinbox(systems_vbox, "Climate:", 1, 120, 1, 1, Callable())
	clim_spin.editable = false
	clim_spin.tooltip_text = "Climate system runs every tick (not configurable)"
	
	# Other systems
	hydro_spin = _add_label_with_spinbox(systems_vbox, "Hydrology:", 1, 120, 1, 30, func(v): _on_hydro_cadence_changed(v))
	cloud_spin = _add_label_with_spinbox(systems_vbox, "Clouds:", 1, 120, 1, 7, func(v): _on_cloud_cadence_changed(v))
	biome_spin = _add_label_with_spinbox(systems_vbox, "Biomes:", 1, 200, 1, WorldConstants.CADENCE_BIOMES, func(v): _on_biome_cadence_changed(v))
	cryosphere_spin = _add_label_with_spinbox(systems_vbox, "Cryosphere:", 1, 200, 1, WorldConstants.CADENCE_CRYOSPHERE, func(v): _on_cryosphere_cadence_changed(v))
	var initial_plates_cadence = time_system.get_days_per_year() if time_system else 365.0
	plates_cad = _add_label_with_spinbox(systems_vbox, "Plates:", 1, 1000, 1, initial_plates_cadence, func(v): _on_plates_cadence_changed(v))

# Helper functions for creating UI elements
func _add_section_header(parent: Container, text: String) -> Label:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color.CYAN)
	parent.add_child(label)
	return label

func _add_label(parent: Container, text: String) -> Label:
	var label = Label.new()
	label.text = text
	parent.add_child(label)
	return label

func _add_checkbox(parent: Container, text: String, checked: bool, callback: Callable) -> CheckBox:
	var checkbox = CheckBox.new()
	checkbox.text = text
	checkbox.button_pressed = checked
	if callback.is_valid(): checkbox.toggled.connect(callback)
	parent.add_child(checkbox)
	return checkbox

func _add_horizontal_group(parent: Container) -> HBoxContainer:
	var container = HBoxContainer.new()
	parent.add_child(container)
	return container

func _add_label_to_container(container: Container, text: String) -> Label:
	var label = Label.new()
	label.text = text
	container.add_child(label)
	return label

func _add_line_edit_to_container(container: Container, text: String) -> LineEdit:
	var edit = LineEdit.new()
	edit.text = text
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(edit)
	return edit

func _add_button_to_container(container: Container, text: String) -> Button:
	var button = Button.new()
	button.text = text
	container.add_child(button)
	return button

func _add_spinbox_to_container(container: Container, min_v…21837 tokens truncated…lider() -> void:
	if generator == null or sea_slider == null:
		return
	var v: float = sea_pending_value if sea_update_pending else float(sea_slider.value)
	if abs(v - sea_last_applied) < 0.0001:
		sea_update_pending = false
		return
	# Update only sea level and regenerate without changing current seed/config jitter
	if "quick_update_sea_level" in generator:
		generator.quick_update_sea_level(float(v))
	else:
		generator.apply_config({"sea_level": float(v)})
	_sync_sea_slider_to_generator()
	sea_update_pending = false
	# Redraw from current state after applying the new sea level
	_redraw_ascii_from_current_state()
	_update_cursor_dimensions()
	_refresh_hover_info()

func _on_temp_changed(v: float) -> void:
	if generator == null:
		return
	# Mapping requested:
	# v=0 -> min=-80, max=-15 | v=1 -> min=15, max=80
	var min_c: float = lerp(-80.0, 15.0, v)
	var max_c: float = lerp(-15.0, 80.0, v)
	var cfg := {
		"temp_min_c": min_c,
		"temp_max_c": max_c,
		"temp_base_offset": (v - 0.5) * 0.4,
		"temp_scale": lerp(0.9, 1.2, v),
	}
	generator.apply_config(cfg)
	_update_temp_label()
	var temp_timer := get_node_or_null("TempDebounceTimer")
	if temp_timer and temp_timer is Timer:
		(temp_timer as Timer).start()

func _update_temp_label() -> void:
	if temp_value_label and generator and "config" in generator:
		temp_value_label.text = "%d..%d C" % [int(generator.config.temp_min_c), int(generator.config.temp_max_c)]

func _on_temp_debounce_timeout() -> void:
	_generate_and_draw()

func _on_cont_changed(v: float) -> void:
	if generator == null:
		return
	# Apply without altering current seed
	var cfg := { "continentality_scale": float(v) }
	generator.apply_config(cfg)
	_update_cont_label()
	var temp_timer := get_node_or_null("TempDebounceTimer")
	if temp_timer and temp_timer is Timer:
		(temp_timer as Timer).start()

func _update_cont_label() -> void:
	if cont_value_label and generator and "config" in generator:
		cont_value_label.text = "x%.2f" % float(generator.config.continentality_scale)

func _on_sea_debounce_timeout() -> void:
	if sea_update_pending:
		_apply_sea_level_from_slider()

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
		if cursor_overlay and cursor_overlay.has_method("apply_font"):
			cursor_overlay.apply_font(sys)

# Old highlight functions removed - replaced by CursorOverlay system


func _update_char_size_cache() -> void:
	# Skip if already computed and dimensions haven't changed
	var w: int = generator.get_width()
	var h: int = generator.get_height()
	if char_w_cached > 0.0 and char_h_cached > 0.0 and w == tile_cols and h == tile_rows:
		return

	# Always derive character cell size from current font metrics to avoid content padding effects
	char_w_cached = 0.0
	char_h_cached = 0.0

	# When GPU rendering is active, query exact on-screen cell size from renderer to ensure a perfect match
	if use_gpu_rendering and gpu_ascii_renderer and gpu_ascii_renderer.has_method("get_cell_size_screen"):
		var cs: Vector2 = gpu_ascii_renderer.get_cell_size_screen()
		if cs.x > 0.0 and cs.y > 0.0:
			char_w_cached = cs.x
			char_h_cached = cs.y
	else:
		# Use precise font metrics with RichTextLabel-specific adjustments
		var font: Font = ascii_map.get_theme_font("normal_font")
		if not font:
			font = ascii_map.get_theme_default_font()
		if font:
			var font_size: int = ascii_map.get_theme_font_size("normal_font_size")
			if font_size <= 0:
				font_size = ascii_map.get_theme_default_font_size()
			if font_size > 0:
				# Use precise character measurement - test with multiple chars to get average
				var test_chars = ["A", "M", "W", "i", "l", "1", "0", "#"]
				var total_width: float = 0.0
				for test_char in test_chars:
					total_width += font.get_char_size(test_char.unicode_at(0), font_size).x
				var avg_char_width: float = total_width / float(test_chars.size())
				
				var font_height: float = float(font.get_height(font_size))
				# Include any themed line spacing to match RichTextLabel layout precisely
				var line_spacing: int = 0
				if ascii_map.has_theme_constant("line_spacing"):
					line_spacing = ascii_map.get_theme_constant("line_spacing")
				
				if avg_char_width > 0.0 and font_height > 0.0:
					char_w_cached = avg_char_width
					char_h_cached = font_height + float(line_spacing)

	# Final fallback values
	if char_w_cached <= 0.0:
		char_w_cached = 8.0
	if char_h_cached <= 0.0:
		char_h_cached = 16.0


func _on_map_resized() -> void:
	_update_char_size_cache()
	# Adjust font size to keep tile count while filling available space
	if not use_gpu_rendering:
		_apply_font_to_fit_tiles()
	# Ensure cursor overlay tracks the resized map and updated glyph metrics
	_update_cursor_dimensions()
	_refresh_hover_info()

# Mouse enter/exit now handled by CursorOverlay

func _apply_font_to_fit_tiles() -> void:
	if use_gpu_rendering:
		return
	# Compute font size to fit tile_cols x tile_rows using measured glyph metrics
	var w: int = max(1, tile_cols)
	var h: int = max(1, tile_rows)
	# Prefer the parent RightContent width and height minus a small padding to avoid wrapping
	var container := ascii_map.get_parent()
	var rect_w: float = float(ascii_map.size.x)
	var rect_h: float = float(ascii_map.size.y)
	if container and container is Control:
		rect_w = max(rect_w, float((container as Control).size.x))
		rect_h = max(rect_h, float((container as Control).size.y))
	if rect_w <= 0.0 or rect_h <= 0.0:
		return
	var font: Font = ascii_map.get_theme_font("normal_font")
	if not font:
		font = ascii_map.get_theme_default_font()
	if not font:
		return
	var s0: int = max(8, ascii_map.get_theme_default_font_size())
	var cw0: float = font.get_char_size(65, s0).x
	var ch0: float = float(font.get_height(s0))
	var line_spacing0: int = 0
	if ascii_map.has_theme_constant("line_spacing"):
		line_spacing0 = ascii_map.get_theme_constant("line_spacing")
	ch0 += float(line_spacing0)
	if cw0 <= 0.0 or ch0 <= 0.0:
		return
	var cw_per_pt: float = cw0 / float(s0)
	var ch_per_pt: float = ch0 / float(s0)
	# Slightly bias to width so it fills horizontally; height may clip by one row at worst
	var size_fit_w: float = rect_w / (cw_per_pt * float(w))
	var size_fit_h: float = rect_h / (ch_per_pt * float(h))
	var size_guess: int = int(floor(min(size_fit_w * 0.98, size_fit_h)))
	if size_guess <= 0:
		return
	ascii_map.add_theme_font_size_override("normal_font_size", size_guess)
	_update_char_size_cache()
	_update_cursor_dimensions()

func _schedule_tile_fit() -> void:
	if not use_gpu_rendering or not GPU_AUTO_FIT_TILES:
		return
	if tile_fit_timer:
		tile_fit_timer.start()

func _on_tile_fit_timeout() -> void:
	_apply_gpu_tile_fit()

func _apply_gpu_tile_fit() -> void:
	if not use_gpu_rendering or not GPU_SQUARE_TILES:
		return
	var rect_size := Vector2.ZERO
	if gpu_ascii_renderer and gpu_ascii_renderer is Control:
		rect_size = (gpu_ascii_renderer as Control).size
	if rect_size.x <= 0.0 or rect_size.y <= 0.0:
		if ascii_map:
			rect_size = ascii_map.size
	if rect_size.x <= 0.0 or rect_size.y <= 0.0:
		return
	# Establish target square tile size once (halve size = double grid)
	if desired_tile_px <= 0.0:
		var base_cols: int = max(1, tile_cols)
		var current_tile_px: float = rect_size.x / float(base_cols)
		desired_tile_px = max(1.0, current_tile_px / max(1.0, GPU_TILE_SCALE))
	var new_cols: int = int(floor(rect_size.x / desired_tile_px))
	var new_rows: int = int(floor(rect_size.y / desired_tile_px))
	new_cols = clamp(new_cols, 8, 2048)
	new_rows = clamp(new_rows, 8, 2048)
	if new_cols == tile_cols and new_rows == tile_rows:
		return
	_set_tile_grid(new_cols, new_rows)

func _set_tile_grid(new_cols: int, new_rows: int) -> void:
	tile_cols = max(1, new_cols)
	tile_rows = max(1, new_rows)
	base_width = tile_cols
	base_height = tile_rows
	if tiles_across_spin:
		tiles_across_spin.set_block_signals(true)
		tiles_across_spin.value = tile_cols
		tiles_across_spin.set_block_signals(false)
	if tiles_down_spin:
		tiles_down_spin.set_block_signals(true)
		tiles_down_spin.value = tile_rows
		tiles_down_spin.set_block_signals(false)
	if lock_aspect_check:
		lock_aspect_check.button_pressed = true
		lock_aspect = true
		if tiles_down_spin:
			tiles_down_spin.editable = false
	_generate_and_draw()

func _on_tiles_across_changed(v: float) -> void:
	tile_cols = int(max(1, v))
	desired_tile_px = 0.0
	# Maintain aspect ratio of the current viewport if locked
	var rect_w: float = max(1.0, float(ascii_map.size.x))
	var rect_h: float = max(1.0, float(ascii_map.size.y))
	var aspect: float = rect_w / rect_h
	if lock_aspect_check and lock_aspect_check.button_pressed:
		lock_aspect = true
		tile_rows = int(round(float(tile_cols) / max(0.01, aspect)))
		if tiles_down_spin:
			tiles_down_spin.value = max(1, tile_rows)
	else:
		lock_aspect = false
	# Apply to generator dims and redraw
	_apply_tile_grid_to_generator()
	_apply_font_to_fit_tiles()

func _on_lock_aspect_toggled(on: bool) -> void:
	lock_aspect = on
	# Recompute rows to match current aspect if locking turned on
	if lock_aspect:
		_on_tiles_across_changed(float(tile_cols))
		if tiles_down_spin:
			tiles_down_spin.editable = false
	else:
		if tiles_down_spin:
			tiles_down_spin.editable = true

func _on_tiles_down_changed(v: float) -> void:
	if lock_aspect_check and lock_aspect_check.button_pressed:
		return
	tile_rows = int(max(1, v))
	desired_tile_px = 0.0
	_apply_tile_grid_to_generator()
	_apply_font_to_fit_tiles()

func _apply_tile_grid_to_generator() -> void:
	base_width = max(1, tile_cols)
	base_height = max(1, tile_rows)
	_generate_and_draw()

# Connect cursor overlay signals
func _connect_cursor_overlay() -> void:
	if cursor_overlay and cursor_overlay.has_signal("tile_hovered"):
		cursor_overlay.tile_hovered.connect(_on_tile_hovered)
		cursor_overlay.mouse_exited_map.connect(_on_cursor_exited)
		if cursor_overlay.has_signal("tile_clicked"):
			cursor_overlay.tile_clicked.connect(_on_tile_clicked)
		# Position overlay to match AsciiMap exactly
		_setup_cursor_overlay_positioning()

func _setup_cursor_overlay_positioning() -> void:
	if cursor_overlay:
		# Wait a frame to ensure ascii_map has proper size
		await get_tree().process_frame
		var map_container = ascii_map.get_parent() if ascii_map else cursor_overlay.get_parent()
		if map_container and cursor_overlay.get_parent() != map_container:
			cursor_overlay.reparent(map_container)
		# Fill entire map rect and capture events for snappy cursor tracking
		cursor_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# Ensure same transform as map (inherit size/scale)
		cursor_overlay.top_level = false
		cursor_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		# Ensure overlay renders above clouds/text (must be <= CANVAS_ITEM_Z_MAX)
		cursor_overlay.z_index = 3000
		# debug removed

# Setup panel hide/show controls
func _setup_panel_controls() -> void:
	if _settings_panel_controller == null and SettingsPanelControllerScript != null:
		_settings_panel_controller = SettingsPanelControllerScript.new()
		add_child(_settings_panel_controller)
	if _settings_panel_controller != null and "initialize" in _settings_panel_controller:
		_settings_panel_controller.initialize(self, bottom_panel, settings_button, hide_button)
	_sync_settings_button_label()

func _sync_settings_button_label() -> void:
	if _settings_panel_controller != null and "is_panel_hidden" in _settings_panel_controller:
		if settings_button:
			settings_button.text = "Show Settings" if VariantCasts.to_bool(_settings_panel_controller.is_panel_hidden()) else "Hide Settings"
		return
	if settings_button and bottom_panel:
		settings_button.text = "Show Settings" if not bottom_panel.visible else "Hide Settings"

func _on_hide_panel_pressed() -> void:
	if _settings_panel_controller != null and "toggle_panel" in _settings_panel_controller:
		_settings_panel_controller.toggle_panel()
		return
	if bottom_panel:
		bottom_panel.visible = not bottom_panel.visible
	_sync_settings_button_label()

func _on_viewport_resized() -> void:
	if _settings_panel_controller != null and "on_viewport_resized" in _settings_panel_controller:
		_settings_panel_controller.on_viewport_resized()
	
	# Update cursor overlay dimensions when window is resized (triggers font rescaling)
	call_deferred("_update_cursor_dimensions")
	if use_gpu_rendering and GPU_AUTO_FIT_TILES:
		_schedule_tile_fit()


func _on_tile_hovered(x: int, y: int) -> void:
	# Record current hover tile and update info immediately
	hover_has_tile = true
	hover_tile_x = x
	hover_tile_y = y
	_update_info_panel_for_tile(x, y)
	# Also update GPU hover overlay immediately (if enabled)
	_gpu_hover_cell(x, y)

func _on_tile_clicked(x: int, y: int, button_index: int) -> void:
	if button_index != MOUSE_BUTTON_LEFT:
		return
	if generator == null:
		return
	var startup_state: Node = get_node_or_null("/root/StartupState")
	var game_state: Node = get_node_or_null("/root/GameState")
	var scene_router: Node = get_node_or_null("/root/SceneRouter")
	var cell_info: Dictionary = generator.get_cell_info(x, y)
	if not VariantCasts.to_bool(cell_info.get("is_land", false)):
		if info_label:
			info_label.text = "Cannot enter ocean/ice tiles."
		return
	if game_state != null and game_state.has_method("initialize_world_snapshot"):
		var biome_snapshot: PackedInt32Array = _capture_biome_snapshot_for_gameplay(generator.get_width(), generator.get_height())
		game_state.initialize_world_snapshot(
			generator.get_width(),
			generator.get_height(),
			int(generator.config.rng_seed),
			biome_snapshot
		)
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(
			"regional",
			x,
			y,
			48,
			48,
			int(cell_info.get("biome", -1)),
			String(cell_info.get("biome_name", "Unknown"))
		)
		if startup_state != null:
			if startup_state.has_method("set_world_snapshot"):
				var biome_snapshot2: PackedInt32Array = _capture_biome_snapshot_for_gameplay(generator.get_width(), generator.get_height())
				startup_state.set_world_snapshot(
					generator.get_width(),
					generator.get_height(),
					int(generator.config.rng_seed),
					biome_snapshot2
				)
		if startup_state.has_method("set_selected_world_tile"):
			startup_state.set_selected_world_tile(
				x,
				y,
				int(cell_info.get("biome", -1)),
				String(cell_info.get("biome_name", "Unknown")),
				48,
				48
			)
	if scene_router != null and scene_router.has_method("goto_regional"):
		scene_router.goto_regional(
			x,
			y,
			48,
			48,
			int(cell_info.get("biome", -1)),
			String(cell_info.get("biome_name", "Unknown"))
		)
	else:
		get_tree().change_scene_to_file(REGIONAL_MAP_SCENE_PATH)

func _on_cursor_exited() -> void:
	if info_label:
		info_label.text = "Hover: -"
	hover_has_tile = false
	hover_tile_x = -1
	hover_tile_y = -1
	_gpu_clear_hover()

func _update_info_panel_for_tile(x: int, y: int) -> void:
	if generator == null or info_label == null:
		return
	if "sync_debug_cpu_snapshot" in generator:
		generator.sync_debug_cpu_snapshot(x, y, 3, 2)
	var game_state: Node = get_node_or_null("/root/GameState")
	HoverInfoControllerScript.update_label(
		info_label,
		generator,
		x,
		y,
		show_bedrock_view,
		ENABLE_SOCIETY_CIV_WORLDGEN,
		_society_hover_cache,
		game_state
	)

func _refresh_hover_info() -> void:
	if not hover_has_tile:
		return
	_update_info_panel_for_tile(hover_tile_x, hover_tile_y)

func _update_cursor_dimensions() -> void:
	# Called after char cache updates to sync cursor overlay
	if cursor_overlay and generator:
		# Force recalculation of character dimensions to ensure we have the latest values
		var saved_char_w = char_w_cached
		var saved_char_h = char_h_cached
		
		# Temporarily clear cache to force fresh calculation
		char_w_cached = 0.0
		char_h_cached = 0.0
		_update_char_size_cache()
		
		# Use the freshly calculated dimensions
		if char_w_cached > 0.0 and char_h_cached > 0.0:
			cursor_overlay.setup_dimensions(generator.get_width(), generator.get_height(), char_w_cached, char_h_cached)
		else:
			# Restore saved values if calculation failed
			char_w_cached = saved_char_w
			char_h_cached = saved_char_h
			cursor_overlay.setup_dimensions(generator.get_width(), generator.get_height(), char_w_cached, char_h_cached)
			
		# Reposition overlay to match ascii_map (use call_deferred to ensure font changes are applied)
		call_deferred("_setup_cursor_overlay_positioning")
		# Ensure GPU hover overlay cleared on dimension changes
		_gpu_clear_hover()
		# Let overlay render its own rect only in string mode
		if cursor_overlay and cursor_overlay.has_method("set_draw_enabled"):
			(cursor_overlay as Node).call("set_draw_enabled", !use_gpu_rendering)
	# In GPU mode, also snap the bottom-panel info grid to the renderer's exact dimensions
	if use_gpu_rendering and gpu_ascii_renderer and gpu_ascii_renderer.has_method("get_map_dimensions"):
		var dims: Vector2i = gpu_ascii_renderer.get_map_dimensions()
		tile_cols = int(dims.x)
		tile_rows = int(dims.y)

func _gpu_hover_cell(x: int, y: int) -> void:
	if use_gpu_rendering and gpu_ascii_renderer and gpu_ascii_renderer.has_method("set_hover_cell"):
		gpu_ascii_renderer.set_hover_cell(x, y)

func _gpu_clear_hover() -> void:
	if use_gpu_rendering and gpu_ascii_renderer and gpu_ascii_renderer.has_method("clear_hover_cell"):
		gpu_ascii_renderer.clear_hover_cell()

func _initialize_gpu_renderer() -> void:
	"""Initialize GPU-based ASCII rendering system"""
	if gpu_ascii_renderer != null and is_instance_valid(gpu_ascii_renderer):
		return
	if ascii_map == null:
		push_error("Main: cannot initialize GPU renderer, AsciiMap node missing.")
		return
	if generator == null:
		push_error("Main: cannot initialize GPU renderer, world generator missing.")
		ascii_map.modulate.a = 0.0
		return
	if _render_controller == null:
		_render_controller = RenderControllerScript.new()
		add_child(_render_controller)
	if _render_controller != null and "initialize_gpu_ascii_renderer" in _render_controller:
		var renderer: Control = _render_controller.initialize_gpu_ascii_renderer(
			ascii_map,
			int(generator.config.width),
			int(generator.config.height)
		)
		if renderer != null:
			gpu_ascii_renderer = renderer
			return
	push_error("Main: GPU renderer init failed via RenderController in GPU-only mode.")
	ascii_map.modulate.a = 0.0

func _get_plate_boundary_mask() -> PackedByteArray:
	# Convert int32 boundary mask to byte mask for rendering
	var mask := PackedByteArray()
	var expected_size: int = 0
	if generator and "config" in generator:
		expected_size = int(generator.config.width) * int(generator.config.height)
	if generator and generator._plates_boundary_mask_render_u8.size() > 0:
		var render_mask: PackedByteArray = generator._plates_boundary_mask_render_u8
		if expected_size <= 0 or render_mask.size() == expected_size:
			mask = render_mask.duplicate()
	if mask.size() == 0 and generator and generator._plates_boundary_mask_i32.size() > 0:
		var mask_size = generator._plates_boundary_mask_i32.size()
		if expected_size <= 0 or mask_size == expected_size:
			mask.resize(mask_size)
			for i in range(mask_size):
				mask[i] = (1 if generator._plates_boundary_mask_i32[i] == 1 else 0)
	return mask
