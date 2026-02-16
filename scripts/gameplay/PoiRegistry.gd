extends RefCounted
class_name PoiRegistry


const REGION_SIZE: int = 96
const POI_GRID_STEP: int = 12
const _CACHE_LIMIT: int = 320

const _SETTLEMENT_NONE: int = 0
const _SETTLEMENT_VILLAGE: int = 1
const _SETTLEMENT_TOWN: int = 2
const _SETTLEMENT_CITY: int = 3

static var _tile_plan_cache: Dictionary = {}
static var _tile_plan_order: Array[String] = []

static func get_poi_at(
	world_seed_hash: int,
	world_x: int,
	world_y: int,
	local_x: int,
	local_y: int,
	biome_id: int,
	settlement_context: Dictionary = {}
) -> Dictionary:
	if biome_id == 0 or biome_id == 1:
		return {}
	local_x = int(local_x)
	local_y = int(local_y)
	if local_x < 0 or local_y < 0 or local_x >= REGION_SIZE or local_y >= REGION_SIZE:
		return {}
	if local_x % POI_GRID_STEP != 0 or local_y % POI_GRID_STEP != 0:
		return {}
	var plan: Dictionary = _tile_plan(world_seed_hash, world_x, world_y, biome_id, settlement_context)
	var pv: Variant = plan.get("poi_by_local", {})
	if typeof(pv) != TYPE_DICTIONARY:
		return {}
	var poi_by_local: Dictionary = pv as Dictionary
	var key: String = "%d,%d" % [local_x, local_y]
	var vv: Variant = poi_by_local.get(key, {})
	if typeof(vv) == TYPE_DICTIONARY:
		return (vv as Dictionary).duplicate(true)
	return {}

static func _tile_plan(
	world_seed_hash: int,
	world_x: int,
	world_y: int,
	biome_id: int,
	settlement_context: Dictionary = {}
) -> Dictionary:
	var seed_value: int = 1 if int(world_seed_hash) == 0 else int(world_seed_hash)
	world_x = int(world_x)
	world_y = int(world_y)
	biome_id = int(biome_id)
	var context_sig: String = _settlement_context_signature(settlement_context)
	var cache_key: String = "%d|%d|%d|%d|%s" % [seed_value, world_x, world_y, biome_id, context_sig]
	var cv: Variant = _tile_plan_cache.get(cache_key, {})
	if typeof(cv) == TYPE_DICTIONARY and not (cv as Dictionary).is_empty():
		return cv as Dictionary

	var built: Dictionary = _build_tile_plan(seed_value, world_x, world_y, biome_id, settlement_context)
	_tile_plan_cache[cache_key] = built
	_tile_plan_order.append(cache_key)
	if _tile_plan_order.size() > _CACHE_LIMIT:
		var old_key: String = String(_tile_plan_order[0])
		_tile_plan_order.remove_at(0)
		_tile_plan_cache.erase(old_key)
	return built

static func _build_tile_plan(
	seed_value: int,
	world_x: int,
	world_y: int,
	biome_id: int,
	settlement_context: Dictionary = {}
) -> Dictionary:
	var plan: Dictionary = {
		"poi_by_local": {},
		"settlement_tier": "wild",
	}
	var poi_by_local: Dictionary = plan["poi_by_local"]
	var used_boxes: Array[Rect2i] = []
	var layout_cache: Dictionary = {}
	var key_root: String = "tile|%d|%d|b=%d" % [world_x, world_y, biome_id]

	var tier: int = _choose_settlement_tier(seed_value, world_x, world_y, biome_id, settlement_context)
	var allow_wild_houses: bool = true
	if not settlement_context.is_empty():
		allow_wild_houses = bool(settlement_context.get("allow_wild_houses", false))
	if tier == _SETTLEMENT_NONE:
		if allow_wild_houses:
			_populate_wild_houses(seed_value, world_x, world_y, biome_id, key_root + "|wild", poi_by_local, used_boxes, -1, layout_cache)
		_add_dungeon_pois(seed_value, world_x, world_y, biome_id, key_root + "|dungeons", tier, poi_by_local, used_boxes)
		return plan

	var profile: Dictionary = _settlement_profile(tier)
	plan["settlement_tier"] = String(profile.get("name", "village"))

	var center: Vector2 = _settlement_center(seed_value, key_root)
	var square_half: int = int(profile.get("square_half", 4))
	var square_rect: Rect2i = Rect2i(
		int(round(center.x)) - square_half,
		int(round(center.y)) - square_half,
		square_half * 2 + 1,
		square_half * 2 + 1
	)

	var candidates: Array[Dictionary] = _candidate_anchors(center)
	var target_min: int = int(profile.get("buildings_min", 4))
	var target_max: int = int(profile.get("buildings_max", 8))
	var target_count: int = DeterministicRng.randi_range(seed_value, key_root + "|building_count", target_min, target_max)
	var services: Array[String] = _service_queue_for_tier(seed_value, key_root, tier, target_count)

	for service in services:
		_try_place_service_building(
			seed_value,
			world_x,
			world_y,
			biome_id,
			String(profile.get("name", "village")),
			center,
			square_rect,
			service,
			key_root,
			candidates,
			poi_by_local,
			used_boxes,
			layout_cache
		)

	# If strict overlap rejection skipped too many placements, fill the remainder with sparse homes.
	if poi_by_local.size() < max(2, int(round(float(target_count) * 0.60))):
		var fallback_houses: int = max(0, target_count - poi_by_local.size())
		_populate_wild_houses(seed_value, world_x, world_y, biome_id, key_root + "|fallback", poi_by_local, used_boxes, fallback_houses, layout_cache)

	_add_dungeon_pois(seed_value, world_x, world_y, biome_id, key_root + "|dungeons", tier, poi_by_local, used_boxes)
	return plan

