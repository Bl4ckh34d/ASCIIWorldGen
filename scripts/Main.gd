# File: res://scripts/Main.gd
extends Control

const WorldConstants = preload("res://scripts/core/WorldConstants.gd")

# UI References - will be set in _initialize_ui_nodes()
var play_button: Button
var reset_button: Button
var step_button: Button
var backstep_button: Button
var randomize_check: CheckBox
var speed_slider: HSlider
var speed_value_label: Label
var year_label: Label
var settings_button: Button

var ascii_map: RichTextLabel
var info_label: Label
var cursor_overlay: Control
var settings_dialog: Window

var hide_button: Button
var bottom_panel: PanelContainer

# Tab containers
var generation_vbox: VBoxContainer
var terrain_vbox: VBoxContainer
var climate_vbox: VBoxContainer
var hydro_vbox: VBoxContainer
var simulation_vbox: VBoxContainer
var systems_vbox: VBoxContainer

# UI Box containers for legacy UI sections
var general_box: VBoxContainer
var systems_box: VBoxContainer
var simulation_box: VBoxContainer
var climate_box: VBoxContainer
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
var season_slider: HSlider
var season_value_label: Label
var ocean_damp_slider: HSlider
var ocean_damp_value_label: Label
var _sim_tick_counter: int = 0
var _seasonal_sys: Object
var _hydro_sys: Object
var _clouds_sys: Object
var _biome_sys: Object
var _plates_sys: Object
var cloud_coupling_check: CheckBox
var rain_strength_slider: HSlider
var evap_strength_slider: HSlider

var is_running: bool = false
var generator: Object
var time_system: Node
var simulation: Node
var _checkpoint_sys: Node
var AsciiStyler = load("res://scripts/style/AsciiStyler.gd")
const RandomizeService = preload("res://scripts/ui/RandomizeService.gd")
# Load GPU renderer dynamically to avoid preload issues
var cloud_map: RichTextLabel
var last_ascii_text: String = ""
var styler_single: Object
var char_w_cached: float = 0.0
var char_h_cached: float = 0.0
var sea_debounce_timer: Timer
var sea_update_pending: bool = false
var sea_signal_blocked: bool = false
var map_scale: int = 1
var base_width: int = 0
var base_height: int = 0
var tile_cols: int = 0
var tile_rows: int = 0
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
var use_gpu_rendering: bool = false
var gpu_rendering_toggle: CheckBox

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

func _initialize_ui_nodes() -> void:
	"""Initialize all UI node references with the new layout"""
	
	# Get main UI elements (support both scene variants via unique name lookup)
	top_bar = get_node_or_null("%TopBar")
	play_button = get_node_or_null("%TopBar/PlayButton")
	reset_button = get_node_or_null("%TopBar/ResetButton")
	step_button = get_node_or_null("%TopBar/StepButton")
	backstep_button = get_node_or_null("%TopBar/BackStepButton")
	randomize_check = get_node_or_null("%TopBar/Randomize")
	speed_slider = get_node_or_null("%TopBar/SpeedSlider")
	speed_value_label = get_node_or_null("%TopBar/SpeedValue")
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
	
	# Settings dialog - WITH NULL CHECK TO PREVENT CRASH
	settings_dialog = get_node_or_null("SettingsDialog")
	
	print("UI Layout initialized:")
	print("  play_button: ", play_button != null)
	print("  ascii_map: ", ascii_map != null)
	print("  generation_vbox: ", generation_vbox != null)
	print("  bottom_panel: ", bottom_panel != null)
	print("  settings_dialog: ", settings_dialog != null)
	
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
	if speed_slider:
		if not speed_slider.value_changed.is_connected(_on_speed_changed):
			speed_slider.value_changed.connect(_on_speed_changed)
		# Update label using a type-safe branch (avoid incompatible ternary types)
		speed_slider.value_changed.connect(func(v):
			if speed_value_label:
				speed_value_label.text = "%.1fx" % v
		)
	
	# Setup all tab content
	_setup_all_tabs()
	
	# DISABLE ALL COMPLEX UI SETUP
	# terrain_vbox = get_node_or_null("%TerrainVBox")
	# ... all other UI elements commented out
	
	print("=== MINIMAL UI SETUP COMPLETE ===")

func _setup_all_tabs() -> void:
	"""Setup content for all tabs with proper organization"""
	_setup_generation_tab()
	_setup_terrain_tab()
	_setup_climate_tab()
	_setup_hydro_tab()
	_setup_simulation_tab()
	_setup_systems_tab()

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

func _setup_terrain_tab() -> void:
	"""Setup Terrain tab - elevation, continents, sea level"""
	if not terrain_vbox: return
	
	# Sea level
	_add_section_header(terrain_vbox, "Sea Level")
	var sea_result = _add_label_with_slider(terrain_vbox, "Sea Level:", -1.0, 1.0, 0.01, 0.0, func(v): _on_sea_level_changed(v))
	sea_slider = sea_result.slider
	sea_value_label = sea_result.value_label
	
	# Continental parameters
	_add_section_header(terrain_vbox, "Continental Shape")
	var cont_result = _add_label_with_slider(terrain_vbox, "Continentality:", 0.0, 3.0, 0.01, 1.2, func(v): _on_cont_changed(v))
	cont_slider = cont_result.slider
	cont_value_label = cont_result.value_label
	
	# Temperature
	_add_section_header(terrain_vbox, "Temperature")
	var temp_result = _add_label_with_slider(terrain_vbox, "Temperature:", 0.0, 1.0, 0.001, 0.5, func(v): _on_temp_changed(v))
	temp_slider = temp_result.slider
	temp_value_label = temp_result.value_label

func _setup_climate_tab() -> void:
	"""Setup Climate tab - weather, precipitation, seasons"""
	if not climate_vbox: return
	
	# Seasonal controls
	_add_section_header(climate_vbox, "Seasonal Effects")
	var season_result = _add_label_with_slider(climate_vbox, "Season Strength:", 0.0, 1.0, 0.01, 0.0, func(v): _on_season_strength_changed(v))
	season_slider = season_result.slider
	season_value_label = season_result.value_label
	
	# Precipitation
	_add_section_header(climate_vbox, "Precipitation")
	cloud_coupling_check = _add_checkbox(climate_vbox, "Couple Clouds/Rain", true, func(v): _on_cloud_coupling_changed(v))
	var rain_result = _add_label_with_slider(climate_vbox, "Rain Strength:", 0.0, 0.2, 0.005, 0.08, func(v): _on_rain_strength_changed(v))
	rain_strength_slider = rain_result.slider
	var evap_result = _add_label_with_slider(climate_vbox, "Evaporation:", 0.0, 0.2, 0.005, 0.06, func(v): _on_evap_strength_changed(v))
	evap_strength_slider = evap_result.slider
	
	# Climate cycles
	_add_section_header(climate_vbox, "Climate Cycles")
	var diurnal_result = _add_label_with_slider(climate_vbox, "Diurnal Mod:", 0.0, 2.0, 0.05, 0.5, Callable())
	var seasonal_result = _add_label_with_slider(climate_vbox, "Seasonal Mod:", 0.0, 2.0, 0.05, 0.5, Callable())
	
	# Connect cycle modulation
	diurnal_result.slider.value_changed.connect(func(_v): _update_cycle_modulation(diurnal_result.slider, seasonal_result.slider))
	seasonal_result.slider.value_changed.connect(func(_v): _update_cycle_modulation(diurnal_result.slider, seasonal_result.slider))
	
	# Ocean damping
	_add_section_header(climate_vbox, "Ocean Effects")
	var ocean_result = _add_label_with_slider(climate_vbox, "Ocean Damping:", 0.0, 1.0, 0.01, 0.6, func(v): _on_ocean_damp_changed(v))
	ocean_damp_slider = ocean_result.slider
	ocean_damp_value_label = ocean_result.value_label

