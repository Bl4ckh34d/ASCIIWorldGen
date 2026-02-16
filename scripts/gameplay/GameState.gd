extends Node

const SAVE_SCHEMA_VERSION: int = 6
const PARTY_MEMBER_CAP: int = 4
const REST_MORNING_HOUR: int = 6
const _FACTION_REP_KEY: String = "faction_reputation"
const _FACTION_REP_MIN: int = -100
const _FACTION_REP_MAX: int = 250

const _TOD_NIGHT: int = 0
const _TOD_DAWN: int = 1
const _TOD_DAY: int = 2
const _TOD_DUSK: int = 3

const _SEASON_SPRING: int = 0
const _SEASON_SUMMER: int = 1
const _SEASON_AUTUMN: int = 2
const _SEASON_WINTER: int = 3

var party: PartyStateModel = PartyStateModel.new()
var world_time: WorldTimeStateModel = WorldTimeStateModel.new()
var settings_state: SettingsStateModel = SettingsStateModel.new()
var quest_state: QuestStateModel = QuestStateModel.new()
var world_flags: WorldFlagsStateModel = WorldFlagsStateModel.new()
var economy_state: EconomyStateModel = EconomyStateModel.new()
var politics_state: PoliticsStateModel = PoliticsStateModel.new()
var npc_world_state: NpcWorldStateModel = NpcWorldStateModel.new()
var civilization_state: CivilizationStateModel = CivilizationStateModel.new()

var world_seed_hash: int = 0
var world_width: int = 0
var world_height: int = 0
var world_biome_ids: PackedInt32Array = PackedInt32Array()
var world_height_raw: PackedFloat32Array = PackedFloat32Array()
var world_temperature: PackedFloat32Array = PackedFloat32Array()
var world_moisture: PackedFloat32Array = PackedFloat32Array()
var world_land_mask: PackedByteArray = PackedByteArray()
var world_beach_mask: PackedByteArray = PackedByteArray()
var world_cloud_cover: PackedFloat32Array = PackedFloat32Array()
var world_wind_u: PackedFloat32Array = PackedFloat32Array()
var world_wind_v: PackedFloat32Array = PackedFloat32Array()

var location: Dictionary = {
	"scene": SceneContracts.STATE_WORLD,
	"world_x": 0,
	"world_y": 0,
	"local_x": 48,
	"local_y": 48,
	"biome_id": -1,
	"biome_name": "",
}

var pending_battle: Dictionary = {}
var pending_poi: Dictionary = {}
var last_battle_result: Dictionary = {}
var run_flags: Dictionary = {}
var regional_cache_stats: Dictionary = {}
var local_rest_context: Dictionary = {}
var society_gpu_stats: Dictionary = {}

# In-game realtime clock (separate from world-map simulation TimeSystem).
# We advance `world_time` only while exploring (regional/local), at 1:1 by default.
# 1 real second == 1 in-game second.
const MAX_REALTIME_DELTA_SECONDS: float = 0.25
var _ingame_time_accum_seconds: float = 0.0
var _ui_pause_count: int = 0

var _events: Node = null
var _dialogue_service: NpcDialogueService = NpcDialogueService.new()

func _ready() -> void:
	_events = get_node_or_null("/root/GameEvents")
	_wire_event_pauses()
	if party.members.is_empty():
		party.reset_default_party()
	if world_time.year <= 0:
		world_time.reset_defaults()
	if quest_state.quests.is_empty():
		quest_state.ensure_default_quests()
	_ensure_sim_state_defaults()
	_refresh_epoch_metadata()
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_time_advanced()
	_emit_settings_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()
	set_process(true)

func _wire_event_pauses() -> void:
	if _events == null:
		return
	if _events.has_signal("menu_opened") and not _events.menu_opened.is_connected(_on_menu_opened):
		_events.menu_opened.connect(_on_menu_opened)
	if _events.has_signal("menu_closed") and not _events.menu_closed.is_connected(_on_menu_closed):
		_events.menu_closed.connect(_on_menu_closed)

func push_ui_pause(_reason: String = "") -> void:
	_ui_pause_count += 1

func pop_ui_pause(_reason: String = "") -> void:
	_ui_pause_count = max(0, _ui_pause_count - 1)

func _on_menu_opened(_context_title: String) -> void:
	push_ui_pause("menu")

func _on_menu_closed(_context_title: String) -> void:
	pop_ui_pause("menu")

func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if not _should_advance_ingame_realtime():
		# Don't carry fractional seconds across modes.
		_ingame_time_accum_seconds = 0.0
		return
	var dt: float = min(delta, MAX_REALTIME_DELTA_SECONDS)
	var scale: float = 1.0
	if run_flags.has("ingame_time_scale"):
		scale = max(0.0, float(run_flags.get("ingame_time_scale", 1.0)))
	if scale <= 0.0:
		return
	_ingame_time_accum_seconds += dt * scale
	var seconds: int = int(floor(_ingame_time_accum_seconds))
	if seconds <= 0:
		return
	_ingame_time_accum_seconds -= float(seconds)
	advance_world_time_seconds(seconds, "realtime")

func _should_advance_ingame_realtime() -> bool:
	var scene_name: String = String(location.get("scene", SceneContracts.STATE_WORLD))
	if _ui_pause_count > 0:
		return false
	return scene_name == SceneContracts.STATE_REGIONAL or scene_name == SceneContracts.STATE_LOCAL

func reset_run() -> void:
	party.reset_default_party()
	world_time.reset_defaults()
	settings_state.reset_defaults()
	quest_state.reset_defaults()
	world_flags.reset_defaults()
	economy_state.reset_defaults()
	politics_state.reset_defaults()
	npc_world_state.reset_defaults()
	civilization_state.reset_defaults()
	world_seed_hash = 0
	world_width = 0
	world_height = 0
	world_biome_ids = PackedInt32Array()
	world_height_raw = PackedFloat32Array()
	world_temperature = PackedFloat32Array()
	world_moisture = PackedFloat32Array()
	world_land_mask = PackedByteArray()
	world_beach_mask = PackedByteArray()
	world_cloud_cover = PackedFloat32Array()
	world_wind_u = PackedFloat32Array()
	world_wind_v = PackedFloat32Array()
	location = {
		"scene": SceneContracts.STATE_WORLD,
		"world_x": 0,
		"world_y": 0,
		"local_x": 48,
		"local_y": 48,
		"biome_id": -1,
		"biome_name": "",
	}
	pending_battle.clear()
	pending_poi.clear()
	last_battle_result.clear()
	run_flags.clear()
	regional_cache_stats.clear()
	local_rest_context.clear()
	society_gpu_stats.clear()
	_ingame_time_accum_seconds = 0.0
	_ui_pause_count = 0
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_time_advanced()
	_emit_location_changed()
	_emit_settings_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()

func initialize_world_snapshot(
	width: int,
	height: int,
	seed_hash: int,
	biome_ids: PackedInt32Array,
	height_raw: PackedFloat32Array = PackedFloat32Array(),
	temperature: PackedFloat32Array = PackedFloat32Array(),
	moisture: PackedFloat32Array = PackedFloat32Array(),
	land_mask: PackedByteArray = PackedByteArray(),
	beach_mask: PackedByteArray = PackedByteArray(),
	cloud_cover: PackedFloat32Array = PackedFloat32Array(),
	wind_u: PackedFloat32Array = PackedFloat32Array(),
	wind_v: PackedFloat32Array = PackedFloat32Array()
) -> void:
	world_width = max(1, width)
	world_height = max(1, height)
	world_seed_hash = seed_hash
	world_biome_ids = biome_ids.duplicate()
	var size: int = world_width * world_height
	world_height_raw = height_raw.duplicate() if height_raw.size() == size else PackedFloat32Array()
	world_temperature = temperature.duplicate() if temperature.size() == size else PackedFloat32Array()
	world_moisture = moisture.duplicate() if moisture.size() == size else PackedFloat32Array()
	world_land_mask = land_mask.duplicate() if land_mask.size() == size else PackedByteArray()
	world_beach_mask = beach_mask.duplicate() if beach_mask.size() == size else PackedByteArray()
	world_cloud_cover = cloud_cover.duplicate() if cloud_cover.size() == size else PackedFloat32Array()
	world_wind_u = wind_u.duplicate() if wind_u.size() == size else PackedFloat32Array()
	world_wind_v = wind_v.duplicate() if wind_v.size() == size else PackedFloat32Array()
	_ensure_sim_state_defaults()
	civilization_state.ensure_size(world_width, world_height)
	if civilization_state.emergence_abs_day < 0:
		civilization_state.emergence_abs_day = 365 + DeterministicRng.randi_range(
			_seed_or_default(),
			"civ_emergence_abs_day",
			0,
			4 * 365
		)
	# New world snapshots should invalidate regional perf telemetry from older maps.
	regional_cache_stats.clear()
	run_flags.erase("society_seeded_tiles")
	if _events and _events.has_signal("world_snapshot_updated"):
		_events.emit_signal("world_snapshot_updated", world_width, world_height, world_seed_hash)

func has_world_snapshot() -> bool:
	return world_width > 0 and world_height > 0 and world_biome_ids.size() == world_width * world_height

func get_world_biome_id(x: int, y: int) -> int:
	if not has_world_snapshot():
		return int(location.get("biome_id", -1))
	var wx: int = posmod(x, world_width)
	var wy: int = clamp(y, 0, world_height - 1)
	var i: int = wx + wy * world_width
	if i < 0 or i >= world_biome_ids.size():
		return int(location.get("biome_id", -1))
	return world_biome_ids[i]

func ensure_world_snapshot_integrity() -> void:
	var startup_state: Node = get_node_or_null("/root/StartupState")
	if startup_state == null:
		return
	if not startup_state.has_method("has_world_snapshot") or not bool(startup_state.has_world_snapshot()):
		return
	var startup_w: int = int(startup_state.get("world_width"))
	var startup_h: int = int(startup_state.get("world_height"))
	var startup_biomes_v: Variant = startup_state.get("world_biome_ids")
	if startup_w <= 0 or startup_h <= 0 or not (startup_biomes_v is PackedInt32Array):
		return
	var startup_biomes: PackedInt32Array = startup_biomes_v
	if startup_biomes.size() != startup_w * startup_h:
		return
	var use_startup: bool = false
	if not has_world_snapshot():
		use_startup = true
	else:
		var loc_x: int = int(location.get("world_x", 0))
		var loc_y: int = int(location.get("world_y", 0))
		var game_here: int = get_world_biome_id(loc_x, loc_y)
		var startup_here: int = int(startup_state.get_world_biome_id(loc_x, loc_y)) if startup_state.has_method("get_world_biome_id") else game_here
		if game_here <= 1 and startup_here > 1:
			use_startup = true
		else:
			var game_ocean: float = _ocean_fraction(world_biome_ids)
			var startup_ocean: float = _ocean_fraction(startup_biomes)
			if game_ocean >= 0.995 and startup_ocean < game_ocean:
				use_startup = true
	if not use_startup:
		return
	var startup_seed: int = int(startup_state.get("world_seed_hash"))
	var height_raw: PackedFloat32Array = startup_state.get("world_height_raw") if startup_state.get("world_height_raw") is PackedFloat32Array else PackedFloat32Array()
	var temp: PackedFloat32Array = startup_state.get("world_temperature") if startup_state.get("world_temperature") is PackedFloat32Array else PackedFloat32Array()
	var moist: PackedFloat32Array = startup_state.get("world_moisture") if startup_state.get("world_moisture") is PackedFloat32Array else PackedFloat32Array()
	var land_mask: PackedByteArray = startup_state.get("world_land_mask") if startup_state.get("world_land_mask") is PackedByteArray else PackedByteArray()
	var beach_mask: PackedByteArray = startup_state.get("world_beach_mask") if startup_state.get("world_beach_mask") is PackedByteArray else PackedByteArray()
	var cloud_cover: PackedFloat32Array = startup_state.get("world_cloud_cover") if startup_state.get("world_cloud_cover") is PackedFloat32Array else PackedFloat32Array()
	var wind_u: PackedFloat32Array = startup_state.get("world_wind_u") if startup_state.get("world_wind_u") is PackedFloat32Array else PackedFloat32Array()
	var wind_v: PackedFloat32Array = startup_state.get("world_wind_v") if startup_state.get("world_wind_v") is PackedFloat32Array else PackedFloat32Array()
	initialize_world_snapshot(
		startup_w,
		startup_h,
		startup_seed,
		startup_biomes,
		height_raw,
		temp,
		moist,
		land_mask,
		beach_mask,
		cloud_cover,
		wind_u,
		wind_v
	)

func set_location(scene_name: String, world_x: int, world_y: int, local_x: int, local_y: int, biome_id: int = -1, biome_name: String = "") -> void:
	# UI pauses are transient; don't let them leak across scene changes.
	var next_scene: String = String(scene_name)
	if next_scene != SceneContracts.STATE_REGIONAL and next_scene != SceneContracts.STATE_LOCAL:
		_ui_pause_count = 0
	location["scene"] = scene_name
	location["world_x"] = world_x
	location["world_y"] = world_y
	location["local_x"] = local_x
	location["local_y"] = local_y
	if biome_id >= 0:
		location["biome_id"] = biome_id
	if not biome_name.is_empty():
		location["biome_name"] = biome_name
	if next_scene == SceneContracts.STATE_REGIONAL or next_scene == SceneContracts.STATE_LOCAL:
		_ensure_society_tile_records(world_x, world_y)
	_emit_location_changed()

func get_location() -> Dictionary:
	return location.duplicate(true)

func mark_regional_step() -> void:
	if _events and _events.has_signal("regional_step_taken"):
		_events.emit_signal("regional_step_taken", get_location())

func ensure_encounter_meter_state() -> Dictionary:
	var v: Variant = run_flags.get("encounter_meter_state")
	if typeof(v) != TYPE_DICTIONARY:
		v = {}
		run_flags["encounter_meter_state"] = v
	var st: Dictionary = v
	EncounterRegistry.ensure_danger_meter_state_inplace(st)
	return st

func reset_encounter_meter_after_battle(encounter_ctx: Dictionary = {}) -> void:
	# FF-style: after any battle, reset the step-based encounter meter.
	var st: Dictionary = ensure_encounter_meter_state()
	var wx: int = int(location.get("world_x", 0))
	var wy: int = int(location.get("world_y", 0))
	var biome_id: int = int(location.get("biome_id", -1))
	if typeof(encounter_ctx) == TYPE_DICTIONARY and not encounter_ctx.is_empty():
		wx = int(encounter_ctx.get("world_x", wx))
		wy = int(encounter_ctx.get("world_y", wy))
		if encounter_ctx.has("biome_id"):
			biome_id = int(encounter_ctx.get("biome_id", biome_id))
	if biome_id < 0:
		biome_id = get_world_biome_id(wx, wy)
	var minute: int = int(world_time.minute_of_day) if world_time != null else -1
	EncounterRegistry.reset_danger_meter(world_seed_hash, st, wx, wy, biome_id, minute)

