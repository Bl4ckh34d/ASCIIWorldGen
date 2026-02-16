extends RefCounted
class_name EnemyCatalog

const _SEASON_UNKNOWN: int = -1
const _SEASON_SPRING: int = 0
const _SEASON_SUMMER: int = 1
const _SEASON_AUTUMN: int = 2
const _SEASON_WINTER: int = 3

const _TOD_NIGHT: int = 0
const _TOD_DAWN: int = 1
const _TOD_DAY: int = 2
const _TOD_DUSK: int = 3

static func encounter_for_biome(biome_id: int, seed_roll: float, context: Dictionary = {}) -> Dictionary:
	var tod_bucket: int = int(context.get("tod_bucket", _TOD_DAY))
	var season_bucket: int = int(context.get("season_bucket", _SEASON_UNKNOWN))
	var is_night: bool = VariantCasts.to_bool(context.get("is_night", tod_bucket == _TOD_NIGHT))
	var options: Array[Dictionary] = []

	if _is_forest_biome(biome_id):
		options = [
			_cand("Wolves", 8, 28),
			_cand("Bandits", 9, 30),
		]
		if is_night:
			options.append(_cand("Dire Wolves", 10, 33))
			options.append(_cand("Night Stalkers", 11, 35))
		elif tod_bucket == _TOD_DAWN:
			options.append(_cand("Boars", 9, 31))
		elif tod_bucket == _TOD_DUSK:
			options.append(_cand("Poachers", 10, 32))
		match season_bucket:
			_SEASON_SPRING:
				options.append(_cand("Briar Sprites", 9, 27))
			_SEASON_SUMMER:
				options.append(_cand("Hornet Swarm", 10, 29))
			_SEASON_AUTUMN:
				options.append(_cand("Raven Flock", 10, 30))
			_SEASON_WINTER:
				options.append(_cand("Frost Wolves", 11, 34))
		return _pick(options, seed_roll)

	if _is_mountain_biome(biome_id):
		options = [
			_cand("Goblins", 9, 29),
			_cand("Harpies", 10, 32),
		]
		if is_night:
			options.append(_cand("Cave Stalkers", 11, 33))
			options.append(_cand("Stone Imps", 10, 31))
		elif tod_bucket == _TOD_DAWN:
			options.append(_cand("Cliff Goats", 9, 30))
		elif tod_bucket == _TOD_DUSK:
			options.append(_cand("Rock Prowlers", 10, 31))
		match season_bucket:
			_SEASON_SPRING:
				options.append(_cand("Meltwater Goblins", 10, 31))
			_SEASON_SUMMER:
				options.append(_cand("Thunder Hawks", 11, 33))
			_SEASON_AUTUMN:
				options.append(_cand("Stone Trolls", 11, 35))
			_SEASON_WINTER:
				options.append(_cand("Ice Wargs", 12, 36))
		return _pick(options, seed_roll)

	if _is_desert_biome(biome_id):
		options = [
			_cand("Scorpions", 9, 30),
			_cand("Raiders", 11, 34),
		]
		if is_night:
			options.append(_cand("Dune Stalkers", 11, 33))
		elif tod_bucket == _TOD_DAY:
			options.append(_cand("Dust Vipers", 10, 31))
		elif tod_bucket == _TOD_DUSK:
			options.append(_cand("Sand Reavers", 11, 34))
		match season_bucket:
			_SEASON_SPRING:
				options.append(_cand("Nomad Scouts", 10, 32))
			_SEASON_SUMMER:
				options.append(_cand("Sand Wyrmlings", 12, 36))
				options.append(_cand("Sun Cultists", 12, 35))
			_SEASON_AUTUMN:
				options.append(_cand("Glass Jackals", 11, 34))
			_SEASON_WINTER:
				options.append(_cand("Dust Jackals", 10, 32))
		return _pick(options, seed_roll)

	if biome_id == 10 or biome_id == 23:
		options = [
			_cand("Slimes", 7, 26),
			_cand("Leeches", 8, 27),
		]
		if is_night:
			options.append(_cand("Marsh Wraiths", 10, 29))
		elif tod_bucket == _TOD_DAWN:
			options.append(_cand("Bog Hounds", 8, 28))
		match season_bucket:
			_SEASON_SPRING:
				options.append(_cand("Frog Swarm", 8, 26))
			_SEASON_SUMMER:
				options.append(_cand("Mosquito Swarm", 9, 27))
			_SEASON_AUTUMN:
				options.append(_cand("Rot Stalkers", 9, 28))
			_SEASON_WINTER:
				options.append(_cand("Mire Crabs", 9, 30))
		return _pick(options, seed_roll)

	options = [
		_cand("Wild Beasts", 8, 28),
		_cand("Strays", 8, 27),
	]
	if is_night:
		options.append(_cand("Night Prowlers", 10, 31))
	if season_bucket == _SEASON_WINTER:
		options.append(_cand("Starved Pack", 9, 30))
	elif season_bucket == _SEASON_SUMMER:
		options.append(_cand("Heat Jackals", 9, 29))
	return _pick(options, seed_roll)

