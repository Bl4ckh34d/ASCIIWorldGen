extends Node

func goto_world_main() -> void:
	var game_state: Node = get_node_or_null("/root/GameState")
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(SceneContracts.STATE_WORLD, 0, 0, 48, 48, -1, "")
	get_tree().change_scene_to_file(SceneContracts.SCENE_WORLD_MAIN)

func goto_regional(world_x: int, world_y: int, local_x: int, local_y: int, biome_id: int, biome_name: String = "") -> void:
	var game_state: Node = get_node_or_null("/root/GameState")
	var resolved_world_x: int = int(world_x)
	var resolved_world_y: int = int(world_y)
	var resolved_local_x: int = int(local_x)
	var resolved_local_y: int = int(local_y)
	var resolved_biome_id: int = int(biome_id)
	var resolved_biome_name: String = String(biome_name)
	if game_state != null and game_state.has_method("has_world_snapshot") and VariantCasts.to_bool(game_state.has_world_snapshot()):
		if game_state.has_method("get_world_biome_id"):
			resolved_biome_id = int(game_state.get_world_biome_id(resolved_world_x, resolved_world_y))
		if _is_ocean_or_ice_biome(resolved_biome_id):
			var nearest: Vector2i = _nearest_enterable_world_tile(game_state, resolved_world_x, resolved_world_y)
			resolved_world_x = nearest.x
			resolved_world_y = nearest.y
			resolved_local_x = 48
			resolved_local_y = 48
			if game_state.has_method("get_world_biome_id"):
				resolved_biome_id = int(game_state.get_world_biome_id(resolved_world_x, resolved_world_y))
			resolved_biome_name = ""
	if game_state != null and game_state.has_method("set_location"):
		game_state.set_location(
			SceneContracts.STATE_REGIONAL,
			resolved_world_x,
			resolved_world_y,
			resolved_local_x,
			resolved_local_y,
			resolved_biome_id,
			resolved_biome_name
		)
	var startup_state: Node = get_node_or_null("/root/StartupState")
	if startup_state != null and startup_state.has_method("set_selected_world_tile"):
		startup_state.set_selected_world_tile(
			resolved_world_x,
			resolved_world_y,
			resolved_biome_id,
			resolved_biome_name,
			resolved_local_x,
			resolved_local_y
		)
	get_tree().change_scene_to_file(SceneContracts.SCENE_REGIONAL_MAP)

func _is_ocean_or_ice_biome(biome_id: int) -> bool:
	return biome_id == 0 or biome_id == 1

func _nearest_enterable_world_tile(game_state: Node, world_x: int, world_y: int) -> Vector2i:
	var w: int = max(1, int(game_state.get("world_width")))
	var h: int = max(1, int(game_state.get("world_height")))
	world_x = posmod(int(world_x), w)
	world_y = clamp(int(world_y), 0, h - 1)
	if game_state.has_method("get_world_biome_id"):
		var start_biome: int = int(game_state.get_world_biome_id(world_x, world_y))
		if not _is_ocean_or_ice_biome(start_biome):
			return Vector2i(world_x, world_y)
	var search_max: int = max(1, max(w, h))
	for r in range(1, search_max + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var tx: int = posmod(world_x + dx, w)
				var ty: int = clamp(world_y + dy, 0, h - 1)
				if not game_state.has_method("get_world_biome_id"):
					return Vector2i(tx, ty)
				var bid: int = int(game_state.get_world_biome_id(tx, ty))
				if not _is_ocean_or_ice_biome(bid):
					return Vector2i(tx, ty)
	return Vector2i(world_x, world_y)

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