func advance_world_time(minutes: int, _reason: String = "") -> void:
	var mins: int = max(0, minutes)
	if mins <= 0:
		return
	var day_before: int = world_time.abs_day_index()
	world_time.advance_minutes(mins)
	_tick_background_society_days(day_before, world_time.abs_day_index())
	_emit_time_advanced()

func advance_world_time_seconds(seconds: int, _reason: String = "") -> void:
	var secs: int = max(0, seconds)
	if secs <= 0:
		return
	var day_before: int = world_time.abs_day_index()
	world_time.advance_seconds(secs)
	_tick_background_society_days(day_before, world_time.abs_day_index())
	_emit_time_advanced()

func sync_world_time_from_sim_days(sim_days: float, _reason: String = "") -> void:
	# Bridge world-map simulation clock into gameplay clock when entering exploration.
	var days: float = max(0.0, float(sim_days))
	var abs_day: int = int(floor(days))
	var day_frac: float = clamp(days - float(abs_day), 0.0, 0.999999)
	var second_in_day: int = int(round(day_frac * float(WorldTimeStateModel.SECONDS_PER_DAY)))
	if second_in_day >= WorldTimeStateModel.SECONDS_PER_DAY:
		second_in_day = 0
		abs_day += 1
	world_time.set_from_abs_day(abs_day, second_in_day)
	_emit_time_advanced()

func queue_battle(encounter_data: Dictionary) -> void:
	pending_battle = encounter_data.duplicate(true)
	if _events and _events.has_signal("battle_started"):
		_events.emit_signal("battle_started", pending_battle.duplicate(true))

func consume_pending_battle() -> Dictionary:
	if pending_battle.is_empty():
		return {}
	var out: Dictionary = pending_battle.duplicate(true)
	pending_battle.clear()
	return out

func queue_poi(poi_data: Dictionary) -> void:
	pending_poi = poi_data.duplicate(true)
	register_poi_discovery(poi_data)
	if _events and _events.has_signal("poi_entered"):
		_events.emit_signal("poi_entered", pending_poi.duplicate(true))

func consume_pending_poi() -> Dictionary:
	if pending_poi.is_empty():
		return {}
	var out: Dictionary = pending_poi.duplicate(true)
	pending_poi.clear()
	return out

func register_poi_discovery(poi_data: Dictionary) -> void:
	world_flags.register_poi_discovery(poi_data)
	_emit_world_flags_changed()

func mark_world_tile_visited(world_x: int, world_y: int) -> void:
	world_flags.mark_world_tile_visited(world_x, world_y)
	_ensure_society_tile_records(world_x, world_y)
	_emit_world_flags_changed()

func is_world_tile_visited(world_x: int, world_y: int) -> bool:
	return world_flags.is_world_tile_visited(world_x, world_y)

func get_poi_instance_state(poi_id: String) -> Dictionary:
	return world_flags.get_poi_instance_state(poi_id)

func apply_poi_instance_patch(poi_id: String, patch: Dictionary) -> void:
	world_flags.apply_poi_instance_patch(poi_id, patch)
	_emit_world_flags_changed()

func is_poi_boss_defeated(poi_id: String) -> bool:
	return world_flags.is_poi_boss_defeated(poi_id)

func mark_poi_cleared(poi_id: String) -> void:
	world_flags.mark_poi_cleared(poi_id)
	_emit_world_flags_changed()

func is_poi_cleared(poi_id: String) -> bool:
	return world_flags.is_poi_cleared(poi_id)

func apply_battle_result(result_data: Dictionary) -> Dictionary:
	last_battle_result = result_data.duplicate(true)
	world_flags.register_battle_result(result_data)
	var enc_for_reset: Dictionary = result_data.get("encounter", {})
	if typeof(enc_for_reset) != TYPE_DICTIONARY:
		enc_for_reset = {}
	reset_encounter_meter_after_battle(enc_for_reset)
	# Apply party HP/MP changes from battle.
	var after_list: Variant = result_data.get("party_after", [])
	if typeof(after_list) == TYPE_ARRAY:
		var hp_map: Dictionary = {}
		var mp_map: Dictionary = {}
		for entry in after_list:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var idv: String = String(entry.get("id", ""))
			if idv.is_empty():
				continue
			hp_map[idv] = int(entry.get("hp", 0))
			mp_map[idv] = int(entry.get("mp", 0))
		for member in party.members:
			if member == null:
				continue
			var mid: String = String(member.member_id)
			if hp_map.has(mid):
				member.hp = clamp(int(hp_map[mid]), 0, member.max_hp)
			if mp_map.has(mid):
				member.mp = clamp(int(mp_map[mid]), 0, member.max_mp)
	var logs: PackedStringArray = PackedStringArray()
	if bool(result_data.get("victory", false)):
		var enc_ctx: Dictionary = result_data.get("encounter", {})
		var rewards: Dictionary = _apply_reward_context_multipliers(result_data.get("rewards", {}), enc_ctx)
		logs = party.grant_rewards(rewards)
		last_battle_result["reward_logs"] = logs
		last_battle_result["rewards"] = rewards.duplicate(true)
		# Dungeon boss clears the dungeon POI.
		var enc: Dictionary = enc_ctx
		var battle_kind: String = String(enc.get("battle_kind", ""))
		if battle_kind == "dungeon_boss":
			var poi_id: String = String(enc.get("poi_id", ""))
			if not poi_id.is_empty():
				world_flags.apply_poi_instance_patch(poi_id, {"boss_defeated": true})
				world_flags.mark_poi_cleared(poi_id)
		# Faction progression hook: victories improve standing in the local owning state.
		var rep_wx: int = int(enc.get("world_x", int(location.get("world_x", 0))))
		var rep_wy: int = int(enc.get("world_y", int(location.get("world_y", 0))))
		var rep_state_id: String = get_political_state_id_at(rep_wx, rep_wy)
		var rep_faction_id: String = _faction_id_for_state(rep_state_id)
		if not rep_faction_id.is_empty():
			var rep_gain: int = 1
			if battle_kind == "dungeon_boss":
				rep_gain = 8
			elif battle_kind == "dungeon_random":
				rep_gain = 2
			_award_faction_reputation(rep_faction_id, rep_gain, "battle_" + battle_kind)
		# Scaffold quest progression: complete the starter quest on first victory.
		if quest_state.quests.has("quest_first_steps"):
			var q: Dictionary = quest_state.quests["quest_first_steps"]
			if int(q.get("status", QuestStateModel.QuestStatus.ACTIVE)) == QuestStateModel.QuestStatus.ACTIVE:
				quest_state.set_status("quest_first_steps", QuestStateModel.QuestStatus.COMPLETED)
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()
	if _events and _events.has_signal("battle_resolved"):
		_events.emit_signal("battle_resolved", last_battle_result.duplicate(true))
	return {
		"reward_logs": logs,
	}

func apply_settings_patch(patch: Dictionary) -> void:
	settings_state.apply_patch(patch)
	_emit_settings_changed()

func get_settings_snapshot() -> Dictionary:
	return settings_state.to_dict()

func get_encounter_rate_multiplier() -> float:
	return clamp(settings_state.encounter_rate_multiplier, 0.10, 2.00)

func get_epoch_encounter_rate_multiplier() -> float:
	var gp: Dictionary = _epoch_gameplay_multipliers()
	var out: float = clamp(float(gp.get("encounter_rate_mul", 1.0)), 0.25, 3.00)
	var tod: int = _tod_bucket_from_minute(_minute_of_day())
	match tod:
		_TOD_NIGHT:
			out *= 1.14
		_TOD_DAWN:
			out *= 1.05
		_TOD_DUSK:
			out *= 1.08
		_:
			out *= 0.95
	var season: int = _season_bucket_from_day(_day_of_year_0_364())
	if season == _SEASON_WINTER:
		out *= 1.07
	elif season == _SEASON_SUMMER:
		out *= 1.03
	return clamp(out, 0.30, 3.20)

func apply_epoch_gameplay_to_encounter(encounter_data: Dictionary) -> Dictionary:
	if typeof(encounter_data) != TYPE_DICTIONARY or encounter_data.is_empty():
		return encounter_data
	var out: Dictionary = encounter_data.duplicate(true)
	var gp: Dictionary = _epoch_gameplay_multipliers()
	var context: Dictionary = _local_society_context(
		int(out.get("world_x", int(location.get("world_x", 0)))),
		int(out.get("world_y", int(location.get("world_y", 0)))),
		String(out.get("home_state_id", ""))
	)
	var scarcity: float = clamp(float(context.get("scarcity_pressure", 0.0)), 0.0, 1.0)
	var war_pressure: float = clamp(float(context.get("local_war_pressure", 0.0)), 0.0, 1.0)
	var tod: int = _tod_bucket_from_minute(int(out.get("minute_of_day", _minute_of_day())))
	var season: int = _season_bucket_from_day(int(out.get("day_of_year", _day_of_year_0_364())))

	var power_mul: float = clamp(float(gp.get("encounter_power_mul", 1.0)), 0.50, 3.00)
	var hp_mul: float = clamp(float(gp.get("encounter_hp_mul", 1.0)), 0.50, 3.50)
	var power_add: int = int(gp.get("encounter_power_add", 0))
	power_mul *= (1.0 + scarcity * 0.22 + war_pressure * 0.28)
	hp_mul *= (1.0 + scarcity * 0.18 + war_pressure * 0.22)
	if tod == _TOD_NIGHT:
		power_mul *= 1.10
		hp_mul *= 1.06
	elif tod == _TOD_DAWN:
		power_mul *= 0.98
	if season == _SEASON_WINTER:
		hp_mul *= 1.06
	elif season == _SEASON_SUMMER:
		power_mul *= 1.03
	power_add += int(round(scarcity * 2.0 + war_pressure * 3.0))

	out["enemy_power"] = max(1, int(round(float(out.get("enemy_power", 8)) * power_mul)) + power_add)
	out["enemy_hp"] = max(4, int(round(float(out.get("enemy_hp", 30)) * hp_mul)))

	var flee_mul: float = clamp(float(gp.get("flee_mul", 1.0)), 0.35, 1.80)
	flee_mul *= (1.0 - scarcity * 0.16 - war_pressure * 0.18)
	if tod == _TOD_NIGHT:
		flee_mul *= 0.92
	out["flee_chance"] = clamp(float(out.get("flee_chance", 0.45)) * flee_mul, 0.03, 0.97)

	var reward_gold_mul: float = clamp(float(gp.get("reward_gold_mul", 1.0)), 0.25, 4.00)
	var reward_exp_mul: float = clamp(float(gp.get("reward_exp_mul", 1.0)), 0.25, 4.00)
	reward_gold_mul *= (1.0 + scarcity * 0.10 + war_pressure * 0.16)
	reward_exp_mul *= (1.0 + scarcity * 0.08 + war_pressure * 0.10)
	if tod == _TOD_NIGHT:
		reward_exp_mul *= 1.06
	if season == _SEASON_WINTER:
		reward_gold_mul *= 1.04
	var rewards: Dictionary = out.get("rewards", {}).duplicate(true)
	rewards["exp"] = max(0, int(round(float(rewards.get("exp", 0)) * reward_exp_mul)))
	rewards["gold"] = max(0, int(round(float(rewards.get("gold", 0)) * reward_gold_mul)))
	out["rewards"] = rewards
	out["rewards_scaled"] = true
	out["reward_exp_mul"] = reward_exp_mul
	out["reward_gold_mul"] = reward_gold_mul
	out["epoch_gameplay_mul"] = gp.duplicate(true)
	out["scarcity_pressure"] = scarcity
	out["local_war_pressure"] = war_pressure
	out["top_shortage"] = String(context.get("top_shortage", ""))
	out["top_shortage_value"] = float(context.get("top_shortage_value", 0.0))
	return out

func get_item_market_price_multipliers(item_name: String, world_x: int, world_y: int) -> Dictionary:
	item_name = String(item_name)
	var gp: Dictionary = _epoch_gameplay_multipliers()
	var ec: Dictionary = _local_society_context(world_x, world_y, "")
	var scarcity: float = clamp(float(ec.get("scarcity_pressure", 0.0)), 0.0, 1.0)
	var war_pressure: float = clamp(float(ec.get("local_war_pressure", 0.0)), 0.0, 1.0)
	var buy_mul: float = clamp(float(gp.get("shop_buy_mul", 1.0)), 0.35, 4.00)
	var sell_mul: float = clamp(float(gp.get("shop_sell_mul", 0.45)), 0.10, 1.60)
	buy_mul *= (1.0 + scarcity * 0.70 + war_pressure * 0.45)
	sell_mul *= (1.0 - scarcity * 0.20 - war_pressure * 0.20)
	var tod: int = _tod_bucket_from_minute(_minute_of_day())
	if tod == _TOD_NIGHT:
		buy_mul *= 1.08
		sell_mul *= 0.94
	elif tod == _TOD_DAWN:
		buy_mul *= 0.98
		sell_mul *= 1.02
	var season: int = _season_bucket_from_day(_day_of_year_0_364())
	var item: Dictionary = ItemCatalog.get_item(item_name)
	var kind: String = String(item.get("kind", "item"))
	if season == _SEASON_WINTER and (kind == "consumable" or item_name == "Herb" or item_name == "Potion"):
		buy_mul *= 1.10
		sell_mul *= 0.96
	elif season == _SEASON_SUMMER and kind == "weapon":
		buy_mul *= 1.05
	if kind == "weapon" or kind == "armor" or kind == "accessory":
		buy_mul *= 1.04 + war_pressure * 0.10
		sell_mul *= 1.02
	return {
		"buy_mul": clamp(buy_mul, 0.20, 8.00),
		"sell_mul": clamp(sell_mul, 0.05, 2.00),
		"scarcity_pressure": scarcity,
		"local_war_pressure": war_pressure,
		"top_shortage": String(ec.get("top_shortage", "")),
		"top_shortage_value": float(ec.get("top_shortage_value", 0.0)),
		"epoch_id": String(civilization_state.epoch_id),
		"epoch_variant": String(civilization_state.epoch_variant),
	}