static func _cand(group: String, power: int, base_hp: int, profile_id: String = "") -> Dictionary:
	var pid: String = String(profile_id).strip_edges()
	if pid.is_empty():
		pid = _profile_id_for_group_name(group)
	var prof: Dictionary = _profile_for_id(pid)
	var tags: PackedStringArray = _normalize_tags(prof.get("tags", []))
	var resist: Dictionary = _normalize_resist(prof.get("resist", {}))
	var actions: Array[Dictionary] = _normalize_actions(prof.get("actions", []))
	return {
		"group": String(group),
		"power": int(power),
		"base_hp": int(base_hp),
		"profile_id": pid,
		"tags": tags,
		"resist": resist,
		"actions": actions,
	}

static func _pick(options: Array[Dictionary], seed_roll: float) -> Dictionary:
	if options.is_empty():
		return _cand("Wild Beasts", 8, 28)
	var r: float = clamp(float(seed_roll), 0.0, 0.999999)
	var idx: int = int(floor(r * float(options.size())))
	idx = clamp(idx, 0, options.size() - 1)
	return options[idx]

static func profile_for_group(group_name: String) -> Dictionary:
	var pid: String = _profile_id_for_group_name(group_name)
	var prof: Dictionary = _profile_for_id(pid)
	prof["id"] = pid
	return {
		"id": pid,
		"tags": _normalize_tags(prof.get("tags", [])),
		"resist": _normalize_resist(prof.get("resist", {})),
		"actions": _normalize_actions(prof.get("actions", [])),
	}

static func _profile_id_for_group_name(group_name: String) -> String:
	var g: String = String(group_name).to_lower().strip_edges()
	match g:
		"wolves", "boars", "cliff goats", "bog hounds", "wild beasts", "strays", "heat jackals":
			return "beasts"
		"dire wolves", "frost wolves", "ice wargs", "starved pack":
			return "pack_hunters"
		"night stalkers", "dust vipers", "leeches", "rot stalkers":
			return "venom_predators"
		"hornet swarm", "mosquito swarm":
			return "venom_swarm"
		"bandits", "poachers", "raiders", "nomad scouts":
			return "humanoid_raiders"
		"goblins", "meltwater goblins":
			return "skirmishers"
		"harpies", "thunder hawks", "raven flock":
			return "fliers"
		"cave stalkers", "rock prowlers", "dune stalkers", "glass jackals", "sand reavers":
			return "ambushers"
		"stone imps":
			return "stone_imps"
		"stone trolls":
			return "stone_trolls"
		"scorpions":
			return "scorpions"
		"sand wyrmlings":
			return "sand_wyrms"
		"sun cultists":
			return "sun_cultists"
		"slimes", "briar sprites":
			return "ooze_spirits"
		"marsh wraiths":
			return "wraiths"
		"frog swarm":
			return "swarm"
		"mire crabs":
			return "carapace"
		"dust jackals":
			return "desert_hunters"
		_:
			return "beasts"

