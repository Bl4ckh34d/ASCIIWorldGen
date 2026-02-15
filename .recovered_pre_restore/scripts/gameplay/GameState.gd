extends Node
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const SceneContracts = preload("res://scripts/gameplay/SceneContracts.gd")
const EncounterRegistry = preload("res://scripts/gameplay/EncounterRegistry.gd")
const PartyStateModel = preload("res://scripts/gameplay/models/PartyState.gd")
const WorldTimeStateModel = preload("res://scripts/gameplay/models/WorldTimeState.gd")
const SettingsStateModel = preload("res://scripts/gameplay/models/SettingsState.gd")
const QuestStateModel = preload("res://scripts/gameplay/models/QuestState.gd")
const WorldFlagsStateModel = preload("res://scripts/gameplay/models/WorldFlagsState.gd")
const NpcDialogueService = preload("res://scripts/gameplay/dialogue/NpcDialogueService.gd")
const EconomyStateModel = preload("res://scripts/gameplay/models/EconomyState.gd")
const PoliticsStateModel = preload("res://scripts/gameplay/models/PoliticsState.gd")
const NpcWorldStateModel = preload("res://scripts/gameplay/models/NpcWorldState.gd")
const WildlifeStateModel = preload("res://scripts/gameplay/models/WildlifeState.gd")
const CivilizationStateModel = preload("res://scripts/gameplay/models/CivilizationState.gd")
const SettlementStateModel = preload("res://scripts/gameplay/models/SettlementState.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")

const SocietyGpuBridge = preload("res://scripts/gameplay/sim/SocietyGpuBridge.gd")
const SocietySeeder = preload("res://scripts/gameplay/sim/SocietySeeder.gd")
const PoliticsSeeder = preload("res://scripts/gameplay/sim/PoliticsSeeder.gd")
const PoliticsFromSettlements = preload("res://scripts/gameplay/sim/PoliticsFromSettlements.gd")
const PoliticsEventLayer = preload("res://scripts/gameplay/sim/PoliticsEventLayer.gd")
const EpochSystem = preload("res://scripts/gameplay/sim/EpochSystem.gd")
const EconomyFromSettlements = preload("res://scripts/gameplay/sim/EconomyFromSettlements.gd")
const TradeRouteSeeder = preload("res://scripts/gameplay/sim/TradeRouteSeeder.gd")
const NpcSeederFromSettlements = preload("res://scripts/gameplay/sim/NpcSeederFromSettlements.gd")
const DevHudOverlay = preload("res://scripts/gameplay/ui/DevHudOverlay.gd")

const SAVE_SCHEMA_VERSION: int = 6
const REGIONAL_BIOME_TRANSITION_KEY: String = "regional_biome_transition_tiles"
const REGIONAL_BIOME_TRANSITION_MIN_DAYS: int = 2
const REGIONAL_BIOME_TRANSITION_MAX_DAYS: int = 6
const WORLD_SNAPSHOT_DEGENERATE_OCEAN_THRESHOLD: float = 0.998
const WORLD_SNAPSHOT_REPAIRED_FLAG_KEY: String = "world_snapshot_repaired"

var party: PartyStateModel = PartyStateModel.new()
var world_time: WorldTimeStateModel = WorldTimeStateModel.new()
var settings_state: SettingsStateModel = SettingsStateModel.new()
var quest_state: QuestStateModel = QuestStateModel.new()
var world_flags: WorldFlagsStateModel = WorldFlagsStateModel.new()
var economy_state: EconomyStateModel = EconomyStateModel.new()
var politics_state: PoliticsStateModel = PoliticsStateModel.new()
var npc_world_state: NpcWorldStateModel = NpcWorldStateModel.new()
var wildlife_state: WildlifeStateModel = WildlifeStateModel.new()
var civilization_state: CivilizationStateModel = CivilizationStateModel.new()
var settlement_state: SettlementStateModel = SettlementStateModel.new()

