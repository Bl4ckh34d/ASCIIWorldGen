# File: res://scripts/Main.gd
extends Control

@onready var play_button: Button = $RootVBox/TopBar/PlayButton
@onready var reset_button: Button = $RootVBox/TopBar/ResetButton
@onready var top_bar: Control = $RootVBox/TopBar
@onready var ascii_map: RichTextLabel = %AsciiMap
@onready var info_label: Label = %Info
@onready var settings_dialog: Window = $SettingsDialog
@onready var seed_input: LineEdit = $RootVBox/MainSplit/LeftPanel/Tabs/General/SeedInput
@onready var seed_used_label: Label = $RootVBox/MainSplit/LeftPanel/Tabs/General/SeedUsed
@onready var randomize_check: CheckBox = $RootVBox/TopBar/Randomize
@onready var sea_slider: HSlider = $RootVBox/MainSplit/LeftPanel/Tabs/General/SeaSlider
@onready var sea_value_label: Label = $RootVBox/MainSplit/LeftPanel/Tabs/General/SeaVal
@onready var general_box: VBoxContainer = $RootVBox/MainSplit/LeftPanel/Tabs/General
@onready var climate_box: VBoxContainer = $RootVBox/MainSplit/LeftPanel/Tabs/Climate
@onready var hydro_box: VBoxContainer = $RootVBox/MainSplit/LeftPanel/Tabs/Hydro
@onready var simulation_box: VBoxContainer = $RootVBox/MainSplit/LeftPanel/Tabs/Simulation
@onready var systems_box: VBoxContainer = $RootVBox/MainSplit/LeftPanel/Tabs/Systems
var temp_slider: HSlider
var temp_value_label: Label
var cont_slider: HSlider
var cont_value_label: Label
var year_label: Label
var speed_slider: HSlider
var step_spin: SpinBox
var step_button: Button
var backstep_button: Button
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
var highlight_rect: ColorRect
var highlight_label: Label
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