static func _choose_settlement_tier(
	seed_value: int,
	world_x: int,
	world_y: int,
	biome_id: int,
	settlement_context: Dictionary = {}
) -> int:
	if not settlement_context.is_empty():
		var humans_emerged: bool = bool(settlement_context.get("humans_emerged", false))
		if not humans_emerged:
			return _SETTLEMENT_NONE
		var allow_settlement: bool = bool(settlement_context.get("allow_settlement", false))
		var settlement_core: bool = bool(settlement_context.get("settlement_core", false))
		var effective_pop: float = _effective_pop_from_context(settlement_context)
		var strength: float = clamp(float(settlement_context.get("settlement_strength", effective_pop / 280.0)), 0.0, 1.0)
		var biome_weight: float = _settlement_spawn_weight_for_biome(biome_id)
		if biome_weight <= 0.0001:
			return _SETTLEMENT_NONE
		if not allow_settlement and not settlement_core:
			return _SETTLEMENT_NONE
		var viability: float = clamp(
			strength * (0.70 + biome_weight * 0.45) + (0.20 if settlement_core else 0.0),
			0.0,
			1.0
		)
		if effective_pop >= 320.0 and viability >= 0.45:
			return _SETTLEMENT_CITY
		if effective_pop >= 120.0 and viability >= 0.25:
			return _SETTLEMENT_TOWN
		if effective_pop >= 18.0 and viability >= 0.08:
			return _SETTLEMENT_VILLAGE
		if settlement_core and effective_pop >= 8.0:
			return _SETTLEMENT_VILLAGE
		return _SETTLEMENT_NONE

	var weight: float = _settlement_spawn_weight_for_biome(biome_id)
	if weight <= 0.0001:
		return _SETTLEMENT_NONE
	var key_root: String = "settle|%d|%d|b=%d" % [world_x, world_y, biome_id]
	var spawn_roll: float = DeterministicRng.randf01(seed_value, key_root + "|spawn")
	if spawn_roll > weight:
		return _SETTLEMENT_NONE
	var size_roll: float = DeterministicRng.randf01(seed_value, key_root + "|size")
	var city_threshold: float = clamp(0.028 + weight * 0.12, 0.03, 0.14)
	var town_threshold: float = clamp(city_threshold + 0.22 + weight * 0.24, 0.28, 0.76)
	if size_roll < city_threshold:
		return _SETTLEMENT_CITY
	if size_roll < town_threshold:
		return _SETTLEMENT_TOWN
	return _SETTLEMENT_VILLAGE

static func _effective_pop_from_context(settlement_context: Dictionary) -> float:
	var human_pop: float = max(0.0, float(settlement_context.get("human_pop", 0.0)))
	var settlement_pop: float = max(0.0, float(settlement_context.get("settlement_pop", 0.0)))
	var effective_pop: float = max(human_pop, settlement_pop)
	return max(effective_pop, max(0.0, float(settlement_context.get("effective_pop", effective_pop))))

