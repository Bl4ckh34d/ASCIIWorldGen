extends RefCounted
class_name HoverInfoController

static func update_label(
	info_label: Label,
	generator: Object,
	x: int,
	y: int,
	show_bedrock_view: bool,
	enable_society_worldgen: bool,
	hover_cache: Dictionary,
	game_state: Node
) -> void:
	if info_label == null or generator == null:
		return
	if not ("get_width" in generator) or not ("get_height" in generator) or not ("get_cell_info" in generator):
		return
	var w: int = int(generator.get_width())
	var h: int = int(generator.get_height())
	if x < 0 or y < 0 or x >= w or y >= h:
		return
	var info_v: Variant = generator.get_cell_info(x, y)
	if typeof(info_v) != TYPE_DICTIONARY:
		return
	var info: Dictionary = info_v as Dictionary
	var coords: String = "(%d,%d)" % [x, y]
	var htxt: String = "%.2f" % float(info.get("height_m", 0.0))
	var humid: float = float(info.get("moisture", 0.0))
	var temp_c: float = float(info.get("temp_c", 0.0))
	var ttxt: String = String(info.get("rock_name", "Unknown Rock")) if show_bedrock_view else String(info.get("biome_name", "Unknown"))
	var flags: PackedStringArray = PackedStringArray()
	if VariantCasts.to_bool(info.get("is_beach", false)):
		flags.append("Beach")
	if VariantCasts.to_bool(info.get("is_lava", false)):
		flags.append("Lava")
	if VariantCasts.to_bool(info.get("is_river", false)):
		flags.append("River")
	if VariantCasts.to_bool(info.get("is_lake", false)):
		flags.append("Lake")
	if VariantCasts.to_bool(info.get("is_plate_boundary", false)):
		flags.append("Tectonic")
	var extra: String = ""
	if flags.size() > 0:
		extra = " - " + ", ".join(flags)

	var geological_info: String = _build_geological_info(info)
	var civ_extra: String = _build_society_info(x, y, enable_society_worldgen, hover_cache, game_state)
	var type_label: String = "Lithology" if show_bedrock_view else "Type"
	info_label.text = "%s - %s - %s: %s - Humidity: %.2f - Temp: %.1f degC%s%s%s" % [coords, htxt, type_label, ttxt, humid, temp_c, extra, geological_info, civ_extra]

static func _build_geological_info(info: Dictionary) -> String:
	var total_plates: int = int(info.get("tectonic_plates", 0))
	var boundary_cells: int = int(info.get("boundary_cells", 0))
	var lava_cells: int = int(info.get("active_lava_cells", 0))
	var eruption_potential: float = float(info.get("eruption_potential", 0.0))
	if total_plates <= 0 and lava_cells <= 0:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	if total_plates > 0:
		parts.append("%d plates" % total_plates)
	if boundary_cells > 0:
		parts.append("%d boundaries" % boundary_cells)
	if lava_cells > 0:
		parts.append("%d lava cells" % lava_cells)
	if eruption_potential > 0.01:
		parts.append("%.1f%% volcanic" % eruption_potential)
	return (" | " + ", ".join(parts)) if parts.size() > 0 else ""

static func _build_society_info(
	x: int,
	y: int,
	enable_society_worldgen: bool,
	hover_cache: Dictionary,
	game_state: Node
) -> String:
	if not enable_society_worldgen or game_state == null:
		return ""
	var key: String = "%d,%d" % [x, y]
	var civ: Dictionary = {}
	var cached: Variant = hover_cache.get(key)
	if typeof(cached) == TYPE_DICTIONARY:
		civ = cached as Dictionary
	elif game_state.has_method("get_society_debug_tile"):
		var cv: Variant = game_state.get_society_debug_tile(x, y)
		if typeof(cv) == TYPE_DICTIONARY:
			civ = cv as Dictionary
			hover_cache[key] = civ
	if civ.is_empty():
		return ""

	var wild: float = float(civ.get("wildlife", -1.0))
	var pop: float = float(civ.get("human_pop", -1.0))
	var lvl: String = _settlement_label_for_pop(pop)
	var out: String = ""
	if wild >= 0.0 or pop >= 0.0:
		out = " | Wild: %.2f | Humans: %.1f%s" % [max(0.0, wild), max(0.0, pop), (" (%s)" % lvl) if not lvl.is_empty() else ""]
	var war_p: float = float(civ.get("war_pressure", -1.0))
	var dev: float = float(civ.get("devastation", -1.0))
	var tech: float = float(civ.get("tech_level", -1.0))
	if war_p >= 0.0:
		out += " | War: %.2f" % clamp(war_p, 0.0, 1.0)
	if dev >= 0.0:
		out += " | Dev: %.2f" % clamp(dev, 0.0, 1.0)
	if tech >= 0.0:
		out += " | Tech: %.2f" % clamp(tech, 0.0, 1.0)
	if game_state.has_method("get_civilization_epoch_info"):
		var ev: Variant = game_state.get_civilization_epoch_info()
		if typeof(ev) == TYPE_DICTIONARY:
			var epoch: Dictionary = ev as Dictionary
			var eid: String = String(epoch.get("epoch_id", ""))
			if not eid.is_empty():
				out += " | Epoch: %s" % eid
	if game_state.has_method("get_political_state_id_at"):
		var stid: String = String(game_state.get_political_state_id_at(x, y))
		if not stid.is_empty():
			out += " | State: %s" % stid
	return out

static func _settlement_label_for_pop(pop: float) -> String:
	if pop >= 80.0:
		return "City"
	if pop >= 30.0:
		return "Village"
	if pop >= 10.0:
		return "Camp"
	if pop > 0.5:
		return "Band"
	return ""