func _setup_hydro_tab() -> void:
	"""Setup Hydro tab - rivers, lakes, water flow"""
	if not hydro_vbox: return
	
	_add_section_header(hydro_vbox, "Hydrology System")
	_add_label(hydro_vbox, "Hydrology system controls will be added here")
	# TODO: Add hydrology specific controls when available

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
	
	fps_spin = _add_label_with_spinbox(simulation_vbox, "Simulation FPS:", 1.0, 60.0, 1.0, 10.0, func(v): _on_sim_fps_changed(v))
	speed_slider = _add_label_with_slider(simulation_vbox, "Speed:", 0.0, 2.0, 0.01, 0.2, func(v): _on_speed_changed(v)).slider
	
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
	gpu_rendering_toggle = _add_checkbox(simulation_vbox, "GPU Rendering", use_gpu_rendering, func(v): _on_gpu_rendering_toggled(v))
	
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
	biome_spin = _add_label_with_spinbox(systems_vbox, "Biomes:", 1, 200, 1, 90, func(v): _on_biome_cadence_changed(v))
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
	if settings_dialog:
		settings_dialog.popup_centered()

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
		print("Checkpoint saved")

func _on_load_checkpoint_pressed() -> void:
	if _checkpoint_sys and "load_latest_checkpoint" in _checkpoint_sys:
		var result = _checkpoint_sys.load_latest_checkpoint()
		if result["success"]:
			time_system.set_current_time(result["days"])
			if generator and "apply_world_state" in generator:
				generator.apply_world_state(result["state"])
			_redraw_ascii_from_current_state()
			print("Checkpoint loaded: day ", result["days"])
		else:
			print("Load failed: ", result.get("error", "No checkpoints available"))

func _on_refresh_checkpoints_pressed() -> void:
	if _checkpoint_sys and "get_checkpoint_list" in _checkpoint_sys:
		var ckpts = _checkpoint_sys.get_checkpoint_list()
		print("Available checkpoints: ", ckpts.size())
		for ckpt in ckpts:
			print("  Day %.1f" % ckpt["days"])

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
			print("Scrubbed to day ", result["days"])
		else:
			print("Scrub failed: ", result.get("error", "Unknown error"))

func _on_hydro_cadence_changed(value: float) -> void:
	if simulation and _hydro_sys and "update_cadence" in simulation:
		simulation.update_cadence(_hydro_sys, int(value))

func _on_cloud_cadence_changed(value: float) -> void:
	if simulation and _clouds_sys and "update_cadence" in simulation:
		simulation.update_cadence(_clouds_sys, int(value))

func _on_biome_cadence_changed(value: float) -> void:
	if simulation and _biome_sys and "update_cadence" in simulation:
		simulation.update_cadence(_biome_sys, int(value))

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
	print("DEBUG: Force generating initial world...")
	if ascii_map:
		generator.generate()
		var w = generator.config.width
		var h = generator.config.height
		var styler = AsciiStyler.new()
		# Simplified call with minimal required parameters
		var ascii_str = styler.build_ascii(w, h, generator.last_height, generator.last_is_land)
		ascii_map.clear()
		ascii_map.append_text(ascii_str)
		print("DEBUG: Forced generation complete - ascii length: ", ascii_str.length())
	else:
		print("DEBUG: ascii_map is null - cannot generate!")

func _print_node_tree(node: Node, depth: int) -> void:
	var indent = ""
	for i in range(depth):
		indent += "  "
	print(indent + node.name + " (" + node.get_class() + ")")
	for child in node.get_children():
		_print_node_tree(child, depth + 1)