var world_seed_hash: int = 0
var world_width: int = 0
var world_height: int = 0
var world_biome_ids: PackedInt32Array = PackedInt32Array()

var location: Dictionary = {
	"scene": SceneContracts.STATE_WORLD,
	"world_x": 0,
	"world_y": 0,
	"local_x": 48,
	"local_y": 48,
	"biome_id": -1,
	"biome_name": "",
	# Derived field: political unit id for the current tile (state/kingdom/empire).
	"political_state_id": "",
}

var pending_battle: Dictionary = {}
var pending_poi: Dictionary = {}
var last_battle_result: Dictionary = {}
var run_flags: Dictionary = {}

# In-game realtime clock (separate from world-map simulation TimeSystem).
# We advance `world_time` only while exploring (regional/local), at 1:1 by default.
# 1 real second == 1 in-game second.
const MAX_REALTIME_DELTA_SECONDS: float = 0.25
var _ingame_time_accum_seconds: float = 0.0
var _ui_pause_count: int = 0

var _events: Node = null
var _dev_hud: CanvasLayer = null
var _society_gpu: Object = null
var _npc_dialogue: Object = NpcDialogueService.new()
var _regional_cache_stats: Dictionary = {}

func _ready() -> void:
	_events = get_node_or_null("/root/GameEvents")
	_wire_event_pauses()
	_install_dev_hud()
	_install_society_gpu()
	if party.members.is_empty():
		party.reset_default_party()
	if world_time.year <= 0:
		world_time.reset_defaults()
	if quest_state.quests.is_empty():
		quest_state.ensure_default_quests()
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_time_advanced()
	_emit_settings_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()
	set_process(true)

func _exit_tree() -> void:
	if _society_gpu != null and "cleanup" in _society_gpu:
		_society_gpu.cleanup()
	_society_gpu = null
	if _dev_hud != null and is_instance_valid(_dev_hud):
		_dev_hud.queue_free()
	_dev_hud = null

func _install_dev_hud() -> void:
	if _dev_hud != null:
		return
	_dev_hud = DevHudOverlay.new()
	add_child(_dev_hud)

func _install_society_gpu() -> void:
	if _society_gpu != null:
		return
	_society_gpu = SocietyGpuBridge.new()

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
	wildlife_state.reset_defaults()
	civilization_state.reset_defaults()
	settlement_state.reset_defaults()
	world_seed_hash = 0
	world_width = 0
	world_height = 0
	world_biome_ids = PackedInt32Array()
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
	_regional_cache_stats.clear()
	_ingame_time_accum_seconds = 0.0
	_ui_pause_count = 0
	_emit_party_changed()
	_emit_inventory_changed()
	_emit_time_advanced()
	_emit_location_changed()
	_emit_settings_changed()
	_emit_quests_changed()
	_emit_world_flags_changed()

func initialize_world_snapshot(width: int, height: int, seed_hash: int, biome_ids: PackedInt32Array) -> void:
	var prev_w: int = int(world_width)
	var prev_h: int = int(world_height)
	var prev_seed: int = int(world_seed_hash)
	var prev_biomes: PackedInt32Array = world_biome_ids.duplicate()
	world_width = max(1, width)
	world_height = max(1, height)
	world_seed_hash = seed_hash
	world_biome_ids = biome_ids.duplicate()
	_register_regional_biome_transitions(prev_w, prev_h, prev_seed, prev_biomes, world_width, world_height, world_seed_hash, world_biome_ids)
	# Ensure society fields that depend on world dimensions are sized.
	if wildlife_state != null:
		wildlife_state.ensure_size(world_width, world_height, 0.65)
		_seed_initial_wildlife_from_biomes()
	if civilization_state != null:
		civilization_state.ensure_size(world_width, world_height)
		_seed_civ_start_tile_from_biomes_if_needed()
		_seed_civ_emergence_schedule_if_needed()
		_refresh_epoch_state(_current_abs_day_index(), false)
	# Seed coarse political map deterministically so "local political unit" is always defined.
	PoliticsSeeder.seed_full_map_if_needed(
		world_seed_hash,
		world_width,
		world_height,
		politics_state,
		String(civilization_state.epoch_id) if civilization_state != null else "prehistoric",
		String(civilization_state.epoch_variant) if civilization_state != null else "stable"
	)
	location["political_state_id"] = _compute_political_state_id(int(location.get("world_x", 0)), int(location.get("world_y", 0)))
	if _society_gpu != null and "mark_dirty" in _society_gpu:
		_society_gpu.mark_dirty()
	if _events and _events.has_signal("world_snapshot_updated"):
		_events.emit_signal("world_snapshot_updated", world_width, world_height, world_seed_hash)

