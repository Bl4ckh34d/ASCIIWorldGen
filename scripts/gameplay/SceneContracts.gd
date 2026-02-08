extends RefCounted
class_name SceneContracts

const SCENE_WORLD_MAIN: String = "res://scenes/Main.tscn"
const SCENE_REGIONAL_MAP: String = "res://scenes/RegionalMap.tscn"
const SCENE_LOCAL_AREA: String = "res://scenes/LocalAreaScene.tscn"
const SCENE_BATTLE: String = "res://scenes/BattleScene.tscn"
const SCENE_GAME_OVER: String = "res://scenes/GameOver.tscn"
const SCENE_MENU_OVERLAY: String = "res://scenes/ui/MenuOverlay.tscn"
const SCENE_WORLD_MAP_OVERLAY: String = "res://scenes/ui/WorldMapOverlay.tscn"

const SAVE_SLOT_0: String = "user://save_slot_0.json"
const SAVE_SLOT_1: String = "user://save_slot_1.json"
const SAVE_SLOT_2: String = "user://save_slot_2.json"

const STATE_WORLD: String = "world"
const STATE_REGIONAL: String = "regional"
const STATE_LOCAL: String = "local"
const STATE_BATTLE: String = "battle"
const STATE_GAME_OVER: String = "game_over"

static func save_slot_path(slot_index: int) -> String:
	match slot_index:
		1:
			return SAVE_SLOT_1
		2:
			return SAVE_SLOT_2
		_:
			return SAVE_SLOT_0

const KEY_SCENE: String = "scene"
const KEY_WORLD_X: String = "world_x"
const KEY_WORLD_Y: String = "world_y"
const KEY_LOCAL_X: String = "local_x"
const KEY_LOCAL_Y: String = "local_y"
const KEY_BIOME_ID: String = "biome_id"
const KEY_BIOME_NAME: String = "biome_name"
