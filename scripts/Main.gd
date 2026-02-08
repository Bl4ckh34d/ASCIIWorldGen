# File: res://scripts/Main.gd
extends Control
class_name MainController

const WorldConstants = preload("res://scripts/core/WorldConstants.gd")
const HighSpeedValidatorScript = preload("res://scripts/core/HighSpeedValidator.gd")

# --- Performance toggles (turn off heavy systems for faster world map) ---
const ENABLE_SEASONAL_CLIMATE: bool = true
const ENABLE_HYDRO: bool = true
const ENABLE_EROSION: bool = true
const ENABLE_CLOUDS: bool = true
const ENABLE_PLATES: bool = true
const ENABLE_BIOMES_TICK: bool = true
const ENABLE_CRYOSPHERE_TICK: bool = true
const ENABLE_VOLCANISM: bool = true
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

# Bottom panel controls  
var panel_hidden: bool = false

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

func _add_spinbox_to_container(container: Container, min_val: float, max_val: float, step_val: float, value: float) -> SpinBox:
	var spinbox = SpinBox.new()
	spinbox.min_value = min_val
	spinbox.max_value = max_val
	spinbox.step = step_val
	spinbox.value = value
	container.add_child(spinbox)
	return spinbox

func _add_label_with_slider(parent: Container, label_text: String, min_val: float, max_val: float, step_val: float, value: float, callback: Callable) -> Dictionary:
	var container = _add_horizontal_group(parent)
	var label = _add_label_to_container(container, label_text)
	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step_val
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if callback.is_valid(): slider.value_changed.connect(callback)
	container.add_child(slider)
	var value_label = _add_label_to_container(container, "%.3f" % value)
	slider.value_changed.connect(func(v): value_label.text = "%.3f" % v)
	return {"label": label, "slider": slider, "value_label": value_label}

func _add_label_with_spinbox(parent: Container, label_text: String, min_val: float, max_val: float, step_val: float, value: float, callback: Callable) -> SpinBox:
	var container = _add_horizontal_group(parent)
	_add_label_to_container(container, label_text)
	var spinbox = _add_spinbox_to_container(container, min_val, max_val, step_val, value)
	if callback.is_valid(): spinbox.value_changed.connect(callback)
	return spinbox

func _configure_speed_slider(_slider: HSlider, _value_label: Label = null) -> void:
	# Legacy no-op: speed is now controlled via fixed preset buttons.
	pass

func _install_top_speed_buttons() -> void:
	if top_bar == null:
		return
	var insert_index: int = -1
	if top_speed_slider and top_speed_slider.get_parent() == top_bar:
		insert_index = top_speed_slider.get_index()
		if speed_slider == top_speed_slider:
			speed_slider = null
		top_speed_slider.queue_free()
		top_speed_slider = null
	var existing: Node = top_bar.get_node_or_null("SpeedButtonsBar")
	if existing != null and existing is HBoxContainer:
		top_speed_buttons_bar = existing as HBoxContainer
	else:
		top_speed_buttons_bar = HBoxContainer.new()
		top_speed_buttons_bar.name = "SpeedButtonsBar"
		top_bar.add_child(top_speed_buttons_bar)
		if insert_index >= 0:
			top_bar.move_child(top_speed_buttons_bar, insert_index)
	_top_speed_buttons = _create_speed_preset_buttons(top_speed_buttons_bar, true)
	_update_speed_button_states()

func _create_speed_preset_buttons(container: Container, compact_labels: bool) -> Array:
	var created: Array = []
	if container == null:
		return created
	for child in container.get_children():
		child.queue_free()
	for preset in SPEED_PRESETS:
		var speed_scale: float = float(preset)
		var btn := Button.new()
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(46, 0) if compact_labels else Vector2(64, 0)
		btn.text = _speed_button_label(speed_scale, compact_labels)
		btn.tooltip_text = "Set speed to %dx" % int(round(speed_scale))
		btn.pressed.connect(_on_speed_preset_pressed.bind(speed_scale))
		container.add_child(btn)
		created.append(btn)
	return created

func _speed_button_label(speed_scale: float, compact_labels: bool) -> String:
	var rounded: int = int(round(speed_scale))
	if not compact_labels:
		return "%dx" % rounded
	if rounded >= 1000000:
		return "1Mx"
	if rounded >= 100000:
		return "100Kx"
	if rounded >= 10000:
		return "10Kx"
	if rounded >= 1000:
		return "1Kx"
	return "%dx" % rounded

func _on_speed_preset_pressed(speed_scale: float) -> void:
	_set_simulation_speed(speed_scale, false)

func _snap_to_speed_preset(speed_scale: float) -> float:
	var target: float = max(1.0, speed_scale)
	var best: float = float(SPEED_PRESETS[0])
	var best_diff: float = abs(target - best)
	for i in range(1, SPEED_PRESETS.size()):
		var candidate: float = float(SPEED_PRESETS[i])
		var diff: float = abs(target - candidate)
		if diff < best_diff:
			best_diff = diff
			best = candidate
	return best

func _set_simulation_speed(speed_scale: float, force_resync: bool) -> void:
	var snapped_scale: float = _snap_to_speed_preset(speed_scale)
	_selected_speed_scale = snapped_scale
	if time_system and "set_time_scale" in time_system:
		time_system.set_time_scale(snapped_scale)
	_update_speed_labels(snapped_scale)
	_update_speed_button_states()
	_apply_speed_lod_policy(snapped_scale, force_resync)

func _update_speed_button_states() -> void:
	for i in range(SPEED_PRESETS.size()):
		var selected: bool = abs(_selected_speed_scale - float(SPEED_PRESETS[i])) < 0.01
		if i < _top_speed_buttons.size():
			var top_btn: Button = _top_speed_buttons[i]
			if is_instance_valid(top_btn):
				top_btn.set_pressed_no_signal(selected)
		if i < _simulation_speed_buttons.size():
			var sim_btn: Button = _simulation_speed_buttons[i]
			if is_instance_valid(sim_btn):
				sim_btn.set_pressed_no_signal(selected)

func _format_int_with_grouping(v: int) -> String:
	var s: String = str(max(0, v))
	var out: String = ""
	var group_count: int = 0
	for i in range(s.length() - 1, -1, -1):
		out = s.substr(i, 1) + out
		group_count += 1
		if group_count == 3 and i > 0:
			out = "," + out
			group_count = 0
	return out

func _format_speed_value(speed_scale: float) -> String:
	var s: float = max(1.0, speed_scale)
	if s < 10.0:
		if abs(s - round(s)) < 0.05:
			return "%.0fx" % s
		return "%.1fx" % s
	if s < 100.0:
		return "%.0fx" % s
	return "%sx" % _format_int_with_grouping(int(round(s)))

func _update_speed_labels(speed_scale: float) -> void:
	var txt: String = _format_speed_value(speed_scale)
	if speed_value_label:
		speed_value_label.text = txt
	if top_speed_value_label and top_speed_value_label != speed_value_label:
		top_speed_value_label.text = txt

func _sync_season_strength_from_config() -> void:
	if generator == null or season_slider == null:
		return
	var amp_eq: float = float(generator.config.season_amp_equator)
	var amp_pole: float = float(generator.config.season_amp_pole)
	var strength: float = clamp(max(amp_eq / 0.20, amp_pole / 0.45), 0.0, 1.0)
	season_slider.set_block_signals(true)
	season_slider.value = strength
	season_slider.set_block_signals(false)
	if season_value_label:
		season_value_label.text = "x%.2f" % strength

func _sync_temp_slider_from_config() -> void:
	if generator == null or temp_slider == null:
		return
	# Inverse of _on_temp_changed() mapping:
	# min = lerp(-80, 15, v), max = lerp(-15, 80, v)
	var v_from_min: float = (float(generator.config.temp_min_c) + 80.0) / 95.0
	var v_from_max: float = (float(generator.config.temp_max_c) + 15.0) / 95.0
	var v: float = clamp((v_from_min + v_from_max) * 0.5, 0.0, 1.0)
	temp_slider.set_block_signals(true)
	temp_slider.value = v
	temp_slider.set_block_signals(false)
	_update_temp_label()

func _apply_intro_startup_config() -> bool:
	if generator == null:
		return false
	var startup_state: Node = get_node_or_null("/root/StartupState")
	if startup_state == null:
		return false
	if not ("has_pending_world_config" in startup_state):
		return false
	if not startup_state.has_pending_world_config():
		return false
	if not ("consume_world_config" in startup_state):
		return false
	var cfg: Dictionary = startup_state.consume_world_config()
	if cfg.is_empty():
		return false
	generator.apply_config(cfg)
	if sea_slider:
		sea_signal_blocked = true
		sea_slider.value = float(generator.config.sea_level)
		sea_signal_blocked = false
		_update_sea_label()
		sea_last_applied = float(generator.config.sea_level)
		sea_pending_value = sea_last_applied
	if ocean_damp_slider:
		ocean_damp_slider.set_block_signals(true)
		ocean_damp_slider.value = float(generator.config.season_ocean_damp)
		ocean_damp_slider.set_block_signals(false)
	if ocean_damp_value_label:
		ocean_damp_value_label.text = "%.2f" % float(generator.config.season_ocean_damp)
	_sync_temp_slider_from_config()
	_sync_season_strength_from_config()
	if seed_used_label:
		seed_used_label.text = "Used: %d" % int(generator.config.rng_seed)
	_update_top_seed_label()
	return true

# Additional callback functions for the new UI
func _on_play_pressed() -> void:
	if play_button.text == "Play":
		_start_simulation()
	else:
		_stop_simulation()

func _on_reset_pressed() -> void:
	_stop_simulation()
	_generate_new_world()

func _start_simulation() -> void:
	is_running = true
	if play_button: play_button.text = "Pause"
	
	# Apply current seed settings without regenerating world
	# Only update seed if user entered a manual seed
	var manual_seed: String = ""
	if seed_input:
		manual_seed = seed_input.text.strip_edges()
	if manual_seed.length() > 0:
		# User entered a manual seed - apply it and regenerate
		generator.apply_config({"seed": manual_seed})
		_generate_and_draw()
	else:
		# No manual seed - keep current world and just start simulation
		# Update UI to show current seed being used
		if seed_used_label and generator and "config" in generator:
			seed_used_label.text = "Used: %d" % generator.config.rng_seed
		_update_top_seed_label()
	# Ensure persistent buffers are seeded before first simulation tick.
	if generator and "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(true)
	_refresh_plate_masks_for_current_size()
	_redraw_ascii_from_current_state()
	
	# Save initial checkpoint at t=0 for rewind/scrub
	if _checkpoint_sys and "save_checkpoint" in _checkpoint_sys:
		_checkpoint_sys.save_checkpoint(0.0)
	
	# Start time system
	if time_system and "start" in time_system:
		time_system.start()

func _stop_simulation() -> void:
	is_running = false
	if play_button: play_button.text = "Play"
	
	# Pause time system
	if time_system and "pause" in time_system:
		time_system.pause()