func _ready() -> void:
	print("Main: _ready")
	# Initialize UI node references
	_initialize_ui_nodes()
	generator = load("res://scripts/WorldGenerator.gd").new()
	# Create time and simulation nodes
	time_system = load("res://scripts/core/TimeSystem.gd").new()
	add_child(time_system)
	simulation = load("res://scripts/core/Simulation.gd").new()
	add_child(simulation)
	# Balance simulation performance with UI responsiveness
	simulation.set_max_tick_time_ms(12.0)  # Allow up to 12ms per tick (keep UI at 60fps)
	simulation.set_max_systems_per_tick(2)  # Fewer systems per tick for smoother UI
	# Create checkpoint system (in-memory ring buffer)
	_checkpoint_sys = load("res://scripts/core/CheckpointSystem.gd").new()
	add_child(_checkpoint_sys)
	if "initialize" in _checkpoint_sys:
		_checkpoint_sys.initialize(generator)
	if "set_interval_days" in _checkpoint_sys:
		_checkpoint_sys.set_interval_days(5.0)
	# Register seasonal climate param updater
	_seasonal_sys = load("res://scripts/systems/SeasonalClimateSystem.gd").new()
	if "initialize" in _seasonal_sys:
		_seasonal_sys.initialize(generator, time_system)
	# NOTE: SeasonalClimateSystem now runs directly in _on_sim_tick() to ensure it's never skipped due to frame budgeting
	# Register hydro updater at a much slower cadence (most expensive system)
	_hydro_sys = load("res://scripts/systems/HydroUpdateSystem.gd").new()
	if "initialize" in _hydro_sys:
		_hydro_sys.initialize(generator)
		# Reduce tiles per tick for hydro system performance
		_hydro_sys.tiles_per_tick = 1  # Process 1 tile per tick instead of 2
	if "register_system" in simulation:
		simulation.register_system(_hydro_sys, 30, 0)  # Hydro: seasonal changes (monthly)
	# Register cloud/wind overlay updater (visual only for now)
	_clouds_sys = load("res://scripts/systems/CloudWindSystem.gd").new()
	if "initialize" in _clouds_sys:
		_clouds_sys.initialize(generator, time_system)
	if "register_system" in simulation:
		simulation.register_system(_clouds_sys, 7, 0)  # Clouds: weekly weather patterns
	# Register biome reclassify system (cadence separate from climate)
	_biome_sys = load("res://scripts/systems/BiomeUpdateSystem.gd").new()
	# Register plates prototype at a very slow cadence
	_plates_sys = load("res://scripts/systems/PlateSystem.gd").new()
	if "initialize" in _plates_sys:
		_plates_sys.initialize(generator)
	if "register_system" in simulation:
		simulation.register_system(_plates_sys, int(time_system.get_days_per_year()), 0)  # Plate tectonics: once per simulated year
	if "initialize" in _biome_sys:
		_biome_sys.initialize(generator)
	if "register_system" in simulation:
		simulation.register_system(_biome_sys, 90, 0)  # Biomes: seasonal ecosystem shifts
	# Register volcanism system at slower cadence
	var _volc_sys: Object = load("res://scripts/systems/VolcanismSystem.gd").new()
	if "initialize" in _volc_sys:
		_volc_sys.initialize(generator, time_system)
	if "register_system" in simulation:
		simulation.register_system(_volc_sys, 3, 0)  # Volcanism: rapid geological events
	# Forward ticks to simulation (world state lives in generator)
	if time_system.has_signal("tick"):
		time_system.connect("tick", Callable(self, "_on_sim_tick"))
	# Guard against missing buttons and duplicate connects
	if play_button and not play_button.pressed.is_connected(_on_play_pressed):
		play_button.pressed.connect(_on_play_pressed)
	if reset_button and not reset_button.pressed.is_connected(_on_reset_pressed):
		reset_button.pressed.connect(_on_reset_pressed)
	_apply_monospace_font()
	_connect_cursor_overlay()
	_setup_panel_controls()
	# Ensure ASCII map is visible
	if ascii_map:
		ascii_map.modulate.a = 1.0
	# Create cloud overlay label above the ASCII map
	cloud_map = RichTextLabel.new()
	cloud_map.bbcode_enabled = true
	cloud_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cloud_map.z_index = 2000
	cloud_map.fit_content = false
	cloud_map.scroll_active = false
	cloud_map.clip_contents = false
	cloud_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cloud_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cloud_map.anchors_preset = Control.PRESET_FULL_RECT
	ascii_map.add_child(cloud_map)
	
	# Initialize GPU ASCII renderer if toggled on
	if use_gpu_rendering:
		_initialize_gpu_renderer()
	
	styler_single = AsciiStyler.new()
	if ascii_map:
		ascii_map.resized.connect(_on_map_resized)
	# Init tile grid from current generator config
	tile_cols = int(generator.config.width)
	tile_rows = int(generator.config.height)
	if sea_slider and sea_value_label:
		sea_slider.value_changed.connect(_on_sea_changed)
		_update_sea_label()
	else:
		print("ERROR: sea_slider or sea_value_label is null - check scene structure")
	# Build left panel tabs UI; if legacy boxes are missing, continue gracefully
	if not general_box:
		print("ERROR: general_box is null - check scene structure")
	if general_box:
		var temp_label := Label.new(); temp_label.text = "Temp"; general_box.add_child(temp_label)
		temp_slider = HSlider.new(); temp_slider.min_value = 0.0; temp_slider.max_value = 1.0; temp_slider.step = 0.001; temp_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; general_box.add_child(temp_slider)
		temp_value_label = Label.new(); temp_value_label.text = ""; general_box.add_child(temp_value_label)
		temp_slider.value_changed.connect(_on_temp_changed)
		_update_temp_label()
		var cont_label := Label.new(); cont_label.text = "Cont"; general_box.add_child(cont_label)
		cont_slider = HSlider.new(); cont_slider.min_value = 0.0; cont_slider.max_value = 3.0; cont_slider.step = 0.01; cont_slider.value = 1.2; cont_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; general_box.add_child(cont_slider)
		cont_value_label = Label.new(); cont_value_label.text = ""; general_box.add_child(cont_value_label)
		cont_slider.value_changed.connect(_on_cont_changed)
		_update_cont_label()
		var season_lbl := Label.new(); season_lbl.text = "Season"; general_box.add_child(season_lbl)
		season_slider = HSlider.new(); season_slider.min_value = 0.0; season_slider.max_value = 1.0; season_slider.step = 0.01; season_slider.value = 0.0; season_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; general_box.add_child(season_slider)
		season_value_label = Label.new(); season_value_label.text = "x0.00"; general_box.add_child(season_value_label)
		season_slider.value_changed.connect(_on_season_strength_changed)
		var od_lbl := Label.new(); od_lbl.text = "OceanDamp"; general_box.add_child(od_lbl)
		ocean_damp_slider = HSlider.new(); ocean_damp_slider.min_value = 0.0; ocean_damp_slider.max_value = 1.0; ocean_damp_slider.step = 0.01; ocean_damp_slider.value = 0.6; ocean_damp_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; general_box.add_child(ocean_damp_slider)
		ocean_damp_value_label = Label.new(); ocean_damp_value_label.text = "0.60"; general_box.add_child(ocean_damp_value_label)
		ocean_damp_slider.value_changed.connect(_on_ocean_damp_changed)
	if systems_box:
		var cad_lbl := Label.new(); cad_lbl.text = "Cadence"; systems_box.add_child(cad_lbl)
		var clim_cad := SpinBox.new(); clim_cad.min_value = 1; clim_cad.max_value = 120; clim_cad.step = 1; clim_cad.value = 1; systems_box.add_child(clim_cad)
		clim_cad.tooltip_text = "SeasonalClimateSystem now runs every tick (bypasses simulation orchestrator)"
		clim_cad.editable = false  # Can't be changed since it runs directly in main loop
		var hydro_cad := SpinBox.new(); hydro_cad.min_value = 1; hydro_cad.max_value = 120; hydro_cad.step = 1; hydro_cad.value = 30; systems_box.add_child(hydro_cad)
		hydro_cad.value_changed.connect(func(v: float) -> void:
			if simulation and _hydro_sys and "update_cadence" in simulation:
				simulation.update_cadence(_hydro_sys, int(v))
		)
		var cloud_cad := SpinBox.new(); cloud_cad.min_value = 1; cloud_cad.max_value = 120; cloud_cad.step = 1; cloud_cad.value = 7; systems_box.add_child(cloud_cad)
		cloud_cad.value_changed.connect(func(v: float) -> void:
			if simulation and _clouds_sys and "update_cadence" in simulation:
				simulation.update_cadence(_clouds_sys, int(v))
		)
		var biome_cad_lbl := Label.new(); biome_cad_lbl.text = "Biome"; systems_box.add_child(biome_cad_lbl)
		var biome_cad := SpinBox.new(); biome_cad.min_value = 1; biome_cad.max_value = 200; biome_cad.step = 1; biome_cad.value = 90; systems_box.add_child(biome_cad)
		biome_cad.value_changed.connect(func(v: float) -> void:
			if simulation and _biome_sys and "update_cadence" in simulation:
				simulation.update_cadence(_biome_sys, int(v))
		)
		var plates_cad_lbl := Label.new(); plates_cad_lbl.text = "Plates"; systems_box.add_child(plates_cad_lbl)
		plates_cad = SpinBox.new(); plates_cad.min_value = 1; plates_cad.max_value = 1000; plates_cad.step = 1; plates_cad.value = time_system.get_days_per_year(); systems_box.add_child(plates_cad)
		plates_cad.value_changed.connect(func(v: float) -> void:
			if simulation and _plates_sys and "update_cadence" in simulation:
				simulation.update_cadence(_plates_sys, int(v))
		)
	if simulation_box:
		# Tile grid controls
		var tiles_lbl := Label.new(); tiles_lbl.text = "Tiles across"; simulation_box.add_child(tiles_lbl)
		tiles_across_spin = SpinBox.new(); tiles_across_spin.min_value = 8; tiles_across_spin.max_value = 1024; tiles_across_spin.step = 1; tiles_across_spin.value = max(1, tile_cols); simulation_box.add_child(tiles_across_spin)
		tiles_across_spin.value_changed.connect(_on_tiles_across_changed)
		lock_aspect_check = CheckBox.new(); lock_aspect_check.text = "Lock aspect"; lock_aspect_check.button_pressed = true; simulation_box.add_child(lock_aspect_check)
		lock_aspect_check.toggled.connect(_on_lock_aspect_toggled)
		var tiles_down_lbl := Label.new(); tiles_down_lbl.text = "Tiles down"; simulation_box.add_child(tiles_down_lbl)
		tiles_down_spin = SpinBox.new(); tiles_down_spin.min_value = 8; tiles_down_spin.max_value = 1024; tiles_down_spin.step = 1; tiles_down_spin.value = max(1, tile_rows); simulation_box.add_child(tiles_down_spin)
		tiles_down_spin.value_changed.connect(_on_tiles_down_changed)
		var budget_lbl := Label.new(); budget_lbl.text = "Budget(#/tick)"; simulation_box.add_child(budget_lbl)
		budget_spin = SpinBox.new(); budget_spin.min_value = 1; budget_spin.max_value = 10; budget_spin.step = 1; budget_spin.value = 3; simulation_box.add_child(budget_spin)
		budget_spin.value_changed.connect(func(v: float) -> void:
			if simulation and "set_max_systems_per_tick" in simulation:
				simulation.set_max_systems_per_tick(int(v))
		)
		var time_lbl := Label.new(); time_lbl.text = "Time(ms/tick)"; simulation_box.add_child(time_lbl)
		time_spin = SpinBox.new(); time_spin.min_value = 0.0; time_spin.max_value = 20.0; time_spin.step = 0.5; time_spin.value = 6.0; simulation_box.add_child(time_spin)
		time_spin.value_changed.connect(func(v: float) -> void:
			if simulation and "set_max_tick_time_ms" in simulation:
				simulation.set_max_tick_time_ms(float(v))
		)
		var mode_lbl := Label.new(); mode_lbl.text = "Budget=Time"; simulation_box.add_child(mode_lbl)
		var mode_check := CheckBox.new(); mode_check.text = "On"; mode_check.button_pressed = true; simulation_box.add_child(mode_check)
		mode_check.toggled.connect(func(on: bool) -> void:
			if simulation and "set_budget_mode_time" in simulation:
				simulation.set_budget_mode_time(on)
		)
		
		# Add GPU rendering toggle
		var gpu_lbl := Label.new(); gpu_lbl.text = "GPU Rendering"; simulation_box.add_child(gpu_lbl)
		gpu_rendering_toggle = CheckBox.new(); gpu_rendering_toggle.text = "Enabled"; gpu_rendering_toggle.button_pressed = use_gpu_rendering; simulation_box.add_child(gpu_rendering_toggle)
		gpu_rendering_toggle.toggled.connect(_on_gpu_rendering_toggled)
		year_label = Label.new(); year_label.text = "Year: 0.00"; simulation_box.add_child(year_label)
		
		# Year length controls
		var year_len_lbl := Label.new(); year_len_lbl.text = "Days per Year"; simulation_box.add_child(year_len_lbl)
		year_len_slider = HSlider.new(); year_len_slider.min_value = 50.0; year_len_slider.max_value = 500.0; year_len_slider.step = 1.0; year_len_slider.value = time_system.get_days_per_year(); year_len_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; simulation_box.add_child(year_len_slider)
		year_len_value = Label.new(); year_len_value.text = str(int(time_system.get_days_per_year())); simulation_box.add_child(year_len_value)
		year_len_slider.value_changed.connect(func(v: float) -> void:
			time_system.set_days_per_year(v)
			if year_len_value:
				year_len_value.text = str(int(v))
			# Update plates system cadence to match new year length
			if simulation and _plates_sys and "update_cadence" in simulation:
				simulation.update_cadence(_plates_sys, int(v))
			# Update plates UI spinner value
			if plates_cad:
				plates_cad.value = v
		)
		
		# FPS Settings
		var fps_lbl := Label.new(); fps_lbl.text = "Simulation FPS"; simulation_box.add_child(fps_lbl)
		fps_spin = SpinBox.new(); fps_spin.min_value = 1.0; fps_spin.max_value = 60.0; fps_spin.step = 1.0; fps_spin.value = 10.0; fps_spin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN; simulation_box.add_child(fps_spin)
		fps_spin.value_changed.connect(func(v: float) -> void:
			if time_system and time_system._timer:
				time_system._timer.wait_time = 1.0 / float(v)
		)
		
		var speed_lbl := Label.new(); speed_lbl.text = "Speed"; simulation_box.add_child(speed_lbl)
		speed_slider = HSlider.new(); speed_slider.min_value = 0.0; speed_slider.max_value = 2.0; speed_slider.step = 0.01; speed_slider.value = 0.2; speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; simulation_box.add_child(speed_slider)
		speed_slider.value_changed.connect(_on_speed_changed)
		var step_lbl := Label.new(); step_lbl.text = "Step (min)"; simulation_box.add_child(step_lbl)
		step_spin = SpinBox.new(); step_spin.min_value = 1.0; step_spin.max_value = 1440.0; step_spin.step = 1.0; step_spin.value = 1.0; step_spin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN; simulation_box.add_child(step_spin)
		step_spin.value_changed.connect(_on_step_minutes_changed)
		step_button = Button.new(); step_button.text = "Step"; simulation_box.add_child(step_button)
		step_button.pressed.connect(_on_step_pressed)
		backstep_button = Button.new(); backstep_button.text = "Backstep"; simulation_box.add_child(backstep_button)
		backstep_button.pressed.connect(_on_backstep_pressed)
		var ckpt_lbl := Label.new(); ckpt_lbl.text = "Ckpt (days)"; simulation_box.add_child(ckpt_lbl)
		ckpt_interval_spin = SpinBox.new(); ckpt_interval_spin.min_value = 0.5; ckpt_interval_spin.max_value = 60.0; ckpt_interval_spin.step = 0.5; ckpt_interval_spin.value = 5.0; simulation_box.add_child(ckpt_interval_spin)
		ckpt_interval_spin.value_changed.connect(func(v: float) -> void:
			if _checkpoint_sys and "set_interval_days" in _checkpoint_sys:
				_checkpoint_sys.set_interval_days(float(v))
		)
		# Save/Load checkpoint controls
		var save_lbl := Label.new(); save_lbl.text = "Checkpoint"; simulation_box.add_child(save_lbl)
		save_ckpt_button = Button.new(); save_ckpt_button.text = "Save"; simulation_box.add_child(save_ckpt_button)
		save_ckpt_button.pressed.connect(func() -> void:
			if save_dialog:
				save_dialog.current_dir = "user://"
				save_dialog.current_file = "world_%d.tres" % int(Time.get_ticks_msec())
				save_dialog.popup_centered()
		)
		load_ckpt_button = Button.new(); load_ckpt_button.text = "Load"; simulation_box.add_child(load_ckpt_button)
		load_ckpt_button.pressed.connect(func() -> void:
			if load_dialog:
				load_dialog.current_dir = "user://"
				load_dialog.popup_centered()
		)
		# Scrub UI
		var scrub_lbl := Label.new(); scrub_lbl.text = "Scrub (days)"; simulation_box.add_child(scrub_lbl)
		scrub_days_spin = SpinBox.new(); scrub_days_spin.min_value = 0.0; scrub_days_spin.max_value = 100000.0; scrub_days_spin.step = 0.1; scrub_days_spin.value = 0.0; simulation_box.add_child(scrub_days_spin)
		scrub_button = Button.new(); scrub_button.text = "Go"; simulation_box.add_child(scrub_button)
		scrub_button.pressed.connect(func() -> void:
			if _checkpoint_sys and "scrub_to" in _checkpoint_sys and time_system and simulation and generator and "_world_state" in generator:
				var ok_scrub: bool = _checkpoint_sys.scrub_to(float(scrub_days_spin.value), time_system, simulation, generator._world_state)
				if ok_scrub:
					if year_label and time_system and "get_year_float" in time_system:
						year_label.text = "Year: %.2f" % float(time_system.get_year_float())
					_redraw_ascii_from_current_state()
		)
		# Checkpoint list UI
		ckpt_list = OptionButton.new(); simulation_box.add_child(ckpt_list)
		ckpt_refresh_button = Button.new(); ckpt_refresh_button.text = "Refresh"; simulation_box.add_child(ckpt_refresh_button)
		ckpt_load_button = Button.new(); ckpt_load_button.text = "Load Selected"; simulation_box.add_child(ckpt_load_button)
		ckpt_refresh_button.pressed.connect(func() -> void:
			if _checkpoint_sys and "list_checkpoint_times" in _checkpoint_sys:
				ckpt_list.clear()
				var times: PackedFloat32Array = _checkpoint_sys.list_checkpoint_times()
				for i in range(times.size()):
					ckpt_list.add_item("t=%.2f d" % float(times[i]), i)
		)
		ckpt_load_button.pressed.connect(func() -> void:
			if _checkpoint_sys and "load_by_index" in _checkpoint_sys:
				var idx: int = int(ckpt_list.get_selected_id())
				var ok_load: bool = _checkpoint_sys.load_by_index(idx)
				if ok_load:
					if "last_loaded_time_days" in _checkpoint_sys and time_system:
						var lt: float = float(_checkpoint_sys.last_loaded_time_days)
						time_system.simulation_time_days = lt
					if year_label and time_system and "get_year_float" in time_system:
						year_label.text = "Year: %.2f" % float(time_system.get_year_float())
					_redraw_ascii_from_current_state()
		)
	# Always-visible Save/Load on Top Bar
	if top_bar:
		top_save_ckpt_button = Button.new(); top_save_ckpt_button.text = "Save"; top_bar.add_child(top_save_ckpt_button)
		top_save_ckpt_button.pressed.connect(func() -> void:
			if save_dialog:
				save_dialog.current_dir = "user://"
				save_dialog.current_file = "world_%d.tres" % int(Time.get_ticks_msec())
				save_dialog.popup_centered()
		)
		top_load_ckpt_button = Button.new(); top_load_ckpt_button.text = "Load"; top_bar.add_child(top_load_ckpt_button)
		top_load_ckpt_button.pressed.connect(func() -> void:
			if load_dialog:
				load_dialog.current_dir = "user://"
				load_dialog.popup_centered()
		)
		# Top bar seed/time labels
		top_seed_label = Label.new(); top_seed_label.text = "Seed: -"; top_bar.add_child(top_seed_label)
		top_time_label = Label.new(); top_time_label.text = "Time: 0y 0d 00:00"; top_bar.add_child(top_time_label)
		_update_top_seed_label()
		_update_top_time_label()

	if climate_box:
		var cc_lbl := Label.new(); cc_lbl.text = "Cloud->Moisture"; climate_box.add_child(cc_lbl)
		cloud_coupling_check = CheckBox.new(); cloud_coupling_check.text = "Enable"; cloud_coupling_check.button_pressed = true; climate_box.add_child(cloud_coupling_check)
		cloud_coupling_check.toggled.connect(func(on: bool) -> void:
			if _clouds_sys and "set_coupling_enabled" in _clouds_sys:
				_clouds_sys.set_coupling_enabled(on)
		)
		var rain_lbl := Label.new(); rain_lbl.text = "Rain"; climate_box.add_child(rain_lbl)
		rain_strength_slider = HSlider.new(); rain_strength_slider.min_value = 0.0; rain_strength_slider.max_value = 0.2; rain_strength_slider.step = 0.005; rain_strength_slider.value = 0.08; rain_strength_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; climate_box.add_child(rain_strength_slider)
		rain_strength_slider.value_changed.connect(_on_rain_strength_changed)
		var evap_lbl := Label.new(); evap_lbl.text = "Evap"; climate_box.add_child(evap_lbl)
		evap_strength_slider = HSlider.new(); evap_strength_slider.min_value = 0.0; evap_strength_slider.max_value = 0.2; evap_strength_slider.step = 0.005; evap_strength_slider.value = 0.06; evap_strength_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; climate_box.add_child(evap_strength_slider)
		evap_strength_slider.value_changed.connect(_on_evap_strength_changed)
		var cyc_lbl := Label.new(); cyc_lbl.text = "Cycles"; climate_box.add_child(cyc_lbl)
		var di_mod_lbl := Label.new(); di_mod_lbl.text = "Diurnal"; climate_box.add_child(di_mod_lbl)
		var di_mod := HSlider.new(); di_mod.min_value = 0.0; di_mod.max_value = 2.0; di_mod.step = 0.05; di_mod.value = 0.5; di_mod.size_flags_horizontal = Control.SIZE_EXPAND_FILL; climate_box.add_child(di_mod)
		var se_mod_lbl := Label.new(); se_mod_lbl.text = "Seasonal"; climate_box.add_child(se_mod_lbl)
		var se_mod := HSlider.new(); se_mod.min_value = 0.0; se_mod.max_value = 2.0; se_mod.step = 0.05; se_mod.value = 0.5; se_mod.size_flags_horizontal = Control.SIZE_EXPAND_FILL; climate_box.add_child(se_mod)
		di_mod.value_changed.connect(func(_v: float) -> void:
			if _clouds_sys and "set_cycle_modulation" in _clouds_sys:
				_clouds_sys.set_cycle_modulation(float(di_mod.value), float(se_mod.value))
		)
		se_mod.value_changed.connect(func(_v: float) -> void:
			if _clouds_sys and "set_cycle_modulation" in _clouds_sys:
				_clouds_sys.set_cycle_modulation(float(di_mod.value), float(se_mod.value))
		)
	sea_debounce_timer = Timer.new()
	sea_debounce_timer.one_shot = true
	sea_debounce_timer.wait_time = 0.08
	add_child(sea_debounce_timer)
	sea_debounce_timer.timeout.connect(_on_sea_debounce_timeout)
	# Debounce for temperature slider as well
	var temp_timer := Timer.new()
	temp_timer.name = "TempDebounceTimer"
	temp_timer.one_shot = true
	temp_timer.wait_time = 0.12
	add_child(temp_timer)
	(temp_timer as Timer).timeout.connect(_on_temp_debounce_timeout)
	if settings_dialog and settings_dialog.has_signal("settings_applied"):
		settings_dialog.connect("settings_applied", Callable(self, "_on_settings_applied"))
	_reset_view()
	# Auto-generate first world on startup at base resolution
	base_width = generator.config.width
	base_height = generator.config.height

	# File dialogs for Save/Load
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
	print("Main: initial generate")
	_generate_and_draw()
	# capture base dimensions for scaling
	base_width = generator.config.width
	base_height = generator.config.height
	
	# Connect viewport resize to reposition floating button
	get_viewport().size_changed.connect(_on_viewport_resized)