static func _profile_for_id(profile_id: String) -> Dictionary:
	match String(profile_id):
		"pack_hunters":
			return {
				"tags": PackedStringArray(["beast", "pack"]),
				"resist": {"physical": 0.95, "fire": 1.05, "poison": 0.80},
				"actions": [
					{"id": "maul", "label": "mauls", "weight": 0.62, "damage_type": "physical", "power_mult": 1.06},
					{"id": "rend", "label": "rends", "weight": 0.38, "damage_type": "physical", "power_mult": 0.94, "status": "poison", "status_turns": 1, "status_chance": 0.20},
				],
			}
		"venom_predators":
			return {
				"tags": PackedStringArray(["beast", "venom"]),
				"resist": {"physical": 1.0, "fire": 1.0, "poison": 0.62},
				"actions": [
					{"id": "bite", "label": "bites", "weight": 0.58, "damage_type": "physical", "power_mult": 1.00},
					{"id": "venom_sting", "label": "stings", "weight": 0.42, "damage_type": "physical", "power_mult": 0.82, "status": "poison", "status_turns": 2, "status_chance": 0.36},
				],
			}
		"venom_swarm":
			return {
				"tags": PackedStringArray(["swarm", "venom"]),
				"resist": {"physical": 1.10, "fire": 0.82, "poison": 0.55},
				"actions": [
					{"id": "swarm_bite", "label": "swarm", "weight": 0.70, "damage_type": "physical", "power_mult": 0.84},
					{"id": "toxic_cloud", "label": "sprays venom at", "weight": 0.30, "damage_type": "poison", "power_mult": 0.72, "status": "poison", "status_turns": 2, "status_chance": 0.44},
				],
			}
		"humanoid_raiders":
			return {
				"tags": PackedStringArray(["humanoid", "raider"]),
				"resist": {"physical": 1.0, "fire": 1.02, "poison": 1.05},
				"actions": [
					{"id": "slash", "label": "slashes", "weight": 0.74, "damage_type": "physical", "power_mult": 1.04},
					{"id": "dirty_strike", "label": "cheap-shots", "weight": 0.26, "damage_type": "physical", "power_mult": 0.90, "status": "poison", "status_turns": 1, "status_chance": 0.18},
				],
			}
		"skirmishers":
			return {
				"tags": PackedStringArray(["humanoid", "skirmisher"]),
				"resist": {"physical": 1.0, "fire": 1.0, "poison": 0.90},
				"actions": [
					{"id": "jab", "label": "jabs", "weight": 0.64, "damage_type": "physical", "power_mult": 0.95},
					{"id": "volley", "label": "throws a volley at", "weight": 0.36, "damage_type": "physical", "power_mult": 0.78, "target_mode": "all"},
				],
			}
		"fliers":
			return {
				"tags": PackedStringArray(["beast", "flier"]),
				"resist": {"physical": 0.95, "fire": 1.05, "poison": 0.90},
				"actions": [
					{"id": "talon", "label": "claws", "weight": 0.68, "damage_type": "physical", "power_mult": 0.98},
					{"id": "screech", "label": "screeches at", "weight": 0.32, "damage_type": "arcane", "power_mult": 0.72, "target_mode": "all"},
				],
			}
		"ambushers":
			return {
				"tags": PackedStringArray(["beast", "ambusher"]),
				"resist": {"physical": 1.0, "fire": 1.0, "poison": 0.86},
				"actions": [
					{"id": "lunge", "label": "lunges at", "weight": 0.72, "damage_type": "physical", "power_mult": 1.00},
					{"id": "ambush", "label": "ambushes", "weight": 0.28, "damage_type": "physical", "power_mult": 1.18},
				],
			}
		"stone_imps":
			return {
				"tags": PackedStringArray(["fiend", "stone"]),
				"resist": {"physical": 0.84, "fire": 1.18, "explosive": 1.16, "poison": 0.70},
				"actions": [
					{"id": "chip", "label": "chips", "weight": 0.67, "damage_type": "physical", "power_mult": 0.92},
					{"id": "shard", "label": "hurls shards at", "weight": 0.33, "damage_type": "physical", "power_mult": 1.04},
				],
			}
		"stone_trolls":
			return {
				"tags": PackedStringArray(["giant", "stone"]),
				"resist": {"physical": 0.78, "fire": 1.22, "explosive": 1.18, "poison": 0.65},
				"actions": [
					{"id": "smash", "label": "smashes", "weight": 0.70, "damage_type": "physical", "power_mult": 1.20},
					{"id": "ground_slam", "label": "slams the ground at", "weight": 0.30, "damage_type": "physical", "power_mult": 0.86, "target_mode": "all"},
				],
			}
		"scorpions":
			return {
				"tags": PackedStringArray(["beast", "venom", "carapace"]),
				"resist": {"physical": 0.92, "fire": 1.10, "poison": 0.50},
				"actions": [
					{"id": "claw", "label": "claws", "weight": 0.52, "damage_type": "physical", "power_mult": 0.92},
					{"id": "tail_sting", "label": "tail-stings", "weight": 0.48, "damage_type": "poison", "power_mult": 0.84, "status": "poison", "status_turns": 2, "status_chance": 0.44},
				],
			}
		"sand_wyrms":
			return {
				"tags": PackedStringArray(["beast", "sand"]),
				"resist": {"physical": 0.90, "fire": 0.92, "poison": 0.80},
				"actions": [
					{"id": "bite", "label": "bites", "weight": 0.62, "damage_type": "physical", "power_mult": 1.14},
					{"id": "sandblast", "label": "sandblasts", "weight": 0.38, "damage_type": "physical", "power_mult": 0.90, "target_mode": "all"},
				],
			}
		"sun_cultists":
			return {
				"tags": PackedStringArray(["humanoid", "fire"]),
				"resist": {"physical": 1.0, "fire": 0.68, "poison": 1.06},
				"actions": [
					{"id": "torch", "label": "burns", "weight": 0.54, "damage_type": "fire", "power_mult": 0.98},
					{"id": "ember_wave", "label": "casts ember wave at", "weight": 0.46, "damage_type": "fire", "power_mult": 0.86, "target_mode": "all"},
				],
			}
		"ooze_spirits":
			return {
				"tags": PackedStringArray(["spirit", "ooze"]),
				"resist": {"physical": 0.82, "fire": 1.20, "poison": 0.50},
				"actions": [
					{"id": "splash", "label": "splashes", "weight": 0.74, "damage_type": "physical", "power_mult": 0.84},
					{"id": "acid", "label": "sprays acid at", "weight": 0.26, "damage_type": "poison", "power_mult": 0.90},
				],
			}
		"wraiths":
			return {
				"tags": PackedStringArray(["undead", "spirit"]),
				"resist": {"physical": 1.12, "fire": 0.92, "poison": 0.20},
				"actions": [
					{"id": "drain_touch", "label": "drains", "weight": 0.70, "damage_type": "arcane", "power_mult": 0.98},
					{"id": "dread", "label": "emanates dread at", "weight": 0.30, "damage_type": "arcane", "power_mult": 0.76, "target_mode": "all"},
				],
			}
		"swarm":
			return {
				"tags": PackedStringArray(["swarm"]),
				"resist": {"physical": 1.12, "fire": 0.76, "poison": 0.72},
				"actions": [
					{"id": "swarm_bite", "label": "swarm", "weight": 0.86, "damage_type": "physical", "power_mult": 0.76},
					{"id": "mass_swarm", "label": "swarm the whole party", "weight": 0.14, "damage_type": "physical", "power_mult": 0.64, "target_mode": "all"},
				],
			}
		"carapace":
			return {
				"tags": PackedStringArray(["beast", "carapace"]),
				"resist": {"physical": 0.86, "fire": 1.08, "poison": 0.82},
				"actions": [
					{"id": "pinch", "label": "pinches", "weight": 0.66, "damage_type": "physical", "power_mult": 0.95},
					{"id": "shell_bash", "label": "shell-bashes", "weight": 0.34, "damage_type": "physical", "power_mult": 1.06},
				],
			}
		"desert_hunters":
			return {
				"tags": PackedStringArray(["beast", "desert"]),
				"resist": {"physical": 0.98, "fire": 0.88, "poison": 0.86},
				"actions": [
					{"id": "pounce", "label": "pounces on", "weight": 0.68, "damage_type": "physical", "power_mult": 1.02},
					{"id": "dust_pounce", "label": "kicks dust at", "weight": 0.32, "damage_type": "physical", "power_mult": 0.80, "target_mode": "all"},
				],
			}
		_:
			return {
				"tags": PackedStringArray(["beast"]),
				"resist": {"physical": 1.0, "fire": 1.0, "poison": 1.0},
				"actions": [
					{"id": "attack", "label": "hits", "weight": 1.0, "damage_type": "physical", "power_mult": 1.0},
				],
			}