func _generate_new_world() -> void:
	is_running = false
	if play_button: play_button.text = "Play"
	generator.clear()
	if time_system and "reset" in time_system:
		time_system.reset()
	
	# Clear checkpoints
	if _checkpoint_sys and "initialize" in _checkpoint_sys:
		_checkpoint_sys.initialize(generator)
	
	_reset_view()
	
	# Reset generates new random seed and clears manual seed input
	if seed_input:
		seed_input.text = ""  # Clear manual seed input
	
	# Reset terrain noise to standard defaults and regenerate with new random seed
	var defaults := {
		"octaves": 5,
		"frequency": 0.02,
		"lacunarity": 2.0,
		"gain": 0.5,
		"warp": 24.0,
		"wrap_x": true,
		"seed": ""  # Empty seed triggers random generation
	}
	generator.apply_config(defaults)
	_generate_and_draw()

func _on_settings_pressed() -> void:
	if bottom_panel and hide_button:
		_on_hide_panel_pressed()

func _show_centered_dialog(dialog: Window) -> void:
	if dialog == null:
		return
	# Avoid re-requesting transient parenting on an already visible popup.
	if dialog.visible:
		dialog.grab_focus()
		return
	dialog.popup_centered()

func _sync_settings_controls_from_generator() -> void:
	if generator == null:
		return
	if noise_octaves_spin:
		noise_octaves_spin.set_block_signals(true)
		noise_octaves_spin.value = float(generator.config.octaves)
		noise_octaves_spin.set_block_signals(false)
	if noise_frequency_spin:
		noise_frequency_spin.set_block_signals(true)
		noise_frequency_spin.value = float(generator.config.frequency)
		noise_frequency_spin.set_block_signals(false)
	if noise_lacunarity_spin:
		noise_lacunarity_spin.set_block_signals(true)
		noise_lacunarity_spin.value = float(generator.config.lacunarity)
		noise_lacunarity_spin.set_block_signals(false)
	if noise_gain_spin:
		noise_gain_spin.set_block_signals(true)
		noise_gain_spin.value = float(generator.config.gain)
		noise_gain_spin.set_block_signals(false)
	if noise_warp_spin:
		noise_warp_spin.set_block_signals(true)
		noise_warp_spin.value = float(generator.config.warp)
		noise_warp_spin.set_block_signals(false)
	if shallow_threshold_spin:
		shallow_threshold_spin.set_block_signals(true)
		shallow_threshold_spin.value = float(generator.config.shallow_threshold)
		shallow_threshold_spin.set_block_signals(false)
	if shore_band_spin:
		shore_band_spin.set_block_signals(true)
		shore_band_spin.value = float(generator.config.shore_band)
		shore_band_spin.set_block_signals(false)
	if shore_noise_mult_spin:
		shore_noise_mult_spin.set_block_signals(true)
		shore_noise_mult_spin.value = float(generator.config.shore_noise_mult)
		shore_noise_mult_spin.set_block_signals(false)
	if polar_cap_frac_slider:
		polar_cap_frac_slider.set_block_signals(true)
		polar_cap_frac_slider.value = float(generator.config.polar_cap_frac)
		polar_cap_frac_slider.set_block_signals(false)
	if bedrock_view_check:
		bedrock_view_check.set_block_signals(true)
		bedrock_view_check.button_pressed = show_bedrock_view
		bedrock_view_check.set_block_signals(false)
	if rivers_enabled_check:
		rivers_enabled_check.set_block_signals(true)
		rivers_enabled_check.button_pressed = bool(generator.config.rivers_enabled)
		rivers_enabled_check.set_block_signals(false)
	if lakes_enabled_check:
		lakes_enabled_check.set_block_signals(true)
		lakes_enabled_check.button_pressed = bool(generator.config.lakes_enabled)
		lakes_enabled_check.set_block_signals(false)
	if river_threshold_spin:
		river_threshold_spin.set_block_signals(true)
		river_threshold_spin.value = float(generator.config.river_threshold_factor)
		river_threshold_spin.set_block_signals(false)
	if river_delta_widening_check:
		river_delta_widening_check.set_block_signals(true)
		river_delta_widening_check.button_pressed = bool(generator.config.river_delta_widening)
		river_delta_widening_check.set_block_signals(false)

func _on_noise_settings_changed() -> void:
	if generator == null:
		return
	var cfg := {}
	if noise_octaves_spin:
		cfg["octaves"] = int(noise_octaves_spin.value)
	if noise_frequency_spin:
		cfg["frequency"] = float(noise_frequency_spin.value)
	if noise_lacunarity_spin:
		cfg["lacunarity"] = float(noise_lacunarity_spin.value)
	if noise_gain_spin:
		cfg["gain"] = float(noise_gain_spin.value)
	if noise_warp_spin:
		cfg["warp"] = float(noise_warp_spin.value)
	if cfg.is_empty():
		return
	generator.apply_config(cfg)
	_generate_and_draw()

func _on_shoreline_settings_changed() -> void:
	if generator == null:
		return
	var cfg := {}
	if shallow_threshold_spin:
		cfg["shallow_threshold"] = float(shallow_threshold_spin.value)
	if shore_band_spin:
		cfg["shore_band"] = float(shore_band_spin.value)
	if shore_noise_mult_spin:
		cfg["shore_noise_mult"] = float(shore_noise_mult_spin.value)
	if cfg.is_empty():
		return
	generator.apply_config(cfg)
	if "quick_update_sea_level" in generator:
		generator.quick_update_sea_level(float(generator.config.sea_level))
		_sync_sea_slider_to_generator()
		_redraw_ascii_from_current_state()
		_update_cursor_dimensions()
		_refresh_hover_info()
	else:
		_generate_and_draw()

func _on_polar_cap_frac_changed(v: float) -> void:
	if generator == null:
		return
	generator.apply_config({"polar_cap_frac": clamp(float(v), 0.0, 0.5)})
	if "quick_update_climate" in generator:
		generator.quick_update_climate()
	if "quick_update_biomes" in generator:
		generator.quick_update_biomes()
	if "quick_update_flow_rivers" in generator:
		generator.quick_update_flow_rivers()
	_redraw_ascii_from_current_state()
	_refresh_hover_info()

func _on_bedrock_view_toggled(enabled: bool) -> void:
	show_bedrock_view = bool(enabled)
	_redraw_ascii_from_current_state()
	_refresh_hover_info()

func _on_hydro_generation_settings_changed() -> void:
	if generator == null:
		return
	var cfg := {}
	if rivers_enabled_check:
		cfg["rivers_enabled"] = bool(rivers_enabled_check.button_pressed)
	if lakes_enabled_check:
		cfg["lakes_enabled"] = bool(lakes_enabled_check.button_pressed)
	if river_threshold_spin:
		cfg["river_threshold_factor"] = float(river_threshold_spin.value)
	if river_delta_widening_check:
		cfg["river_delta_widening"] = bool(river_delta_widening_check.button_pressed)
	if cfg.is_empty():
		return
	generator.apply_config(cfg)
	if "quick_update_sea_level" in generator:
		generator.quick_update_sea_level(float(generator.config.sea_level))
		_sync_sea_slider_to_generator()
	elif "quick_update_flow_rivers" in generator:
		generator.quick_update_flow_rivers()
	else:
		_generate_and_draw()
		return
	_redraw_ascii_from_current_state()
	_refresh_hover_info()

func _on_sea_level_changed(value: float) -> void:
	_on_sea_changed(value)

func _on_year_length_changed(value: float) -> void:
	time_system.set_days_per_year(value)
	if plates_cad:
		plates_cad.value = value  # Update plates cadence to match year length

func _on_sim_fps_changed(value: float) -> void:
	if time_system and time_system._timer:
		time_system._timer.wait_time = 1.0 / float(value)

func _on_budget_changed(value: float) -> void:
	if simulation and "set_max_systems_per_tick" in simulation:
		simulation.set_max_systems_per_tick(int(value))

func _on_time_budget_changed(value: float) -> void:
	if simulation and "set_max_tick_time_ms" in simulation:
		simulation.set_max_tick_time_ms(float(value))

func _on_budget_mode_changed(enabled: bool) -> void:
	if simulation and "set_budget_mode_time" in simulation:
		simulation.set_budget_mode_time(enabled)

func _on_checkpoint_interval_changed(value: float) -> void:
	if _checkpoint_sys and "set_interval_days" in _checkpoint_sys:
		_checkpoint_sys.set_interval_days(float(value))

func _on_save_checkpoint_pressed() -> void:
	if _checkpoint_sys and "save_checkpoint" in _checkpoint_sys:
		_checkpoint_sys.save_checkpoint()

func _on_load_checkpoint_pressed() -> void:
	if _checkpoint_sys and "load_latest_checkpoint" in _checkpoint_sys:
		var result = _checkpoint_sys.load_latest_checkpoint()
		if result["success"]:
			time_system.set_current_time(result["days"])
			if generator and "apply_world_state" in generator:
				generator.apply_world_state(result["state"])
			_redraw_ascii_from_current_state()
		else:
			pass

func _on_refresh_checkpoints_pressed() -> void:
	if _checkpoint_sys and "get_checkpoint_list" in _checkpoint_sys:
		var _ckpts = _checkpoint_sys.get_checkpoint_list()

func _on_scrub_pressed() -> void:
	if _checkpoint_sys and "scrub_to" in _checkpoint_sys and time_system and simulation and generator and "_world_state" in generator:
		var target_days = float(scrub_days_spin.value)
		var result = _checkpoint_sys.scrub_to(target_days)
		if result["success"]:
			time_system.set_current_time(result["days"])
			generator._world_state = result["state"]
			# Apply the restored state
			if "apply_world_state" in generator:
				generator.apply_world_state(result["state"])
			_redraw_ascii_from_current_state()
		else:
			pass

func _on_hydro_cadence_changed(value: float) -> void:
	if simulation and _hydro_sys and "update_cadence" in simulation:
		simulation.update_cadence(_hydro_sys, int(value))

func _on_cloud_cadence_changed(value: float) -> void:
	if simulation and _clouds_sys and "update_cadence" in simulation:
		simulation.update_cadence(_clouds_sys, int(value))

func _on_biome_cadence_changed(value: float) -> void:
	if simulation and "update_cadence" in simulation:
		for sys in _biome_like_systems:
			if sys:
				simulation.update_cadence(sys, int(value))
		if _biome_like_systems.is_empty() and _biome_sys:
			simulation.update_cadence(_biome_sys, int(value))

func _on_cryosphere_cadence_changed(value: float) -> void:
	if simulation and _cryosphere_sys and "update_cadence" in simulation:
		simulation.update_cadence(_cryosphere_sys, int(value))

func _on_plates_cadence_changed(value: float) -> void:
	if simulation and _plates_sys and "update_cadence" in simulation:
		simulation.update_cadence(_plates_sys, int(value))

func _update_cycle_modulation(diurnal_slider: HSlider, seasonal_slider: HSlider) -> void:
	if _clouds_sys and "set_cycle_modulation" in _clouds_sys:
		_clouds_sys.set_cycle_modulation(float(diurnal_slider.value), float(seasonal_slider.value))