func get_local_npc_activity_multipliers(world_x: int, world_y: int, state_id: String = "") -> Dictionary:
	state_id = String(state_id)
	var ec: Dictionary = _local_society_context(world_x, world_y, state_id)
	var scarcity: float = clamp(float(ec.get("scarcity_pressure", 0.0)), 0.0, 1.0)
	var war_pressure: float = clamp(float(ec.get("local_war_pressure", 0.0)), 0.0, 1.0)
	var tod: int = _tod_bucket_from_minute(_minute_of_day())
	var npc_mul: Dictionary = EpochSystem.npc_multipliers(civilization_state.epoch_id, civilization_state.epoch_variant)
	var density_mul: float = 1.0 - scarcity * 0.35 - war_pressure * 0.28
	if tod == _TOD_NIGHT:
		density_mul *= 0.62
	elif tod == _TOD_DUSK:
		density_mul *= 0.86
	elif tod == _TOD_DAWN:
		density_mul *= 0.92
	density_mul *= clamp(float(npc_mul.get("local_relief_scale", 1.0)), 0.60, 1.60)
	var move_interval_mul: float = 1.0 + scarcity * 0.35 + war_pressure * 0.40
	if tod == _TOD_NIGHT:
		move_interval_mul *= 1.35
	move_interval_mul *= clamp(float(npc_mul.get("need_gain_scale", 1.0)), 0.70, 1.80)
	var disposition_shift: float = -0.10 * scarcity - 0.18 * war_pressure
	disposition_shift += (0.05 if tod == _TOD_DAY else 0.0)
	disposition_shift += (0.04 if civilization_state.epoch_variant == "stable" else -0.02)
	return {
		"density_mul": clamp(density_mul, 0.25, 2.00),
		"move_interval_mul": clamp(move_interval_mul, 0.50, 3.00),
		"disposition_shift": clamp(disposition_shift, -0.90, 0.50),
		"scarcity_pressure": scarcity,
		"local_war_pressure": war_pressure,
	}

func get_political_state_id_at(world_x: int, world_y: int) -> String:
	_ensure_society_tile_records(world_x, world_y)
	var prov_id: String = politics_state.province_id_at(world_x, world_y)
	var pv: Variant = politics_state.provinces.get(prov_id, {})
	if typeof(pv) == TYPE_DICTIONARY:
		var pd: Dictionary = pv as Dictionary
		var owner_state_id: String = String(pd.get("owner_state_id", ""))
		if not owner_state_id.is_empty():
			return owner_state_id
	return ""

func get_npc_dialogue_line(npc_profile: Dictionary) -> String:
	if typeof(npc_profile) != TYPE_DICTIONARY or npc_profile.is_empty():
		return ""
	var world_x: int = int(npc_profile.get("world_x", int(location.get("world_x", 0))))
	var world_y: int = int(npc_profile.get("world_y", int(location.get("world_y", 0))))
	var state_id: String = String(npc_profile.get("home_state_id", ""))
	if state_id.is_empty():
		state_id = get_political_state_id_at(world_x, world_y)
	var ec: Dictionary = _local_society_context(world_x, world_y, state_id)
	var world_ctx: Dictionary = {
		"epoch_id": String(civilization_state.epoch_id),
		"epoch_variant": String(civilization_state.epoch_variant),
		"season_name": world_time.season_name(),
		"time_bucket": _tod_bucket_name(_tod_bucket_from_minute(_minute_of_day())),
		"disposition_hint": float(npc_profile.get("disposition_bias", 0.0)) + float(ec.get("disposition_shift", 0.0)),
		"top_shortage": String(ec.get("top_shortage", "")),
		"top_shortage_value": float(ec.get("top_shortage_value", 0.0)),
		"scarcity_pressure": float(ec.get("scarcity_pressure", 0.0)),
		"states_at_war": bool(ec.get("states_at_war", false)),
		"local_war_pressure": float(ec.get("local_war_pressure", 0.0)),
	}
	var player_ctx: Dictionary = {
		"party_size": party.members.size(),
		"party_power": get_party_power(),
		"gold": party.gold,
	}
	var request: Dictionary = _dialogue_service.build_context(npc_profile, player_ctx, world_ctx)
	var out: Dictionary = _dialogue_service.request_dialogue(request)
	return String(out.get("text", ""))

func get_regional_biome_transition_overrides(center_world_x: int, center_world_y: int, radius_tiles: int = 1) -> Dictionary:
	var out: Dictionary = {}
	radius_tiles = clamp(int(radius_tiles), 0, 4)
	var d: int = _day_of_year_0_364()
	var winter_strength: float = _winter_strength(d)
	for oy in range(-radius_tiles, radius_tiles + 1):
		for ox in range(-radius_tiles, radius_tiles + 1):
			var wx: int = posmod(center_world_x + ox, max(1, world_width))
			var wy: int = clamp(center_world_y + oy, 0, max(1, world_height) - 1)
			var from_biome: int = get_world_biome_id(wx, wy)
			var to_biome: int = _seasonal_target_biome_id(from_biome, wx, wy)
			if from_biome == to_biome:
				continue
			var lat_abs: float = _lat_abs01(wy)
			var noise: float = DeterministicRng.randf01(_seed_or_default(), "region_transition|%d|%d" % [wx, wy])
			var p: float = clamp(winter_strength * (0.35 + lat_abs * 0.95) + (noise - 0.5) * 0.30, 0.0, 1.0)
			if p <= 0.01:
				continue
			out["%d,%d" % [wx, wy]] = {
				"from_biome": from_biome,
				"to_biome": to_biome,
				"progress": p,
			}
	return out

func set_regional_cache_stats(stats: Dictionary) -> void:
	if typeof(stats) != TYPE_DICTIONARY:
		regional_cache_stats = {}
		return
	regional_cache_stats = stats.duplicate(true)

func get_regional_cache_stats() -> Dictionary:
	return regional_cache_stats.duplicate(true)

func set_society_gpu_stats(stats: Dictionary) -> void:
	if typeof(stats) != TYPE_DICTIONARY:
		society_gpu_stats = {}
		return
	society_gpu_stats = stats.duplicate(true)

func get_society_gpu_stats() -> Dictionary:
	return society_gpu_stats.duplicate(true)

func get_civilization_epoch_info() -> Dictionary:
	_ensure_sim_state_defaults()
	return {
		"epoch_id": String(civilization_state.epoch_id),
		"epoch_index": int(civilization_state.epoch_index),
		"epoch_progress": float(civilization_state.epoch_progress),
		"epoch_variant": String(civilization_state.epoch_variant),
		"epoch_target_id": String(civilization_state.epoch_target_id),
		"epoch_target_variant": String(civilization_state.epoch_target_variant),
		"epoch_shift_due_abs_day": int(civilization_state.epoch_shift_due_abs_day),
		"tech_level": float(civilization_state.tech_level),
		"global_devastation": float(civilization_state.global_devastation),
	}

func get_society_debug_tile(world_x: int, world_y: int) -> Dictionary:
	world_x = posmod(int(world_x), max(1, world_width))
	world_y = clamp(int(world_y), 0, max(1, world_height) - 1)
	var out: Dictionary = {}
	var biome_id: int = get_world_biome_id(world_x, world_y)
	out["wildlife"] = _wildlife_proxy_for_biome(biome_id)
	out["human_pop"] = _settlement_population_proxy(world_x, world_y)
	var ctx: Dictionary = _local_society_context(world_x, world_y, "")
	out["war_pressure"] = float(ctx.get("local_war_pressure", 0.0))
	out["devastation"] = float(civilization_state.global_devastation)
	out["tech_level"] = float(civilization_state.tech_level)
	return out

func set_local_rest_context(can_rest: bool, rest_type: String = "") -> void:
	local_rest_context = {
		"ok": bool(can_rest),
		"rest_type": String(rest_type),
		"scene": String(location.get("scene", "")),
		"world_x": int(location.get("world_x", 0)),
		"world_y": int(location.get("world_y", 0)),
	}

func clear_local_rest_context() -> void:
	local_rest_context.clear()

func get_local_rest_context() -> Dictionary:
	return local_rest_context.duplicate(true)

func can_rest_until_morning() -> Dictionary:
	var scene_name: String = String(location.get("scene", ""))
	if scene_name != SceneContracts.STATE_LOCAL and scene_name != SceneContracts.STATE_REGIONAL:
		return {"ok": false, "reason": "Rest is only available while exploring."}
	if bool(local_rest_context.get("ok", false)):
		var cost: int = _rest_cost_for_context()
		if party.gold < cost:
			return {"ok": false, "reason": "Not enough gold to rest (%d needed)." % cost}
		return {"ok": true, "cost": cost, "rest_type": String(local_rest_context.get("rest_type", ""))}
	return {"ok": false, "reason": "No safe resting place here."}

func rest_until_morning() -> Dictionary:
	var gate: Dictionary = can_rest_until_morning()
	if not bool(gate.get("ok", false)):
		return {"ok": false, "message": String(gate.get("reason", "Cannot rest here."))}
	var cost: int = max(0, int(gate.get("cost", 0)))
	if cost > 0:
		party.gold = max(0, party.gold - cost)
	var now: int = _second_of_day()
	var target: int = REST_MORNING_HOUR * 60 * 60
	var delta: int = target - now
	if delta <= 0:
		delta += WorldTimeStateModel.SECONDS_PER_DAY
	advance_world_time_seconds(delta, "rest")
	for member in party.members:
		if member == null:
			continue
		member.hp = member.max_hp
		member.mp = member.max_mp
	_emit_party_changed()
	_emit_inventory_changed()
	return {
		"ok": true,
		"seconds_advanced": delta,
		"message": "Rested until morning. Party recovered.",
	}

func can_hire_party_member() -> bool:
	return party.members.size() < PARTY_MEMBER_CAP

func try_hire_npc(npc_profile: Dictionary) -> Dictionary:
	if typeof(npc_profile) != TYPE_DICTIONARY:
		return {"ok": false, "message": "This person is not interested."}
	if not can_hire_party_member():
		return {"ok": false, "message": "Your party is full (max %d)." % PARTY_MEMBER_CAP}
	var role: String = String(npc_profile.get("role", "resident")).to_lower()
	var kind: int = int(npc_profile.get("kind", 0))
	if kind == 3:
		return {"ok": false, "message": "They are too young to join."}
	var disposition: float = clamp(float(npc_profile.get("disposition_bias", 0.0)), -1.0, 1.0)
	if role == "shopkeeper":
		return {"ok": false, "message": "The shopkeeper will not leave the post."}
	var world_x: int = int(npc_profile.get("world_x", int(location.get("world_x", 0))))
	var world_y: int = int(npc_profile.get("world_y", int(location.get("world_y", 0))))
	var home_state_id: String = String(npc_profile.get("home_state_id", ""))
	if home_state_id.is_empty():
		home_state_id = get_political_state_id_at(world_x, world_y)
	var recruit_source: String = _resolve_hire_source(npc_profile, role)
	var source_label: String = _hire_source_label(recruit_source)
	var faction_id: String = String(npc_profile.get("faction_id", "")).strip_edges()
	if faction_id.is_empty() and (recruit_source == "temple" or recruit_source == "faction_hall"):
		faction_id = _faction_id_for_state(home_state_id)
	var required_rank: int = max(0, int(npc_profile.get("faction_rank_required", 0)))
	if recruit_source == "temple":
		required_rank = max(required_rank, 1)
	elif recruit_source == "faction_hall":
		required_rank = max(required_rank, 2)
	var faction_rep: int = get_faction_reputation(faction_id)
	var faction_rank: int = _faction_rank_for_rep(faction_rep)
	if required_rank > 0:
		if faction_id.is_empty():
			return {"ok": false, "message": "They only recruit trusted members."}
		if faction_rank < required_rank:
			return {"ok": false, "message": "Need %s rank with this faction (%s required)." % [_faction_rank_label(faction_rank), _faction_rank_label(required_rank)]}

	var disposition_needed: float = 0.10
	if recruit_source == "inn":
		disposition_needed = 0.02
	elif recruit_source == "temple":
		disposition_needed = 0.16
	elif recruit_source == "faction_hall":
		disposition_needed = 0.22
	if role == "guard":
		disposition_needed = max(disposition_needed, 0.20)
	if disposition < disposition_needed:
		return {"ok": false, "message": "They are not ready to join from the %s yet." % source_label.to_lower()}
	var npc_id: String = String(npc_profile.get("npc_id", "npc"))
	var base_cost: int = 42 + int(round(float(civilization_state.epoch_index) * 8.0))
	base_cost += int(round(clamp(float(npc_profile.get("social_class_rank", 0.4)), 0.0, 1.0) * 26.0))
	base_cost += int(round(max(0.0, -disposition) * 18.0))
	var ctx: Dictionary = _local_society_context(
		world_x,
		world_y,
		home_state_id
	)
	base_cost = int(round(float(base_cost) * (1.0 + float(ctx.get("scarcity_pressure", 0.0)) * 0.20)))
	var source_cost_mul: float = 1.0
	if recruit_source == "inn":
		source_cost_mul = 1.12
	elif recruit_source == "temple":
		source_cost_mul = 0.96
	elif recruit_source == "faction_hall":
		source_cost_mul = clamp(1.22 - float(faction_rank) * 0.10, 0.72, 1.22)
	if not faction_id.is_empty():
		source_cost_mul *= (1.0 - clamp(float(faction_rank) * 0.03, 0.0, 0.12))
	base_cost = int(round(float(base_cost) * source_cost_mul))
	base_cost = max(12, base_cost)
	if party.gold < base_cost:
		return {"ok": false, "message": "They ask %d gold to join from the %s." % [base_cost, source_label]}

	var member := PartyMemberModel.new()
	member.member_id = _next_hire_member_id(npc_id)
	member.display_name = _hire_display_name(npc_id, kind)
	var avg_level: float = _party_average_level()
	member.level = clamp(int(round(avg_level)), 1, 60)
	member.experience_points = 0
	member.max_hp = 32 + member.level * 4
	member.max_mp = 8 + member.level * 2
	member.strength = 7 + int(round(avg_level * 0.6))
	member.defense = 6 + int(round(avg_level * 0.5))
	member.agility = 6 + int(round(avg_level * 0.55))
	member.intellect = 6 + int(round(avg_level * 0.45))
	if kind == 1:
		member.strength += 1
		member.defense += 1
	elif kind == 2:
		member.agility += 1
		member.intellect += 1
	else:
		member.agility += 2
	member.hp = member.max_hp
	member.mp = member.max_mp
	member.ensure_bag()
	var gear_tier: int = _gear_tier_for_hire(avg_level)
	_assign_hire_starting_loadout(member, npc_id, recruit_source, gear_tier)
	party.members.append(member)
	party.gold = max(0, party.gold - base_cost)
	party.rebuild_inventory_view()
	if not faction_id.is_empty():
		var rep_gain: int = 1
		if recruit_source == "inn":
			rep_gain = 2
		elif recruit_source == "temple":
			rep_gain = 3
		elif recruit_source == "faction_hall":
			rep_gain = 4
		_award_faction_reputation(faction_id, rep_gain, "hire_" + recruit_source)
	_emit_party_changed()
	_emit_inventory_changed()
	return {
		"ok": true,
		"member_id": member.member_id,
		"member_name": member.display_name,
		"cost": base_cost,
		"recruit_source": recruit_source,
		"faction_id": faction_id,
		"faction_rank": faction_rank,
		"message": "%s joined your party for %d gold (%s)." % [member.display_name, base_cost, source_label],
	}