func _seed_initial_wildlife_from_biomes() -> void:
	# v0: infer a baseline wildlife density from biome id (cheap and deterministic).
	# This will later be driven by climate fields + seasonal effects.
	if wildlife_state == null:
		return
	var w: int = int(world_width)
	var h: int = int(world_height)
	var size: int = w * h
	if size <= 0 or world_biome_ids.size() != size:
		return
	wildlife_state.ensure_size(w, h, 0.65)
	for i in range(size):
		var bid: int = int(world_biome_ids[i])
		var v: float = 0.60
		if bid == 0 or bid == 1:
			v = 0.05
		# deserts
		elif bid == 3 or bid == 4 or bid == 5 or bid == 28:
			v = 0.18
		# mountains-ish
		elif bid == 18 or bid == 19 or bid == 24 or bid == 34 or bid == 41:
			v = 0.28
		# swamp
		elif bid == 17:
			v = 0.70
		# forests-ish
		elif bid == 11 or bid == 12 or bid == 13 or bid == 14 or bid == 15 or bid == 22 or bid == 27:
			v = 0.78
		# grassland/steppe/savanna etc
		elif bid == 7 or bid == 16 or bid == 10 or bid == 23:
			v = 0.62
		wildlife_state.density[i] = v

func _seed_civ_start_tile_from_biomes_if_needed() -> void:
	if civilization_state == null:
		return
	var w: int = int(world_width)
	var h: int = int(world_height)
	var size: int = w * h
	if size <= 0 or world_biome_ids.size() != size:
		return
	var best_score: float = -999.0
	var best_x: int = -1
	var best_y: int = -1
	for y in range(h):
		for x in range(w):
			var idx: int = x + y * w
			var bid: int = int(world_biome_ids[idx])
			# Hard constraints: no ocean/ice.
			if bid == 0 or bid == 1:
				continue
			# Score from biome family (fully inferred).
			var s: float = 0.0
			# Prefer temperate-ish fertile biomes for first emergence.
			if bid == 7: # grassland (project id)
				s += 3.0
			elif bid == 10 or bid == 23: # steppe-ish
				s += 2.0
			elif bid == 11 or bid == 12 or bid == 13 or bid == 14 or bid == 15 or bid == 22 or bid == 27: # forests
				s += 2.6
			elif bid == 17: # swamp (survivable but harsher)
				s += 1.2
			elif bid == 3 or bid == 4 or bid == 5 or bid == 28: # deserts
				s -= 2.0
			elif bid == 18 or bid == 19 or bid == 24 or bid == 34 or bid == 41: # mountains
				s -= 0.8
			# Lat bias: avoid extreme poles if possible (but keep it soft; deserts can be cold-temperate too).
			var lat_abs: float = 0.0
			if h > 1:
				lat_abs = abs(0.5 - (float(y) / float(h - 1))) * 2.0
			s += (1.0 - lat_abs) * 0.8
			# Deterministic tie-breaker noise from seed.
			var n: float = float(abs(int(("civ_start|" + str(world_seed_hash) + "|%d,%d" % [x, y]).hash()) % 10000)) / 10000.0
			s += (n - 0.5) * 0.05
			if s > best_score:
				best_score = s
				best_x = x
				best_y = y
	if best_x < 0 or best_y < 0:
		# Deterministic fallback if no suitable tile passed filters.
		best_x = abs(int(("civ_start_x|" + str(world_seed_hash)).hash())) % max(1, w)
		best_y = abs(int(("civ_start_y|" + str(world_seed_hash)).hash())) % max(1, h)
	civilization_state.start_world_x = best_x
	civilization_state.start_world_y = best_y