func _on_cloud_coupling_changed(enabled: bool) -> void:
	if _clouds_sys and "set_cloud_coupling" in _clouds_sys:
		_clouds_sys.set_cloud_coupling(enabled)

func _force_initial_generation() -> void:
	# debug removed
	if _plates_sys and "_build_plates" in _plates_sys:
		_plates_sys._build_plates()
	generator.generate()
	_refresh_plate_masks_for_current_size()
	_redraw_ascii_from_current_state()

func _print_node_tree(node: Node, depth: int) -> void:
	var _indent = ""
	for i in range(depth):
		_indent += "  "
	# debug removed
	for child in node.get_children():
		_print_node_tree(child, depth + 1)

func _ready() -> void:
	# debug removed
	# Initialize UI node references
	_initialize_ui_nodes()
	call_deferred("_ensure_window_visible")
	_setup_core_runtime()
	_register_simulation_systems()
	_connect_runtime_signals()
	_setup_runtime_ui_and_rendering()
	_setup_runtime_timers()
	_reset_view()
	# Auto-generate first world on startup at base resolution
	base_width = generator.config.width
	base_height = generator.config.height
	_setup_file_dialogs()
	# debug removed
	_entered_from_intro = _apply_intro_startup_config()
	_sync_settings_controls_from_generator()
	_generate_and_draw()
	# capture base dimensions for scaling
	base_width = generator.config.width
	base_height = generator.config.height
	if use_gpu_rendering and GPU_AUTO_FIT_TILES:
		call_deferred("_schedule_tile_fit")
	
	# Connect viewport resize to reposition floating button
	get_viewport().size_changed.connect(_on_viewport_resized)
	if _entered_from_intro:
		_selected_speed_scale = 1.0
	_set_simulation_speed(_selected_speed_scale, true)
	if _entered_from_intro:
		if not panel_hidden:
			if hide_button and bottom_panel:
				_on_hide_panel_pressed()
			elif bottom_panel:
				panel_hidden = true
				bottom_panel.hide()
		if not is_running:
			_start_simulation()
	if _entered_from_intro:
		_defer_intro_scene_reveal()
	else:
		_play_scene_fade_in()

func _setup_core_runtime() -> void:
	generator = load("res://scripts/WorldGenerator.gd").new()
	time_system = load("res://scripts/core/TimeSystem.gd").new()
	add_child(time_system)
	simulation = load("res://scripts/core/Simulation.gd").new()
	add_child(simulation)
	simulation.set_max_tick_time_ms(12.0)
	simulation.set_max_systems_per_tick(2)
	_checkpoint_sys = load("res://scripts/core/CheckpointSystem.gd").new()
	add_child(_checkpoint_sys)
	if "initialize" in _checkpoint_sys:
		_checkpoint_sys.initialize(generator)
	if "set_interval_days" in _checkpoint_sys:
		_checkpoint_sys.set_interval_days(5.0)

func _register_simulation_systems() -> void:
	_register_seasonal_system()
	_register_hydro_system()
	_register_erosion_system()
	_register_cloud_system()
	_register_biome_systems()
	_register_plate_system()
	_register_volcanism_system()

func _connect_runtime_signals() -> void:
	if time_system.has_signal("tick"):
		time_system.connect("tick", Callable(self, "_on_sim_tick"))
	if play_button and not play_button.pressed.is_connected(_on_play_pressed):
		play_button.pressed.connect(_on_play_pressed)
	if reset_button and not reset_button.pressed.is_connected(_on_reset_pressed):
		reset_button.pressed.connect(_on_reset_pressed)

func _setup_runtime_ui_and_rendering() -> void:
	_apply_monospace_font()
	_connect_cursor_overlay()
	_setup_panel_controls()
	if ascii_map:
		ascii_map.modulate.a = 0.0
		ascii_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if use_gpu_rendering:
		_initialize_gpu_renderer()
	if ascii_map:
		ascii_map.resized.connect(_on_map_resized)
	tile_cols = int(generator.config.width)
	tile_rows = int(generator.config.height)
	if sea_slider and sea_value_label:
		_update_sea_label()
		sea_last_applied = float(generator.config.sea_level)
		sea_pending_value = sea_last_applied
	if top_bar:
		top_save_ckpt_button = Button.new(); top_save_ckpt_button.text = "Save"; top_bar.add_child(top_save_ckpt_button)
		top_save_ckpt_button.pressed.connect(func() -> void:
			if save_dialog:
				save_dialog.current_dir = "user://"
				save_dialog.current_file = "world_%d.tres" % int(Time.get_ticks_msec())
				_show_centered_dialog(save_dialog)
		)
		top_load_ckpt_button = Button.new(); top_load_ckpt_button.text = "Load"; top_bar.add_child(top_load_ckpt_button)
		top_load_ckpt_button.pressed.connect(func() -> void:
			if load_dialog:
				load_dialog.current_dir = "user://"
				_show_centered_dialog(load_dialog)
		)
		top_seed_label = Label.new(); top_seed_label.text = "Seed: -"; top_bar.add_child(top_seed_label)
		top_time_label = Label.new(); top_time_label.text = "Time: 0y 0d 00:00"; top_bar.add_child(top_time_label)
		_update_top_seed_label()
		_update_top_time_label()
		add_to_group("MainRoot")
	_sync_season_strength_from_config()

func _setup_runtime_timers() -> void:
	sea_debounce_timer = Timer.new()
	sea_debounce_timer.one_shot = true
	sea_debounce_timer.wait_time = 0.08
	add_child(sea_debounce_timer)
	sea_debounce_timer.timeout.connect(_on_sea_debounce_timeout)
	var temp_timer := Timer.new()
	temp_timer.name = "TempDebounceTimer"
	temp_timer.one_shot = true
	temp_timer.wait_time = 0.12
	add_child(temp_timer)
	(temp_timer as Timer).timeout.connect(_on_temp_debounce_timeout)
	tile_fit_timer = Timer.new()
	tile_fit_timer.one_shot = true
	tile_fit_timer.wait_time = 0.12
	add_child(tile_fit_timer)
	tile_fit_timer.timeout.connect(_on_tile_fit_timeout)

func _setup_file_dialogs() -> void:
	save_dialog = FileDialog.new()
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.access = FileDialog.ACCESS_USERDATA
	save_dialog.title = "Save Worldmap"
	save_dialog.add_filter("*.tres", "Checkpoint (*.tres)")
	add_child(save_dialog)
	save_dialog.file_selected.connect(func(path: String) -> void:
		if _checkpoint_sys and "export_latest_to_file" in _checkpoint_sys:
			_checkpoint_sys.export_latest_to_file(path)
	)
	load_dialog = FileDialog.new()
	load_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	load_dialog.access = FileDialog.ACCESS_USERDATA
	load_dialog.title = "Load Worldmap"
	load_dialog.add_filter("*.tres", "Checkpoint (*.tres)")
	add_child(load_dialog)
	load_dialog.file_selected.connect(func(path: String) -> void:
		if _checkpoint_sys and "import_from_file" in _checkpoint_sys:
			var ok_res: bool = _checkpoint_sys.import_from_file(path)
			if ok_res:
				if year_label and time_system and "get_year_float" in time_system:
					year_label.text = "Year: %.2f" % float(time_system.get_year_float())
				_update_top_time_label()
				_redraw_ascii_from_current_state()
	)

func _register_seasonal_system() -> void:
	if not ENABLE_SEASONAL_CLIMATE:
		return
	_seasonal_sys = load("res://scripts/systems/SeasonalClimateSystem.gd").new()
	if "initialize" in _seasonal_sys:
		_seasonal_sys.initialize(generator, time_system)

func _register_hydro_system() -> void:
	if not ENABLE_HYDRO:
		return
	_hydro_sys = load("res://scripts/systems/HydroUpdateSystem.gd").new()
	if "initialize" in _hydro_sys:
		_hydro_sys.initialize(generator)
		_hydro_sys.tiles_per_tick = 1
	if "register_system" in simulation:
		var ts: float = float(time_system.time_scale) if time_system and "time_scale" in time_system else 1.0
		var hydro_cad_init: int = _cadence_ticks_for_sim_days(float(WorldConstants.CADENCE_HYDRO), ts)
		simulation.register_system(_hydro_sys, hydro_cad_init, 0, false, HYDRO_CATCHUP_MAX_DAYS)

func _register_erosion_system() -> void:
	if not ENABLE_EROSION:
		return
	_erosion_sys = load("res://scripts/systems/RainErosionSystem.gd").new()
	if "initialize" in _erosion_sys:
		_erosion_sys.initialize(generator)
	if "register_system" in simulation:
		var ts: float = float(time_system.time_scale) if time_system and "time_scale" in time_system else 1.0
		var erosion_cad_init: int = _cadence_ticks_for_sim_days(float(WorldConstants.CADENCE_EROSION), ts)
		simulation.register_system(_erosion_sys, erosion_cad_init, 0, true, EROSION_CATCHUP_MAX_DAYS)

func _register_cloud_system() -> void:
	if not ENABLE_CLOUDS:
		return
	_clouds_sys = load("res://scripts/systems/CloudWindSystem.gd").new()
	if "initialize" in _clouds_sys:
		_clouds_sys.initialize(generator, time_system)
	if "register_system" in simulation:
		# Clouds/rain are atmosphere-fast processes: run every simulation tick.
		simulation.register_system(_clouds_sys, 1, 0, false, 1.0)