func _on_settings_applied(config: Dictionary) -> void:
	generator.apply_config(config)
	# update base dims if settings changed width/height
	base_width = generator.config.width
	base_height = generator.config.height
	_generate_and_draw()


func _generate_and_draw() -> void:
	_apply_seed_from_ui()
	# scale up resolution by map_scale in both axes
	var scaled_cfg := {
		"width": max(1, base_width * map_scale),
		"height": max(1, base_height * map_scale),
	}
	generator.apply_config(scaled_cfg)
	var grid: PackedByteArray = generator.generate()
	var w: int = generator.config.width
	var h: int = generator.config.height
	var styler: Object = AsciiStyler.new()
	var ascii_str: String = styler.build_ascii(w, h, generator.last_height, grid, generator.last_turquoise_water, generator.last_turquoise_strength, generator.last_beach, generator.last_water_distance, generator.last_biomes, generator.config.sea_level, generator.config.rng_seed, generator.last_temperature, generator.config.temp_min_c, generator.config.temp_max_c, generator.last_shelf_value_noise_field, generator.last_lake, generator.last_river, generator.last_pooled_lake, generator.last_lava, generator.last_clouds, (generator.hydro_extras.get("lake_freeze", PackedByteArray()) if "hydro_extras" in generator else PackedByteArray()), generator.last_light, _get_plate_boundary_mask())
	# Cloud overlay disabled for now
	var clouds_text: String = AsciiStyler.new().build_cloud_overlay(w, h, generator.last_clouds)
	ascii_map.clear()
	ascii_map.append_text(ascii_str)
	print("DEBUG: ASCII map updated with ", ascii_str.length(), " characters")
	print("DEBUG: ascii_map visible: ", ascii_map.visible)
	print("DEBUG: ascii_map modulate: ", ascii_map.modulate)
	print("DEBUG: ascii_map size: ", ascii_map.size)
	if ascii_str.length() > 0:
		print("DEBUG: First 100 chars: ", ascii_str.substr(0, 100))
	cloud_map.clear()
	cloud_map.append_text(clouds_text)
	cloud_map.visible = true
	last_ascii_text = ascii_str
	_update_char_size_cache()
	# Sync world state's notion of time for info overlays
	if time_system and "simulation_time_days" in time_system and "_world_state" in generator:
		generator._world_state.simulation_time_days = float(time_system.simulation_time_days)
		generator._world_state.time_scale = float(time_system.time_scale)
		generator._world_state.tick_days = float(time_system.tick_days)