func get_save_slot_metadata(path: String) -> Dictionary:
	var out: Dictionary = {
		"exists": FileAccess.file_exists(path),
		"corrupt": false,
		"saved_unix": 0,
		"time_compact": "",
		"location_label": "",
		"party_avg_level": 0.0,
	}
	if not bool(out.get("exists", false)):
		return out
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		out["corrupt"] = true
		return out
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		out["corrupt"] = true
		return out
	var d: Dictionary = parsed
	out["saved_unix"] = int(d.get("saved_unix", 0))
	var wt: WorldTimeStateModel = WorldTimeStateModel.from_dict(d.get("world_time", {}))
	out["time_compact"] = wt.format_compact()
	var loc: Dictionary = d.get("location", {})
	out["location_label"] = "W(%d,%d) L(%d,%d)" % [
		int(loc.get("world_x", 0)),
		int(loc.get("world_y", 0)),
		int(loc.get("local_x", 48)),
		int(loc.get("local_y", 48)),
	]
	var p: Dictionary = d.get("party", {})
	var members: Array = p.get("members", [])
	if not members.is_empty():
		var sum_lv: float = 0.0
		var n: int = 0
		for entry in members:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			sum_lv += max(1.0, float((entry as Dictionary).get("level", 1)))
			n += 1
		if n > 0:
			out["party_avg_level"] = sum_lv / float(n)
	return out

func get_menu_snapshot() -> Dictionary:
	var inventory_lines: PackedStringArray = PackedStringArray()
	for key in party.inventory.keys():
		var item_name: String = String(key)
		var item_data: Dictionary = ItemCatalog.get_item(item_name)
		var kind: String = String(item_data.get("kind", "item"))
		inventory_lines.append("%s x%d (%s)" % [item_name, int(party.inventory[key]), kind])
	if inventory_lines.is_empty():
		inventory_lines.append("(empty)")
	var overview_lines: PackedStringArray = PackedStringArray()
	overview_lines.append("Time: %s" % world_time.format_compact())
	overview_lines.append("Seed: %d" % world_seed_hash)
	overview_lines.append("Location: (%d,%d) local(%d,%d)" % [
		int(location.get("world_x", 0)),
		int(location.get("world_y", 0)),
		int(location.get("local_x", 48)),
		int(location.get("local_y", 48)),
	])
	for line in world_flags.summary_lines():
		overview_lines.append(String(line))
	return {
		"overview_lines": overview_lines,
		"time": world_time.format_compact(),
		"party_lines": party.summary_lines(4),
		"inventory_lines": inventory_lines,
		"equipment_lines": party.equipment_lines(4),
		"stats_lines": party.stat_lines(4),
		"quest_lines": quest_state.summary_lines(14),
		"settings_lines": settings_state.summary_lines(),
		"flags_lines": world_flags.summary_lines(),
		"gold": party.gold,
	}

func get_time_label() -> String:
	return world_time.format_compact()

func get_party_power() -> int:
	return party.total_power()

func use_consumable(item_name: String, member_id: String) -> Dictionary:
	item_name = String(item_name)
	member_id = String(member_id)
	if item_name.is_empty():
		return {"ok": false, "message": "No item selected."}
	if member_id.is_empty():
		return {"ok": false, "message": "No party member selected."}
	if int(party.inventory.get(item_name, 0)) <= 0:
		return {"ok": false, "message": "Item is not in inventory."}
	var item: Dictionary = ItemCatalog.get_item(item_name)
	if item.is_empty():
		return {"ok": false, "message": "Unknown item."}
	if String(item.get("kind", "")) != "consumable":
		return {"ok": false, "message": "That item cannot be used here."}
	var effect: Dictionary = item.get("use_effect", {})
	if effect.is_empty():
		return {"ok": false, "message": "Item has no usable effect."}
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	var effect_type: String = String(effect.get("type", ""))
	if effect_type == "heal_hp":
		var amount: int = max(1, int(effect.get("amount", 10)))
		var hp_before: int = int(member.hp)
		var hp_after: int = clamp(hp_before + amount, 0, int(member.max_hp))
		if not party.remove_item(item_name, 1):
			return {"ok": false, "message": "Failed to consume item."}
		member.hp = hp_after
		_emit_party_changed()
		_emit_inventory_changed()
		if hp_after == hp_before:
			return {
				"ok": true,
				"message": "%s used %s, but nothing happened." % [String(member.display_name), item_name],
			}
		return {
			"ok": true,
			"message": "%s used %s (+%d HP)." % [String(member.display_name), item_name, hp_after - hp_before],
		}
	return {"ok": false, "message": "Unsupported item effect."}

func equip_item(item_name: String, member_id: String) -> Dictionary:
	item_name = String(item_name)
	member_id = String(member_id)
	if item_name.is_empty():
		return {"ok": false, "message": "No item selected."}
	if member_id.is_empty():
		return {"ok": false, "message": "No party member selected."}
	var item: Dictionary = ItemCatalog.get_item(item_name)
	if item.is_empty():
		return {"ok": false, "message": "Unknown item."}
	var slot: String = String(item.get("equip_slot", ""))
	if slot.is_empty():
		var kind: String = String(item.get("kind", ""))
		if kind == "weapon" or kind == "armor" or kind == "accessory":
			slot = kind
	if slot != "weapon" and slot != "armor" and slot != "accessory":
		return {"ok": false, "message": "That item cannot be equipped."}
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	member.ensure_bag()
	var bag_idx: int = _find_member_bag_slot_with_item(member, item_name)
	if bag_idx < 0:
		return {"ok": false, "message": "Item must be in %s's inventory." % String(member.display_name)}
	var equipped_now: String = String(member.equipment.get(slot, ""))
	if equipped_now == item_name:
		# Toggle off.
		return unequip_slot(member_id, slot)
	# Unequip old item in this slot (clears bag marker too).
	if not equipped_now.is_empty():
		_clear_member_bag_equipped_marker(member, slot)
	# Equip new item: keep it in bag, but mark slot as equipped.
	_clear_member_bag_equipped_marker(member, slot)
	var slot_data: Dictionary = member.get_bag_slot(bag_idx)
	slot_data["equipped_slot"] = slot
	member.set_bag_slot(bag_idx, slot_data)
	member.equipment[slot] = item_name
	_emit_party_changed()
	_emit_inventory_changed()
	return {
		"ok": true,
		"message": "%s equipped %s (%s)." % [String(member.display_name), item_name, slot.capitalize()],
	}

func unequip_slot(member_id: String, slot: String) -> Dictionary:
	member_id = String(member_id)
	slot = String(slot).to_lower()
	if member_id.is_empty():
		return {"ok": false, "message": "No party member selected."}
	if slot != "weapon" and slot != "armor" and slot != "accessory":
		return {"ok": false, "message": "Invalid equipment slot."}
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	var equipped_now: String = String(member.equipment.get(slot, ""))
	if equipped_now.is_empty():
		return {"ok": false, "message": "%s has nothing equipped in %s." % [String(member.display_name), slot]}
	member.equipment[slot] = ""
	_clear_member_bag_equipped_marker(member, slot)
	_emit_party_changed()
	_emit_inventory_changed()
	return {
		"ok": true,
		"message": "%s unequipped %s." % [String(member.display_name), equipped_now],
	}

func consume_inventory_items(consumes: Array) -> void:
	# Used by battle system to apply item consumption once actions resolve.
	if consumes.is_empty():
		return
	var changed: bool = false
	for entry in consumes:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var item_name: String = String(entry.get("name", ""))
		var count: int = max(1, int(entry.get("count", 1)))
		if item_name.is_empty():
			continue
		if party.remove_item(item_name, count):
			changed = true
	if changed:
		_emit_inventory_changed()

func move_bag_item(from_member_id: String, from_idx: int, to_member_id: String, to_idx: int) -> Dictionary:
	from_member_id = String(from_member_id)
	to_member_id = String(to_member_id)
	if from_member_id.is_empty() or to_member_id.is_empty():
		return {"ok": false, "message": "Invalid party member."}
	var from_member: Variant = _find_member_by_id(from_member_id)
	var to_member: Variant = _find_member_by_id(to_member_id)
	if from_member == null or to_member == null:
		return {"ok": false, "message": "Party member not found."}
	from_member.ensure_bag()
	to_member.ensure_bag()
	if from_idx < 0 or from_idx >= from_member.bag.size():
		return {"ok": false, "message": "Invalid source slot."}
	if to_idx < 0 or to_idx >= to_member.bag.size():
		return {"ok": false, "message": "Invalid target slot."}
	if from_member_id == to_member_id and from_idx == to_idx:
		return {"ok": false, "message": "Same slot."}
	var a: Dictionary = from_member.get_bag_slot(from_idx)
	var b: Dictionary = to_member.get_bag_slot(to_idx)
	if String(a.get("name", "")).is_empty() or int(a.get("count", 0)) <= 0:
		return {"ok": false, "message": "Source slot is empty."}
	var a_equipped: String = String(a.get("equipped_slot", ""))
	var b_equipped: String = String(b.get("equipped_slot", ""))
	if from_member_id != to_member_id and (not a_equipped.is_empty() or not b_equipped.is_empty()):
		return {"ok": false, "message": "Unequip items before moving between characters."}
	# Merge if same item and stackable.
	var a_name: String = String(a.get("name", ""))
	var b_name: String = String(b.get("name", ""))
	if from_member_id == to_member_id:
		# Intra-bag moves can carry equipped marker without breaking anything.
		pass
	if a_name == b_name and not a_name.is_empty():
		var item: Dictionary = ItemCatalog.get_item(a_name)
		if bool(item.get("stackable", true)) and a_equipped.is_empty() and b_equipped.is_empty():
			var total: int = max(0, int(a.get("count", 0))) + max(0, int(b.get("count", 0)))
			b["count"] = total
			to_member.set_bag_slot(to_idx, b)
			from_member.set_bag_slot(from_idx, {})
			party.rebuild_inventory_view()
			_emit_inventory_changed()
			return {"ok": true, "message": "Stacked."}
	# Swap.
	from_member.set_bag_slot(from_idx, b)
	to_member.set_bag_slot(to_idx, a)
	party.rebuild_inventory_view()
	_emit_inventory_changed()
	_emit_party_changed()
	return {"ok": true, "message": "Moved."}

func give_bag_item(from_member_id: String, from_idx: int, to_member_id: String) -> Dictionary:
	# Give an item to another party member (auto-place). Used by drag-to-character UI.
	from_member_id = String(from_member_id)
	to_member_id = String(to_member_id)
	if from_member_id.is_empty() or to_member_id.is_empty():
		return {"ok": false, "message": "Invalid party member."}
	if from_member_id == to_member_id:
		return {"ok": false, "message": "That character already has the item."}
	var from_member: Variant = _find_member_by_id(from_member_id)
	var to_member: Variant = _find_member_by_id(to_member_id)
	if from_member == null or to_member == null:
		return {"ok": false, "message": "Party member not found."}
	from_member.ensure_bag()
	to_member.ensure_bag()
	if from_idx < 0 or from_idx >= from_member.bag.size():
		return {"ok": false, "message": "Invalid source slot."}
	var slot_data: Dictionary = from_member.get_bag_slot(from_idx)
	var item_name: String = String(slot_data.get("name", ""))
	var count: int = int(slot_data.get("count", 0))
	if item_name.is_empty() or count <= 0:
		return {"ok": false, "message": "Source slot is empty."}
	if not String(slot_data.get("equipped_slot", "")).is_empty():
		return {"ok": false, "message": "Unequip items before giving them away."}
	slot_data.erase("equipped_slot")

	var item: Dictionary = ItemCatalog.get_item(item_name)
	var stackable: bool = bool(item.get("stackable", true))
	if stackable:
		for i in range(to_member.bag.size()):
			var dst: Dictionary = to_member.get_bag_slot(i)
			if String(dst.get("name", "")) != item_name:
				continue
			if int(dst.get("count", 0)) <= 0:
				continue
			if not String(dst.get("equipped_slot", "")).is_empty():
				continue
			dst["count"] = int(dst.get("count", 0)) + count
			to_member.set_bag_slot(i, dst)
			from_member.set_bag_slot(from_idx, {})
			party.rebuild_inventory_view()
			_emit_inventory_changed()
			_emit_party_changed()
			return {"ok": true, "message": "Gave %s to %s." % [item_name, String(to_member.display_name)]}

	var empty_idx: int = -1
	for j in range(to_member.bag.size()):
		if to_member.is_bag_slot_empty(j):
			empty_idx = j
			break
	if empty_idx < 0:
		return {"ok": false, "message": "%s has no free inventory slots." % String(to_member.display_name)}
	to_member.set_bag_slot(empty_idx, {"name": item_name, "count": count})
	from_member.set_bag_slot(from_idx, {})
	party.rebuild_inventory_view()
	_emit_inventory_changed()
	_emit_party_changed()
	return {"ok": true, "message": "Gave %s to %s." % [item_name, String(to_member.display_name)]}

func drop_bag_item(member_id: String, idx: int) -> Dictionary:
	member_id = String(member_id)
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	member.ensure_bag()
	if idx < 0 or idx >= member.bag.size():
		return {"ok": false, "message": "Invalid slot."}
	var slot: Dictionary = member.get_bag_slot(idx)
	var item_name: String = String(slot.get("name", ""))
	var count: int = int(slot.get("count", 0))
	if item_name.is_empty() or count <= 0:
		return {"ok": false, "message": "Empty slot."}
	if not String(slot.get("equipped_slot", "")).is_empty():
		return {"ok": false, "message": "Unequip before dropping."}
	member.set_bag_slot(idx, {})
	party.rebuild_inventory_view()
	_emit_inventory_changed()
	return {"ok": true, "message": "Dropped %s." % item_name}