func _register_biome_systems() -> void:
	if not (ENABLE_BIOMES_TICK or ENABLE_CRYOSPHERE_TICK):
		return
	_biome_like_systems.clear()
	_biome_sys = null
	_cryosphere_sys = null
	var biome_path: String = "res://scripts/systems/BiomeUpdateSystem.gd"
	if ResourceLoader.exists(biome_path):
		if ENABLE_BIOMES_TICK:
			_biome_sys = load(biome_path).new()
			if "initialize" in _biome_sys:
				_biome_sys.initialize(generator)
			if "set_update_modes" in _biome_sys:
				_biome_sys.set_update_modes(true, false)
			if "register_system" in simulation:
				var ts_b: float = float(time_system.time_scale) if time_system and "time_scale" in time_system else 1.0
				var biome_cad_init: int = _cadence_ticks_for_sim_days(float(WorldConstants.CADENCE_BIOMES), ts_b)
				simulation.register_system(_biome_sys, biome_cad_init, 0, true, BIOME_CATCHUP_MAX_DAYS, BIOME_MAX_RUNS_PER_TICK)
			_biome_like_systems.append(_biome_sys)
		if ENABLE_CRYOSPHERE_TICK:
			_cryosphere_sys = load(biome_path).new()
			if "initialize" in _cryosphere_sys:
				_cryosphere_sys.initialize(generator)
			if "set_update_modes" in _cryosphere_sys:
				_cryosphere_sys.set_update_modes(false, true)
			if "register_system" in simulation:
				var ts_c: float = float(time_system.time_scale) if time_system and "time_scale" in time_system else 1.0
				var cryo_cad_init: int = _cadence_ticks_for_sim_days(float(WorldConstants.CADENCE_CRYOSPHERE), ts_c)
				simulation.register_system(_cryosphere_sys, cryo_cad_init, 0, true, CRYOSPHERE_CATCHUP_MAX_DAYS, CRYOSPHERE_MAX_RUNS_PER_TICK)
		return
	var split_systems := [
		{
			"path": "res://scripts/systems/CryosphereUpdateSystem.gd",
			"is_cryosphere": true,
			"enabled": ENABLE_CRYOSPHERE_TICK,
			"cadence": WorldConstants.CADENCE_CRYOSPHERE if "CADENCE_CRYOSPHERE" in WorldConstants else WorldConstants.CADENCE_BIOMES,
			"use_time_debt": false,
			"max_catchup_days": 45.0
		},
		{
			"path": "res://scripts/systems/BiosphereUpdateSystem.gd",
			"is_cryosphere": false,
			"enabled": ENABLE_BIOMES_TICK,
			"cadence": WorldConstants.CADENCE_BIOMES,
			"use_time_debt": false,
			"max_catchup_days": 90.0
		},
		{
			"path": "res://scripts/systems/VegetationUpdateSystem.gd",
			"is_cryosphere": false,
			"enabled": ENABLE_BIOMES_TICK,
			"cadence": WorldConstants.CADENCE_BIOMES,
			"use_time_debt": false,
			"max_catchup_days": 90.0
		}
	]
	for def in split_systems:
		if not bool(def.get("enabled", true)):
			continue
		var path: String = String(def.get("path", ""))
		if not ResourceLoader.exists(path):
			continue
		var sys_obj: Object = load(path).new()
		if "initialize" in sys_obj:
			sys_obj.initialize(generator)
		if "register_system" in simulation:
			simulation.register_system(
				sys_obj,
				int(def.get("cadence", WorldConstants.CADENCE_BIOMES)),
				0,
				bool(def.get("use_time_debt", false)),
				float(def.get("max_catchup_days", 365.0))
			)
		if bool(def.get("is_cryosphere", false)):
			_cryosphere_sys = sys_obj
		else:
			_biome_like_systems.append(sys_obj)
	if not _biome_like_systems.is_empty():
		_biome_sys = _biome_like_systems[0]

func _register_plate_system() -> void:
	if not ENABLE_PLATES:
		return
	_plates_sys = load("res://scripts/systems/PlateSystem.gd").new()
	if "initialize" in _plates_sys:
		_plates_sys.initialize(generator)
	if "register_system" in simulation:
		var ts: float = float(time_system.time_scale) if time_system and "time_scale" in time_system else 1.0
		var plate_cad_init: int = _cadence_ticks_for_sim_days(float(WorldConstants.CADENCE_PLATES), ts)
		simulation.register_system(_plates_sys, plate_cad_init, 0, false, 180.0)

func _register_volcanism_system() -> void:
	if not ENABLE_VOLCANISM:
		return
	_volcanism_sys = load("res://scripts/systems/VolcanismSystem.gd").new()
	if "initialize" in _volcanism_sys:
		_volcanism_sys.initialize(generator, time_system)
	if "register_system" in simulation:
		var ts: float = float(time_system.time_scale) if time_system and "time_scale" in time_system else 1.0
		var volc_cad_init: int = _cadence_ticks_for_sim_days(float(WorldConstants.CADENCE_VOLCANISM), ts)
		simulation.register_system(_volcanism_sys, volc_cad_init, 0, false, 30.0)

func _ensure_scene_fade_overlay() -> ColorRect:
	if is_instance_valid(_scene_fade_rect):
		return _scene_fade_rect
	var fade := ColorRect.new()
	fade.color = Color.BLACK
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.z_index = 4090
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(fade)
	_scene_fade_rect = fade
	return fade

func _defer_intro_scene_reveal() -> void:
	_ensure_scene_fade_overlay()
	_pending_intro_reveal = true
	_intro_reveal_min_delay_elapsed = false
	_intro_reveal_first_tick_seen = false
	var min_timer: SceneTreeTimer = get_tree().create_timer(INTRO_SCENE_REVEAL_MIN_DELAY_SEC)
	min_timer.timeout.connect(func() -> void:
		_intro_reveal_min_delay_elapsed = true
		_try_finish_intro_scene_reveal(false)
	)
	var max_timer: SceneTreeTimer = get_tree().create_timer(INTRO_SCENE_REVEAL_MAX_DELAY_SEC)
	max_timer.timeout.connect(func() -> void:
		_try_finish_intro_scene_reveal(true)
	)

func _try_finish_intro_scene_reveal(force: bool) -> void:
	if not _pending_intro_reveal:
		return
	if not force:
		if not _intro_reveal_min_delay_elapsed:
			return
		if not _intro_reveal_first_tick_seen:
			return
	_pending_intro_reveal = false
	_play_scene_fade_in()

func _play_scene_fade_in() -> void:
	var fade: ColorRect = _ensure_scene_fade_overlay()
	fade.modulate.a = 1.0
	if _scene_fade_tween != null:
		_scene_fade_tween.kill()
	_scene_fade_tween = create_tween()
	_scene_fade_tween.tween_property(fade, "modulate:a", 0.0, 1.10).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_scene_fade_tween.finished.connect(func() -> void:
		if is_instance_valid(_scene_fade_rect):
			_scene_fade_rect.queue_free()
		_scene_fade_rect = null
		_scene_fade_tween = null
	)

func _ensure_window_visible() -> void:
	# Only adjust standalone game windows (avoid moving the editor window)
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var screen: int = DisplayServer.window_get_current_screen()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		return
	var window_size: Vector2i = DisplayServer.window_get_size()
	var new_size := window_size
	if new_size.x > usable.size.x:
		new_size.x = usable.size.x
	if new_size.y > usable.size.y:
		new_size.y = usable.size.y
	if new_size != window_size:
		DisplayServer.window_set_size(new_size)
	var pos: Vector2i = DisplayServer.window_get_position()
	var max_pos := usable.position + usable.size - new_size
	var new_pos := Vector2i(
		clamp(pos.x, usable.position.x, max_pos.x),
		clamp(pos.y, usable.position.y, max_pos.y)
	)
	if new_pos != pos:
		DisplayServer.window_set_position(new_pos)

func _generate_and_draw() -> void:
	_apply_seed_from_ui()
	# scale up resolution by map_scale in both axes
	var scaled_cfg := {
		"width": max(1, base_width * map_scale),
		"height": max(1, base_height * map_scale),
	}
	generator.apply_config(scaled_cfg)
	# Build tectonic plates first so terrain generation can use the same plate layout
	# as a structural foundation (coastline/mountain alignment).
	if _plates_sys and "_build_plates" in _plates_sys:
		_plates_sys._build_plates()
	var generated: PackedByteArray = generator.generate()
	if generated.is_empty():
		push_error("Main: world generation failed; redraw skipped to avoid invalid map state.")
		return
	_acclimate_generated_world()
	_prime_startup_cloud_overrides()
	_refresh_plate_masks_for_current_size()
	_sync_sea_slider_to_generator()
	_redraw_ascii_from_current_state()
	_update_cursor_dimensions()
	_refresh_hover_info()
	_sync_settings_controls_from_generator()
	# Sync world state's notion of time for info overlays
	if time_system and "simulation_time_days" in time_system and "_world_state" in generator:
		generator._world_state.simulation_time_days = float(time_system.simulation_time_days)
		generator._world_state.time_scale = float(time_system.time_scale)
		generator._world_state.tick_days = float(time_system.tick_days)

func _acclimate_generated_world() -> void:
	# Run a tiny hidden warm-up so the first visible frame matches the immediate post-Play state.
	if generator == null or not ("_world_state" in generator) or generator._world_state == null:
		return
	if simulation == null:
		return
	var world_state = generator._world_state
	if time_system:
		world_state.simulation_time_days = float(time_system.simulation_time_days)
		world_state.time_scale = float(time_system.time_scale)
		world_state.tick_days = float(time_system.tick_days)
	# Temporarily unthrottle the simulation scheduler so warm-up reaches a stable state.
	var prev_budget_mode_time: bool = true
	var prev_max_systems: int = 2
	var prev_max_tick_ms: float = 12.0
	if "budget_mode_time_ms" in simulation:
		prev_budget_mode_time = bool(simulation.budget_mode_time_ms)
	if "max_systems_per_tick" in simulation:
		prev_max_systems = int(simulation.max_systems_per_tick)
	if "max_tick_time_ms" in simulation:
		prev_max_tick_ms = float(simulation.max_tick_time_ms)
	if "set_budget_mode_time" in simulation:
		simulation.set_budget_mode_time(false)
	if "set_max_systems_per_tick" in simulation:
		var sys_count: int = 8
		if "systems" in simulation:
			sys_count = max(8, int(simulation.systems.size()) + 4)
		simulation.set_max_systems_per_tick(sys_count)
	if "set_max_tick_time_ms" in simulation:
		simulation.set_max_tick_time_ms(max(prev_max_tick_ms, 1000.0))
	var dt_days: float = STARTUP_ACCLIMATE_STEP_DAYS
	if time_system and "tick_days" in time_system:
		dt_days = max(dt_days, float(time_system.tick_days))
	dt_days = clamp(dt_days, 1.0 / 1440.0, 0.5)
	var warmup_steps: int = max(1, STARTUP_ACCLIMATE_STEPS)
	if "systems" in simulation:
		warmup_steps = max(warmup_steps, int(simulation.systems.size()) + 2)
	if simulation and "request_catchup_all" in simulation:
		simulation.request_catchup_all()
	if _clouds_sys and "request_full_resync" in _clouds_sys:
		# Warm-up should trigger a single cloud resync; cloud ticks themselves are driven via simulation.on_tick().
		_clouds_sys.request_full_resync()
	for wi in range(warmup_steps):
		if _seasonal_sys and "tick" in _seasonal_sys:
			_seasonal_sys.tick(dt_days, world_state, {})
		if simulation and "on_tick" in simulation:
			simulation.on_tick(dt_days, world_state, {})
		world_state.simulation_time_days += dt_days
		# Early out once all forced catch-up flags have been consumed.
		if "systems" in simulation and wi >= max(0, STARTUP_ACCLIMATE_STEPS - 1):
			var has_pending_forced: bool = false
			for sys_state in simulation.systems:
				if bool(sys_state.get("force_next_run", false)):
					has_pending_forced = true
					break
			if not has_pending_forced:
				break
	# Restore scheduler settings.
	if "set_budget_mode_time" in simulation:
		simulation.set_budget_mode_time(prev_budget_mode_time)
	if "set_max_systems_per_tick" in simulation:
		simulation.set_max_systems_per_tick(prev_max_systems)
	if "set_max_tick_time_ms" in simulation:
		simulation.set_max_tick_time_ms(prev_max_tick_ms)
	if time_system:
		time_system.simulation_time_days = float(world_state.simulation_time_days)
	if year_label and time_system and "get_year_float" in time_system:
		year_label.text = "Year: %.2f" % float(time_system.get_year_float())