func _seed_civ_emergence_schedule_if_needed() -> void:
	if civilization_state == null:
		return
	# User decision: emergence delay is always deterministic random in [1..5] years.
	var base_abs_day: int = _current_abs_day_index()
	var min_offset: int = 365
	var max_offset: int = 365 * 5
	var cur: int = int(civilization_state.emergence_abs_day)
	if cur >= base_abs_day + min_offset and cur <= base_abs_day + max_offset:
		return
	var span: int = max_offset - min_offset + 1
	var seed: int = int(world_seed_hash)
	if seed == 0:
		seed = 1
	var n: int = abs(int(("civ_emerge|" + str(seed)).hash())) % span
	civilization_state.emergence_abs_day = base_abs_day + min_offset + n

func has_world_snapshot() -> bool:
	return world_width > 0 and world_height > 0 and world_biome_ids.size() == world_width * world_height

func ensure_world_snapshot_integrity() -> bool:
	# Runtime self-heal for stale/degenerated snapshots (e.g. all-ocean array with land gameplay location).
	if not has_world_snapshot():
		return false
	var size: int = world_width * world_height
	if size <= 0 or world_biome_ids.size() != size:
		return false
	var ocean_count: int = 0
	for bid_v in world_biome_ids:
		var bid: int = int(bid_v)
		if bid == 0 or bid == 1:
			ocean_count += 1
	var ocean_frac: float = float(ocean_count) / float(max(1, size))
	if ocean_frac < WORLD_SNAPSHOT_DEGENERATE_OCEAN_THRESHOLD:
		return false
	var loc_biome: int = int(location.get("biome_id", -1))
	var anchor_biome: int = loc_biome
	if anchor_biome <= 1:
		# If location biome is stale too, still recover a usable macro map.
		anchor_biome = 7
	var loc_x: int = posmod(int(location.get("world_x", 0)), max(1, world_width))
	var loc_y: int = clamp(int(location.get("world_y", 0)), 0, max(1, world_height) - 1)
	var repaired: PackedInt32Array = _build_repaired_world_biomes(loc_x, loc_y, anchor_biome)
	if repaired.size() != size:
		return false
	world_biome_ids = repaired
	run_flags[WORLD_SNAPSHOT_REPAIRED_FLAG_KEY] = true
	_ensure_regional_transition_store().clear()
	location["political_state_id"] = _compute_political_state_id(loc_x, loc_y)
	if _society_gpu != null and "mark_dirty" in _society_gpu:
		_society_gpu.mark_dirty()
	if _events and _events.has_signal("world_snapshot_updated"):
		_events.emit_signal("world_snapshot_updated", world_width, world_height, world_seed_hash)
	return true