func _ready() -> void:
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
		_seasonal_sys.initialize(generator)
	# NOTE: SeasonalClimateSystem now runs directly in _on_sim_tick() to ensure it's never skipped due to frame budgeting
	# Register hydro updater at a much slower cadence (most expensive system)
	_hydro_sys = load("res://scripts/systems/HydroUpdateSystem.gd").new()
	if "initialize" in _hydro_sys:
		_hydro_sys.initialize(generator)
		# Reduce tiles per tick for hydro system performance
		_hydro_sys.tiles_per_tick = 1  # Process 1 tile per tick instead of 2
	if "register_system" in simulation:
		simulation.register_system(_hydro_sys, 60, 0)  # Much slower hydro updates
	# Register cloud/wind overlay updater (visual only for now)
	_clouds_sys = load("res://scripts/systems/CloudWindSystem.gd").new()
	if "initialize" in _clouds_sys:
		_clouds_sys.initialize(generator)
	if "register_system" in simulation:
		simulation.register_system(_clouds_sys, 15, 0)  # Slower cloud updates
	# Register biome reclassify system (cadence separate from climate)
	_biome_sys = load("res://scripts/systems/BiomeUpdateSystem.gd").new()
	# Register plates prototype at a very slow cadence
	_plates_sys = load("res://scripts/systems/PlateSystem.gd").new()
	if "initialize" in _plates_sys:
		_plates_sys.initialize(generator)
	if "register_system" in simulation:
		simulation.register_system(_plates_sys, 180, 0)  # Even slower plate updates
	if "initialize" in _biome_sys:
		_biome_sys.initialize(generator)
	if "register_system" in simulation:
		simulation.register_system(_biome_sys, 20, 0)  # Slower biome updates
	# Register volcanism system at slower cadence
	var _volc_sys: Object = load("res://scripts/systems/VolcanismSystem.gd").new()
	if "initialize" in _volc_sys:
		_volc_sys.initialize(generator)
	if "register_system" in simulation:
		simulation.register_system(_volc_sys, 8, 0)  # Slower volcanism
	# Forward ticks to simulation (world state lives in generator)
	if time_system.has_signal("tick"):
		time_system.connect("tick", Callable(self, "_on_sim_tick"))
	play_button.pressed.connect(_on_play_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	ascii_map.gui_input.connect(_on_ascii_input)
	_apply_monospace_font()
	ascii_map.mouse_entered.connect(_on_map_enter)
	ascii_map.mouse_exited.connect(_on_map_exit)
	_create_highlight_overlay()
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
	styler_single = AsciiStyler.new()
	ascii_map.resized.connect(_on_map_resized)
	# Init tile grid from current generator config
	tile_cols = int(generator.config.width)
	tile_rows = int(generator.config.height)
	sea_slider.value_changed.connect(_on_sea_changed)
	_update_sea_label()
	# Build left panel tabs UI
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
		var hydro_cad := SpinBox.new(); hydro_cad.min_value = 1; hydro_cad.max_value = 120; hydro_cad.step = 1; hydro_cad.value = 20; systems_box.add_child(hydro_cad)
		hydro_cad.value_changed.connect(func(v: float) -> void:
			if simulation and _hydro_sys and "update_cadence" in simulation:
				simulation.update_cadence(_hydro_sys, int(v))
		)
		var cloud_cad := SpinBox.new(); cloud_cad.min_value = 1; cloud_cad.max_value = 120; cloud_cad.step = 1; cloud_cad.value = 10; systems_box.add_child(cloud_cad)
		cloud_cad.value_changed.connect(func(v: float) -> void:
			if simulation and _clouds_sys and "update_cadence" in simulation:
				simulation.update_cadence(_clouds_sys, int(v))
		)
		var biome_cad_lbl := Label.new(); biome_cad_lbl.text = "Biome"; systems_box.add_child(biome_cad_lbl)
		var biome_cad := SpinBox.new(); biome_cad.min_value = 1; biome_cad.max_value = 120; biome_cad.step = 1; biome_cad.value = 15; systems_box.add_child(biome_cad)
		biome_cad.value_changed.connect(func(v: float) -> void:
			if simulation and _biome_sys and "update_cadence" in simulation:
				simulation.update_cadence(_biome_sys, int(v))
		)
		var plates_cad_lbl := Label.new(); plates_cad_lbl.text = "Plates"; systems_box.add_child(plates_cad_lbl)
		var plates_cad := SpinBox.new(); plates_cad.min_value = 1; plates_cad.max_value = 300; plates_cad.step = 1; plates_cad.value = 40; systems_box.add_child(plates_cad)
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
		var budget_spin := SpinBox.new(); budget_spin.min_value = 1; budget_spin.max_value = 10; budget_spin.step = 1; budget_spin.value = 3; simulation_box.add_child(budget_spin)
		budget_spin.value_changed.connect(func(v: float) -> void:
			if simulation and "set_max_systems_per_tick" in simulation:
				simulation.set_max_systems_per_tick(int(v))
		)
		var time_lbl := Label.new(); time_lbl.text = "Time(ms/tick)"; simulation_box.add_child(time_lbl)
		var time_spin := SpinBox.new(); time_spin.min_value = 0.0; time_spin.max_value = 20.0; time_spin.step = 0.5; time_spin.value = 6.0; simulation_box.add_child(time_spin)
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
		year_label = Label.new(); year_label.text = "Year: 0.00"; simulation_box.add_child(year_label)
		var speed_lbl := Label.new(); speed_lbl.text = "Speed"; simulation_box.add_child(speed_lbl)
		speed_slider = HSlider.new(); speed_slider.min_value = 0.0; speed_slider.max_value = 10.0; speed_slider.step = 0.05; speed_slider.value = 1.0; speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL; simulation_box.add_child(speed_slider)
		speed_slider.value_changed.connect(_on_speed_changed)
		var step_lbl := Label.new(); step_lbl.text = "Step (min)"; simulation_box.add_child(step_lbl)
		step_spin = SpinBox.new(); step_spin.min_value = 1.0; step_spin.max_value = 1440.0; step_spin.step = 1.0; step_spin.value = 12.0; step_spin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN; simulation_box.add_child(step_spin)
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
	if settings_dialog.has_signal("settings_applied"):
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
	_generate_and_draw()
	# capture base dimensions for scaling
	base_width = generator.config.width
	base_height = generator.config.height

func _on_play_pressed() -> void:
	if not is_running:
		is_running = true
		play_button.text = "Pause"
		# New simulation: if no manual seed entered, randomize seed each time
		if seed_input.text.strip_edges().length() == 0:
			generator.apply_config({"seed": ""})
		_generate_and_draw()
		# Save initial checkpoint at t=0 for rewind/scrub
		if _checkpoint_sys and "save_checkpoint" in _checkpoint_sys:
			_checkpoint_sys.save_checkpoint(0.0)
		# start time system
		if time_system and "start" in time_system:
			time_system.start()
	else:
		is_running = false
		play_button.text = "Play"
		# pause time system
		if time_system and "pause" in time_system:
			time_system.pause()

func _on_reset_pressed() -> void:
	is_running = false
	play_button.text = "Play"
	generator.clear()
	if time_system and "reset" in time_system:
		time_system.reset()
	# Clear checkpoints
	if _checkpoint_sys and "initialize" in _checkpoint_sys:
		_checkpoint_sys.initialize(generator)
	_reset_view()
	# Reset terrain noise to standard defaults and regenerate
	var defaults := {
		"octaves": 5,
		"frequency": 0.02,
		"lacunarity": 2.0,
		"gain": 0.5,
		"warp": 24.0,
		"wrap_x": true,
	}
	generator.apply_config(defaults)
	_generate_and_draw()

func _on_settings_pressed() -> void:
	if settings_dialog:
		settings_dialog.popup_centered()

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
	var ascii_str: String = styler.build_ascii(w, h, generator.last_height, grid, generator.last_turquoise_water, generator.last_turquoise_strength, generator.last_beach, generator.last_water_distance, generator.last_biomes, generator.config.sea_level, generator.config.rng_seed, generator.last_temperature, generator.config.temp_min_c, generator.config.temp_max_c, generator.last_shelf_value_noise_field, generator.last_lake, generator.last_river, generator.last_pooled_lake, generator.last_lava, generator.last_clouds, (generator.hydro_extras.get("lake_freeze", PackedByteArray()) if "hydro_extras" in generator else PackedByteArray()), generator.last_light)
	# Cloud overlay disabled for now
	var clouds_text: String = AsciiStyler.new().build_cloud_overlay(w, h, generator.last_clouds)
	ascii_map.clear()
	ascii_map.append_text(ascii_str)
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
	
	# Check frame time budget before heavy simulation work
	var current_time = Time.get_ticks_usec()
	var elapsed_ms = float(current_time - frame_start_time) / 1000.0
	
	# CRITICAL: Always run essential systems like day-night cycle, even if frame budget is tight
	# This ensures the day-night cycle never freezes due to performance budgeting
	if _seasonal_sys and "tick" in _seasonal_sys and "_world_state" in generator:
		_seasonal_sys.tick(_dt_days, generator._world_state, {})
	
	# Only do full simulation work if we have frame time budget left
	if elapsed_ms < available_frame_time_ms * 0.8:  # Use only 80% of frame budget
		# Drive registered systems via orchestrator (MVP)
		if simulation and "on_tick" in simulation and "_world_state" in generator:
			simulation.on_tick(_dt_days, generator._world_state, {})
			_sim_tick_counter += 1
			
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
	
	# Adaptive ASCII redraw cadence based on map size (but check frame budget)
	var redraw_cadence = _get_adaptive_redraw_cadence()
	if _sim_tick_counter % redraw_cadence == 0:
		# Check frame budget again before expensive ASCII redraw
		var current_time2 = Time.get_ticks_usec()
		var elapsed_ms2 = float(current_time2 - frame_start_time) / 1000.0
		
		if elapsed_ms2 < available_frame_time_ms * 0.9:  # Use 90% budget for ASCII
			# Keep WorldState synchronized from generator fields for consumers that rely on it
			_sync_world_state_from_generator()
			_update_top_time_label()
			_redraw_ascii_from_current_state()
		else:
			# Skip ASCII redraw to maintain UI responsiveness
			_update_top_time_label()  # At least update time label
		_sim_tick_counter = 0

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
	"""Adaptive ASCII redraw cadence based on map size and performance"""
	if generator == null:
		return 8
	
	var total_cells = generator.config.width * generator.config.height
	
	# More aggressive cadence scaling for better frame rates
	if total_cells <= 4000:        # Small maps (e.g., 50x80)
		return 4
	elif total_cells <= 10000:     # Medium maps (e.g., 100x100)  
		return 8
	elif total_cells <= 25000:     # Large maps (e.g., 200x125)
		return 15
	else:                          # Very large maps
		return 25

func _update_top_seed_label() -> void:
	if top_seed_label and generator:
		top_seed_label.text = "Seed: %d" % int(generator.config.rng_seed)

func _update_top_time_label() -> void:
	if top_time_label and time_system:
		var days_total: float = float(time_system.simulation_time_days)
		var years: int = int(floor(days_total / 365.0))
		var rem_days_f: float = fmod(days_total, 365.0)
		if rem_days_f < 0.0:
			rem_days_f += 365.0
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
	ws.turquoise_water = generator.last_turquoise_water
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
	var w: int = generator.config.width
	var h: int = generator.config.height
	var grid: PackedByteArray = generator.last_is_land
	var styler: Object = AsciiStyler.new()
	var ascii_str: String = styler.build_ascii(w, h, generator.last_height, grid, generator.last_turquoise_water, generator.last_turquoise_strength, generator.last_beach, generator.last_water_distance, generator.last_biomes, generator.config.sea_level, generator.config.rng_seed, generator.last_temperature, generator.config.temp_min_c, generator.config.temp_max_c, generator.last_shelf_value_noise_field, generator.last_lake, generator.last_river, generator.last_pooled_lake, generator.last_lava, generator.last_clouds, (generator.hydro_extras.get("lake_freeze", PackedByteArray()) if "hydro_extras" in generator else PackedByteArray()), generator.last_light)
	ascii_map.clear()
	ascii_map.append_text(ascii_str)
	# Update cloud overlay string
	if cloud_map:
		var clouds_text: String = AsciiStyler.new().build_cloud_overlay(w, h, generator.last_clouds)
		cloud_map.clear()
		cloud_map.append_text(clouds_text)
		cloud_map.visible = true
	last_ascii_text = ascii_str
	_update_char_size_cache()

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
	ascii_map.clear()
	ascii_map.append_text("")
	if cloud_map:
		cloud_map.clear()
	info_label.text = "Hover: -"
	seed_used_label.text = "Used: -"
	last_ascii_text = ""
	_hide_highlight()

func _apply_seed_from_ui() -> void:
	var txt: String = seed_input.text.strip_edges()
	var cfg := {}
	if txt.length() == 0:
		# Leave existing seed unchanged; just reflect it in the label
		seed_used_label.text = "Used: %d" % generator.config.rng_seed
	else:
		cfg["seed"] = txt
		generator.apply_config(cfg)
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
	if temp_value_label and generator:
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
	if cont_value_label and generator:
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
	var ascii_str: String = styler.build_ascii(w, h, generator.last_height, grid, generator.last_turquoise_water, generator.last_turquoise_strength, generator.last_beach, generator.last_water_distance, generator.last_biomes, generator.config.sea_level, generator.config.rng_seed, generator.last_temperature, generator.config.temp_min_c, generator.config.temp_max_c, generator.last_shelf_value_noise_field, generator.last_lake, generator.last_river, generator.last_pooled_lake, generator.last_lava, generator.last_clouds, (generator.hydro_extras.get("lake_freeze", PackedByteArray()) if "hydro_extras" in generator else PackedByteArray()), generator.last_light)
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
		if cloud_map:
			cloud_map.add_theme_font_override("normal_font", sys)
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
				if info.get("is_lava", false): flags.append("Lava")
				if info.get("is_river", false): flags.append("River")
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
	# Adjust font size to keep tile count while filling available space
	_apply_font_to_fit_tiles()

func _on_map_enter() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)

func _on_map_exit() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_hide_highlight()

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