func _prime_startup_cloud_overrides() -> void:
	# Ensure first render uses the same cloud texture path as runtime (no pre-play mismatch).
	if not use_gpu_rendering or gpu_ascii_renderer == null:
		return
	if generator == null or _clouds_sys == null:
		return
	if not ("_world_state" in generator) or generator._world_state == null:
		return
	if time_system and "simulation_time_days" in time_system:
		generator._world_state.simulation_time_days = float(time_system.simulation_time_days)
		generator._world_state.time_scale = float(time_system.time_scale)
		generator._world_state.tick_days = float(time_system.tick_days)
	if "request_full_resync" in _clouds_sys:
		_clouds_sys.request_full_resync()
	if "tick" in _clouds_sys:
		_clouds_sys.tick(0.0, generator._world_state, {})
	if "cloud_texture_override" in generator and generator.cloud_texture_override:
		gpu_ascii_renderer.set_cloud_texture_override(generator.cloud_texture_override)
	if "light_texture_override" in generator and generator.light_texture_override:
		gpu_ascii_renderer.set_light_texture_override(generator.light_texture_override)
	_sync_gpu_solar_params()

func _sync_gpu_solar_params() -> void:
	if not use_gpu_rendering or gpu_ascii_renderer == null or generator == null:
		return
	var day_of_year: float = 0.0
	var time_of_day: float = 0.0
	if generator.config != null:
		day_of_year = fposmod(float(generator.config.season_phase), 1.0)
		time_of_day = fposmod(float(generator.config.time_of_day), 1.0)
	if gpu_ascii_renderer.has_method("set_solar_params"):
		gpu_ascii_renderer.set_solar_params(day_of_year, time_of_day)

func _refresh_plate_masks_for_current_size() -> void:
	"""Rebuild plate masks immediately after generation so boundary overlay matches current map size."""
	if not _plates_sys or not generator:
		return
	if "_build_plates" in _plates_sys:
		_plates_sys._build_plates()
	if "_world_state" in generator and generator._world_state and "tick" in _plates_sys:
		_plates_sys.tick(0.0, generator._world_state, {})

func _on_sim_tick(_dt_days: float) -> void:
	# Minimal MVP: on each tick, just refresh overlays that depend on time (future: incremental system updates)
	if generator == null:
		return
	if _pending_intro_reveal and not _intro_reveal_first_tick_seen:
		_intro_reveal_first_tick_seen = true
		_try_finish_intro_scene_reveal(false)
	if time_system and "time_scale" in time_system:
		var ts_now: float = max(1.0, float(time_system.time_scale))
		if abs(ts_now - _last_speed_time_scale) > 0.001:
			_apply_speed_lod_policy(ts_now, false)
	
	# Track frame start for lightweight redraw budgeting later in this tick.
	var frame_start_time = Time.get_ticks_usec()
	
	# For now, only update Year label if present and refresh climate season phase into next generation params
	# Redraw ASCII less frequently to avoid heavy load; could throttle with a frame counter
	# Simple approach: regenerate climate/biome every N ticks can be wired later via Simulation
	# Here we just keep time in world state for tooltips
	if "_world_state" in generator:
		generator._world_state.simulation_time_days = float(time_system.simulation_time_days)
		generator._world_state.time_scale = float(time_system.time_scale)
		generator._world_state.tick_days = float(time_system.tick_days)
	if year_label:
		year_label.text = "Year: %.2f" % float(time_system.get_year_float())
	# Always update GPU light when available
	if gpu_ascii_renderer:
		if "light_texture_override" in generator and generator.light_texture_override:
			gpu_ascii_renderer.set_light_texture_override(generator.light_texture_override)
		_sync_gpu_solar_params()
		
	
	# CRITICAL: Always run essential systems like day-night cycle, even if frame budget is tight
	# This ensures the day-night cycle never freezes due to performance budgeting
	if _seasonal_sys and "tick" in _seasonal_sys and "_world_state" in generator:
		_seasonal_sys.tick(_dt_days, generator._world_state, {})
	
	# Always increment counter for consistent timing regardless of frame budget
	_sim_tick_counter += 1
	
	# Always run orchestrated simulation systems.
	# They already have their own internal time budget and cadence controls.
	var simulation_ran: bool = false
	if simulation and "on_tick" in simulation and "_world_state" in generator:
		simulation.on_tick(_dt_days, generator._world_state, {})
		simulation_ran = true
		# If clouds updated, rely on GPU cloud texture override path only.
		# GPU cloud texture override (no CPU readback path)
		if use_gpu_rendering and gpu_ascii_renderer and "cloud_texture_override" in generator and generator.cloud_texture_override:
			gpu_ascii_renderer.set_cloud_texture_override(generator.cloud_texture_override)
		# GPU light texture override (no CPU readback path)
		if use_gpu_rendering and gpu_ascii_renderer and "light_texture_override" in generator and generator.light_texture_override:
			gpu_ascii_renderer.set_light_texture_override(generator.light_texture_override)
			_sync_gpu_solar_params()
		# GPU river texture override (no CPU readback path)
		if use_gpu_rendering and gpu_ascii_renderer and "river_texture_override" in generator and generator.river_texture_override:
			gpu_ascii_renderer.set_river_texture_override(generator.river_texture_override)
		# GPU biome/lava texture overrides (no CPU readback path)
		if use_gpu_rendering and gpu_ascii_renderer and "biome_texture_override" in generator and generator.biome_texture_override:
			gpu_ascii_renderer.set_biome_texture_override(null if show_bedrock_view else generator.biome_texture_override)
		if use_gpu_rendering and gpu_ascii_renderer and "lava_texture_override" in generator and generator.lava_texture_override:
			gpu_ascii_renderer.set_lava_texture_override(generator.lava_texture_override)
		
		# Debug performance every validation interval and auto-tune
		if _sim_tick_counter % HIGH_SPEED_VALIDATION_INTERVAL_TICKS == 0:
			_log_performance_stats()
			_auto_tune_performance()
			_run_high_speed_validation()
	# Ensure clouds still animate even when simulation budget skips systems
	if _clouds_sys and "tick" in _clouds_sys and "_world_state" in generator:
		var allow_fallback_cloud_tick: bool = (time_system and "time_scale" in time_system and float(time_system.time_scale) <= 10.0)
		if (not simulation_ran) and allow_fallback_cloud_tick and not _speed_lod_clouds_paused:
			_clouds_sys.tick(_dt_days, generator._world_state, {})
	
	# Always do these lightweight tasks regardless of frame budget
	# Periodic checkpointing based on in-game time
	if _checkpoint_sys and time_system and "maybe_checkpoint" in _checkpoint_sys:
		_checkpoint_sys.maybe_checkpoint(float(time_system.simulation_time_days))
	
	# Always update essential visual elements for day-night visibility
	# Priority: day-night cycle visibility > frame budget
	var redraw_cadence = _get_adaptive_redraw_cadence()
	if _sim_tick_counter % redraw_cadence == 0:
		# Always sync world state and update time - these are lightweight
		_sync_world_state_from_generator()
		_update_top_time_label()
		
		# Check frame budget for ASCII redraw, but be more permissive for day-night visibility
		var current_time2 = Time.get_ticks_usec()
		var elapsed_ms2 = float(current_time2 - frame_start_time) / 1000.0
		
		# Prioritize day-night visibility - use very generous frame budget allowance
		var total_cells = generator.config.width * generator.config.height
		var force_redraw = total_cells <= 25000  # Force redraw for all but extremely large maps
		
		# For day-night visibility, allow up to 8ms for ASCII redraw (will drop to ~120fps briefly)  
		var generous_budget_ms = 8.0
		
		if force_redraw or elapsed_ms2 < generous_budget_ms:
			_redraw_ascii_from_current_state()
		else:
			# Only skip for extremely large maps and high frame time usage
			pass

	# Hover info is now updated only when mouse moves to a different tile (performance optimization)

func _reset_high_speed_validation_state() -> void:
	if _high_speed_validator == null:
		_high_speed_validator = HighSpeedValidatorScript.new()
	_high_speed_validator.reset_state()

func _collect_total_system_debt_days() -> float:
	if _high_speed_validator == null:
		_high_speed_validator = HighSpeedValidatorScript.new()
	return _high_speed_validator.collect_total_system_debt_days(simulation)

func _run_high_speed_validation() -> void:
	if _high_speed_validator == null:
		_high_speed_validator = HighSpeedValidatorScript.new()
	var result: Dictionary = _high_speed_validator.run(
		simulation,
		time_system,
		generator,
		_sim_tick_counter,
		{
			"min_scale": HIGH_SPEED_VALIDATION_MIN_SCALE,
			"interval_ticks": HIGH_SPEED_VALIDATION_INTERVAL_TICKS,
			"debt_growth_limit": HIGH_SPEED_DEBT_GROWTH_LIMIT,
			"debt_abs_limit_days": HIGH_SPEED_DEBT_ABS_LIMIT_DAYS,
			"skip_delta_limit": HIGH_SPEED_SKIP_DELTA_LIMIT,
			"budget_ratio_limit": HIGH_SPEED_BUDGET_RATIO_LIMIT,
			"progress_ratio_limit": HIGH_SPEED_PROGRESS_RATIO_LIMIT,
			"backlog_days_limit": HIGH_SPEED_BACKLOG_DAYS_LIMIT,
			"warning_interval": 5,
		}
	)
	var warning_text: String = str(result.get("warning", ""))
	if warning_text.length() > 0:
		push_warning(warning_text)

func _log_performance_stats() -> void:
	"""Log performance statistics to help diagnose slow simulation"""
	if simulation and "get_performance_stats" in simulation:
		var stats: Dictionary = simulation.get_performance_stats()
		var ts: float = max(1.0, float(time_system.time_scale)) if time_system and "time_scale" in time_system else 1.0
		if ts >= HIGH_SPEED_VALIDATION_MIN_SCALE:
			var total_debt: float = _collect_total_system_debt_days()
			var backlog_days: float = 0.0
			if time_system and "get_pending_backlog_days" in time_system:
				backlog_days = max(0.0, float(time_system.get_pending_backlog_days()))
			if (_sim_tick_counter % (HIGH_SPEED_VALIDATION_INTERVAL_TICKS * 4)) == 0:
				print(
					"[HS-BENCH] ts=%.0fx avg=%.2fms budget=%.2fms debt=%.2f backlog=%.2f skipped=%d" %
					[
						ts,
						float(stats.get("avg_tick_time_ms", 0.0)),
						float(stats.get("max_budget_ms", 0.0)),
						total_debt,
						backlog_days,
						int(stats.get("skipped_systems_count", 0))
					]
				)

