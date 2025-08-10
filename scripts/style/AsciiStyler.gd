# File: res://scripts/style/AsciiStyler.gd
extends RefCounted

## Turns world arrays into a colored ASCII string

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

func color_for_water(h_val: float, sea_level: float, is_turq: bool, turq_strength: float, dist_to_land: float, depth_scale: float) -> Color:
	var depth: float = sea_level - h_val
	var t: float = clamp(depth / 0.8, 0.0, 1.0)
	var deep := Color(0.02, 0.10, 0.25)
	var shallow := Color(0.05, 0.65, 0.80)
	var c := deep.lerp(shallow, t)
	# Distance-based deepening: farther from land → darker, limited by depth_scale
	var d_norm: float = 0.0
	if depth_scale > 0.0:
		d_norm = clamp(dist_to_land / depth_scale, 0.0, 1.0)
	if is_turq:
		d_norm *= 0.2
	c = c.lerp(deep, d_norm)
	# Smooth turquoise overlay using strength factor
	if is_turq or turq_strength > 0.0:
		c = c.lerp(Color(0.10, 0.85, 0.95), clamp(turq_strength, 0.0, 0.85))
	return c

func color_for_land(_h_val: float, biome: int, is_beach: bool) -> Color:
	if is_beach:
		# Bright Maldives-like sand, less skin-toned
		return Color(1.0, 0.98, 0.90)
	match biome:
		BiomeClassifier.Biome.ICE_SHEET:
			return Color(0.95, 0.98, 1.0)
		BiomeClassifier.Biome.TROPICAL_FOREST:
			return Color(0.12, 0.78, 0.28)
		BiomeClassifier.Biome.DESERT_SAND:
			return Color(0.90, 0.85, 0.55)
		BiomeClassifier.Biome.DESERT_ROCK:
			return Color(0.70, 0.65, 0.50)
		BiomeClassifier.Biome.DESERT_ICE:
			return Color(0.90, 0.95, 1.0)
		BiomeClassifier.Biome.STEPPE:
			return Color(0.65, 0.75, 0.50)
		BiomeClassifier.Biome.GRASSLAND, BiomeClassifier.Biome.MEADOW, BiomeClassifier.Biome.PRAIRIE:
			return Color(0.20, 0.80, 0.20)
		BiomeClassifier.Biome.SWAMP:
			return Color(0.25, 0.45, 0.25)
		BiomeClassifier.Biome.BOREAL_FOREST:
			return Color(0.20, 0.55, 0.25)
		BiomeClassifier.Biome.CONIFER_FOREST:
			return Color(0.18, 0.65, 0.28)
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return Color(0.15, 0.70, 0.25)
		BiomeClassifier.Biome.RAINFOREST:
			return Color(0.10, 0.75, 0.30)
		BiomeClassifier.Biome.HILLS:
			return Color(0.35, 0.55, 0.25)
		BiomeClassifier.Biome.FOOTHILLS:
			return Color(0.45, 0.55, 0.30)
		BiomeClassifier.Biome.MOUNTAINS:
			return Color(0.50, 0.50, 0.50)
		BiomeClassifier.Biome.ALPINE:
			return Color(0.85, 0.85, 0.90)
		_:
			return Color(0.30, 0.70, 0.25)

func _glyph_for_biome(biome: int, is_beach: bool) -> String:
	if is_beach:
		return "░"
	match biome:
		BiomeClassifier.Biome.ICE_SHEET:
			return "~"
		BiomeClassifier.Biome.TROPICAL_FOREST:
			return "T"
		BiomeClassifier.Biome.DESERT_SAND:
			return "."
		BiomeClassifier.Biome.DESERT_ROCK:
			return ":"
		BiomeClassifier.Biome.DESERT_ICE:
			return "*"
		BiomeClassifier.Biome.STEPPE:
			return ","
		BiomeClassifier.Biome.MEADOW:
			return ";"
		BiomeClassifier.Biome.PRAIRIE:
			return ","
		BiomeClassifier.Biome.GRASSLAND:
			return "'"
		BiomeClassifier.Biome.SWAMP:
			return "~"
		BiomeClassifier.Biome.BOREAL_FOREST:
			return "^"
		BiomeClassifier.Biome.CONIFER_FOREST:
			return "A"
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return "Y"
		BiomeClassifier.Biome.RAINFOREST:
			return "R"
		BiomeClassifier.Biome.HILLS:
			return "+"
		BiomeClassifier.Biome.FOOTHILLS:
			return "+"
		BiomeClassifier.Biome.MOUNTAINS:
			return "M"
		BiomeClassifier.Biome.ALPINE:
			return "^"
		_:
			return "░"

func _hash2(x: int, y: int, s: int) -> int:
	var v: int = int(x) * 73856093 ^ int(y) * 19349663 ^ int(s) * 83492791
	return abs(v)