func _build_repaired_world_biomes(anchor_x: int, anchor_y: int, anchor_biome: int) -> PackedInt32Array:
	var w: int = max(1, world_width)
	var h: int = max(1, world_height)
	var size: int = w * h
	var out := PackedInt32Array()
	out.resize(size)
	out.fill(0)
	var seed: int = world_seed_hash if world_seed_hash != 0 else 1
	var continent := FastNoiseLite.new()
	continent.seed = seed ^ 0x4A5B6C
	continent.noise_type = FastNoiseLite.TYPE_SIMPLEX
	continent.frequency = 0.020
	continent.fractal_type = FastNoiseLite.FRACTAL_FBM
	continent.fractal_octaves = 4
	continent.fractal_lacunarity = 2.1
	continent.fractal_gain = 0.52
	var moist_noise := FastNoiseLite.new()
	moist_noise.seed = seed ^ 0x9182F1
	moist_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	moist_noise.frequency = 0.038
	moist_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	moist_noise.fractal_octaves = 3
	moist_noise.fractal_lacunarity = 2.0
	moist_noise.fractal_gain = 0.56
	var rugged_noise := FastNoiseLite.new()
	rugged_noise.seed = seed ^ 0x3BD944
	rugged_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	rugged_noise.frequency = 0.055
	for y in range(h):
		var lat_abs: float = 0.0
		if h > 1:
			lat_abs = abs(0.5 - (float(y) / float(h - 1))) * 2.0
		for x in range(w):
			var idx: int = x + y * w
			var c: float = continent.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var m: float = moist_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var r: float = rugged_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var sea_level_bias: float = 0.47 + lat_abs * 0.05
			var is_land: bool = c > sea_level_bias
			if not is_land:
				out[idx] = 1 if lat_abs > 0.90 else 0
				continue
			# Lightweight macro classification for repaired snapshot.
			var biome_id: int = 7 # grassland baseline
			if lat_abs > 0.84:
				biome_id = 1
			elif r > 0.82:
				biome_id = 19 # mountains
			elif m < 0.22:
				biome_id = 3 # desert
			elif m > 0.70:
				biome_id = 12 # temperate forest
			elif m > 0.58:
				biome_id = 11 # boreal/woodland-ish
			elif m < 0.32:
				biome_id = 10 # steppe-ish
			out[idx] = biome_id
	# Anchor area to the known current macro biome so local/regional context stays coherent.
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var ax: int = posmod(anchor_x + ox, w)
			var ay: int = clamp(anchor_y + oy, 0, h - 1)
			out[ax + ay * w] = max(2, anchor_biome)
	return out

func get_world_biome_id(x: int, y: int) -> int:
	if not has_world_snapshot():
		return int(location.get("biome_id", -1))
	var wx: int = posmod(x, world_width)
	var wy: int = clamp(y, 0, world_height - 1)
	var i: int = wx + wy * world_width
	if i < 0 or i >= world_biome_ids.size():
		return int(location.get("biome_id", -1))
	return world_biome_ids[i]

func _regional_transition_key(world_x: int, world_y: int) -> String:
	return "%d,%d" % [int(world_x), int(world_y)]

func _regional_transition_duration_days(world_x: int, world_y: int, to_biome: int) -> int:
	var span: int = REGIONAL_BIOME_TRANSITION_MAX_DAYS - REGIONAL_BIOME_TRANSITION_MIN_DAYS + 1
	span = max(1, span)
	var key: String = "reg_biome_dur|%d|%d|%d|%d" % [int(world_seed_hash), int(world_x), int(world_y), int(to_biome)]
	var n: int = abs(int(key.hash())) % span
	return REGIONAL_BIOME_TRANSITION_MIN_DAYS + n

func _ensure_regional_transition_store() -> Dictionary:
	var v: Variant = run_flags.get(REGIONAL_BIOME_TRANSITION_KEY, {})
	if typeof(v) != TYPE_DICTIONARY:
		v = {}
		run_flags[REGIONAL_BIOME_TRANSITION_KEY] = v
	return v as Dictionary