func toggle_equip_bag_item(member_id: String, idx: int) -> Dictionary:
	member_id = String(member_id)
	var member: Variant = _find_member_by_id(member_id)
	if member == null:
		return {"ok": false, "message": "Party member not found."}
	member.ensure_bag()
	if idx < 0 or idx >= member.bag.size():
		return {"ok": false, "message": "Invalid slot."}
	var slot_data: Dictionary = member.get_bag_slot(idx)
	var item_name: String = String(slot_data.get("name", ""))
	if item_name.is_empty() or int(slot_data.get("count", 0)) <= 0:
		return {"ok": false, "message": "Empty slot."}
	var item: Dictionary = ItemCatalog.get_item(item_name)
	if item.is_empty():
		return {"ok": false, "message": "Unknown item."}
	var equip_slot: String = String(item.get("equip_slot", ""))
	if equip_slot.is_empty():
		var kind: String = String(item.get("kind", ""))
		if kind == "weapon" or kind == "armor" or kind == "accessory":
			equip_slot = kind
	if equip_slot != "weapon" and equip_slot != "armor" and equip_slot != "accessory":
		return {"ok": false, "message": "That item cannot be equipped."}
	var equipped_now: String = String(member.equipment.get(equip_slot, ""))
	if equipped_now == item_name and String(slot_data.get("equipped_slot", "")) == equip_slot:
		return unequip_slot(member_id, equip_slot)
	# Unequip previous, then equip this slot.
	if not equipped_now.is_empty():
		_clear_member_bag_equipped_marker(member, equip_slot)
	member.equipment[equip_slot] = item_name
	_clear_member_bag_equipped_marker(member, equip_slot)
	slot_data["equipped_slot"] = equip_slot
	member.set_bag_slot(idx, slot_data)
	_emit_party_changed()
	_emit_inventory_changed()
	return {"ok": true, "message": "%s equipped %s." % [String(member.display_name), item_name]}

func use_consumable_from_bag_slot(from_member_id: String, from_idx: int, target_member_id: String) -> Dictionary:
	from_member_id = String(from_member_id)
	target_member_id = String(target_member_id)
	var from_member: Variant = _find_member_by_id(from_member_id)
	var target: Variant = _find_member_by_id(target_member_id)
	if from_member == null or target == null:
		return {"ok": false, "message": "Party member not found."}
	from_member.ensure_bag()
	if from_idx < 0 or from_idx >= from_member.bag.size():
		return {"ok": false, "message": "Invalid item slot."}
	var slot_data: Dictionary = from_member.get_bag_slot(from_idx)
	var item_name: String = String(slot_data.get("name", ""))
	if item_name.is_empty() or int(slot_data.get("count", 0)) <= 0:
		return {"ok": false, "message": "Empty slot."}
	var item: Dictionary = ItemCatalog.get_item(item_name)
	if String(item.get("kind", "")) != "consumable":
		return {"ok": false, "message": "That item cannot be used."}
	var effect: Dictionary = item.get("use_effect", {})
	var effect_type: String = String(effect.get("type", ""))
	if effect_type == "heal_hp":
		var amount: int = max(1, int(effect.get("amount", 10)))
		var hp_before: int = int(target.hp)
		var hp_after: int = clamp(hp_before + amount, 0, int(target.max_hp))
		# Consume one from this slot.
		var left: int = int(slot_data.get("count", 0)) - 1
		if left <= 0:
			from_member.set_bag_slot(from_idx, {})
		else:
			slot_data["count"] = left
			from_member.set_bag_slot(from_idx, slot_data)
		target.hp = hp_after
		party.rebuild_inventory_view()
		_emit_party_changed()
		_emit_inventory_changed()
		if hp_after == hp_before:
			return {"ok": true, "message": "%s used %s, but nothing happened." % [String(target.display_name), item_name]}
		return {"ok": true, "message": "%s used %s (+%d HP)." % [String(target.display_name), item_name, hp_after - hp_before]}
	return {"ok": false, "message": "Unsupported item effect."}

func _find_member_bag_slot_with_item(member: Variant, item_name: String) -> int:
	if member == null or item_name.is_empty():
		return -1
	member.ensure_bag()
	for i in range(member.bag.size()):
		var slot_data: Dictionary = member.get_bag_slot(i)
		if String(slot_data.get("name", "")) == item_name and int(slot_data.get("count", 0)) > 0:
			return i
	return -1

func _clear_member_bag_equipped_marker(member: Variant, equip_slot: String) -> void:
	if member == null:
		return
	member.ensure_bag()
	for i in range(member.bag.size()):
		var slot_data: Dictionary = member.get_bag_slot(i)
		if String(slot_data.get("equipped_slot", "")) == equip_slot:
			slot_data.erase("equipped_slot")
			member.set_bag_slot(i, slot_data)

func save_to_path(path: String = SceneContracts.SAVE_SLOT_0) -> bool:
	var payload: Dictionary = _to_save_payload()
	var text: String = JSON.stringify(payload, "\t")
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	if _events and _events.has_signal("save_written"):
		_events.emit_signal("save_written", path)
	return true

func load_from_path(path: String = SceneContracts.SAVE_SLOT_0) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var data: Dictionary = parsed
	var version: int = int(data.get("version", 1))
	if version < 1 or version > SAVE_SCHEMA_VERSION:
		return false
	_from_save_payload(data, version)
	# UI pauses/accumulators are transient runtime state; do not restore from saves.
	_ingame_time_accum_seconds = 0.0
	_ui_pause_count = 0
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_time_advanced()
	_emit_location_changed()
	_emit_settings_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()
	if _events and _events.has_signal("save_loaded"):
		_events.emit_signal("save_loaded", path)
	return true

func _to_save_payload() -> Dictionary:
	var now_unix: int = int(Time.get_unix_time_from_system())
	return {
		"version": SAVE_SCHEMA_VERSION,
		"saved_unix": now_unix,
		"world_seed_hash": world_seed_hash,
		"world_width": world_width,
		"world_height": world_height,
		"world_biome_ids": _packed_int32_to_array(world_biome_ids),
		"world_height_raw": _packed_float32_to_array(world_height_raw),
		"world_temperature": _packed_float32_to_array(world_temperature),
		"world_moisture": _packed_float32_to_array(world_moisture),
		"world_land_mask": _packed_byte_to_array(world_land_mask),
		"world_beach_mask": _packed_byte_to_array(world_beach_mask),
		"world_cloud_cover": _packed_float32_to_array(world_cloud_cover),
		"world_wind_u": _packed_float32_to_array(world_wind_u),
		"world_wind_v": _packed_float32_to_array(world_wind_v),
		"location": location.duplicate(true),
		"party": party.to_dict(),
		"world_time": world_time.to_dict(),
		"settings_state": settings_state.to_dict(),
		"quest_state": quest_state.to_dict(),
		"world_flags": world_flags.to_dict(),
		"economy_state": economy_state.to_dict(),
		"politics_state": politics_state.to_dict(),
		"npc_world_state": npc_world_state.to_dict(),
		"civilization_state": civilization_state.to_dict(),
		"pending_battle": pending_battle.duplicate(true),
		"pending_poi": pending_poi.duplicate(true),
		"last_battle_result": last_battle_result.duplicate(true),
		"run_flags": run_flags.duplicate(true),
		"regional_cache_stats": regional_cache_stats.duplicate(true),
		"local_rest_context": local_rest_context.duplicate(true),
		"society_gpu_stats": society_gpu_stats.duplicate(true),
	}

func _from_save_payload(data: Dictionary, version: int = SAVE_SCHEMA_VERSION) -> void:
	world_seed_hash = int(data.get("world_seed_hash", 0))
	world_width = max(0, int(data.get("world_width", 0)))
	world_height = max(0, int(data.get("world_height", 0)))
	var size: int = max(0, world_width * world_height)
	world_biome_ids = _variant_to_packed_int32(data.get("world_biome_ids", []), size)
	world_height_raw = _variant_to_packed_float32(data.get("world_height_raw", []), size)
	world_temperature = _variant_to_packed_float32(data.get("world_temperature", []), size)
	world_moisture = _variant_to_packed_float32(data.get("world_moisture", []), size)
	world_land_mask = _variant_to_packed_byte(data.get("world_land_mask", []), size)
	world_beach_mask = _variant_to_packed_byte(data.get("world_beach_mask", []), size)
	world_cloud_cover = _variant_to_packed_float32(data.get("world_cloud_cover", []), size)
	world_wind_u = _variant_to_packed_float32(data.get("world_wind_u", []), size)
	world_wind_v = _variant_to_packed_float32(data.get("world_wind_v", []), size)
	location = data.get("location", {}).duplicate(true)
	_normalize_location()
	party = PartyStateModel.from_dict(data.get("party", {}))
	world_time = WorldTimeStateModel.from_dict(data.get("world_time", {}))
	if version >= 2:
		settings_state = SettingsStateModel.from_dict(data.get("settings_state", {}))
		quest_state = QuestStateModel.from_dict(data.get("quest_state", {}))
		world_flags = WorldFlagsStateModel.from_dict(data.get("world_flags", {}))
	else:
		settings_state = SettingsStateModel.new()
		settings_state.reset_defaults()
		quest_state = QuestStateModel.new()
		quest_state.reset_defaults()
		world_flags = WorldFlagsStateModel.new()
		world_flags.reset_defaults()
	if version >= 6:
		economy_state = EconomyStateModel.from_dict(data.get("economy_state", {}))
		politics_state = PoliticsStateModel.from_dict(data.get("politics_state", {}))
		npc_world_state = NpcWorldStateModel.from_dict(data.get("npc_world_state", {}))
		civilization_state = CivilizationStateModel.from_dict(data.get("civilization_state", {}))
		regional_cache_stats = data.get("regional_cache_stats", {}).duplicate(true)
		local_rest_context = data.get("local_rest_context", {}).duplicate(true)
		society_gpu_stats = data.get("society_gpu_stats", {}).duplicate(true)
	else:
		economy_state = EconomyStateModel.new()
		economy_state.reset_defaults()
		politics_state = PoliticsStateModel.new()
		politics_state.reset_defaults()
		npc_world_state = NpcWorldStateModel.new()
		npc_world_state.reset_defaults()
		civilization_state = CivilizationStateModel.new()
		civilization_state.reset_defaults()
		regional_cache_stats = {}
		local_rest_context = {}
		society_gpu_stats = {}
	pending_battle = data.get("pending_battle", {}).duplicate(true)
	pending_poi = data.get("pending_poi", {}).duplicate(true)
	last_battle_result = data.get("last_battle_result", {}).duplicate(true)
	run_flags = data.get("run_flags", {}).duplicate(true)
	_ensure_sim_state_defaults()
	_refresh_epoch_metadata()
	_ingame_time_accum_seconds = 0.0

func _emit_location_changed() -> void:
	if _events and _events.has_signal("location_changed"):
		_events.emit_signal("location_changed", get_location())

func _emit_party_changed() -> void:
	if _events and _events.has_signal("party_changed"):
		_events.emit_signal("party_changed", party.to_dict())

func _emit_inventory_changed() -> void:
	if _events and _events.has_signal("inventory_changed"):
		_events.emit_signal("inventory_changed", party.inventory.duplicate(true))

func _emit_time_advanced() -> void:
	if _events and _events.has_signal("time_advanced"):
		_events.emit_signal("time_advanced", world_time.format_compact())

func _emit_settings_changed() -> void:
	if _events and _events.has_signal("settings_changed"):
		_events.emit_signal("settings_changed", settings_state.to_dict())

func _emit_quests_changed() -> void:
	if _events and _events.has_signal("quests_changed"):
		_events.emit_signal("quests_changed", quest_state.to_dict())

func _emit_world_flags_changed() -> void:
	if _events and _events.has_signal("world_flags_changed"):
		_events.emit_signal("world_flags_changed", world_flags.to_dict())

func _normalize_location() -> void:
	location["scene"] = String(location.get("scene", SceneContracts.STATE_WORLD))
	location["world_x"] = int(location.get("world_x", 0))
	location["world_y"] = int(location.get("world_y", 0))
	location["local_x"] = int(location.get("local_x", 48))
	location["local_y"] = int(location.get("local_y", 48))
	location["biome_id"] = int(location.get("biome_id", -1))
	location["biome_name"] = String(location.get("biome_name", ""))

func _find_member_by_id(member_id: String) -> Variant:
	for member in party.members:
		if member == null:
			continue
		if String(member.member_id) == member_id:
			return member
	return null

func _seed_or_default() -> int:
	return 1 if int(world_seed_hash) == 0 else int(world_seed_hash)

func _ocean_fraction(biomes: PackedInt32Array) -> float:
	if biomes.is_empty():
		return 1.0
	var ocean_count: int = 0
	for b in biomes:
		var bid: int = int(b)
		if bid == 0 or bid == 1:
			ocean_count += 1
	return float(ocean_count) / float(biomes.size())

func _ensure_sim_state_defaults() -> void:
	if economy_state == null:
		economy_state = EconomyStateModel.new()
	if politics_state == null:
		politics_state = PoliticsStateModel.new()
	if npc_world_state == null:
		npc_world_state = NpcWorldStateModel.new()
	if civilization_state == null:
		civilization_state = CivilizationStateModel.new()
	if typeof(run_flags.get("society_seeded_tiles", {})) != TYPE_DICTIONARY:
		run_flags["society_seeded_tiles"] = {}
	if typeof(run_flags.get(_FACTION_REP_KEY, {})) != TYPE_DICTIONARY:
		run_flags[_FACTION_REP_KEY] = {}
	if typeof(regional_cache_stats) != TYPE_DICTIONARY:
		regional_cache_stats = {}
	if typeof(local_rest_context) != TYPE_DICTIONARY:
		local_rest_context = {}
	if typeof(society_gpu_stats) != TYPE_DICTIONARY:
		society_gpu_stats = {}
	if world_width <= 0 or world_height <= 0:
		return
	civilization_state.ensure_size(world_width, world_height)
	if civilization_state.emergence_abs_day < 0:
		civilization_state.emergence_abs_day = 365 + DeterministicRng.randi_range(
			_seed_or_default(),
			"civ_emergence_abs_day",
			0,
			4 * 365
		)
	var epoch_id: String = String(civilization_state.epoch_id)
	if epoch_id.is_empty():
		epoch_id = "prehistoric"
	var epoch_variant: String = String(civilization_state.epoch_variant)
	if epoch_variant.is_empty():
		epoch_variant = "stable"
	PoliticsSeeder.seed_full_map_if_needed(
		_seed_or_default(),
		world_width,
		world_height,
		politics_state,
		epoch_id,
		epoch_variant
	)
	if not bool(run_flags.get("_sim_defaults_seeded", false)):
		if economy_state.routes.is_empty() and economy_state.settlements.size() > 1:
			TradeRouteSeeder.rebuild(_seed_or_default(), world_width, world_height, economy_state, politics_state)
		NpcSeederFromSettlements.apply(_seed_or_default(), economy_state, politics_state, npc_world_state, epoch_id, epoch_variant)
		run_flags["_sim_defaults_seeded"] = true

