extends Control
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")

@onready var summary_label: Label = %SummaryLabel
@onready var status_label: Label = %StatusLabel
@onready var save_slot_option: OptionButton = %SaveSlotOption
@onready var load_button: Button = %LoadButton
@onready var restart_button: Button = %RestartButton
@onready var world_button: Button = %WorldButton

var game_state: Node = null
var scene_router: Node = null

func _ready() -> void:
	game_state = get_node_or_null("/root/GameState")
	scene_router = get_node_or_null("/root/SceneRouter")
	_wire()
	_populate_slots()
	_refresh_summary()

func _wire() -> void:
	if load_button and not load_button.pressed.is_connected(_on_load_pressed):
		load_button.pressed.connect(_on_load_pressed)
	if restart_button and not restart_button.pressed.is_connected(_on_restart_pressed):
		restart_button.pressed.connect(_on_restart_pressed)
	if world_button and not world_button.pressed.is_connected(_on_world_pressed):
		world_button.pressed.connect(_on_world_pressed)

func _populate_slots() -> void:
	if save_slot_option == null:
		return
	save_slot_option.clear()
	save_slot_option.add_item("Slot 1", 0)
	save_slot_option.add_item("Slot 2", 1)
	save_slot_option.add_item("Slot 3", 2)
	save_slot_option.select(0)

func _refresh_summary() -> void:
	if summary_label == null:
		return
	if game_state == null:
		summary_label.text = "You were defeated."
		return
	var last: Dictionary = {}
	last = game_state.last_battle_result
	var enc: Dictionary = last.get("encounter", {})
	var biome: String = String(enc.get("biome_name", "Unknown"))
	var group: String = String(enc.get("enemy_group", "Enemies"))
	summary_label.text = "Defeat in %s.\nEncounter: %s" % [biome, group]

func _selected_save_path() -> String:
	var slot_idx: int = 0
	if save_slot_option != null:
		slot_idx = save_slot_option.selected
	return SceneContracts.save_slot_path(slot_idx)

func _on_load_pressed() -> void:
	if game_state == null or not game_state.has_method("load_from_path"):
		_set_status("Load unavailable.")
		return
	var ok_load: bool = VariantCasts.to_bool(game_state.load_from_path(_selected_save_path()))
	if not ok_load:
		_set_status("Load failed (missing file/schema mismatch).")
		return
	_set_status("Loaded.")
	_route_after_load()

func _route_after_load() -> void:
	# Save/load in non-regional scenes is not fully persisted yet (e.g., interiors),
	# so we route conservatively.
	if game_state == null or not game_state.has_method("get_location"):
		_goto_world()
		return
	var loc: Dictionary = game_state.get_location()
	var scene_name: String = String(loc.get("scene", SceneContracts.STATE_WORLD))
	if scene_name == SceneContracts.STATE_REGIONAL and scene_router != null and scene_router.has_method("goto_regional"):
		scene_router.goto_regional(
			int(loc.get("world_x", 0)),
			int(loc.get("world_y", 0)),
			int(loc.get("local_x", 48)),
			int(loc.get("local_y", 48)),
			int(loc.get("biome_id", -1)),
			String(loc.get("biome_name", ""))
		)
		return
	_goto_world()

func _on_restart_pressed() -> void:
	if game_state != null and game_state.has_method("reset_run"):
		game_state.reset_run()
	_goto_world()

func _on_world_pressed() -> void:
	# Game over is not a valid “continue”; returning to world should reset run state.
	if game_state != null and game_state.has_method("reset_run"):
		game_state.reset_run()
	_goto_world()

func _goto_world() -> void:
	if scene_router != null and scene_router.has_method("goto_world_main"):
		scene_router.goto_world_main()
	else:
		get_tree().change_scene_to_file(SceneContracts.SCENE_WORLD_MAIN)

func _set_status(text_value: String) -> void:
	if status_label:
		status_label.text = text_value