func _on_sim_tick(_dt_days: float) -> void:
	# Minimal MVP: on each tick, just refresh overlays that depend on time (future: incremental system updates)
	if generator == null:
		return
	
	# Check if we have enough frame time budget for simulation work
	var frame_start_time = Time.get_ticks_usec()
	var available_frame_time_ms = 16.67  # Target 60fps = 16.67ms per frame
	
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
		if gpu_ascii_renderer and gpu_ascii_renderer.has_method("update_light_only"):
			gpu_ascii_renderer.update_light_only(generator.last_light)
		
	
	# Check frame time budget before heavy simulation work
	var current_time = Time.get_ticks_usec()
	var elapsed_ms = float(current_time - frame_start_time) / 1000.0
	
	# CRITICAL: Always run essential systems like day-night cycle, even if frame budget is tight
	# This ensures the day-night cycle never freezes due to performance budgeting
	if _seasonal_sys and "tick" in _seasonal_sys and "_world_state" in generator:
		_seasonal_sys.tick(_dt_days, generator._world_state, {})
	
	# Always increment counter for consistent timing regardless of frame budget
	_sim_tick_counter += 1
	
	# Only do full simulation work if we have frame time budget left
	if elapsed_ms < available_frame_time_ms * 0.8:  # Use only 80% of frame budget
		# Drive registered systems via orchestrator (MVP)
		if simulation and "on_tick" in simulation and "_world_state" in generator:
			simulation.on_tick(_dt_days, generator._world_state, {})
			
			# Debug performance every 30 ticks and auto-tune
			if _sim_tick_counter % 30 == 0:
				_log_performance_stats()
				_auto_tune_performance()
	else:
		# Skip heavy simulation systems this frame to maintain UI responsiveness
		print("Skipping heavy simulation systems to maintain UI responsiveness (day-night cycle still running)")
	
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
			print("Extremely large map: skipping ASCII redraw to maintain performance (day-night still updating)")