static func _settlement_context_signature(settlement_context: Dictionary) -> String:
	if settlement_context.is_empty():
		return "legacy"
	var humans: int = 1 if bool(settlement_context.get("humans_emerged", false)) else 0
	var allow_settlement: int = 1 if bool(settlement_context.get("allow_settlement", false)) else 0
	var allow_wild_houses: int = 1 if bool(settlement_context.get("allow_wild_houses", false)) else 0
	var settlement_core: int = 1 if bool(settlement_context.get("settlement_core", false)) else 0
	var effective_pop: float = _effective_pop_from_context(settlement_context)
	var pop_bucket: int = int(floor(effective_pop / 8.0))
	var strength: float = clamp(float(settlement_context.get("settlement_strength", effective_pop / 280.0)), 0.0, 1.0)
	var strength_bucket: int = int(round(strength * 32.0))
	return "%d|%d|%d|%d|%d|%d" % [
		humans,
		allow_settlement,
		allow_wild_houses,
		settlement_core,
		pop_bucket,
		strength_bucket,
	]

static func _settlement_profile(tier: int) -> Dictionary:
	match int(tier):
		_SETTLEMENT_CITY:
			return {
				"name": "city",
				"buildings_min": 13,
				"buildings_max": 19,
				"square_half": 8,
			}
		_SETTLEMENT_TOWN:
			return {
				"name": "town",
				"buildings_min": 8,
				"buildings_max": 13,
				"square_half": 6,
			}
		_:
			return {
				"name": "village",
				"buildings_min": 5,
				"buildings_max": 8,
				"square_half": 4,
			}

static func _settlement_center(seed_value: int, key_root: String) -> Vector2:
	var cx: int = DeterministicRng.randi_range(seed_value, key_root + "|center_x", 30, 66)
	var cy: int = DeterministicRng.randi_range(seed_value, key_root + "|center_y", 30, 66)
	return Vector2(float(cx), float(cy))