func _register_regional_biome_transitions(
	prev_w: int,
	prev_h: int,
	prev_seed: int,
	prev_biomes: PackedInt32Array,
	next_w: int,
	next_h: int,
	next_seed: int,
	next_biomes: PackedInt32Array
) -> void:
	var size: int = int(next_w) * int(next_h)
	if size <= 0:
		_ensure_regional_transition_store().clear()
		return
	if next_biomes.size() != size:
		return
	var store: Dictionary = _ensure_regional_transition_store()
	if int(prev_seed) != int(next_seed) or prev_w != next_w or prev_h != next_h or prev_biomes.size() != size:
		# New world snapshot shape/seed: stale transition entries are meaningless.
		store.clear()
		return
	var abs_dayf: float = _current_abs_dayf()
	for i in range(size):
		var old_b: int = int(prev_biomes[i])
		var new_b: int = int(next_biomes[i])
		if old_b == new_b:
			continue
		var x: int = i % next_w
		var y: int = int(i / next_w)
		var k: String = _regional_transition_key(x, y)
		store[k] = {
			"from_biome": old_b,
			"to_biome": new_b,
			"start_abs_dayf": abs_dayf,
			"duration_days": _regional_transition_duration_days(x, y, new_b),
		}…12959 tokens truncated…)
	var count: int = int(slot_data.get("count", 0))
	if item_name.is_empty() or count <= 0:
		return {"ok": false, "message": "Source slot is empty."}
	if not String(slot_data.get("equipped_slot", "")).is_empty():
		return {"ok": false, "message": "Unequip items before giving them away."}
	slot_data.erase("equipped_slot")

	var item: Dictionary = ItemCatalog.get_item(item_name)
	var stackable: bool = VariantCasts.to_bool(item.get("stackable", true))
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
	var name: String = String(slot.get("name", ""))
	var count: int = int(slot.get("count", 0))
	if name.is_empty() or count <= 0:
		return {"ok": false, "message": "Empty slot."}
	if not String(slot.get("equipped_slot", "")).is_empty():
		return {"ok": false, "message": "Unequip before dropping."}
	member.set_bag_slot(idx, {})
	party.rebuild_inventory_view()
	_emit_inventory_changed()
	return {"ok": true, "message": "Dropped %s." % name}

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
	# Snapshot GPU-driven society sim state only at explicit transitions (save/load).
	_tick_background_sims_if_needed()
	if _society_gpu != null and "snapshot_to_cpu" in _society_gpu:
		_society_gpu.snapshot_to_cpu(economy_state, politics_state, npc_world_state, wildlife_state, civilization_state)
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

func get_save_slot_metadata(path: String) -> Dictionary:
	var out: Dictionary = {
		"exists": false,
		"corrupt": false,
		"saved_unix": 0,
		"time_compact": "",
		"location_label": "",
		"party_avg_level": 0.0,
	}
	if path.is_empty() or not FileAccess.file_exists(path):
		return out
	out["exists"] = true
	out["saved_unix"] = int(FileAccess.get_modified_time(path))
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
	var payload: Dictionary = parsed as Dictionary
	out.merge(_extract_save_meta_from_payload(payload), true)
	return out

func get_society_overlay_texture() -> Texture2D:
	# GPU-only: pack the current society buffers into a texture for rendering overlays.
	if _society_gpu == null:
		return null
	if not has_world_snapshot():
		return null
	if "update_overlay_texture" in _society_gpu:
		return _society_gpu.update_overlay_texture()
	return null

func get_society_debug_tile(world_x: int, world_y: int) -> Dictionary:
	# On-demand, cached-at-caller readback for worldgen hover UI.
	if _society_gpu == null:
		return {}
	if "read_debug_tile" in _society_gpu:
		return _society_gpu.read_debug_tile(world_x, world_y)
	return {}

func get_political_state_id_at(world_x: int, world_y: int) -> String:
	return _compute_political_state_id(int(world_x), int(world_y))

func get_society_gpu_stats() -> Dictionary:
	if _society_gpu == null:
		return {}
	if "get_gpu_stats" in _society_gpu:
		return _society_gpu.get_gpu_stats()
	return {}

func set_regional_cache_stats(stats: Dictionary) -> void:
	if typeof(stats) != TYPE_DICTIONARY or stats.is_empty():
		_regional_cache_stats.clear()
		return
	_regional_cache_stats = stats.duplicate(true)

