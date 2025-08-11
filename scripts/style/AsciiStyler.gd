# File: res://scripts/style/AsciiStyler.gd
extends RefCounted

## Turns world arrays into a colored ASCII string

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")
const BiomePalette = preload("res://scripts/style/BiomePalette.gd")
const WaterPalette = preload("res://scripts/style/WaterPalette.gd")

func color_for_water(h_val: float, sea_level: float, is_turq: bool, turq_strength: float, _dist_to_land: float, _depth_scale: float, shelf_pattern: float) -> Color:
	return WaterPalette.new().color_for_water(h_val, sea_level, is_turq, turq_strength, _dist_to_land, _depth_scale, shelf_pattern)

func color_for_land(_h_val: float, biome: int, is_beach: bool) -> Color:
	return BiomePalette.new().color_for_biome(biome, is_beach)

func _glyph_for_biome(biome: int, is_beach: bool) -> String:
	if is_beach:
		return "░"
	match biome:
		BiomeClassifier.Biome.ICE_SHEET:
			return "~"
		BiomeClassifier.Biome.GLACIER:
			return "*"
		BiomeClassifier.Biome.TUNDRA:
			return ","
		BiomeClassifier.Biome.SAVANNA:
			return "'"
		BiomeClassifier.Biome.FROZEN_FOREST:
			return "^"
		BiomeClassifier.Biome.FROZEN_MARSH:
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

func _value_noise2d(x: float, y: float, rng_seed: int, scale: float) -> float:
	var sx: float = x / max(0.0001, scale)
	var sy: float = y / max(0.0001, scale)
	var xi: int = int(floor(sx))
	var yi: int = int(floor(sy))
	var tx: float = sx - float(xi)
	var ty: float = sy - float(yi)
	var h00: float = float(_hash2(xi + 0, yi + 0, rng_seed) % 1000) / 1000.0
	var h10: float = float(_hash2(xi + 1, yi + 0, rng_seed) % 1000) / 1000.0
	var h01: float = float(_hash2(xi + 0, yi + 1, rng_seed) % 1000) / 1000.0
	var h11: float = float(_hash2(xi + 1, yi + 1, rng_seed) % 1000) / 1000.0
	var nx0: float = lerp(h00, h10, tx)
	var nx1: float = lerp(h01, h11, tx)
	return lerp(nx0, nx1, ty)

func _chars_for_water() -> PackedStringArray:
	return PackedStringArray(["~", "~", "~", "-", "_", "~"])

func _chars_for_biome(biome: int, is_beach: bool) -> PackedStringArray:
	if is_beach:
		return PackedStringArray(["·", ".", ":"]) 
	match biome:
		BiomeClassifier.Biome.DESERT_SAND:
			return PackedStringArray([".", ":", "·", ","])
		BiomeClassifier.Biome.GLACIER:
			return PackedStringArray(["*", "°", "·"])
		BiomeClassifier.Biome.TUNDRA:
			return PackedStringArray([",", ".", "·"])
		BiomeClassifier.Biome.SAVANNA:
			return PackedStringArray(["'", ",", "."])
		BiomeClassifier.Biome.FROZEN_FOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.FROZEN_MARSH:
			return PackedStringArray(["~", ",", "."]) 
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

