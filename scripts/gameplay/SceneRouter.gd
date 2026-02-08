extends Node

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")

func goto_world_main() -> void:
	var game_state: Node = get_node_or_null("/root/GameState")
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(SceneContracts.STATE_WORLD, 0, 0, 48, 48, -1, "")
	get_tree().change_scene_to_file(SceneContracts.SCENE_WORLD_MAIN)

func goto_regional(world_x: int, world_y: int, local_x: int, local_y: int, biome_id: int, biome_name: String = "") -> void:
	var game_state: Node = get_node_or_null("/root/GameState")
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(SceneContracts.STATE_REGIONAL, world_x, world_y, local_x, local_y, biome_id, biome_name)
	var startup_state: Node = get_node_or_null("/root/StartupState")
	if startup_state != null and startup_state.has_method("set_selected_world_tile"):
		startup_state.set_selected_world_tile(world_x, world_y, biome_id, biome_name, local_x, local_y)
	get_tree().change_scene_to_file(SceneContracts.SCENE_REGIONAL_MAP)

func goto_local(poi_payload: Dictionary) -> void:
	var game_state: Node = get_node_or_null("/root/GameState")
	if game_state != null and game_state.has_method("queue_poi"):
		game_state.queue_poi(poi_payload)
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(
			SceneContracts.STATE_LOCAL,
			int(poi_payload.get("world_x", 0)),
			int(poi_payload.get("world_y", 0)),
			int(poi_payload.get("local_x", 48)),
			int(poi_payload.get("local_y", 48)),
			int(poi_payload.get("biome_id", -1)),
			String(poi_payload.get("biome_name", ""))
		)
	var startup_state: Node = get_node_or_null("/root/StartupState")
	if startup_state != null and startup_state.has_method("queue_poi"):
		startup_state.queue_poi(poi_payload)
	get_tree().change_scene_to_file(SceneContracts.SCENE_LOCAL_AREA)

func goto_battle(encounter_payload: Dictionary) -> void:
	var game_state: Node = get_node_or_null("/root/GameState")
	if game_state != null and game_state.has_method("queue_battle"):
		game_state.queue_battle(encounter_payload)
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(
			SceneContracts.STATE_BATTLE,
			int(encounter_payload.get("world_x", 0)),
			int(encounter_payload.get("world_y", 0)),
			int(encounter_payload.get("local_x", 48)),
			int(encounter_payload.get("local_y", 48)),
			int(encounter_payload.get("biome_id", -1)),
			String(encounter_payload.get("biome_name", ""))
		)
	var startup_state: Node = get_node_or_null("/root/StartupState")
	if startup_state != null and startup_state.has_method("queue_battle"):
		startup_state.queue_battle(encounter_payload)
	get_tree().change_scene_to_file(SceneContracts.SCENE_BATTLE)

func goto_game_over() -> void:
	var game_state: Node = get_node_or_null("/root/GameState")
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(SceneContracts.STATE_GAME_OVER, 0, 0, 48, 48, -1, "")
	get_tree().change_scene_to_file(SceneContracts.SCENE_GAME_OVER)