static func _normalize_tags(v: Variant) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if typeof(v) != TYPE_ARRAY and typeof(v) != TYPE_PACKED_STRING_ARRAY:
		return out
	for tv in v:
		var s: String = String(tv).strip_edges().to_lower()
		if s.is_empty():
			continue
		out.append(s)
	return out

static func _normalize_resist(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if typeof(v) != TYPE_DICTIONARY:
		return out
	var d: Dictionary = v
	for k in d.keys():
		var key: String = String(k).strip_edges().to_lower()
		if key.is_empty():
			continue
		out[key] = clamp(float(d.get(k, 1.0)), 0.20, 3.00)
	return out

static func _normalize_actions(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for av in v:
		if typeof(av) != TYPE_DICTIONARY:
			continue
		var a: Dictionary = av as Dictionary
		var idv: String = String(a.get("id", "attack")).strip_edges()
		var label: String = String(a.get("label", "hits")).strip_edges()
		var damage_type: String = String(a.get("damage_type", "physical")).to_lower()
		var target_mode: String = String(a.get("target_mode", "single")).to_lower()
		if target_mode != "all":
			target_mode = "single"
		out.append({
			"id": idv if not idv.is_empty() else "attack",
			"label": label if not label.is_empty() else "hits",
			"weight": max(0.0, float(a.get("weight", 1.0))),
			"damage_type": damage_type if not damage_type.is_empty() else "physical",
			"power_mult": clamp(float(a.get("power_mult", 1.0)), 0.20, 3.00),
			"target_mode": target_mode,
			"status": String(a.get("status", "")).to_lower(),
			"status_turns": max(1, int(a.get("status_turns", 1))),
			"status_chance": clamp(float(a.get("status_chance", 0.0)), 0.0, 1.0),
		})
	if out.is_empty():
		out.append({
			"id": "attack",
			"label": "hits",
			"weight": 1.0,
			"damage_type": "physical",
			"power_mult": 1.0,
			"target_mode": "single",
			"status": "",
			"status_turns": 1,
			"status_chance": 0.0,
		})
	return out

static func _is_forest_biome(biome_id: int) -> bool:
	return biome_id == 11 or biome_id == 12 or biome_id == 13 or biome_id == 14 or biome_id == 15 or biome_id == 22 or biome_id == 27

static func _is_mountain_biome(biome_id: int) -> bool:
	return biome_id == 18 or biome_id == 19 or biome_id == 24 or biome_id == 34 or biome_id == 41

static func _is_desert_biome(biome_id: int) -> bool:
	return biome_id == 3 or biome_id == 4 or biome_id == 5 or biome_id == 28