func _log_performance_stats() -> void:
	"""Log performance statistics to help diagnose slow simulation"""
	if simulation and "get_performance_stats" in simulation:
		var stats = simulation.get_performance_stats()
		print("=== SIMULATION PERFORMANCE ===")
		print("Current tick time: %.2f ms (budget: %.2f ms)" % [stats.get("current_tick_time_ms", 0), stats.get("max_budget_ms", 0)])
		print("Average tick time: %.2f ms" % stats.get("avg_tick_time_ms", 0))
		print("Performance status: %s" % stats.get("performance_status", "unknown"))
		print("Skipped systems: %d" % stats.get("skipped_systems_count", 0))
		print("System breakdown:")
		var system_breakdown = stats.get("system_breakdown", [])
		for system in system_breakdown:
			print("  - %s: %.2f ms (cadence: %d)" % [system.get("name", "unknown"), system.get("avg_cost_ms", 0), system.get("cadence", 1)])
		print("==============================")

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
	return WorldConstants.get_adaptive_redraw_cadence(total_cells)

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
	# Arrays (assign references; they’re persistent PackedArrays)
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
	
	# Performance optimization: reuse styler instance
	if styler_single == null:
		styler_single = AsciiStyler.new()
	
	# Try GPU rendering first, fallback to string rendering
	if use_gpu_rendering and gpu_ascii_renderer and gpu_ascii_renderer.is_using_gpu_rendering():
		# GPU-based rendering (high performance)
		gpu_ascii_renderer.update_ascii_display(
			w, h,
			generator.last_height,
			generator.last_temperature, 
			generator.last_moisture,
			generator.last_light,
			generator.last_biomes,
			generator.last_is_land,
			generator.last_beach,
			generator.config.rng_seed
		)
		# Ensure GPU renderer texture is visible and ASCII label hidden
		if ascii_map:
			ascii_map.modulate.a = 0.0
	else:
		# Fallback to string-based rendering
		var grid: PackedByteArray = generator.last_is_land
		var ascii_str: String = styler_single.build_ascii(w, h, generator.last_height, grid, generator.last_turquoise_water, generator.last_turquoise_strength, generator.last_beach, generator.last_water_distance, generator.last_biomes, generator.config.sea_level, generator.config.rng_seed, generator.last_temperature, generator.config.temp_min_c, generator.config.temp_max_c, generator.last_shelf_value_noise_field, generator.last_lake, generator.last_river, generator.last_pooled_lake, generator.last_lava, generator.last_clouds, (generator.hydro_extras.get("lake_freeze", PackedByteArray()) if "hydro_extras" in generator else PackedByteArray()), generator.last_light, _get_plate_boundary_mask())
		
		# Update ASCII map - always update to ensure day-night lighting changes are visible
		ascii_map.clear()
		ascii_map.append_text(ascii_str)
		last_ascii_text = ascii_str
		
		# Also update GPU renderer as fallback if available
		if gpu_ascii_renderer:
			gpu_ascii_renderer.update_ascii_display(
				w, h,
				generator.last_height,
				generator.last_temperature,
				generator.last_moisture, 
				generator.last_light,
				generator.last_biomes,
				generator.last_is_land,
				generator.last_beach,
				generator.config.rng_seed,
				ascii_str  # Pass string as fallback
			)
	_update_char_size_cache()
	
	# Cloud overlay update (lightweight)
	if cloud_map:
		var clouds_text: String = styler_single.build_cloud_overlay(w, h, generator.last_clouds)
		cloud_map.clear()
		cloud_map.append_text(clouds_text)
		cloud_map.visible = true