func _refresh_epoch_metadata() -> void:
	if civilization_state == null:
		return
	var abs_day: int = world_time.abs_day_index() if world_time != null else 0
	var desired: Dictionary = EpochSystem.classify(
		bool(civilization_state.humans_emerged),
		float(civilization_state.tech_level),
		float(civilization_state.global_devastation)
	)
	var desired_id: String = String(desired.get("epoch_id", "prehistoric"))
	var desired_variant: String = String(desired.get("epoch_variant", "stable"))
	if String(civilization_state.epoch_id).is_empty():
		civilization_state.epoch_id = desired_id
		civilization_state.epoch_variant = desired_variant
		civilization_state.last_epoch_change_abs_day = abs_day
	civilization_state.epoch_progress = clamp(float(desired.get("epoch_progress", civilization_state.epoch_progress)), 0.0, 1.0)
	civilization_state.epoch_index = max(0, EpochSystem.epoch_index_for_id(String(civilization_state.epoch_id)))

	var cur_id: String = String(civilization_state.epoch_id)
	var cur_variant: String = String(civilization_state.epoch_variant)
	if cur_id == desired_id and cur_variant == desired_variant:
		civilization_state.epoch_target_id = ""
		civilization_state.epoch_target_variant = ""
		civilization_state.epoch_shift_due_abs_day = -1
	elif String(civilization_state.epoch_target_id) != desired_id \
		or String(civilization_state.epoch_target_variant) != desired_variant \
		or int(civilization_state.epoch_shift_due_abs_day) < abs_day:
		var serial: int = max(0, int(civilization_state.epoch_shift_serial)) + 1
		civilization_state.epoch_shift_serial = serial
		var delay_days: int = EpochSystem.roll_shift_delay_days(
			_seed_or_default(),
			cur_id,
			desired_id,
			cur_variant,
			desired_variant,
			abs_day,
			serial
		)
		civilization_state.epoch_target_id = desired_id
		civilization_state.epoch_target_variant = desired_variant
		civilization_state.epoch_shift_due_abs_day = abs_day + max(30, delay_days)

	var due_day: int = int(civilization_state.epoch_shift_due_abs_day)
	var target_id: String = String(civilization_state.epoch_target_id)
	if due_day >= 0 and abs_day >= due_day and not target_id.is_empty():
		civilization_state.epoch_id = target_id
		civilization_state.epoch_variant = String(civilization_state.epoch_target_variant)
		civilization_state.epoch_index = max(0, EpochSystem.epoch_index_for_id(String(civilization_state.epoch_id)))
		civilization_state.last_epoch_change_abs_day = abs_day
		civilization_state.epoch_target_id = ""
		civilization_state.epoch_target_variant = ""
		civilization_state.epoch_shift_due_abs_day = -1

	var epoch_info: Dictionary = {
		"epoch_id": String(civilization_state.epoch_id),
		"epoch_index": int(civilization_state.epoch_index),
		"epoch_progress": float(civilization_state.epoch_progress),
		"epoch_variant": String(civilization_state.epoch_variant),
		"government_hint": EpochSystem.government_hint(String(civilization_state.epoch_id), String(civilization_state.epoch_variant)),
		"social_rigidity": EpochSystem.social_rigidity_hint(String(civilization_state.epoch_id), String(civilization_state.epoch_variant)),
	}
	EpochSystem.apply_to_politics(politics_state, epoch_info)
	EpochSystem.apply_to_npcs(npc_world_state, epoch_info)

func _ensure_society_tile_records(world_x: int, world_y: int) -> void:
	if world_width <= 0 or world_height <= 0:
		return
	_ensure_sim_state_defaults()
	_refresh_epoch_metadata()
	world_x = posmod(int(world_x), max(1, world_width))
	world_y = clamp(int(world_y), 0, max(1, world_height) - 1)

	var seeded_v: Variant = run_flags.get("society_seeded_tiles", {})
	if typeof(seeded_v) != TYPE_DICTIONARY:
		seeded_v = {}
		run_flags["society_seeded_tiles"] = seeded_v
	var seeded: Dictionary = seeded_v as Dictionary
	var tile_key: String = "%d,%d" % [world_x, world_y]
	var already_seeded: bool = bool(seeded.get(tile_key, false))

	var prov_id: String = politics_state.province_id_at(world_x, world_y)
	if not politics_state.provinces.has(prov_id):
		var pxy: Vector2i = politics_state.province_coords_for_world_tile(world_x, world_y)
		var state_id_seed: String = politics_state.state_id_for_province_coords(pxy.x, pxy.y)
		if not politics_state.states.has(state_id_seed):
			politics_state.ensure_state(state_id_seed, {
				"name": "State %d,%d" % [pxy.x, pxy.y],
				"government": EpochSystem.government_hint(String(civilization_state.epoch_id), String(civilization_state.epoch_variant)),
				"government_auto": true,
				"epoch": String(civilization_state.epoch_id),
				"epoch_variant": String(civilization_state.epoch_variant),
				"social_rigidity": EpochSystem.social_rigidity_hint(String(civilization_state.epoch_id), String(civilization_state.epoch_variant)),
			})
		var unrest_seed: float = 0.08 + DeterministicRng.randf01(_seed_or_default(), "prov_unrest|%s" % prov_id) * 0.18
		politics_state.ensure_province(prov_id, {
			"px": int(pxy.x),
			"py": int(pxy.y),
			"owner_state_id": state_id_seed,
			"unrest": clamp(unrest_seed, 0.0, 1.0),
		})

	if already_seeded:
		return
	var before_settlements: int = economy_state.settlements.size()
	var biome_id: int = get_world_biome_id(world_x, world_y)
	SocietySeeder.seed_on_world_tile_visit(
		_seed_or_default(),
		world_x,
		world_y,
		biome_id,
		economy_state,
		politics_state,
		npc_world_state,
		String(civilization_state.epoch_id),
		String(civilization_state.epoch_variant)
	)

	var pv: Variant = politics_state.provinces.get(prov_id, {})
	var owner_state_id: String = ""
	if typeof(pv) == TYPE_DICTIONARY:
		owner_state_id = String((pv as Dictionary).get("owner_state_id", ""))
	var settle_id: String = EconomyStateModel.settlement_id_for_tile(world_x, world_y)
	var sv: Variant = economy_state.settlements.get(settle_id, {})
	if typeof(sv) == TYPE_DICTIONARY:
		var st: Dictionary = (sv as Dictionary).duplicate(true)
		if String(st.get("home_state_id", "")).is_empty():
			st["home_state_id"] = owner_state_id
		st["state_id"] = owner_state_id
		st["last_update_abs_day"] = int(world_time.abs_day_index()) if world_time != null else 0
		economy_state.settlements[settle_id] = st

	var settlement_count_changed: bool = economy_state.settlements.size() > before_settlements
	if settlement_count_changed or economy_state.routes.is_empty():
		TradeRouteSeeder.rebuild(_seed_or_default(), world_width, world_height, economy_state, politics_state)
	NpcSeederFromSettlements.apply(
		_seed_or_default(),
		economy_state,
		politics_state,
		npc_world_state,
		String(civilization_state.epoch_id),
		String(civilization_state.epoch_variant)
	)
	seeded[tile_key] = true
	run_flags["society_seeded_tiles"] = seeded

func _tick_background_society_days(day_before: int, day_after: int) -> void:
	day_before = int(day_before)
	day_after = int(day_after)
	if day_after <= day_before:
		return
	_ensure_sim_state_defaults()
	if world_width > 0 and world_height > 0:
		_ensure_society_tile_records(int(location.get("world_x", 0)), int(location.get("world_y", 0)))
	for d in range(day_before + 1, day_after + 1):
		var abs_day: int = max(0, int(d))
		_tick_civilization_day(abs_day)
		_refresh_epoch_metadata()
		_tick_economy_day(abs_day)
		_tick_politics_day(abs_day)
		_tick_npc_day(abs_day)

func _tick_civilization_day(abs_day: int) -> void:
	if civilization_state == null:
		return
	if civilization_state.emergence_abs_day < 0:
		civilization_state.emergence_abs_day = 365 + DeterministicRng.randi_range(
			_seed_or_default(),
			"civ_emergence_abs_day",
			0,
			4 * 365
		)
	if not civilization_state.humans_emerged and abs_day >= int(civilization_state.emergence_abs_day):
		civilization_state.humans_emerged = true
		if civilization_state.start_world_x < 0 or civilization_state.start_world_y < 0:
			var best_x: int = posmod(int(location.get("world_x", 0)), max(1, world_width))
			var best_y: int = clamp(int(location.get("world_y", 0)), 0, max(1, world_height) - 1)
			var best_score: float = -999.0
			var samples: int = 72
			for i in range(samples):
				var sx: int = DeterministicRng.randi_range(_seed_or_default(), "civ_start_x|%d" % i, 0, max(0, world_width - 1))
				var sy: int = DeterministicRng.randi_range(_seed_or_default(), "civ_start_y|%d" % i, 0, max(0, world_height - 1))
				var sb: int = get_world_biome_id(sx, sy)
				if sb <= 1:
					continue
				var score: float = _wildlife_proxy_for_biome(sb) + DeterministicRng.randf01(_seed_or_default(), "civ_start_tie|%d" % i) * 0.20
				if score > best_score:
					best_score = score
					best_x = sx
					best_y = sy
			civilization_state.start_world_x = best_x
			civilization_state.start_world_y = best_y
	if civilization_state.humans_emerged and world_width > 0 and world_height > 0:
		civilization_state.ensure_size(world_width, world_height)
		var sx0: int = posmod(max(0, int(civilization_state.start_world_x)), world_width)
		var sy0: int = clamp(max(0, int(civilization_state.start_world_y)), 0, world_height - 1)
		var idx0: int = sx0 + sy0 * world_width
		if idx0 >= 0 and idx0 < civilization_state.human_pop.size():
			if civilization_state.human_pop[idx0] < 24.0:
				civilization_state.human_pop[idx0] = 24.0
			var scarcity_mean: float = _average_settlement_scarcity()
			var growth: float = max(0.02, 0.45 * (1.0 - float(civilization_state.global_devastation) * 0.60) * (1.0 - scarcity_mean * 0.35))
			civilization_state.human_pop[idx0] = max(0.0, civilization_state.human_pop[idx0] + growth)
			var spread: float = growth * 0.15
			var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
			for d in dirs:
				var nx: int = posmod(sx0 + d.x, world_width)
				var ny: int = clamp(sy0 + d.y, 0, world_height - 1)
				var nidx: int = nx + ny * world_width
				if nidx < 0 or nidx >= civilization_state.human_pop.size():
					continue
				civilization_state.human_pop[nidx] = max(0.0, civilization_state.human_pop[nidx] + spread)

	var states_n: int = max(1, politics_state.states.size())
	var active_wars: int = _active_war_count()
	var war_pressure: float = clamp(float(active_wars) / float(states_n), 0.0, 1.0)
	var unrest_sum: float = 0.0
	var unrest_n: int = 0
	for pv2 in politics_state.provinces.values():
		if typeof(pv2) != TYPE_DICTIONARY:
			continue
		unrest_sum += clamp(float((pv2 as Dictionary).get("unrest", 0.0)), 0.0, 1.0)
		unrest_n += 1
	var unrest_mean: float = (unrest_sum / float(unrest_n)) if unrest_n > 0 else 0.0
	var scarcity_mean2: float = _average_settlement_scarcity()
	var target_dev: float = clamp(war_pressure * 0.74 + unrest_mean * 0.36 + scarcity_mean2 * 0.26, 0.0, 1.0)
	civilization_state.global_devastation = clamp(lerp(float(civilization_state.global_devastation), target_dev, 0.06), 0.0, 1.0)

	var tech_gain: float = 0.00010
	if civilization_state.humans_emerged:
		tech_gain += 0.00034 + float(economy_state.settlements.size()) * 0.00001
	var variant: String = String(civilization_state.epoch_variant)
	if variant == "stressed":
		tech_gain *= 0.72
	elif variant == "post_collapse":
		tech_gain *= 0.38
	tech_gain *= 1.0 - float(civilization_state.global_devastation) * 0.58
	var tech_loss: float = war_pressure * 0.00010 + max(0.0, float(civilization_state.global_devastation) - 0.60) * 0.00020
	civilization_state.tech_level = clamp(float(civilization_state.tech_level) + tech_gain - tech_loss, 0.0, 1.0)
	civilization_state.last_tick_abs_day = abs_day

func _average_settlement_scarcity() -> float:
	if economy_state == null or economy_state.settlements.is_empty():
		return 0.0
	var sum_sc: float = 0.0
	var n: int = 0
	for sv in economy_state.settlements.values():
		if typeof(sv) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = sv as Dictionary
		var scv: Variant = st.get("scarcity", {})
		if typeof(scv) != TYPE_DICTIONARY:
			continue
		var sc: Dictionary = scv as Dictionary
		var local_sum: float = 0.0
		var local_n: int = 0
		for k in CommodityCatalog.keys():
			var key: String = String(k)
			local_sum += clamp(float(sc.get(key, 0.0)), 0.0, 1.0)
			local_n += 1
		if local_n <= 0:
			continue
		sum_sc += local_sum / float(local_n)
		n += 1
	return (sum_sc / float(n)) if n > 0 else 0.0

func _active_war_count() -> int:
	if politics_state == null:
		return 0
	var n: int = 0
	for wv in politics_state.wars:
		if typeof(wv) != TYPE_DICTIONARY:
			continue
		var wd: Dictionary = wv as Dictionary
		var status: String = String(wd.get("status", "active")).to_lower()
		if status == "ended" or status == "broken" or status == "expired" or status == "void":
			continue
		n += 1
	return n

