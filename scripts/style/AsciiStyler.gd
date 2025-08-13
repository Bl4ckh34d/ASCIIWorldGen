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
		BiomeClassifier.Biome.WASTELAND:
			return ":"
		BiomeClassifier.Biome.DESERT_ICE:
			return "*"
		BiomeClassifier.Biome.STEPPE:
			return ","
		BiomeClassifier.Biome.GRASSLAND:
			return "'"
		BiomeClassifier.Biome.SWAMP:
			return "~"
		BiomeClassifier.Biome.BOREAL_FOREST:
			return "^"
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return "Y"
		BiomeClassifier.Biome.RAINFOREST:
			return "R"
		BiomeClassifier.Biome.HILLS:
			return "+"
		BiomeClassifier.Biome.MOUNTAINS:
			return "M"
		BiomeClassifier.Biome.ALPINE:
			return "^"
		BiomeClassifier.Biome.FROZEN_GRASSLAND, BiomeClassifier.Biome.FROZEN_STEPPE, BiomeClassifier.Biome.FROZEN_SAVANNA:
			return "*"
		BiomeClassifier.Biome.FROZEN_HILLS:
			return "^"
		BiomeClassifier.Biome.SCORCHED_GRASSLAND, BiomeClassifier.Biome.SCORCHED_STEPPE, BiomeClassifier.Biome.SCORCHED_SAVANNA:
			return ":"
		BiomeClassifier.Biome.SCORCHED_HILLS:
			return "+"
		BiomeClassifier.Biome.SALT_DESERT:
			return "▫"
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
		BiomeClassifier.Biome.SALT_DESERT:
			# Sparkly bright crust
			return PackedStringArray(["▫", "·", "□"])
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
		BiomeClassifier.Biome.WASTELAND:
			return PackedStringArray([":", ";", "."])
		BiomeClassifier.Biome.DESERT_ICE:
			return PackedStringArray(["*", "°", "·"])
		BiomeClassifier.Biome.STEPPE:
			return PackedStringArray([",", "'", "."])
		# Meadow/Prairie merged into Grassland
		BiomeClassifier.Biome.GRASSLAND:
			return PackedStringArray(["'", "`"]) 
		BiomeClassifier.Biome.SWAMP:
			return PackedStringArray(["~", ",", "."]) 
		BiomeClassifier.Biome.BOREAL_FOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		# Conifer merged into Boreal
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.RAINFOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.TROPICAL_FOREST:
			return PackedStringArray(["^", "†", "‡"]) 
		BiomeClassifier.Biome.HILLS:
			return PackedStringArray(["+", "^"]) 
		# Foothills merged into Hills
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