static func _candidate_anchors(center: Vector2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ly in range(POI_GRID_STEP, REGION_SIZE - POI_GRID_STEP + 1, POI_GRID_STEP):
		for lx in range(POI_GRID_STEP, REGION_SIZE - POI_GRID_STEP + 1, POI_GRID_STEP):
			var d: float = Vector2(float(lx), float(ly)).distance_to(center)
			var axis_dist: float = min(abs(float(lx) - center.x), abs(float(ly) - center.y))
			out.append({
				"x": lx,
				"y": ly,
				"dist": d,
				"axis": axis_dist,
			})
	return out

static func _service_queue_for_tier(seed_value: int, key_root: String, tier: int, target_count: int) -> Array[String]:
	var services: Array[String] = []
	if tier >= _SETTLEMENT_VILLAGE:
		services.append("shop")
	if tier >= _SETTLEMENT_TOWN:
		services.append("inn")
		services.append("temple")
		services.append("town_hall")
	if tier >= _SETTLEMENT_CITY:
		services.append("shop")
		services.append("shop")
		services.append("inn")
		services.append("faction_hall")
		if DeterministicRng.randf01(seed_value, key_root + "|city_temple_extra") < 0.55:
			services.append("temple")
	elif tier >= _SETTLEMENT_TOWN:
		if DeterministicRng.randf01(seed_value, key_root + "|town_faction") < 0.58:
			services.append("faction_hall")
		if DeterministicRng.randf01(seed_value, key_root + "|town_shop_extra") < 0.45:
			services.append("shop")
	elif tier >= _SETTLEMENT_VILLAGE:
		if DeterministicRng.randf01(seed_value, key_root + "|village_inn") < 0.40:
			services.append("inn")

	while services.size() > max(1, target_count - 1):
		services.remove_at(services.size() - 1)
	while services.size() < target_count:
		services.append("home")
	return services

static func _try_place_service_building(
	seed_value: int,
	world_x: int,
	world_y: int,
	biome_id: int,
	settlement_tier: String,
	center: Vector2,
	square_rect: Rect2i,
	service_type: String,
	key_root: String,
	candidates: Array[Dictionary],
	poi_by_local: Dictionary,
	used_boxes: Array[Rect2i],
	layout_cache: Dictionary
) -> bool:
	var scored: Array[Dictionary] = []
	for cv in candidates:
		if typeof(cv) != TYPE_DICTIONARY:
			continue
		var c: Dictionary = cv as Dictionary
		var lx: int = int(c.get("x", 0))
		var ly: int = int(c.get("y", 0))
		var coord_key: String = "%d,%d" % [lx, ly]
		if poi_by_local.has(coord_key):
			continue
		var dist: float = float(c.get("dist", 0.0))
		var axis: float = float(c.get("axis", 0.0))
		var score: float = _service_anchor_score(seed_value, key_root, service_type, lx, ly, dist, axis, center, square_rect)
		scored.append({"x": lx, "y": ly, "score": score})
	if scored.is_empty():
		return false
	scored.sort_custom(func(a, b): return float(a.get("score", 0.0)) < float(b.get("score", 0.0)))

	for sv in scored:
		if typeof(sv) != TYPE_DICTIONARY:
			continue
		var s: Dictionary = sv as Dictionary
		var lx2: int = int(s.get("x", 0))
		var ly2: int = int(s.get("y", 0))
		var layout: Dictionary = _cached_house_layout(seed_value, world_x, world_y, lx2, ly2, service_type, layout_cache)
		if layout.is_empty():
			continue
		var bbox: Rect2i = _layout_bbox_for_anchor(lx2, ly2, layout)
		if bbox.size.x <= 0 or bbox.size.y <= 0:
			continue
		# Keep footprints inside their parent regional tile so neighboring tiles don't overlap.
		if bbox.position.x < 1 or bbox.position.y < 1:
			continue
		if bbox.position.x + bbox.size.x > REGION_SIZE - 1:
			continue
		if bbox.position.y + bbox.size.y > REGION_SIZE - 1:
			continue
		if square_rect.size.x > 0 and square_rect.size.y > 0 and bbox.grow(1).intersects(square_rect.grow(2)):
			continue
		var overlap: bool = false
		for rb in used_boxes:
			if bbox.grow(1).intersects(rb):
				overlap = true
				break
		if overlap:
			continue

		used_boxes.append(bbox)
		var poi: Dictionary = _build_house_poi(
			seed_value,
			world_x,
			world_y,
			biome_id,
			lx2,
			ly2,
			service_type,
			settlement_tier,
			center
		)
		poi_by_local["%d,%d" % [lx2, ly2]] = poi
		return true
	return false

static func _service_anchor_score(
	seed_value: int,
	key_root: String,
	service_type: String,
	lx: int,
	ly: int,
	dist: float,
	axis_dist: float,
	_center: Vector2,
	square_rect: Rect2i
) -> float:
	var square_half: float = float(max(square_rect.size.x, square_rect.size.y)) * 0.5
	var target_ring: float = square_half + 10.0
	var score: float = abs(dist - target_ring)
	match service_type:
		"town_hall":
			score = abs(dist - (square_half + 7.0)) * 1.35 + axis_dist * 0.18
		"temple":
			score = abs(dist - (square_half + 11.0)) * 1.20 + axis_dist * 0.09
		"faction_hall":
			score = abs(dist - (square_half + 10.0)) * 1.10 + axis_dist * 0.08
		"inn":
			score = abs(dist - (square_half + 12.0)) * 1.08 + axis_dist * 0.14
		"shop":
			score = abs(dist - (square_half + 9.0)) * 1.00 + axis_dist * 0.20
		_:
			score = abs(dist - (square_half + 15.0)) * 0.86 + axis_dist * 0.06
	var jitter: float = DeterministicRng.randf01(seed_value, "%s|score|%s|%d|%d" % [key_root, service_type, lx, ly]) * 5.0
	return score + jitter

static func _layout_bbox_for_anchor(local_x: int, local_y: int, layout: Dictionary) -> Rect2i:
	var extent_left: int = max(0, int(layout.get("extent_left", 0)))
	var extent_right: int = max(0, int(layout.get("extent_right", 0)))
	var extent_up: int = max(0, int(layout.get("extent_up", 0)))
	var extent_down: int = max(0, int(layout.get("extent_down", 0)))
	var x0: int = local_x - extent_left
	var y0: int = local_y - extent_up
	var w: int = extent_left + extent_right + 1
	var h: int = extent_up + extent_down + 1
	return Rect2i(x0, y0, w, h)

static func _cached_house_layout(
	seed_value: int,
	world_x: int,
	world_y: int,
	local_x: int,
	local_y: int,
	service_type: String,
	layout_cache: Dictionary
) -> Dictionary:
	var cache_key: String = "%d,%d|%d,%d|%s" % [world_x, world_y, local_x, local_y, service_type]
	var vv: Variant = layout_cache.get(cache_key, {})
	if typeof(vv) == TYPE_DICTIONARY and not (vv as Dictionary).is_empty():
		return vv as Dictionary
	var poi_id: String = "house_%d_%d_%d_%d" % [world_x, world_y, local_x, local_y]
	var layout: Dictionary = LocalAreaGenerator.generate_house_layout(
		seed_value,
		poi_id,
		LocalAreaGenerator.HOUSE_MAP_W,
		LocalAreaGenerator.HOUSE_MAP_H,
		service_type == "shop",
		service_type
	)
	if not layout.is_empty():
		layout_cache[cache_key] = layout
	return layout

static func _build_house_poi(
	seed_value: int,
	world_x: int,
	world_y: int,
	biome_id: int,
	local_x: int,
	local_y: int,
	service_type: String,
	settlement_tier: String,
	town_center: Vector2
) -> Dictionary:
	var faction_id: String = ""
	if service_type == "temple" or service_type == "faction_hall" or service_type == "town_hall":
		var fx: int = int(floor(float(world_x) / 16.0))
		var fy: int = int(floor(float(world_y) / 16.0))
		faction_id = "faction|%d|%d" % [fx, fy]
	var faction_rank_required: int = 0
	if service_type == "temple":
		faction_rank_required = 1
	elif service_type == "faction_hall":
		faction_rank_required = 1 + DeterministicRng.randi_range(seed_value, "rank|%d|%d|%d|%d" % [world_x, world_y, local_x, local_y], 0, 1)
	elif service_type == "town_hall":
		faction_rank_required = 1
	return {
		"type": "House",
		"id": "house_%d_%d_%d_%d" % [world_x, world_y, local_x, local_y],
		"seed_key": "poi|%d|%d|%d|%d|%d" % [world_x, world_y, local_x, local_y, biome_id],
		"is_shop": service_type == "shop",
		"service_type": service_type,
		"faction_id": faction_id,
		"faction_rank_required": faction_rank_required,
		"settlement_tier": settlement_tier,
		"town_center_x": int(round(town_center.x)),
		"town_center_y": int(round(town_center.y)),
	}

static func _populate_wild_houses(
	seed_value: int,
	world_x: int,
	world_y: int,
	biome_id: int,
	key_root: String,
	poi_by_local: Dictionary,
	used_boxes: Array[Rect2i],
	fallback_target: int = -1,
	layout_cache: Dictionary = {}
) -> void:
	var house_target: int = fallback_target
	if house_target < 0:
		house_target = 0
		var base_chance: float = _wild_house_base_chance_for_biome(biome_id)
		if DeterministicRng.randf01(seed_value, key_root + "|spawn_0") < base_chance:
			house_target += 1
		if DeterministicRng.randf01(seed_value, key_root + "|spawn_1") < base_chance * 0.45:
			house_target += 1
	if house_target <= 0:
		return

	var candidates: Array[Dictionary] = []
	for ly in range(POI_GRID_STEP, REGION_SIZE - POI_GRID_STEP + 1, POI_GRID_STEP):
		for lx in range(POI_GRID_STEP, REGION_SIZE - POI_GRID_STEP + 1, POI_GRID_STEP):
			var coord_key: String = "%d,%d" % [lx, ly]
			if poi_by_local.has(coord_key):
				continue
			var shuffle_key: float = DeterministicRng.randf01(seed_value, "%s|shuffle|%d|%d" % [key_root, lx, ly])
			candidates.append({"x": lx, "y": ly, "shuffle": shuffle_key})
	candidates.sort_custom(func(a, b): return float(a.get("shuffle", 0.0)) < float(b.get("shuffle", 0.0)))

	var placed: int = 0
	for cv in candidates:
		if placed >= house_target:
			break
		if typeof(cv) != TYPE_DICTIONARY:
			continue
		var c: Dictionary = cv as Dictionary
		var lx2: int = int(c.get("x", 0))
		var ly2: int = int(c.get("y", 0))
		var service_roll: float = DeterministicRng.randf01(seed_value, "%s|service|%d|%d" % [key_root, lx2, ly2])
		var service_type: String = "home"
		if service_roll < 0.14:
			service_type = "shop"
		elif service_roll < 0.20:
			service_type = "inn"

		var layout: Dictionary = _cached_house_layout(seed_value, world_x, world_y, lx2, ly2, service_type, layout_cache)
		if layout.is_empty():
			continue
		var bbox: Rect2i = _layout_bbox_for_anchor(lx2, ly2, layout)
		if bbox.position.x < 1 or bbox.position.y < 1:
			continue
		if bbox.position.x + bbox.size.x > REGION_SIZE - 1:
			continue
		if bbox.position.y + bbox.size.y > REGION_SIZE - 1:
			continue
		var overlap: bool = false
		for rb in used_boxes:
			if bbox.grow(1).intersects(rb):
				overlap = true
				break
		if overlap:
			continue

		used_boxes.append(bbox)
		var poi: Dictionary = _build_house_poi(
			seed_value,
			world_x,
			world_y,
			biome_id,
			lx2,
			ly2,
			service_type,
			"wild",
			Vector2(float(lx2), float(ly2))
		)
		poi_by_local["%d,%d" % [lx2, ly2]] = poi
		placed += 1

static func _add_dungeon_pois(
	seed_value: int,
	world_x: int,
	world_y: int,
	biome_id: int,
	key_root: String,
	tier: int,
	poi_by_local: Dictionary,
	used_boxes: Array[Rect2i] = []
) -> void:
	var base_chance: float = _dungeon_base_chance_for_biome(biome_id)
	if tier == _SETTLEMENT_TOWN:
		base_chance *= 0.80
	elif tier == _SETTLEMENT_CITY:
		base_chance *= 0.60
	var roll_count: int = 1
	if tier == _SETTLEMENT_NONE and DeterministicRng.randf01(seed_value, key_root + "|extra_roll") < 0.35:
		roll_count = 2
	var placed: int = 0
	for i in range(roll_count):
		var roll: float = DeterministicRng.randf01(seed_value, "%s|roll|i=%d" % [key_root, i])
		if roll > base_chance:
			continue
		var lx: int = DeterministicRng.randi_range(seed_value, "%s|x|i=%d" % [key_root, i], POI_GRID_STEP, REGION_SIZE - POI_GRID_STEP)
		var ly: int = DeterministicRng.randi_range(seed_value, "%s|y|i=%d" % [key_root, i], POI_GRID_STEP, REGION_SIZE - POI_GRID_STEP)
		lx = int(round(float(lx) / float(POI_GRID_STEP))) * POI_GRID_STEP
		ly = int(round(float(ly) / float(POI_GRID_STEP))) * POI_GRID_STEP
		lx = clamp(lx, POI_GRID_STEP, REGION_SIZE - POI_GRID_STEP)
		ly = clamp(ly, POI_GRID_STEP, REGION_SIZE - POI_GRID_STEP)
		var key: String = "%d,%d" % [lx, ly]
		if poi_by_local.has(key):
			continue
		var blocked_by_house: bool = false
		for rb in used_boxes:
			if rb.has_point(Vector2i(lx, ly)):
				blocked_by_house = true
				break
		if blocked_by_house:
			continue
		poi_by_local[key] = {
			"type": "Dungeon",
			"id": "dungeon_%d_%d_%d_%d" % [world_x, world_y, lx, ly],
			"seed_key": "poi|%d|%d|%d|%d|%d" % [world_x, world_y, lx, ly, biome_id],
		}
		placed += 1
		if placed >= 2:
			return

static func _settlement_spawn_weight_for_biome(biome_id: int) -> float:
	if _is_mountain_biome(biome_id):
		return 0.26
	if _is_desert_biome(biome_id):
		return 0.30
	if _is_forest_biome(biome_id):
		return 0.58
	if biome_id == 7 or biome_id == 6 or biome_id == 16 or biome_id == 21:
		return 0.64
	if biome_id == 10:
		return 0.42
	return 0.48

static func _wild_house_base_chance_for_biome(biome_id: int) -> float:
	if _is_mountain_biome(biome_id):
		return 0.12
	if _is_desert_biome(biome_id):
		return 0.14
	if _is_forest_biome(biome_id):
		return 0.22
	return 0.18

static func _dungeon_base_chance_for_biome(biome_id: int) -> float:
	var out: float = 0.06
	if _is_mountain_biome(biome_id):
		out = 0.11
	elif _is_desert_biome(biome_id):
		out = 0.09
	elif _is_forest_biome(biome_id):
		out = 0.07
	return out

static func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

static func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

static func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28