func _chars_for_water() -> PackedStringArray:
	return PackedStringArray(["~", "~", "~", "-", "_", "~"])

func _chars_for_biome(biome: int, is_beach: bool) -> PackedStringArray:
	if is_beach:
		return PackedStringArray(["·", ".", ":"]) 
	match biome:
		BiomeClassifier.Biome.DESERT_SAND:
			return PackedStringArray([".", ":", "·", ","])
		BiomeClassifier.Biome.DESERT_ROCK:
			return PackedStringArray([":", ";", "."])
		BiomeClassifier.Biome.DESERT_ICE:
			return PackedStringArray(["*", "°", "·"])
		BiomeClassifier.Biome.STEPPE:
			return PackedStringArray([",", "'", "."])
		BiomeClassifier.Biome.MEADOW:
			return PackedStringArray(["'", ","])
		BiomeClassifier.Biome.PRAIRIE:
			return PackedStringArray(["'", ","])
		BiomeClassifier.Biome.GRASSLAND:
			return PackedStringArray(["'", "`"]) 
		BiomeClassifier.Biome.SWAMP:
			return PackedStringArray(["~", ",", "."]) 
		BiomeClassifier.Biome.BOREAL_FOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.CONIFER_FOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.RAINFOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.TROPICAL_FOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.HILLS:
			return PackedStringArray(["+", "^"]) 
		BiomeClassifier.Biome.FOOTHILLS:
			return PackedStringArray(["+", "^"]) 
		BiomeClassifier.Biome.MOUNTAINS:
			return PackedStringArray(["^", "+"]) 
		BiomeClassifier.Biome.ALPINE:
			return PackedStringArray(["^", "*"]) 
		_:
			return PackedStringArray(["'"])

func glyph_for(x: int, y: int, is_land: bool, biome_id: int, is_beach: bool, rng_seed: int) -> String:
	if is_land:
		var set_l: PackedStringArray = _chars_for_biome(biome_id, is_beach)
		var idx_l: int = _hash2(x, y, rng_seed) % max(1, set_l.size())
		return set_l[idx_l]
	else:
		var set_w: PackedStringArray = _chars_for_water()
		var idx_w: int = _hash2(x, y, rng_seed) % max(1, set_w.size())
		return set_w[idx_w]

func build_ascii(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, is_turq: PackedByteArray, turq_strength: PackedFloat32Array, is_beach: PackedByteArray, water_distance: PackedFloat32Array, biomes: PackedInt32Array, sea_level: float, rng_seed: int, river_mask: PackedByteArray = PackedByteArray(), temperature: PackedFloat32Array = PackedFloat32Array(), temp_min_c: float = 0.0, temp_max_c: float = 1.0) -> String:
	var sb: PackedStringArray = []
	var depth_scale: float = max(8.0, float(min(w, h)) / 3.0)
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var land := (i < is_land.size()) and is_land[i] != 0
			var biome_id: int = (biomes[i] if i < biomes.size() else 0)
			var beach_flag: bool = (i < is_beach.size()) and is_beach[i] != 0
			var hv: float = (height[i] if i < height.size() else 0.0)
			var glyph := "~"
			if land:
				var set_l: PackedStringArray = _chars_for_biome(biome_id, beach_flag)
				var idx_l: int = _hash2(x, y, rng_seed) % max(1, set_l.size())
				glyph = set_l[idx_l]
			else:
				var set_w: PackedStringArray = _chars_for_water()
				var idx_w: int = _hash2(x, y, rng_seed) % max(1, set_w.size())
				glyph = set_w[idx_w]
			# Rivers override land glyph only (keep underlying terrain color)
			var is_river: bool = (i < river_mask.size()) and (river_mask[i] != 0) and land and not beach_flag
			if is_river:
				glyph = "≈"
			# Ocean ice sheet override: draw ocean cells tagged as ICE_SHEET in white
			var ocean_ice: bool = (not land) and (i < biomes.size()) and (biomes[i] == BiomeClassifier.Biome.ICE_SHEET)
			var color := color_for_land(hv, biome_id, beach_flag) if land else color_for_water(hv, sea_level, (i < is_turq.size()) and is_turq[i] != 0, (turq_strength[i] if i < turq_strength.size() else 0.0), (water_distance[i] if i < water_distance.size() else 0.0), depth_scale)
			if ocean_ice:
				color = Color(1, 1, 1)
			# Temperature-based whitening for very cold land (<= -10°C)
			if land and temperature.size() == w * h:
				var t_norm: float = temperature[i]
				var t_c: float = temp_min_c + t_norm * (temp_max_c - temp_min_c)
				if t_c <= -10.0:
					color = Color(1, 1, 1)
			sb.append("[color=" + color.to_html(false) + "]" + glyph + "[/color]")
		sb.append("\n")
	return "".join(sb)