func _auto_tune_performance() -> void:
	"""Automatically adjust performance settings based on current stats with UI priority"""
	if simulation and "get_performance_stats" in simulation:
		var stats = simulation.get_performance_stats()
		var avg_time = stats.get("avg_tick_time_ms", 0)
		var budget = stats.get("max_budget_ms", 12)
		var skip_count = stats.get("skipped_systems_count", 0)
		
		# Prioritize UI responsiveness - keep budget low
		var max_allowed_budget = 14.0  # Never exceed this for UI responsiveness
		
		# If we're consistently over budget, aggressively reduce load
		if avg_time > budget * 0.7:  # More aggressive threshold
			# Slow down expensive systems more aggressively
			if _hydro_sys and "tiles_per_tick" in _hydro_sys:
				_hydro_sys.tiles_per_tick = max(1, _hydro_sys.tiles_per_tick - 1)
			# Only increase budget very slightly and within UI limits
			if skip_count > 15:
				var new_budget = min(max_allowed_budget, budget * 1.05)
				simulation.set_max_tick_time_ms(new_budget)
		
		# If we're consistently under budget, carefully increase performance
		elif avg_time < budget * 0.4 and skip_count == 0:
			# Speed up systems more conservatively
			if _hydro_sys and "tiles_per_tick" in _hydro_sys:
				_hydro_sys.tiles_per_tick = min(2, _hydro_sys.tiles_per_tick + 1)  # Max 2 tiles
		
		# Use built-in auto-tuning but with UI constraints
		if "auto_tune_budget" in simulation:
			simulation.auto_tune_budget()
			# Ensure auto-tuning doesn't exceed UI-friendly limits
			var current_budget = stats.get("max_budget_ms", 12)
			if current_budget > max_allowed_budget:
				simulation.set_max_tick_time_ms(max_allowed_budget)

func _get_adaptive_redraw_cadence() -> int:
	"""Adaptive ASCII redraw cadence prioritizing day-night visibility"""
	if generator == null:
		return WorldConstants.ASCII_REDRAW_CADENCE_MEDIUM
	
	var total_cells = generator.config.width * generator.config.height
	var base_cadence: int = WorldConstants.get_adaptive_redraw_cadence(total_cells)
	var ts: float = 1.0
	if time_system and "time_scale" in time_system:
		ts = max(1.0, float(time_system.time_scale))
	if ts >= 1000000.0:
		return max(base_cadence, 120)
	if ts >= 100000.0:
		return max(base_cadence, 80)
	if ts >= 10000.0:
		return max(base_cadence, 24)
	if ts >= 1000.0:
		return max(base_cadence, 4)
	if ts >= 100.0:
		return max(base_cadence, 2)
	if ts >= 10.0:
		return max(base_cadence, 2)
	return base_cadence

func _update_top_seed_label() -> void:
	if top_seed_label and generator and "config" in generator:
		top_seed_label.text = "Seed: %d" % int(generator.config.rng_seed)

func _update_top_time_label() -> void:
	if top_time_label and time_system and "simulation_time_days" in time_system:
		var days_total: float = float(time_system.simulation_time_days)
		var days_per_year = time_system.get_days_per_year()
		var years: int = int(floor(days_total / days_per_year))
		var rem_days_f: float = fmod(days_total, days_per_year)
		if rem_days_f < 0.0:
			rem_days_f += days_per_year
		var days_int: int = int(floor(rem_days_f))
		var day_frac: float = rem_days_f - float(days_int)
		var minutes_total: int = int(round(day_frac * 24.0 * 60.0))
		if minutes_total >= 24 * 60:
			minutes_total -= 24 * 60
			days_int += 1
		var hours: int = int(floor(float(minutes_total) / 60.0))
		var minutes: int = minutes_total % 60
		top_time_label.text = "Time: %dy %dd %02d:%02d" % [years, days_int, hours, minutes]
func _sync_world_state_from_generator() -> void:
	if generator == null or not ("_world_state" in generator) or generator._world_state == null:
		return
	var ws = generator._world_state
	ws.width = int(generator.config.width)
	ws.height = int(generator.config.height)
	ws.rng_seed = int(generator.config.rng_seed)
	ws.height_scale_m = float(generator.config.height_scale_m)
	ws.temp_min_c = float(generator.config.temp_min_c)
	ws.temp_max_c = float(generator.config.temp_max_c)
	ws.lava_temp_threshold_c = float(generator.config.lava_temp_threshold_c)
	ws.ocean_fraction = float(generator.last_ocean_fraction)
	# Arrays (assign references; they're persistent PackedArrays)
	ws.height_field = generator.last_height
	ws.is_land = generator.last_is_land
	ws.coast_distance = generator.last_water_distance
	ws.turquoise_water = generator.last_is_land
	ws.turquoise_strength = generator.last_turquoise_strength
	ws.beach = generator.last_beach
	ws.flow_dir = generator.last_flow_dir
	ws.flow_accum = generator.last_flow_accum
	ws.river = generator.last_river
	ws.lake = generator.last_lake
	ws.lake_id = generator.last_lake_id
	ws.lava = generator.last_lava
	ws.temperature = generator.last_temperature
	ws.moisture = generator.last_moisture
	ws.precip = PackedFloat32Array() # currently not computed separately
	ws.biome_id = generator.last_biomes

func _redraw_ascii_from_current_state() -> void:
	# Early exit if dimensions are invalid
	var w: int = generator.config.width
	var h: int = generator.config.height
	if w <= 0 or h <= 0:
		return
	if use_gpu_rendering:
		if not gpu_ascii_renderer:
			_initialize_gpu_renderer()
		if gpu_ascii_renderer:
			# GPU-only: refresh base world textures from buffers to avoid CPU packing
			if "update_base_textures_gpu" in generator:
				generator.update_base_textures_gpu(show_bedrock_view)
			if "world_data_1_override" in generator:
				gpu_ascii_renderer.set_world_data_1_override(generator.world_data_1_override)
			if "world_data_2_override" in generator:
				gpu_ascii_renderer.set_world_data_2_override(generator.world_data_2_override)
			# Clear optional GPU texture overrides on full redraw to avoid stale textures after reset.
			if "cloud_texture_override" in generator:
				gpu_ascii_renderer.set_cloud_texture_override(generator.cloud_texture_override)
			if "light_texture_override" in generator:
				gpu_ascii_renderer.set_light_texture_override(generator.light_texture_override)
			_sync_gpu_solar_params()
			if "river_texture_override" in generator:
				gpu_ascii_renderer.set_river_texture_override(generator.river_texture_override)
			if "biome_texture_override" in generator:
				gpu_ascii_renderer.set_biome_texture_override(null if show_bedrock_view else generator.biome_texture_override)
			if "lava_texture_override" in generator:
				gpu_ascii_renderer.set_lava_texture_override(generator.lava_texture_override)
			var skip_base_textures: bool = true
			var skip_aux_textures: bool = skip_base_textures
			var plate_mask_for_render: PackedByteArray = PackedByteArray() if skip_aux_textures else _get_plate_boundary_mask()
			gpu_ascii_renderer.update_ascii_display(
				w, h,
				generator.last_height,
				generator.last_temperature,
				generator.last_moisture,
				generator.last_light,
				generator.last_biomes,
				generator.last_rock_type,
				generator.last_is_land,
				generator.last_beach,
				generator.config.rng_seed,
				show_bedrock_view,
				generator.last_turquoise_strength,
				generator.last_shelf_value_noise_field,
				generator.last_clouds,
				plate_mask_for_render,
				generator.last_lake,
				generator.last_river,
				generator.last_lava,
				generator.last_pooled_lake,
				generator.last_lake_id,
				generator.config.sea_level,
				"",
				skip_base_textures,
				skip_aux_textures
			)
			if ascii_map:
				ascii_map.modulate.a = 0.0
	_update_char_size_cache()

	# Keep bottom panel info in sync with latest tile data
	_refresh_hover_info()

func _on_speed_changed(v: float) -> void:
	# Backward-compatible path if a slider emits values; snap to nearest preset.
	_set_simulation_speed(float(v), false)

func _sim_days_per_tick_for_scale(time_scale: float) -> float:
	var base_tick_days: float = WorldConstants.TICK_DAYS_PER_MINUTE
	if time_system and "tick_days" in time_system:
		base_tick_days = max(1e-6, float(time_system.tick_days))
	return max(0.0, base_tick_days * max(1.0, float(time_scale)))

func _cadence_ticks_for_sim_days(target_sim_days: float, time_scale: float) -> int:
	var days: float = max(1e-6, float(target_sim_days))
	var dt_sim: float = _sim_days_per_tick_for_scale(time_scale)
	if dt_sim <= 1e-9:
		return 1
	return max(1, int(ceil(days / dt_sim)))

func _cap_interval_by_sim_days(current_interval: int, time_scale: float, max_sim_days_per_update: float) -> int:
	var cur: int = max(1, int(current_interval))
	if max_sim_days_per_update <= 0.0:
		return cur
	var dt_sim: float = _sim_days_per_tick_for_scale(time_scale)
	if dt_sim <= 0.0:
		return cur
	var cap_interval: int = int(floor(max_sim_days_per_update / dt_sim))
	cap_interval = max(1, cap_interval)
	return min(cur, cap_interval)