func _on_speed_changed(v: float) -> void:
	if time_system and "set_time_scale" in time_system:
		time_system.set_time_scale(float(v))

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
	if cloud_map:
		cloud_map.clear()
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
	if sea_value_label and sea_slider:
		sea_value_label.text = "%.2f" % float(sea_slider.value)

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
		sea_update_pending = false
		_generate_and_draw_preserve_seed()

func _generate_and_draw_preserve_seed() -> void:
	# If the last change was sea-level only, terrain arrays are already updated
	# but to keep consistent pipeline, regen is safe and quick
	# ensure generator uses scaled dimensions
	var scaled_cfg := {
		"width": max(1, base_width * map_scale),
		"height": max(1, base_height * map_scale),
	}
	generator.apply_config(scaled_cfg)
	# Force a fast recompute of sea-dependent fields (lakes, beaches, water distance)
	generator.quick_update_sea_level(float(sea_slider.value))
	var grid: PackedByteArray = generator.last_is_land
	var w: int = generator.config.width
	var h: int = generator.config.height
	var styler: Object = AsciiStyler.new()
	var ascii_str: String = styler.build_ascii(w, h, generator.last_height, grid, generator.last_turquoise_water, generator.last_turquoise_strength, generator.last_beach, generator.last_water_distance, generator.last_biomes, generator.config.sea_level, generator.config.rng_seed, generator.last_temperature, generator.config.temp_min_c, generator.config.temp_max_c, generator.last_shelf_value_noise_field, generator.last_lake, generator.last_river, generator.last_pooled_lake, generator.last_lava, generator.last_clouds, (generator.hydro_extras.get("lake_freeze", PackedByteArray()) if "hydro_extras" in generator else PackedByteArray()), generator.last_light, _get_plate_boundary_mask())
	ascii_map.clear()
	ascii_map.append_text(ascii_str)
	print("DEBUG: ASCII map updated with ", ascii_str.length(), " characters")
	print("DEBUG: ascii_map visible: ", ascii_map.visible)
	print("DEBUG: ascii_map modulate: ", ascii_map.modulate)
	print("DEBUG: ascii_map size: ", ascii_map.size)
	if ascii_str.length() > 0:
		print("DEBUG: First 100 chars: ", ascii_str.substr(0, 100))
	last_ascii_text = ascii_str
	_update_char_size_cache()
	_update_cursor_dimensions()

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
		if cloud_map:
			cloud_map.add_theme_font_override("normal_font", sys)
		if cursor_overlay and cursor_overlay.has_method("apply_font"):
			cursor_overlay.apply_font(sys)

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
				if info.get("is_lava", false): flags.append("Lava")
				if info.get("is_river", false): flags.append("River")
				var extra := ""
				if flags.size() > 0: extra = " - " + ", ".join(flags)
				info_label.text = "%s - %s - Type: %s - Humidity: %.2f - Temp: %.1f °C%s" % [coords, htxt, ttxt, humid, temp_c, extra]
			else:
				info_label.text = "Hover: -"

# Old highlight functions removed - replaced by CursorOverlay system


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
	if styler_single == null:
		styler_single = AsciiStyler.new()
	return styler_single.glyph_for(x, y, land, biome_id, beach_flag, generator.config.rng_seed)

func _update_char_size_cache() -> void:
	# Skip if already computed and dimensions haven't changed
	var w: int = generator.get_width()
	var h: int = generator.get_height()
	if char_w_cached > 0.0 and char_h_cached > 0.0 and w == tile_cols and h == tile_rows:
		return
	
	char_w_cached = 0.0
	char_h_cached = 0.0
	if w > 0 and h > 0:
		var content_w: float = float(ascii_map.get_content_width())
		var content_h: float = float(ascii_map.get_content_height())
		if content_w > 0.0 and content_h > 0.0:
			char_w_cached = content_w / float(w)
			char_h_cached = content_h / float(h)
	
	# Fallback to font metrics if content size is unavailable
	if char_w_cached <= 0.0 or char_h_cached <= 0.0:
		var font: Font = ascii_map.get_theme_font("normal_font")
		if not font:
			font = ascii_map.get_theme_default_font()
		if font:
			var font_size: int = ascii_map.get_theme_font_size("normal_font_size")
			if font_size <= 0:
				font_size = ascii_map.get_theme_default_font_size()
			if font_size > 0:
				var glyph_size: Vector2 = font.get_char_size(65, font_size)
				if glyph_size.x > 0.0 and font.get_height(font_size) > 0.0:
					char_w_cached = float(glyph_size.x)
					char_h_cached = float(font.get_height(font_size))
	
	# Final fallback values
	if char_w_cached <= 0.0:
		char_w_cached = 8.0
	if char_h_cached <= 0.0:
		char_h_cached = 16.0