func get_regional_cache_stats() -> Dictionary:
	return _regional_cache_stats.duplicate(true)

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
	# Upload loaded society state to GPU on next tick.
	if _society_gpu != null and "mark_dirty" in _society_gpu:
		_society_gpu.mark_dirty()
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
	var biome_array: Array = []
	for b in world_biome_ids:
		biome_array.append(int(b))
	return {
		"version": SAVE_SCHEMA_VERSION,
		"world_seed_hash": world_seed_hash,
		"world_width": world_width,
		"world_height": world_height,
		"world_biome_ids": biome_array,
		"location": location.duplicate(true),
		"party": party.to_dict(),
		"world_time": world_time.to_dict(),
		"settings_state": settings_state.to_dict(),
		"quest_state": quest_state.to_dict(),
		"world_flags": world_flags.to_dict(),
		"economy_state": economy_state.to_dict(),
		"politics_state": politics_state.to_dict(),
		"npc_world_state": npc_world_state.to_dict(),
		"wildlife_state": wildlife_state.to_dict(),
		"civilization_state": civilization_state.to_dict(),
		"settlement_state": settlement_state.to_dict(),
		"pending_battle": pending_battle.duplicate(true),
		"pending_poi": pending_poi.duplicate(true),
		"last_battle_result": last_battle_result.duplicate(true),
		"run_flags": run_flags.duplicate(true),
		"saved_unix_time": int(Time.get_unix_time_from_system()),
		"save_meta": _build_save_meta(),
	}

func _from_save_payload(data: Dictionary, version: int = SAVE_SCHEMA_VERSION) -> void:
	world_seed_hash = int(data.get("world_seed_hash", 0))
	world_width = max(0, int(data.get("world_width", 0)))
	world_height = max(0, int(data.get("world_height", 0)))
	world_biome_ids = PackedInt32Array()
	var incoming_biomes: Array = data.get("world_biome_ids", [])
	world_biome_ids.resize(incoming_biomes.size())
	for i in range(incoming_biomes.size()):
		world_biome_ids[i] = int(incoming_biomes[i])
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
	if version >= 4:
		economy_state = EconomyStateModel.from_dict(data.get("economy_state", {}))
		politics_state = PoliticsStateModel.from_dict(data.get("politics_state", {}))
		npc_world_state = NpcWorldStateModel.from_dict(data.get("npc_world_state", {}))
	else:
		economy_state = EconomyStateModel.new()
		economy_state.reset_defaults()
		politics_state = PoliticsStateModel.new()
		politics_state.reset_defaults()
		npc_world_state = NpcWorldStateModel.new()
		npc_world_state.reset_defaults()
	if version >= 5:
		wildlife_state = WildlifeStateModel.from_dict(data.get("wildlife_state", {}))
		civilization_state = CivilizationStateModel.from_dict(data.get("civilization_state", {}))
	else:
		wildlife_state = WildlifeStateModel.new()
		wildlife_state.reset_defaults()
		civilization_state = CivilizationStateModel.new()
		civilization_state.reset_defaults()
	if version >= 6:
		settlement_state = SettlementStateModel.from_dict(data.get("settlement_state", {}))
	else:
		settlement_state = SettlementStateModel.new()
		settlement_state.reset_defaults()
	pending_battle = data.get("pending_battle", {}).duplicate(true)
	pending_poi = data.get("pending_poi", {}).duplicate(true)
	last_battle_result = data.get("last_battle_result", {}).duplicate(true)
	run_flags = data.get("run_flags", {}).duplicate(true)
	_regional_cache_stats.clear()
	_ingame_time_accum_seconds = 0.0
	# Ensure background sims don't attempt to "backfill" huge spans on load.
	_tick_background_sims_if_needed()
	_refresh_epoch_state(_current_abs_day_index(), false)
	# Refresh derived fields after sims load.
	location["political_state_id"] = _compute_political_state_id(int(location.get("world_x", 0)), int(location.get("world_y", 0)))

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
	location["political_state_id"] = String(location.get("political_state_id", ""))