func _apply_speed_lod_policy(time_scale: float, force_resync: bool) -> void:
	var ts: float = max(1.0, time_scale)
	var was_clouds_paused: bool = _speed_lod_clouds_paused
	_speed_lod_clouds_paused = false
	if _clouds_sys and "set_runtime_lod" in _clouds_sys:
		# Clouds/rain/wind should remain continuous in time.
		_clouds_sys.set_runtime_lod(false, 1, 1, 1, 1, 1)
	var climate_interval: int = 1
	var light_interval: int = 1
	climate_interval = _cap_interval_by_sim_days(climate_interval, ts, SPEED_LOD_CLIMATE_MAX_SIM_DAYS)
	if _seasonal_sys and "set_update_intervals" in _seasonal_sys:
		_seasonal_sys.set_update_intervals(climate_interval, light_interval)
	# System intervals are authored in simulation-days for realism and converted to
	# tick cadence based on current time scale.
	var hydro_target_days: float = 0.25      # every ~6 in-sim hours
	var erosion_target_days: float = 0.25    # every ~6 in-sim hours
	var biome_target_days: float = float(WorldConstants.CADENCE_BIOMES)
	var cryosphere_target_days: float = float(WorldConstants.CADENCE_CRYOSPHERE)
	var volcanism_target_days: float = float(WorldConstants.CADENCE_VOLCANISM)
	var plates_target_days: float = 1825.0   # ~5 in-sim years
	if ts >= 1000000.0:
		hydro_target_days = 2.0
		erosion_target_days = 2.0
		biome_target_days = 540.0
		cryosphere_target_days = 30.0
		volcanism_target_days = 21.0
		plates_target_days = 3650.0
	elif ts >= 100000.0:
		hydro_target_days = 1.0
		erosion_target_days = 1.0
		biome_target_days = 360.0
		cryosphere_target_days = 20.0
		volcanism_target_days = 14.0
		plates_target_days = 2920.0
	elif ts >= 10000.0:
		hydro_target_days = 0.5
		erosion_target_days = 0.5
		biome_target_days = 270.0
		cryosphere_target_days = 14.0
		volcanism_target_days = 10.0
		plates_target_days = 1825.0
	elif ts >= SPEED_LIGHT_HEAVY_THROTTLE_THRESHOLD:
		hydro_target_days = 0.5
		erosion_target_days = 0.5
		biome_target_days = 180.0
		cryosphere_target_days = 10.0
		volcanism_target_days = 7.0
		plates_target_days = 1460.0
	elif ts >= 1000.0:
		hydro_target_days = 0.33
		erosion_target_days = 0.33
		biome_target_days = 180.0
		cryosphere_target_days = 7.0
		volcanism_target_days = 4.0
		plates_target_days = 1095.0
	elif ts >= 100.0:
		hydro_target_days = 0.25
		erosion_target_days = 0.25
		biome_target_days = 120.0
		cryosphere_target_days = 4.0
		volcanism_target_days = 2.0
		plates_target_days = 730.0
	elif ts >= 10.0:
		hydro_target_days = 0.25
		erosion_target_days = 0.25
		biome_target_days = 90.0
		cryosphere_target_days = 2.0
		volcanism_target_days = 1.0
		plates_target_days = 365.0
	var hydro_cad: int = _cadence_ticks_for_sim_days(hydro_target_days, ts)
	var erosion_cad: int = _cadence_ticks_for_sim_days(erosion_target_days, ts)
	var biome_cad: int = _cadence_ticks_for_sim_days(biome_target_days, ts)
	var cryosphere_cad: int = _cadence_ticks_for_sim_days(cryosphere_target_days, ts)
	var volcanism_cad: int = _cadence_ticks_for_sim_days(volcanism_target_days, ts)
	var plates_cadence: int = _cadence_ticks_for_sim_days(plates_target_days, ts)
	hydro_cad = _cap_interval_by_sim_days(hydro_cad, ts, SPEED_LOD_HYDRO_MAX_SIM_DAYS)
	erosion_cad = _cap_interval_by_sim_days(erosion_cad, ts, SPEED_LOD_EROSION_MAX_SIM_DAYS)
	biome_cad = _cap_interval_by_sim_days(biome_cad, ts, SPEED_LOD_BIOME_MAX_SIM_DAYS)
	cryosphere_cad = _cap_interval_by_sim_days(cryosphere_cad, ts, SPEED_LOD_CRYOSPHERE_MAX_SIM_DAYS)
	volcanism_cad = _cap_interval_by_sim_days(volcanism_cad, ts, SPEED_LOD_VOLCANISM_MAX_SIM_DAYS)
	plates_cadence = _cap_interval_by_sim_days(max(1, plates_cadence), ts, SPEED_LOD_PLATES_MAX_SIM_DAYS)
	var max_runs_per_tick: int = 8
	if ts >= 1000000.0:
		max_runs_per_tick = 96
	elif ts >= 100000.0:
		max_runs_per_tick = 64
	elif ts >= 10000.0:
		max_runs_per_tick = 32
	elif ts >= 1000.0:
		max_runs_per_tick = 16
	elif ts >= 100.0:
		max_runs_per_tick = 12
	var hydro_min_runs_to_keep_up: int = int(ceil(_sim_days_per_tick_for_scale(ts) / max(1e-6, HYDRO_CATCHUP_MAX_DAYS)))
	var hydro_runs_per_tick: int = clamp(max(max_runs_per_tick, hydro_min_runs_to_keep_up + HYDRO_CATCHUP_EXTRA_RUN_MARGIN), 1, 128)
	if simulation and "set_system_use_time_debt" in simulation:
		if _hydro_sys:
			simulation.set_system_use_time_debt(_hydro_sys, true)
		if _erosion_sys:
			simulation.set_system_use_time_debt(_erosion_sys, true)
		for biome_sys in _biome_like_systems:
			if biome_sys:
				simulation.set_system_use_time_debt(biome_sys, true)
		if _biome_like_systems.is_empty() and _biome_sys:
			simulation.set_system_use_time_debt(_biome_sys, true)
		if _cryosphere_sys:
			simulation.set_system_use_time_debt(_cryosphere_sys, true)
		if _plates_sys:
			simulation.set_system_use_time_debt(_plates_sys, true)
		if _volcanism_sys:
			simulation.set_system_use_time_debt(_volcanism_sys, true)
	if simulation and "set_system_catchup_max_days" in simulation:
		if _hydro_sys:
			simulation.set_system_catchup_max_days(_hydro_sys, HYDRO_CATCHUP_MAX_DAYS)
		if _erosion_sys:
			simulation.set_system_catchup_max_days(_erosion_sys, EROSION_CATCHUP_MAX_DAYS)
		for biome_sys in _biome_like_systems:
			if biome_sys:
				simulation.set_system_catchup_max_days(biome_sys, BIOME_CATCHUP_MAX_DAYS)
		if _biome_like_systems.is_empty() and _biome_sys:
			simulation.set_system_catchup_max_days(_biome_sys, BIOME_CATCHUP_MAX_DAYS)
		if _cryosphere_sys:
			simulation.set_system_catchup_max_days(_cryosphere_sys, CRYOSPHERE_CATCHUP_MAX_DAYS)
		if _plates_sys:
			simulation.set_system_catchup_max_days(_plates_sys, 180.0)
		if _volcanism_sys:
			simulation.set_system_catchup_max_days(_volcanism_sys, 30.0)
	if simulation and "set_system_max_runs_per_tick" in simulation:
		if _hydro_sys:
			simulation.set_system_max_runs_per_tick(_hydro_sys, hydro_runs_per_tick)
		if _erosion_sys:
			simulation.set_system_max_runs_per_tick(_erosion_sys, max_runs_per_tick)
		for biome_sys in _biome_like_systems:
			if biome_sys:
				simulation.set_system_max_runs_per_tick(biome_sys, BIOME_MAX_RUNS_PER_TICK)
		if _biome_like_systems.is_empty() and _biome_sys:
			simulation.set_system_max_runs_per_tick(_biome_sys, BIOME_MAX_RUNS_PER_TICK)
		if _cryosphere_sys:
			simulation.set_system_max_runs_per_tick(_cryosphere_sys, CRYOSPHERE_MAX_RUNS_PER_TICK)
		if _plates_sys:
			simulation.set_system_max_runs_per_tick(_plates_sys, max_runs_per_tick)
		if _volcanism_sys:
			simulation.set_system_max_runs_per_tick(_volcanism_sys, max_runs_per_tick)
	if simulation and "update_cadence" in simulation:
		if _hydro_sys:
			simulation.update_cadence(_hydro_sys, hydro_cad)
		if _erosion_sys:
			simulation.update_cadence(_erosion_sys, erosion_cad)
		for biome_sys in _biome_like_systems:
			if biome_sys:
				simulation.update_cadence(biome_sys, biome_cad)
		if _biome_like_systems.is_empty() and _biome_sys:
			simulation.update_cadence(_biome_sys, biome_cad)
		if _cryosphere_sys:
			simulation.update_cadence(_cryosphere_sys, cryosphere_cad)
		if _plates_sys:
			simulation.update_cadence(_plates_sys, max(1, plates_cadence))
		if _volcanism_sys:
			simulation.update_cadence(_volcanism_sys, volcanism_cad)
	if hydro_spin:
		hydro_spin.set_block_signals(true)
		hydro_spin.value = hydro_cad
		hydro_spin.set_block_signals(false)
	if biome_spin:
		biome_spin.set_block_signals(true)
		biome_spin.value = biome_cad
		biome_spin.set_block_signals(false)
	if cryosphere_spin:
		cryosphere_spin.set_block_signals(true)
		cryosphere_spin.value = cryosphere_cad
		cryosphere_spin.set_block_signals(false)
	if plates_cad:
		plates_cad.set_block_signals(true)
		plates_cad.value = max(1, plates_cadence)
		plates_cad.set_block_signals(false)
	var resumed_clouds: bool = (was_clouds_paused and not _speed_lod_clouds_paused) or force_resync
	if resumed_clouds and _clouds_sys and "request_full_resync" in _clouds_sys:
		_clouds_sys.request_full_resync()
		if is_running and generator and "_world_state" in generator and "tick" in _clouds_sys:
			var warmup_dt: float = 1.0 / 1440.0
			if time_system and "tick_days" in time_system:
				warmup_dt = max(warmup_dt, float(time_system.tick_days))
			_clouds_sys.tick(warmup_dt, generator._world_state, {})
			if use_gpu_rendering and gpu_ascii_renderer and "cloud_texture_override" in generator and generator.cloud_texture_override:
				gpu_ascii_renderer.set_cloud_texture_override(generator.cloud_texture_override)
	var resumed_light: bool = ((_last_speed_time_scale >= SPEED_LIGHT_HEAVY_THROTTLE_THRESHOLD) and (ts < SPEED_LIGHT_HEAVY_THROTTLE_THRESHOLD)) or force_resync
	if resumed_light and _seasonal_sys and "request_full_resync" in _seasonal_sys:
		_seasonal_sys.request_full_resync()
	_last_speed_time_scale = ts

func _on_step_minutes_changed(v: float) -> void:
	# Convert minutes to days per tick
	var days: float = max(1.0, float(v)) / 1440.0
	if time_system and "set_tick_days" in time_system:
		time_system.set_tick_days(days)

func _on_step_pressed() -> void:
	if time_system and "step_once" in time_system:
		time_system.step_once()

func _on_backstep_pressed() -> void:
	# Load checkpoint and deterministically simulate forward to exact target.
	if _checkpoint_sys and "scrub_to" in _checkpoint_sys and time_system and simulation and generator and "_world_state" in generator:
		var t_now: float = float(time_system.simulation_time_days)
		var target: float = max(0.0, t_now - float(time_system.tick_days))
		var ok2: bool = _checkpoint_sys.scrub_to(target, time_system, simulation, generator._world_state)
		if ok2:
			if year_label:
				year_label.text = "Year: %.2f" % float(time_system.get_year_float())
			_redraw_ascii_from_current_state()

func _on_season_strength_changed(v: float) -> void:
	if season_value_label:
		season_value_label.text = "x%.2f" % float(v)
	# Map a single strength to equator/pole amplitudes with a polar boost
	var amp_eq: float = clamp(float(v), 0.0, 1.0) * 0.20
	var amp_pole: float = clamp(float(v), 0.0, 1.0) * 0.45
	if generator:
		generator.apply_config({
			"season_amp_equator": amp_eq,
			"season_amp_pole": amp_pole,
		})
	# Immediate refresh to visualize change
	if "quick_update_climate" in generator:
		generator.quick_update_climate()
	if "quick_update_biomes" in generator:
		generator.quick_update_biomes()
	_redraw_ascii_from_current_state()

func _on_ocean_damp_changed(v: float) -> void:
	if ocean_damp_value_label:
		ocean_damp_value_label.text = "%.2f" % float(v)
	if generator:
		generator.apply_config({"season_ocean_damp": clamp(float(v), 0.0, 1.0)})
	if "quick_update_climate" in generator:
		generator.quick_update_climate()
	if "quick_update_biomes" in generator:
		generator.quick_update_biomes()
	_redraw_ascii_from_current_state()