func _on_map_resized() -> void:
	_update_char_size_cache()
	# Adjust font size to keep tile count while filling available space
	_apply_font_to_fit_tiles()

# Mouse enter/exit now handled by CursorOverlay

func _apply_font_to_fit_tiles() -> void:
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
	if cloud_map:
		cloud_map.add_theme_font_size_override("normal_font_size", size_guess)
	_update_char_size_cache()

func _on_tiles_across_changed(v: float) -> void:
	tile_cols = int(max(1, v))
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
	_apply_tile_grid_to_generator()
	_apply_font_to_fit_tiles()

func _apply_tile_grid_to_generator() -> void:
	var cfg := {
		"width": max(1, tile_cols),
		"height": max(1, tile_rows),
	}
	generator.apply_config(cfg)
	_redraw_ascii_from_current_state()

class StringBuilder:
	var parts: PackedStringArray = []
	func append(s: String) -> void:
		parts.append(s)
	func as_string() -> String:
		return "".join(parts)

# Connect cursor overlay signals
func _connect_cursor_overlay() -> void:
	if cursor_overlay and cursor_overlay.has_signal("tile_hovered"):
		cursor_overlay.tile_hovered.connect(_on_tile_hovered)
		cursor_overlay.mouse_exited_map.connect(_on_cursor_exited)

# Setup panel hide/show controls
func _setup_panel_controls() -> void:
	if hide_button:
		if not hide_button.pressed.is_connected(_on_hide_panel_pressed):
			hide_button.pressed.connect(_on_hide_panel_pressed)

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

func _on_floating_show_pressed() -> void:
	_on_hide_panel_pressed()  # Toggle back to show

func _on_tile_hovered(x: int, y: int) -> void:
	# Update info panel efficiently without blocking simulation
	if generator == null:
		return
	var info = generator.get_cell_info(x, y)
	var coords: String = "(%d,%d)" % [x, y]
	var htxt: String = "%.2f" % info.get("height_m", 0.0)
	var humid: float = info.get("moisture", 0.0)
	var temp_c: float = info.get("temp_c", 0.0)
	var ttxt: String = info.get("biome_name", "Unknown")
	var flags: PackedStringArray = PackedStringArray()
	if info.get("is_beach", false): flags.append("Beach")
	if info.get("is_turquoise_water", false): flags.append("Turquoise")
	if info.get("is_lava", false): flags.append("Lava")
	if info.get("is_river", false): flags.append("River")
	if info.get("is_lake", false): flags.append("Lake")
	if info.get("is_plate_boundary", false): flags.append("Tectonic")
	var extra: String = ""
	if flags.size() > 0: extra = " - " + ", ".join(flags)
	
	# Add geological activity stats when available
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
	
	info_label.text = "%s - %s - Type: %s - Humidity: %.2f - Temp: %.1f °C%s%s" % [coords, htxt, ttxt, humid, temp_c, extra, geological_info]

func _on_cursor_exited() -> void:
	info_label.text = "Hover: -"

func _update_cursor_dimensions() -> void:
	# Called after char cache updates to sync cursor overlay
	if cursor_overlay and generator and char_w_cached > 0.0 and char_h_cached > 0.0:
		cursor_overlay.setup_dimensions(generator.get_width(), generator.get_height(), char_w_cached, char_h_cached)

func _on_gpu_rendering_toggled(enabled: bool) -> void:
	"""Toggle between GPU and string-based rendering"""
	use_gpu_rendering = enabled
	
	if enabled:
		if not gpu_ascii_renderer:
			_initialize_gpu_renderer()
		if gpu_ascii_renderer and gpu_ascii_renderer.has_method("is_using_gpu_rendering") and gpu_ascii_renderer.is_using_gpu_rendering():
			# Enable GPU rendering
			ascii_map.modulate.a = 0.0  # Hide string rendering
			print("Main: Switched to GPU rendering")
	else:
		# Enable string rendering
		ascii_map.modulate.a = 1.0  # Show string rendering
		print("Main: Switched to string rendering")
	
	# Force a redraw to show the change
	_redraw_ascii_from_current_state()

func _initialize_gpu_renderer() -> void:
	"""Initialize GPU-based ASCII rendering system"""
	
	# Load GPU renderer class dynamically
	var GPUAsciiRendererClass = load("res://scripts/rendering/GPUAsciiRenderer.gd")
	if not GPUAsciiRendererClass:
		print("Main: Could not load GPUAsciiRenderer")
		use_gpu_rendering = false
		return
	
	# Create GPU renderer as a sibling to ASCII map in MapContainer
	gpu_ascii_renderer = GPUAsciiRendererClass.new()
	gpu_ascii_renderer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gpu_ascii_renderer.z_index = -1  # Behind cursor overlay
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
			print("Main: GPU ASCII rendering initialized successfully")
			# Check if GPU renderer is actually using GPU rendering
			if gpu_ascii_renderer.has_method("is_using_gpu_rendering") and gpu_ascii_renderer.is_using_gpu_rendering():
				# Hide the original RichTextLabel when using actual GPU rendering
				ascii_map.modulate.a = 0.0
				print("Main: Using GPU rendering mode")
			else:
				# Keep ASCII map visible when using fallback
				ascii_map.modulate.a = 1.0
				print("Main: GPU renderer using fallback mode - ASCII map remains visible")
		else:
			print("Main: GPU ASCII rendering failed, will use fallback")
			use_gpu_rendering = false
			gpu_ascii_renderer.queue_free()
			gpu_ascii_renderer = null
			ascii_map.modulate.a = 1.0
	else:
		print("Main: GPU renderer missing initialize_gpu_rendering method")
		use_gpu_rendering = false
		gpu_ascii_renderer.queue_free()
		gpu_ascii_renderer = null

func _get_plate_boundary_mask() -> PackedByteArray:
	# Convert int32 boundary mask to byte mask for rendering
	var mask := PackedByteArray()
	if generator and generator._plates_boundary_mask_i32.size() > 0:
		var mask_size = generator._plates_boundary_mask_i32.size()
		mask.resize(mask_size)
		for i in range(mask_size):
			mask[i] = (1 if generator._plates_boundary_mask_i32[i] == 1 else 0)
	return mask