func build_ascii(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, is_turq: PackedByteArray, turq_strength: PackedFloat32Array, is_beach: PackedByteArray, water_distance: PackedFloat32Array, biomes: PackedInt32Array, _sea_level: float, rng_seed: int, temperature: PackedFloat32Array = PackedFloat32Array(), temp_min_c: float = 0.0, temp_max_c: float = 1.0, shelf_value_noise_field: PackedFloat32Array = PackedFloat32Array(), lake_mask: PackedByteArray = PackedByteArray(), river_mask: PackedByteArray = PackedByteArray(), pooled_lake: PackedByteArray = PackedByteArray(), lava_mask: PackedByteArray = PackedByteArray(), cloud_shadow: PackedFloat32Array = PackedFloat32Array()) -> String:
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
			# Local temperature in Celsius if available
			var t_c_local: float = 0.0
			if temperature.size() == w * h:
				var t_norm_l: float = temperature[i]
				t_c_local = temp_min_c + t_norm_l * (temp_max_c - temp_min_c)
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
			# Heat-driven drying thresholds (delayed by +25 C): start at 60C, full at 85C
			var dry01: float = clamp((t_c_local - 60.0) / 25.0, 0.0, 1.0)
			# Dry rivers/lakes first at high heat
			if river_here and dry01 > 0.8:
				river_here = false
			if lake_here and dry01 > 0.7:
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
				# Lakes: reuse ocean shelf coloring by synthesizing a local shelf mask near lake shores
				var shelf_val: float = _shelf_noise
				if lake_here:
					# Approximate distance to lake shore using height offset from sea level as proxy
					# near edges (land neighbors). Simple 8-neighbor check for land adjacency
					var near_shore: bool = false
					if land: # hydrolake_on_land
						near_shore = true
					else:
						var cx: int = x
						var cy: int = y
						for ddy in range(-1, 2):
							for ddx in range(-1, 2):
								if ddx == 0 and ddy == 0: continue
								var nx: int = cx + ddx
								var ny: int = cy + ddy
								if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
								var ni: int = nx + ny * w
								if i < is_land.size() and is_land[ni] != 0: near_shore = true
								if near_shore: break
							if near_shore: break
					var local_shelf: float = (1.0 if near_shore else 0.0)
					shelf_val = max(shelf_val, local_shelf)
				color = color_for_water(hv, _sea_level, _is_turq_here, _turq_here, (water_distance[i] if i < water_distance.size() else 0.0), _depth_scale, shelf_val)
				# Rivers use the same glyph as ocean for consistency
				if river_here:
					glyph = "~"
				# Freeze thresholds for fresh water and ocean
				var lake_freeze: bool = (lake_here and t_c_local <= -1.0)
				var river_freeze: bool = (river_here and t_c_local <= -15.0)
				var ocean_freeze: bool = ((not land) and (not river_here) and (not lake_here) and t_c_local <= -10.0)
				if lake_freeze or river_freeze or ocean_freeze:
					# Draw frozen water with icy tint
					var ice_col := Color(0.88, 0.93, 1.0)
					color = ice_col
					glyph = "≈"
				# Heat-driven drying colorization for oceans: blend toward sandy color
				var sand_col := Color(0.88, 0.80, 0.55)
				color = Color(
					lerp(color.r, sand_col.r, dry01 * 0.6),
					lerp(color.g, sand_col.g, dry01 * 0.6),
					lerp(color.b, sand_col.b, dry01 * 0.6),
					color.a
				)
			else:
				color = color_for_land(hv, biome_id, beach_flag)
				# Scorched/frozen land tints
				if t_c_local >= 45.0:
					# Scorched land: brown/yellow/grey mix
					var scorch_col := Color(0.65, 0.58, 0.35)
					color = Color(
						lerp(color.r, scorch_col.r, 0.6),
						lerp(color.g, scorch_col.g, 0.6),
						lerp(color.b, scorch_col.b, 0.6),
						color.a
					)
				# Sprinkle 10% lava-looking tiles only at true lava-field temps
				if t_c_local >= 75.0 and (_hash2(x, y, rng_seed ^ 0xA11A) % 10 == 0):
						glyph = "█"
						color = Color(1.0, 0.4, 0.1)
				elif t_c_local <= -5.0:
					# Frozen land: bluish/white tint
					var frost_col := Color(0.80, 0.88, 0.98)
					color = Color(
						lerp(color.r, frost_col.r, 0.55),
						lerp(color.g, frost_col.g, 0.55),
						lerp(color.b, frost_col.b, 0.55),
						color.a
					)
			# Optional lake tint already applied above for draw_as_water branch
			if ocean_ice:
				color = Color(1, 1, 1)
			# Temperature-based whitening for very cold land (<= -10°C)
			if (not draw_as_water) and temperature.size() == w * h:
				var t_norm: float = temperature[i]
				var t_c: float = temp_min_c + t_norm * (temp_max_c - temp_min_c)
				if t_c <= -10.0:
					color = Color(1, 1, 1)
			# Lava colorization: lava fields with occasional bright lava
			if lava_mask.size() == w * h and lava_mask[i] != 0 and land:
				var r10: int = _hash2(x, y, rng_seed ^ 0xCE11) % 10
				if r10 == 0:
					# 10% bright molten tile
					var choice: int = _hash2(x, y, rng_seed ^ 0xACED) % 3
					var lava_col := Color(1.0, 0.2, 0.1)
					if choice == 1:
						lava_col = Color(1.0, 0.5, 0.1)
					elif choice == 2:
						lava_col = Color(1.0, 0.85, 0.15)
					color = lava_col
					glyph = "█"
				else:
					# 90% lava field: dark basalt/rock desert look
					var basalt := Color(0.22, 0.20, 0.18)
					color = Color(
						lerp(color.r, basalt.r, 0.7),
						lerp(color.g, basalt.g, 0.7),
						lerp(color.b, basalt.b, 0.7),
						color.a
					)
					glyph = "▒"
			# Apply cloud shadow as a multiplicative darkening of the base color
			if cloud_shadow.size() == w * h:
				var sh: float = clamp(cloud_shadow[i], 0.0, 1.0)
				var shade_factor: float = clamp(1.0 - 0.35 * sh, 0.0, 1.0)
				color = Color(color.r * shade_factor, color.g * shade_factor, color.b * shade_factor, color.a)
			sb.append("[color=" + color.to_html(false) + "]" + glyph + "[/color]")
		sb.append("\n")
	return "".join(sb)

func build_cloud_overlay(w: int, h: int, clouds: PackedFloat32Array) -> String:
	var sb: PackedStringArray = []
	if clouds.size() != w * h:
		# Empty overlay
		for _y in range(h):
			sb.append("\n")
		return "".join(sb)
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var c: float = clamp(clouds[i], 0.0, 1.0)
			var alpha: float = clamp(0.4 + 0.6 * c, 0.0, 1.0)
			# Choose high-contrast block glyphs by intensity
			var glyph: String = "▒"
			if c > 0.66:
				glyph = "█"
			elif c > 0.33:
				glyph = "▓"
			# Make clouds pink/magenta for visibility
			var col := Color(1.0, 0.3, 0.8, alpha)
			sb.append("[color=" + col.to_html(true) + "]" + glyph + "[/color]")
		sb.append("\n")
	return "".join(sb)