func _tick_economy_day(abs_day: int) -> void:
	if economy_state == null:
		return
	EconomySim.tick_day(_seed_or_default(), economy_state, abs_day)
	var em: Dictionary = EpochSystem.economy_multipliers(String(civilization_state.epoch_id), String(civilization_state.epoch_variant))
	var prod_scale: float = clamp(float(em.get("prod_scale", 1.0)), 0.25, 3.00)
	var cons_scale: float = clamp(float(em.get("cons_scale", 1.0)), 0.25, 3.00)
	var scarcity_scale: float = clamp(float(em.get("scarcity_scale", 1.0)), 0.35, 3.50)
	var price_speed: float = clamp(float(em.get("price_speed", 1.0)), 0.35, 3.00)
	for sid in economy_state.settlements.keys():
		var sv: Variant = economy_state.settlements.get(sid, {})
		if typeof(sv) != TYPE_DICTIONARY:
			continue
		var st: Dictionary = (sv as Dictionary).duplicate(true)
		var prod: Dictionary = st.get("production", {})
		var cons: Dictionary = st.get("consumption", {})
		var stock: Dictionary = st.get("stockpile", {})
		var scarcity: Dictionary = st.get("scarcity", {})
		var prices: Dictionary = st.get("prices", {})
		if typeof(prod) != TYPE_DICTIONARY:
			prod = {}
		if typeof(cons) != TYPE_DICTIONARY:
			cons = {}
		if typeof(stock) != TYPE_DICTIONARY:
			stock = {}
		if typeof(scarcity) != TYPE_DICTIONARY:
			scarcity = {}
		if typeof(prices) != TYPE_DICTIONARY:
			prices = {}

		var local_state_id: String = String(st.get("home_state_id", st.get("state_id", st.get("owner_state_id", ""))))
		var at_war: bool = _state_is_at_war(local_state_id)
		for kv in CommodityCatalog.keys():
			var key: String = String(kv)
			var p: float = max(0.0, float(prod.get(key, 0.0)) * prod_scale)
			var c: float = max(0.0, float(cons.get(key, 0.0)) * cons_scale)
			var v: float = max(0.0, float(stock.get(key, 0.0)) + (p - c))
			if at_war and (key == "food" or key == "fuel" or key == "medicine"):
				v = max(0.0, v * 0.98)
			stock[key] = v
			var days_cover: float = v / max(0.001, c)
			var sc: float = clamp((1.0 - days_cover / 7.0) * scarcity_scale, 0.0, 1.0)
			if at_war:
				sc = clamp(sc + 0.08, 0.0, 1.0)
			scarcity[key] = sc
			var base_price: float = CommodityCatalog.base_price(key)
			var prev_price: float = float(prices.get(key, base_price))
			var target: float = base_price * (1.0 + sc * 1.25)
			var alpha: float = clamp(0.20 * price_speed, 0.02, 0.85)
			prices[key] = clamp(lerp(prev_price, target, alpha), 0.05, 50.0)

		st["production"] = prod
		st["consumption"] = cons
		st["stockpile"] = stock
		st["scarcity"] = scarcity
		st["prices"] = prices
		st["last_update_abs_day"] = abs_day
		economy_state.settlements[sid] = st
	economy_state.last_tick_abs_day = abs_day

func _tick_politics_day(abs_day: int) -> void:
	if politics_state == null:
		return
	PoliticsSim.tick_day(_seed_or_default(), politics_state, abs_day)
	var pm: Dictionary = EpochSystem.politics_multipliers(String(civilization_state.epoch_id), String(civilization_state.epoch_variant))
	var unrest_mul: float = clamp(float(pm.get("unrest_mul", 1.0)), 0.40, 3.00)
	var unrest_decay_scale: float = clamp(float(pm.get("unrest_decay_scale", 1.0)), 0.10, 3.00)
	var unrest_drift: float = clamp(float(pm.get("unrest_drift", 0.0)), -0.01, 0.01)
	for pid in politics_state.provinces.keys():
		var pv: Variant = politics_state.provinces.get(pid, {})
		if typeof(pv) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = (pv as Dictionary).duplicate(true)
		var unrest: float = clamp(float(p.get("unrest", 0.0)), 0.0, 1.0)
		unrest = clamp(unrest * (1.0 - 0.0026 * unrest_decay_scale) + unrest_drift, 0.0, 1.0)
		var noise: float = DeterministicRng.randf01(_seed_or_default(), "pol_unrest|%s|%d" % [String(pid), abs_day]) - 0.5
		unrest += noise * 0.015 * unrest_mul
		var owner_state_id: String = String(p.get("owner_state_id", ""))
		if _state_is_at_war(owner_state_id):
			unrest += 0.0045 * unrest_mul
		p["unrest"] = clamp(unrest, 0.0, 1.0)
		p["last_update_abs_day"] = abs_day
		politics_state.provinces[pid] = p

	var changed: bool = PoliticsEventLayer.tick_batched(_seed_or_default(), abs_day - 1, abs_day, politics_state, pm)
	if changed and world_width > 0 and world_height > 0 and economy_state != null and economy_state.settlements.size() > 1:
		TradeRouteSeeder.rebuild(_seed_or_default(), world_width, world_height, economy_state, politics_state)
	politics_state.last_tick_abs_day = abs_day

func _tick_npc_day(abs_day: int) -> void:
	if npc_world_state == null:
		return
	NpcSim.tick_day(_seed_or_default(), npc_world_state, abs_day)
	var nm: Dictionary = EpochSystem.npc_multipliers(String(civilization_state.epoch_id), String(civilization_state.epoch_variant))
	var need_gain: float = clamp(float(nm.get("need_gain_scale", 1.0)), 0.40, 3.00)
	var remote_stress: float = clamp(float(nm.get("remote_stress_scale", 1.0)), 0.25, 3.00)
	for nid in npc_world_state.important_npcs.keys():
		var nv: Variant = npc_world_state.important_npcs.get(nid, {})
		if typeof(nv) != TYPE_DICTIONARY:
			continue
		var n: Dictionary = (nv as Dictionary).duplicate(true)
		var needs: Dictionary = n.get("needs", {})
		if typeof(needs) != TYPE_DICTIONARY:
			needs = {}
		needs["hunger"] = clamp(float(needs.get("hunger", 0.0)) + max(0.0, need_gain - 1.0) * 0.04, 0.0, 1.0)
		needs["thirst"] = clamp(float(needs.get("thirst", 0.0)) + max(0.0, need_gain - 1.0) * 0.05, 0.0, 1.0)
		var home_state_id: String = String(n.get("home_state_id", ""))
		var safety_push: float = max(0.0, remote_stress - 1.0) * 0.06
		if _state_is_at_war(home_state_id):
			safety_push += 0.08
		needs["safety"] = clamp(float(needs.get("safety", 0.0)) + safety_push, 0.0, 1.0)
		n["needs"] = needs
		n["last_update_abs_day"] = abs_day
		npc_world_state.important_npcs[nid] = n
	npc_world_state.last_tick_abs_day = abs_day

func _relation_pair_from_dict(d: Dictionary) -> PackedStringArray:
	var a: String = String(d.get("state_a_id", ""))
	var b: String = String(d.get("state_b_id", ""))
	if a.is_empty() or b.is_empty():
		a = String(d.get("a", ""))
		b = String(d.get("b", ""))
	if a.is_empty() or b.is_empty():
		a = String(d.get("state_a", ""))
		b = String(d.get("state_b", ""))
	if a.is_empty() or b.is_empty():
		a = String(d.get("party_a", ""))
		b = String(d.get("party_b", ""))
	if a.is_empty() or b.is_empty():
		var states_v: Variant = d.get("states", [])
		if typeof(states_v) == TYPE_ARRAY:
			var aa: Array = states_v as Array
			if aa.size() >= 2:
				a = String(aa[0])
				b = String(aa[1])
	return PackedStringArray([a, b])

func _state_is_at_war(state_id: String) -> bool:
	state_id = String(state_id)
	if state_id.is_empty() or politics_state == null:
		return false
	for wv in politics_state.wars:
		if typeof(wv) != TYPE_DICTIONARY:
			continue
		var wd: Dictionary = wv as Dictionary
		var status: String = String(wd.get("status", "active")).to_lower()
		if status == "ended" or status == "broken" or status == "expired" or status == "void":
			continue
		var p: PackedStringArray = _relation_pair_from_dict(wd)
		var a: String = String(p[0])
		var b: String = String(p[1])
		if a == state_id or b == state_id:
			return true
	return false

func _epoch_gameplay_multipliers() -> Dictionary:
	_ensure_sim_state_defaults()
	_refresh_epoch_metadata()
	return EpochSystem.gameplay_multipliers(
		String(civilization_state.epoch_id),
		String(civilization_state.epoch_variant)
	)

func _minute_of_day() -> int:
	if world_time == null:
		return 12 * 60
	return clamp(int(world_time.minute_of_day), 0, WorldTimeStateModel.MINUTES_PER_DAY - 1)

func _second_of_day() -> int:
	if world_time == null:
		return 12 * 60 * 60
	if "second_of_day" in world_time:
		return clamp(int(world_time.second_of_day), 0, WorldTimeStateModel.SECONDS_PER_DAY - 1)
	return clamp(int(world_time.minute_of_day) * 60, 0, WorldTimeStateModel.SECONDS_PER_DAY - 1)

func _day_of_year_0_364() -> int:
	if world_time == null:
		return 0
	if world_time.has_method("abs_day_index"):
		return posmod(int(world_time.abs_day_index()), 365)
	var day_idx: int = max(0, int(world_time.day) - 1)
	for m in range(1, int(world_time.month)):
		day_idx += WorldTimeStateModel.days_in_month(m)
	return clamp(day_idx, 0, 364)

func _tod_bucket_from_minute(minute: int) -> int:
	minute = posmod(int(minute), 24 * 60)
	if minute < 5 * 60 or minute >= 21 * 60:
		return _TOD_NIGHT
	if minute < 8 * 60:
		return _TOD_DAWN
	if minute < 18 * 60:
		return _TOD_DAY
	return _TOD_DUSK

func _tod_bucket_name(bucket: int) -> String:
	match int(bucket):
		_TOD_NIGHT:
			return "night"
		_TOD_DAWN:
			return "dawn"
		_TOD_DUSK:
			return "dusk"
		_:
			return "day"

func _season_bucket_from_day(day_of_year: int) -> int:
	day_of_year = posmod(int(day_of_year), 365)
	if day_of_year < 90:
		return _SEASON_SPRING
	if day_of_year < 181:
		return _SEASON_SUMMER
	if day_of_year < 273:
		return _SEASON_AUTUMN
	return _SEASON_WINTER

func _local_society_context(world_x: int, world_y: int, state_id: String = "") -> Dictionary:
	if world_width > 0 and world_height > 0:
		world_x = posmod(int(world_x), world_width)
		world_y = clamp(int(world_y), 0, world_height - 1)
	else:
		world_x = int(world_x)
		world_y = int(world_y)
	_ensure_society_tile_records(world_x, world_y)

	var prov_id: String = politics_state.province_id_at(world_x, world_y)
	var pv: Variant = politics_state.provinces.get(prov_id, {})
	var province_unrest: float = 0.0
	if typeof(pv) == TYPE_DICTIONARY:
		var p: Dictionary = pv as Dictionary
		province_unrest = clamp(float(p.get("unrest", 0.0)), 0.0, 1.0)
		if String(state_id).is_empty():
			state_id = String(p.get("owner_state_id", ""))

	var settle_id: String = EconomyStateModel.settlement_id_for_tile(world_x, world_y)
	var scarcity_pressure: float = 0.0
	var top_shortage: String = ""
	var top_shortage_value: float = 0.0
	var sv: Variant = economy_state.settlements.get(settle_id, {})
	if typeof(sv) == TYPE_DICTIONARY:
		var st: Dictionary = sv as Dictionary
		var scv: Variant = st.get("scarcity", {})
		if typeof(scv) == TYPE_DICTIONARY:
			var sc: Dictionary = scv as Dictionary
			var sum_sc: float = 0.0
			var n_sc: int = 0
			for kv in CommodityCatalog.keys():
				var key: String = String(kv)
				var v: float = clamp(float(sc.get(key, 0.0)), 0.0, 1.0)
				sum_sc += v
				n_sc += 1
				if v > top_shortage_value:
					top_shortage_value = v
					top_shortage = key
			if n_sc > 0:
				scarcity_pressure = sum_sc / float(n_sc)
	else:
		var biome_id: int = get_world_biome_id(world_x, world_y)
		scarcity_pressure = clamp(0.08 + (1.0 - _wildlife_proxy_for_biome(biome_id)) * 0.42, 0.0, 1.0)
		if scarcity_pressure > 0.25:
			top_shortage = "food"
			top_shortage_value = scarcity_pressure

	var states_at_war: bool = _state_is_at_war(state_id)
	var local_war_pressure: float = province_unrest * 0.45 + float(civilization_state.global_devastation) * 0.35
	if states_at_war:
		local_war_pressure += 0.35
	local_war_pressure = clamp(local_war_pressure, 0.0, 1.0)
	return {
		"world_x": world_x,
		"world_y": world_y,
		"province_id": prov_id,
		"state_id": String(state_id),
		"province_unrest": province_unrest,
		"scarcity_pressure": scarcity_pressure,
		"top_shortage": top_shortage,
		"top_shortage_value": top_shortage_value,
		"states_at_war": states_at_war,
		"local_war_pressure": local_war_pressure,
		"minute_of_day": _minute_of_day(),
		"day_of_year": _day_of_year_0_364(),
	}

func _winter_strength(day_of_year: int) -> float:
	day_of_year = posmod(int(day_of_year), 365)
	var season: int = _season_bucket_from_day(day_of_year)
	if season == _SEASON_WINTER:
		var t: float = clamp(float(day_of_year - 273) / 92.0, 0.0, 1.0)
		return clamp(sin(t * PI), 0.0, 1.0)
	if season == _SEASON_AUTUMN:
		var ta: float = clamp(float(day_of_year - 181) / 92.0, 0.0, 1.0)
		return clamp(ta * 0.35, 0.0, 0.35)
	if season == _SEASON_SPRING:
		var ts: float = clamp(1.0 - float(day_of_year) / 90.0, 0.0, 1.0)
		return clamp(ts * 0.30, 0.0, 0.30)
	return 0.0

func _seasonal_target_biome_id(from_biome: int, _world_x: int, _world_y: int) -> int:
	match int(from_biome):
		6:
			return 30
		7:
			return 29
		10:
			return 23
		11, 12, 13, 14, 15, 27:
			return 22
		16:
			return 34
		18, 19:
			return 24
		21:
			return 33
		3, 4, 28:
			return 5
		36:
			return 29
		37:
			return 30
		40:
			return 33
		41:
			return 34
		_:
			return int(from_biome)

func _lat_abs01(world_y: int) -> float:
	if world_height <= 1:
		return 0.0
	var y01: float = float(clamp(int(world_y), 0, world_height - 1)) / float(max(1, world_height - 1))
	return abs(y01 - 0.5) * 2.0

func _rest_cost_for_context() -> int:
	var rest_type: String = String(local_rest_context.get("rest_type", "")).to_lower()
	var base: int = 18
	if rest_type == "house":
		base = 14
	elif rest_type == "shop":
		base = 22
	elif rest_type == "inn":
		base = 26
	elif rest_type == "temple":
		base = 20
	elif rest_type == "faction_hall":
		base = 19
	var wx: int = int(local_rest_context.get("world_x", int(location.get("world_x", 0))))
	var wy: int = int(local_rest_context.get("world_y", int(location.get("world_y", 0))))
	var ec: Dictionary = _local_society_context(wx, wy, "")
	var scarcity: float = clamp(float(ec.get("scarcity_pressure", 0.0)), 0.0, 1.0)
	var war: float = clamp(float(ec.get("local_war_pressure", 0.0)), 0.0, 1.0)
	var mul: float = 1.0 + scarcity * 0.30 + war * 0.22
	if _tod_bucket_from_minute(_minute_of_day()) == _TOD_NIGHT:
		mul *= 1.06
	base = int(round(float(base) * mul))
	base += max(0, party.members.size() - 1) * 4
	return max(0, base)