func _find_member_by_id(member_id: String) -> Variant:
	for member in party.members:
		if member == null:
			continue
		if String(member.member_id) == member_id:
			return member
	return null

func _build_save_meta() -> Dictionary:
	var scene_name: String = String(location.get("scene", SceneContracts.STATE_WORLD))
	var wx: int = int(location.get("world_x", 0))
	var wy: int = int(location.get("world_y", 0))
	var biome_name: String = String(location.get("biome_name", ""))
	var location_label: String = "%s (%d,%d)" % [scene_name, wx, wy]
	if not biome_name.is_empty():
		location_label += " %s" % biome_name
	return {
		"time_compact": get_time_label(),
		"location_label": location_label,
		"party_avg_level": _party_average_level(),
	}

func _party_average_level() -> float:
	if party == null or party.members.is_empty():
		return 0.0
	var sum_levels: float = 0.0
	var n: int = 0
	for m in party.members:
		if m == null:
			continue
		sum_levels += float(m.level)
		n += 1
	if n <= 0:
		return 0.0
	return sum_levels / float(n)

func _extract_save_meta_from_payload(payload: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"saved_unix": int(payload.get("saved_unix_time", 0)),
		"time_compact": "",
		"location_label": "",
		"party_avg_level": 0.0,
	}
	var meta_v: Variant = payload.get("save_meta", {})
	if typeof(meta_v) == TYPE_DICTIONARY:
		var meta: Dictionary = meta_v as Dictionary
		out["time_compact"] = String(meta.get("time_compact", ""))
		out["location_label"] = String(meta.get("location_label", ""))
		out["party_avg_level"] = float(meta.get("party_avg_level", 0.0))
	if String(out.get("time_compact", "")).is_empty():
		var wt_v: Variant = payload.get("world_time", {})
		if typeof(wt_v) == TYPE_DICTIONARY:
			var wt: Dictionary = wt_v as Dictionary
			var y: int = max(1, int(wt.get("year", 1)))
			var mo: int = clamp(int(wt.get("month", 1)), 1, 12)
			var d: int = clamp(int(wt.get("day", 1)), 1, 31)
			var h: int = clamp(int(wt.get("hour", 0)), 0, 23)
			var mi: int = clamp(int(wt.get("minute", 0)), 0, 59)
			out["time_compact"] = "Y%d M%d D%d %02d:%02d" % [y, mo, d, h, mi]
	if String(out.get("location_label", "")).is_empty():
		var loc_v: Variant = payload.get("location", {})
		if typeof(loc_v) == TYPE_DICTIONARY:
			var loc: Dictionary = loc_v as Dictionary
			var scene_name: String = String(loc.get("scene", SceneContracts.STATE_WORLD))
			var wx: int = int(loc.get("world_x", 0))
			var wy: int = int(loc.get("world_y", 0))
			var biome_name: String = String(loc.get("biome_name", ""))
			var label: String = "%s (%d,%d)" % [scene_name, wx, wy]
			if not biome_name.is_empty():
				label += " %s" % biome_name
			out["location_label"] = label
	if float(out.get("party_avg_level", 0.0)) <= 0.0:
		var p_v: Variant = payload.get("party", {})
		if typeof(p_v) == TYPE_DICTIONARY:
			var p: Dictionary = p_v as Dictionary
			var members_v: Variant = p.get("members", [])
			if typeof(members_v) == TYPE_ARRAY:
				var sum_levels: float = 0.0
				var n: int = 0
				for mv in (members_v as Array):
					if typeof(mv) != TYPE_DICTIONARY:
						continue
					sum_levels += float((mv as Dictionary).get("level", 1))
					n += 1
				if n > 0:
					out["party_avg_level"] = sum_levels / float(n)
	return out