func _on_rain_strength_changed(v: float) -> void:
	if _clouds_sys and "set_coupling" in _clouds_sys:
		var rain: float = float(v)
		var evap: float = 0.06
		if evap_strength_slider:
			evap = float(evap_strength_slider.value)
		_clouds_sys.set_coupling(rain, evap)

func _on_evap_strength_changed(v: float) -> void:
	if _clouds_sys and "set_coupling" in _clouds_sys:
		var evap: float = float(v)
		var rain: float = 0.08
		if rain_strength_slider:
			rain = float(rain_strength_slider.value)
		_clouds_sys.set_coupling(rain, evap)

func _reset_view() -> void:
	if ascii_map:
		ascii_map.clear()
		ascii_map.append_text("")
	if info_label:
		info_label.text = "Hover: -"
	if seed_used_label:
		seed_used_label.text = "Used: -"
	last_ascii_text = ""
	if cursor_overlay:
		cursor_overlay.hide_cursor()

func _apply_seed_from_ui() -> void:
	var txt: String = ""
	if seed_input:
		txt = seed_input.text.strip_edges()
	var cfg := {}
	if txt.length() == 0:
		# Leave existing seed unchanged; just reflect it in the label
		if seed_used_label and generator and "config" in generator:
			seed_used_label.text = "Used: %d" % generator.config.rng_seed
	else:
		cfg["seed"] = txt
		generator.apply_config(cfg)
		if seed_used_label and generator and "config" in generator:
			seed_used_label.text = "Used: %d" % generator.config.rng_seed
	# If randomize is on, jitter core params slightly per Play
	if randomize_check and randomize_check.button_pressed:
		# Jitter other parameters but preserve current seed
		var cfg2 := RandomizeService.new().jitter_config(generator.config, Time.get_ticks_usec())
		cfg2.erase("seed")
		generator.apply_config(cfg2)
		# Reflect randomized sea level to slider without emitting value_changed
		sea_signal_blocked = true
		sea_slider.value = generator.config.sea_level
		sea_signal_blocked = false
		_update_sea_label()
	else:
		# Apply sea level from slider
		if sea_slider:
			var cfg3 := {}
			cfg3["sea_level"] = float(sea_slider.value)
			generator.apply_config(cfg3)
			_update_sea_label()

func _on_sea_changed(v: float) -> void:
	if sea_value_label:
		sea_value_label.text = "%.2f" % v
	if sea_signal_blocked:
		return
	# Defer heavy regeneration until slider is released
	sea_pending_value = float(v)
	sea_update_pending = true
	if sea_slider == null or not sea_slider.has_signal("drag_ended"):
		if sea_debounce_timer and sea_debounce_timer.is_stopped():
			sea_debounce_timer.start()
	_refresh_hover_info()

func _update_sea_label() -> void:
	if sea_value_label and sea_slider:
		sea_value_label.text = "%.2f" % float(sea_slider.value)

func _sync_sea_slider_to_generator() -> void:
	if sea_slider == null or generator == null:
		return
	var effective: float = generator.config.sea_level
	if abs(float(sea_slider.value) - effective) > 0.0001:
		sea_signal_blocked = true
		sea_slider.value = effective
		sea_signal_blocked = false
		_update_sea_label()
	sea_last_applied = effective
	sea_pending_value = effective

func _on_sea_drag_ended(value_changed: bool) -> void:
	if not value_changed:
		return
	_apply_sea_level_from_slider()

func _apply_sea_level_from_slider() -> void:
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
	if hide_button:
		if not hide_button.pressed.is_connected(_on_hide_panel_pressed):
			hide_button.pressed.connect(_on_hide_panel_pressed)
	_sync_settings_button_label()

func _sync_settings_button_label() -> void:
	if settings_button:
		settings_button.text = "Show Settings" if panel_hidden else "Hide Settings"

func _on_hide_panel_pressed() -> void:
	panel_hidden = !panel_hidden
	if panel_hidden:
		bottom_panel.hide()
		hide_button.text = "Show Panel"
		# Add a floating show button
		_create_floating_show_button()
	else:
		bottom_panel.show()
		hide_button.text = "Hide Panel"
		_remove_floating_show_button()
	_sync_settings_button_label()

var floating_show_button: Button = null

func _create_floating_show_button() -> void:
	if floating_show_button == null:
		floating_show_button = Button.new()
		floating_show_button.text = "Show Settings"
		floating_show_button.z_index = 100
		floating_show_button.pressed.connect(_on_floating_show_pressed)
		add_child(floating_show_button)
		_position_floating_button()

func _remove_floating_show_button() -> void:
	if floating_show_button:
		floating_show_button.queue_free()
		floating_show_button = null

func _position_floating_button() -> void:
	if floating_show_button:
		# Get viewport size
		var viewport_size = get_viewport().get_visible_rect().size
		# Get button size (wait for next frame if not ready)
		await get_tree().process_frame
		var button_size = floating_show_button.size
		if button_size == Vector2.ZERO:
			button_size = Vector2(120, 30)  # fallback size
		# Position at bottom right with 10px margin
		floating_show_button.position = Vector2(
			viewport_size.x - button_size.x - 10,
			viewport_size.y - button_size.y - 10
		)

func _on_viewport_resized() -> void:
	# Reposition floating button when viewport is resized
	if floating_show_button and floating_show_button.visible:
		_position_floating_button()
	
	# Update cursor overlay dimensions when window is resized (triggers font rescaling)
	call_deferred("_update_cursor_dimensions")
	if use_gpu_rendering and GPU_AUTO_FIT_TILES:
		_schedule_tile_fit()

func _on_floating_show_pressed() -> void:
	_on_hide_panel_pressed()  # Toggle back to show


func _on_tile_hovered(x: int, y: int) -> void:
	# Record current hover tile and update info immediately
	hover_has_tile = true
	hover_tile_x = x
	hover_tile_y = y
	_update_info_panel_for_tile(x, y)
	# Also update GPU hover overlay immediately (if enabled)
	_gpu_hover_cell(x, y)

func _on_cursor_exited() -> void:
	if info_label:
		info_label.text = "Hover: -"
	hover_has_tile = false
	hover_tile_x = -1
	hover_tile_y = -1
	_gpu_clear_hover()

func _update_info_panel_for_tile(x: int, y: int) -> void:
	if generator == null:
		return
	if "sync_debug_cpu_snapshot" in generator:
		generator.sync_debug_cpu_snapshot(x, y, 3, 2)
	var w: int = generator.get_width()
	var h: int = generator.get_height()
	if x < 0 or y < 0 or x >= w or y >= h:
		return
	var info = generator.get_cell_info(x, y)
	var coords: String = "(%d,%d)" % [x, y]
	var htxt: String = "%.2f" % info.get("height_m", 0.0)
	var humid: float = info.get("moisture", 0.0)
	var temp_c: float = info.get("temp_c", 0.0)
	var ttxt: String = info.get("rock_name", "Unknown Rock") if show_bedrock_view else info.get("biome_name", "Unknown")
	var flags: PackedStringArray = PackedStringArray()
	if info.get("is_beach", false): flags.append("Beach")
	if info.get("is_lava", false): flags.append("Lava")
	if info.get("is_river", false): flags.append("River")
	if info.get("is_lake", false): flags.append("Lake")
	if info.get("is_plate_boundary", false): flags.append("Tectonic")
	var extra: String = ""
	if flags.size() > 0:
		extra = " - " + ", ".join(flags)
	var geological_info: String = ""
	var total_plates = info.get("tectonic_plates", 0)
	var boundary_cells = info.get("boundary_cells", 0)
	var lava_cells = info.get("active_lava_cells", 0)
	var eruption_potential = info.get("eruption_potential", 0.0)
	if total_plates > 0 or lava_cells > 0:
		var parts: PackedStringArray = []
		if total_plates > 0:
			parts.append("%d plates" % total_plates)
		if boundary_cells > 0:
			parts.append("%d boundaries" % boundary_cells)
		if lava_cells > 0:
			parts.append("%d lava cells" % lava_cells)
		if eruption_potential > 0.01:
			parts.append("%.1f%% volcanic" % eruption_potential)
		if parts.size() > 0:
			geological_info = " | " + ", ".join(parts)
	if info_label:
		var type_label: String = "Lithology" if show_bedrock_view else "Type"
		info_label.text = "%s - %s - %s: %s - Humidity: %.2f - Temp: %.1f degC%s%s" % [coords, htxt, type_label, ttxt, humid, temp_c, extra, geological_info]

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
	
	# Load GPU renderer class dynamically
	var GPUAsciiRendererClass = load("res://scripts/rendering/GPUAsciiRenderer.gd")
	if not GPUAsciiRendererClass:
		push_error("Failed to load GPUAsciiRenderer.gd in GPU-only mode.")
		if ascii_map:
			ascii_map.modulate.a = 0.0
		return
	
	# Create GPU renderer as a sibling to ASCII map in MapContainer
	gpu_ascii_renderer = GPUAsciiRendererClass.new()
	gpu_ascii_renderer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gpu_ascii_renderer.z_index = 0  # Keep above background; cursor overlay handles its own z_index
	gpu_ascii_renderer.mouse_filter = Control.MOUSE_FILTER_IGNORE  # Don't block mouse events
	var map_container = ascii_map.get_parent() if ascii_map else null
	if map_container and map_container is Control:
		(map_container as Control).add_child(gpu_ascii_renderer)
		(map_container as Control).move_child(gpu_ascii_renderer, 0)  # Move to back
	
	# Get default font from ascii_map
	var default_font = ascii_map.get_theme_font("normal_font")
	if not default_font:
		default_font = ascii_map.get_theme_default_font()
	
	var font_size = ascii_map.get_theme_font_size("normal_font_size")
	if font_size <= 0:
		font_size = ascii_map.get_theme_default_font_size()
	
	# Initialize with current map dimensions
	if gpu_ascii_renderer.has_method("initialize_gpu_rendering"):
		var success = gpu_ascii_renderer.initialize_gpu_rendering(
			default_font, 
			font_size,
			generator.config.width,
			generator.config.height
		)
		
		if success:
			# Check if GPU renderer is actually using GPU rendering
			if gpu_ascii_renderer.has_method("is_using_gpu_rendering") and gpu_ascii_renderer.is_using_gpu_rendering():
				# Hide the original RichTextLabel when using actual GPU rendering
				ascii_map.modulate.a = 0.0
			else:
				push_error("GPUAsciiRenderer initialized without GPU path; CPU fallback is disabled.")
				ascii_map.modulate.a = 0.0
		else:
			push_error("GPU ASCII rendering initialization failed in GPU-only mode.")
			gpu_ascii_renderer.queue_free()
			gpu_ascii_renderer = null
			ascii_map.modulate.a = 0.0
	else:
		push_error("GPUAsciiRenderer missing initialize_gpu_rendering() in GPU-only mode.")
		gpu_ascii_renderer.queue_free()
		gpu_ascii_renderer = null
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