func _resolve_hire_source(npc_profile: Dictionary, role: String) -> String:
	role = String(role).to_lower().strip_edges()
	var source: String = String(npc_profile.get("recruit_source", npc_profile.get("service_type", ""))).to_lower().strip_edges()
	if source == "faction" or source == "guild":
		source = "faction_hall"
	elif source == "town_hall":
		source = "faction_hall"
	if source.is_empty():
		var poi_type: String = String(npc_profile.get("poi_type", "")).to_lower().strip_edges()
		if poi_type == "house":
			source = "home"
	if source != "home" and source != "shop" and source != "inn" and source != "temple" and source != "faction_hall":
		match role:
			"innkeeper", "mercenary", "traveler":
				source = "inn"
			"priest", "acolyte":
				source = "temple"
			"faction_agent", "guard", "guild_agent":
				source = "faction_hall"
			"shopkeeper", "customer":
				source = "shop"
			_:
				source = "home"
	return source

func _hire_source_label(source: String) -> String:
	source = String(source).to_lower().strip_edges()
	match source:
		"shop":
			return "Shop"
		"inn":
			return "Inn"
		"temple":
			return "Temple"
		"faction_hall":
			return "Faction Hall"
		_:
			return "House"

func _faction_rep_store(create_if_missing: bool = true) -> Dictionary:
	var v: Variant = run_flags.get(_FACTION_REP_KEY, {})
	if typeof(v) == TYPE_DICTIONARY:
		return v as Dictionary
	if create_if_missing:
		run_flags[_FACTION_REP_KEY] = {}
		return run_flags[_FACTION_REP_KEY]
	return {}

func _faction_id_for_state(state_id: String) -> String:
	state_id = String(state_id).strip_edges()
	if state_id.is_empty():
		return ""
	return "faction|%s" % state_id.replace("|", "_")

func get_faction_reputation(faction_id: String) -> int:
	faction_id = String(faction_id).strip_edges()
	if faction_id.is_empty():
		return 0
	var store: Dictionary = _faction_rep_store(false)
	if store.is_empty():
		return 0
	return int(store.get(faction_id, 0))

func get_faction_rank(faction_id: String) -> int:
	return _faction_rank_for_rep(get_faction_reputation(faction_id))

func _faction_rank_for_rep(rep: int) -> int:
	rep = int(rep)
	if rep < 0:
		return -1
	if rep >= 170:
		return 4
	if rep >= 105:
		return 3
	if rep >= 55:
		return 2
	if rep >= 20:
		return 1
	return 0

func _faction_rank_label(rank: int) -> String:
	match int(rank):
		-1:
			return "Hostile"
		0:
			return "Outsider"
		1:
			return "Associate"
		2:
			return "Trusted"
		3:
			return "Veteran"
		_:
			return "Champion"

func _award_faction_reputation(faction_id: String, delta: int, _source: String = "") -> void:
	faction_id = String(faction_id).strip_edges()
	delta = int(delta)
	if faction_id.is_empty() or delta == 0:
		return
	var store: Dictionary = _faction_rep_store(true)
	var cur: int = int(store.get(faction_id, 0))
	var nxt: int = clamp(cur + delta, _FACTION_REP_MIN, _FACTION_REP_MAX)
	store[faction_id] = nxt
	run_flags[_FACTION_REP_KEY] = store

func _gear_tier_for_hire(avg_level: float) -> int:
	var tier: int = 1 + int(floor(max(0.0, float(avg_level) - 1.0) / 6.0))
	tier = max(tier, 1 + int(floor(float(max(0, int(civilization_state.epoch_index))) * 0.5)))
	return clamp(tier, 1, 4)

func _sort_items_by_tier(ids: Array[String]) -> Array[String]:
	var out: Array[String] = ids.duplicate()
	out.sort_custom(func(a: String, b: String) -> bool:
		var ia: Dictionary = ItemCatalog.get_item(a)
		var ib: Dictionary = ItemCatalog.get_item(b)
		var ta: int = int(ia.get("tier", 1))
		var tb: int = int(ib.get("tier", 1))
		if ta == tb:
			return a < b
		return ta < tb
	)
	return out

func _assign_hire_starting_loadout(member: PartyMemberModel, npc_id: String, recruit_source: String, tier: int) -> void:
	if member == null:
		return
	recruit_source = String(recruit_source).to_lower()
	tier = clamp(int(tier), 1, 4)
	var key_root: String = "hire_loadout|%s|%s|t=%d" % [String(npc_id), recruit_source, tier]
	var weapon_pool: Array[String] = _sort_items_by_tier(ItemCatalog.items_up_to_tier(tier, ["weapon"]))
	var armor_pool: Array[String] = _sort_items_by_tier(ItemCatalog.items_up_to_tier(tier, ["armor"]))
	var accessory_pool: Array[String] = _sort_items_by_tier(ItemCatalog.items_up_to_tier(tier, ["accessory"]))
	var consumable_pool: Array[String] = _sort_items_by_tier(ItemCatalog.items_up_to_tier(tier, ["consumable"]))

	if not weapon_pool.is_empty():
		var w_idx: int = DeterministicRng.randi_range(_seed_or_default(), key_root + "|weapon", 0, weapon_pool.size() - 1)
		_member_bag_add(member, weapon_pool[w_idx], 1, "weapon")
	if recruit_source != "inn" and not armor_pool.is_empty():
		var a_idx: int = DeterministicRng.randi_range(_seed_or_default(), key_root + "|armor", 0, armor_pool.size() - 1)
		_member_bag_add(member, armor_pool[a_idx], 1, "armor")
	var add_accessory: bool = (recruit_source == "temple" or recruit_source == "faction_hall")
	if not add_accessory:
		add_accessory = DeterministicRng.randf01(_seed_or_default(), key_root + "|acc_roll") < 0.36
	if add_accessory and not accessory_pool.is_empty():
		var ac_idx: int = DeterministicRng.randi_range(_seed_or_default(), key_root + "|accessory", 0, accessory_pool.size() - 1)
		_member_bag_add(member, accessory_pool[ac_idx], 1, "accessory")
	if not consumable_pool.is_empty():
		var c_idx: int = DeterministicRng.randi_range(_seed_or_default(), key_root + "|cons", 0, consumable_pool.size() - 1)
		var c_name: String = consumable_pool[c_idx]
		var ci: Dictionary = ItemCatalog.get_item(c_name)
		var c_count: int = 1
		if bool(ci.get("stackable", true)):
			var item_tier: int = int(ci.get("tier", 1))
			var tier_penalty: int = int(floor(float(item_tier) / 2.0))
			var extra_max: int = max(0, 2 - tier_penalty)
			c_count = 1 + DeterministicRng.randi_range(_seed_or_default(), key_root + "|cons_count", 0, extra_max)
		_member_bag_add(member, c_name, c_count)

func _member_bag_add(member: PartyMemberModel, item_name: String, count: int = 1, equip_slot: String = "") -> bool:
	if member == null:
		return false
	item_name = String(item_name).strip_edges()
	count = max(1, int(count))
	if item_name.is_empty() or not ItemCatalog.has_item(item_name):
		return false
	member.ensure_bag()
	var item: Dictionary = ItemCatalog.get_item(item_name)
	var stackable: bool = bool(item.get("stackable", true))
	var eq_slot: String = String(equip_slot).to_lower().strip_edges()
	if stackable:
		for i in range(member.bag.size()):
			var slot_existing: Dictionary = member.get_bag_slot(i)
			if String(slot_existing.get("name", "")) != item_name:
				continue
			if not String(slot_existing.get("equipped_slot", "")).is_empty():
				continue
			slot_existing["count"] = int(slot_existing.get("count", 0)) + count
			member.set_bag_slot(i, slot_existing)
			return true
	for j in range(member.bag.size()):
		if not member.is_bag_slot_empty(j):
			continue
		var slot_new: Dictionary = {"name": item_name, "count": count if stackable else 1}
		if eq_slot == "weapon" or eq_slot == "armor" or eq_slot == "accessory":
			slot_new["equipped_slot"] = eq_slot
			member.equipment[eq_slot] = item_name
		member.set_bag_slot(j, slot_new)
		return true
	return false

func _next_hire_member_id(npc_id: String) -> String:
	var base_id: String = String(npc_id).strip_edges()
	if base_id.is_empty():
		base_id = "npc"
	base_id = base_id.replace("|", "_")
	base_id = "hire|%s" % base_id
	var out: String = base_id
	var serial: int = 1
	while _find_member_by_id(out) != null:
		out = "%s|%d" % [base_id, serial]
		serial += 1
	return out

func _hire_display_name(npc_id: String, kind: int) -> String:
	var male: Array[String] = ["Alden", "Bram", "Corin", "Darin", "Eryk", "Fenn", "Galen", "Harlan", "Ivor", "Joren"]
	var female: Array[String] = ["Ayla", "Brina", "Cora", "Daria", "Elin", "Fara", "Gwen", "Hesta", "Ilia", "Juna"]
	var neutral: Array[String] = ["Ash", "Bryn", "Ciel", "Dale", "Ember", "Flint", "Gray", "Harbor", "Indigo", "Jade"]
	var surnames: Array[String] = ["Brook", "Stone", "Vale", "Reed", "Moor", "Flint", "Wren", "Dawn", "Ash", "Rowe"]
	var key_root: String = "hire_name|%s|k=%d" % [String(npc_id), int(kind)]
	var given_pool: Array[String] = neutral
	if int(kind) == 1:
		given_pool = male
	elif int(kind) == 2:
		given_pool = female
	var gidx: int = DeterministicRng.randi_range(_seed_or_default(), key_root + "|given", 0, given_pool.size() - 1)
	var sidx: int = DeterministicRng.randi_range(_seed_or_default(), key_root + "|sur", 0, surnames.size() - 1)
	return "%s %s" % [given_pool[gidx], surnames[sidx]]

func _party_average_level() -> float:
	if party == null or party.members.is_empty():
		return 1.0
	var sum_lv: float = 0.0
	var n: int = 0
	for m in party.members:
		if m == null:
			continue
		sum_lv += max(1.0, float(m.level))
		n += 1
	return (sum_lv / float(n)) if n > 0 else 1.0

func _wildlife_proxy_for_biome(biome_id: int) -> float:
	biome_id = int(biome_id)
	if biome_id == 0 or biome_id == 1:
		return 0.04
	match biome_id:
		3, 4, 5, 28:
			return 0.20
		10, 11, 12, 13, 14, 15, 22, 23:
			return 0.86
		18, 19, 24:
			return 0.34
		6, 7, 16, 20, 21, 29, 30, 33, 34:
			return 0.68
		_:
			return 0.56

func _settlement_population_proxy(world_x: int, world_y: int) -> int:
	world_x = posmod(int(world_x), max(1, world_width))
	world_y = clamp(int(world_y), 0, max(1, world_height) - 1)
	var settle_id: String = EconomyStateModel.settlement_id_for_tile(world_x, world_y)
	var sv: Variant = economy_state.settlements.get(settle_id, {})
	if typeof(sv) == TYPE_DICTIONARY:
		return max(0, int((sv as Dictionary).get("population", 0)))
	if civilization_state != null and civilization_state.human_pop.size() == world_width * world_height:
		var idx: int = world_x + world_y * world_width
		if idx >= 0 and idx < civilization_state.human_pop.size():
			var hp: float = float(civilization_state.human_pop[idx])
			if hp > 0.0:
				return max(0, int(round(hp)))
	var biome_id: int = get_world_biome_id(world_x, world_y)
	var base: int = int(round(_wildlife_proxy_for_biome(biome_id) * 120.0))
	var jitter: int = DeterministicRng.randi_range(_seed_or_default(), "pop_proxy|%d|%d" % [world_x, world_y], 0, 40)
	return max(0, base + jitter)

func _apply_reward_context_multipliers(rewards_data: Variant, encounter_ctx: Dictionary = {}) -> Dictionary:
	if typeof(rewards_data) != TYPE_DICTIONARY:
		return {}
	var out: Dictionary = (rewards_data as Dictionary).duplicate(true)
	if bool(encounter_ctx.get("rewards_scaled", false)):
		return out
	var gp: Dictionary = _epoch_gameplay_multipliers()
	var exp_mul: float = clamp(float(encounter_ctx.get("reward_exp_mul", gp.get("reward_exp_mul", 1.0))), 0.25, 4.00)
	var gold_mul: float = clamp(float(encounter_ctx.get("reward_gold_mul", gp.get("reward_gold_mul", 1.0))), 0.25, 4.00)
	out["exp"] = max(0, int(round(float(out.get("exp", 0)) * exp_mul)))
	out["gold"] = max(0, int(round(float(out.get("gold", 0)) * gold_mul)))
	return out

func _packed_int32_to_array(src: PackedInt32Array) -> Array:
	var out: Array = []
	out.resize(src.size())
	for i in range(src.size()):
		out[i] = int(src[i])
	return out

func _packed_float32_to_array(src: PackedFloat32Array) -> Array:
	var out: Array = []
	out.resize(src.size())
	for i in range(src.size()):
		out[i] = float(src[i])
	return out

func _packed_byte_to_array(src: PackedByteArray) -> Array:
	var out: Array = []
	out.resize(src.size())
	for i in range(src.size()):
		out[i] = int(src[i])
	return out

func _variant_to_packed_int32(v: Variant, expected_size: int = -1) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if v is PackedInt32Array:
		out = (v as PackedInt32Array).duplicate()
	elif typeof(v) == TYPE_ARRAY:
		var a: Array = v as Array
		out.resize(a.size())
		for i in range(a.size()):
			out[i] = int(a[i])
	if expected_size >= 0 and out.size() != expected_size:
		return PackedInt32Array()
	return out

func _variant_to_packed_float32(v: Variant, expected_size: int = -1) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if v is PackedFloat32Array:
		out = (v as PackedFloat32Array).duplicate()
	elif typeof(v) == TYPE_ARRAY:
		var a: Array = v as Array
		out.resize(a.size())
		for i in range(a.size()):
			out[i] = float(a[i])
	if expected_size >= 0 and out.size() != expected_size:
		return PackedFloat32Array()
	return out

func _variant_to_packed_byte(v: Variant, expected_size: int = -1) -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	if v is PackedByteArray:
		out = (v as PackedByteArray).duplicate()
	elif typeof(v) == TYPE_ARRAY:
		var a: Array = v as Array
		out.resize(a.size())
		for i in range(a.size()):
			out[i] = int(clamp(int(a[i]), 0, 255))
	if expected_size >= 0 and out.size() != expected_size:
		return PackedByteArray()
	return out