func build_ascii(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, is_turq: PackedByteArray, turq_strength: PackedFloat32Array, is_beach: PackedByteArray, water_distance: PackedFloat32Array, biomes: PackedInt32Array, _sea_level: float, rng_seed: int, temperature: PackedFloat32Array = PackedFloat32Array(), temp_min_c: float = 0.0, temp_max_c: float = 1.0, shelf_value_noise_field: PackedFloat32Array = PackedFloat32Array(), lake_mask: PackedByteArray = PackedByteArray(), river_mask: PackedByteArray = PackedByteArray(), pooled_lake: PackedByteArray = PackedByteArray(), lava_mask: PackedByteArray = PackedByteArray()) -> String:
	var sb: PackedStringArray = []
	var _depth_scale: float = max(8.0, float(min(w, h)) / 3.0)
	# Smooth transition factor across extreme ocean fractions to avoid visual jump
	var ocean_cells: int = 0
	for i0 in range(w * h):
		if i0 < is_land.size() and is_land[i0] == 0:
			ocean_cells += 1
	var ocean_frac: float = float(ocean_cells) / float(max(1, w * h))
	var global_shelf_mix: float = clamp((ocean_frac - 0.0) / 1.0, 0.0, 1.0)
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var land := (i < is_land.size()) and is_land[i] != 0
			var river_here: bool = river_mask.size() == w * h and river_mask[i] != 0
			var hydrolake_on_land: bool = land and (lake_mask.size() == w * h and lake_mask[i] != 0)
			var inland_water_lake: bool = (not land) and (pooled_lake.size() == w * h and pooled_lake[i] != 0)
			var lake_here: bool = hydrolake_on_land or inland_water_lake
			# Exclude ice and lava from lake highlighting
			if biomes.size() == w * h:
				var b: int = biomes[i]
				if b == BiomeClassifier.Biome.ICE_SHEET or b == BiomeClassifier.Biome.DESERT_ICE or b == BiomeClassifier.Biome.GLACIER:
					lake_here = false
			if lava_mask.size() == w * h and lava_mask[i] != 0:
				lake_here = false
			var draw_as_water: bool = (not land) or river_here or lake_here
			var biome_id: int = (biomes[i] if i < biomes.size() else 0)
			var beach_flag: bool = (i < is_beach.size()) and is_beach[i] != 0
			var hv: float = (height[i] if i < height.size() else 0.0)
			var glyph := "~"
			if not draw_as_water:
				var set_l: PackedStringArray = _chars_for_biome(biome_id, beach_flag)
				var idx_l: int = _hash2(x, y, rng_seed) % max(1, set_l.size())
				glyph = set_l[idx_l]
			else:
				var set_w: PackedStringArray = _chars_for_water()
				var idx_w: int = _hash2(x, y, rng_seed) % max(1, set_w.size())
				glyph = set_w[idx_w]
			# Ocean ice sheet override: draw ocean cells tagged as ICE_SHEET in white
			var ocean_ice: bool = (not land) and (i < biomes.size()) and (biomes[i] == BiomeClassifier.Biome.ICE_SHEET)
			var shelf_mask: float = 0.0
			if not land:
				var dist: float = (water_distance[i] if i < water_distance.size() else 0.0)
				# Blend shelf mask by global ocean coverage to avoid a hard cut near full-ocean
				var local_mask: float = 1.0 - clamp(dist / 14.0, 0.0, 1.0)
				shelf_mask = clamp(lerp(local_mask, 0.0, pow(global_shelf_mix, 1.5)), 0.0, 1.0)
			var _shelf_noise: float = 0.0
			if shelf_mask > 0.0:
				# Prefer prebuilt shelf noise if available
				if shelf_value_noise_field.size() == w * h:
					_shelf_noise = shelf_value_noise_field[i] * shelf_mask
				else:
					_shelf_noise = _value_noise2d(float(x), float(y), rng_seed ^ 0x5E1F, 20.0) * shelf_mask
			var color := Color(1,1,1)
			if draw_as_water:
				var _is_turq_here: bool = (i < is_turq.size()) and is_turq[i] != 0
				var _turq_here: float = (turq_strength[i] if i < turq_strength.size() else 0.0)
				# Color all water (sea, ocean, lakes, rivers) using the same ocean water palette
				color = color_for_water(hv, _sea_level, _is_turq_here, _turq_here, (water_distance[i] if i < water_distance.size() else 0.0), _depth_scale, _shelf_noise)
				# Rivers use the same glyph as ocean for consistency
				if river_here:
					glyph = "~"
			else:
				color = color_for_land(hv, biome_id, beach_flag)
			# Optional lake tint already applied above for draw_as_water branch
			if ocean_ice:
				color = Color(1, 1, 1)
			# Temperature-based whitening for very cold land (<= -10°C)
			if (not draw_as_water) and temperature.size() == w * h:
				var t_norm: float = temperature[i]
				var t_c: float = temp_min_c + t_norm * (temp_max_c - temp_min_c)
				if t_c <= -10.0:
					color = Color(1, 1, 1)
			sb.append("[color=" + color.to_html(false) + "]" + glyph + "[/color]")
		sb.append("\n")
	return "".join(sb)
