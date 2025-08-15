# File: res://scripts/style/AsciiStyler.gd
extends RefCounted

## Turns world arrays into a colored ASCII string
## This version fixes "Unexpected identifier 'sb' in class body" by making
## sure all PackedStringArray usage is *inside* functions and adds an optional
## GPU light-field multiplier (brightness per tile).

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")
const BiomePalette = preload("res://scripts/style/BiomePalette.gd")
const WaterPalette = preload("res://scripts/style/WaterPalette.gd")

# -------------------- Helpers --------------------

static func _safe_size(arr) -> int:
	if typeof(arr) == TYPE_NIL:
		return 0
	if arr is PackedByteArray or arr is PackedFloat32Array or arr is PackedInt32Array:
		return arr.size()
	return 0

static func _has_tile(arr, i: int) -> bool:
	return _safe_size(arr) > i

func _glyph_for_biome(biome: int, is_beach: bool) -> String:
	if is_beach:
		return "."
	match biome:
		BiomeClassifier.Biome.OCEAN: return "≈"
		BiomeClassifier.Biome.ICE_SHEET: return "░"
		BiomeClassifier.Biome.DESERT_SAND: return ":"
		BiomeClassifier.Biome.WASTELAND: return ";"
		BiomeClassifier.Biome.GRASSLAND: return ","
		BiomeClassifier.Biome.SAVANNA: return "`"
		BiomeClassifier.Biome.STEPPE: return "'"
		BiomeClassifier.Biome.SWAMP: return "~"
		BiomeClassifier.Biome.TEMPERATE_FOREST: return "Y"
		BiomeClassifier.Biome.BOREAL_FOREST: return "Y"
		BiomeClassifier.Biome.RAINFOREST: return "R"
		BiomeClassifier.Biome.HILLS: return "+"
		BiomeClassifier.Biome.MOUNTAINS: return "M"
		BiomeClassifier.Biome.ALPINE: return "^"
		_:
			return "#"  # default

# -------------------- Color helpers --------------------

func _color_for_land(h_val: float, biome: int, is_beach: bool) -> Color:
	return BiomePalette.new().color_for_biome(biome, is_beach)

func _color_for_water(
		h_val: float,
		sea_level: float,
		is_turq: bool,
		turq_strength: float,
		dist_to_land: float,
		depth_scale: float,
		shelf_value: float
	) -> Color:
	return WaterPalette.new().color_for_water(
		h_val, sea_level, is_turq, turq_strength, dist_to_land, depth_scale, shelf_value
	)

# -------------------- Main render --------------------
# Keep signature compatible with Main.gd call (22 args incl. lake_freeze and clouds).
# You can pass fewer; defaults will be used. An optional light_field is supported at the end.

func build_ascii(
		w: int,
		h: int,
		height: PackedFloat32Array,
		is_land: PackedByteArray,
		turquoise_mask: PackedByteArray = PackedByteArray(),
		turquoise_strength: PackedFloat32Array = PackedFloat32Array(),
		beach_mask: PackedByteArray = PackedByteArray(),
		water_distance: PackedFloat32Array = PackedFloat32Array(),
		biomes: PackedInt32Array = PackedInt32Array(),
		sea_level: float = 0.0,
		rng_seed: int = 0,
		temperature: PackedFloat32Array = PackedFloat32Array(),
		temp_min_c: float = -20.0,
		temp_max_c: float = 40.0,
		shelf_noise: PackedFloat32Array = PackedFloat32Array(),
		lake_mask: PackedByteArray = PackedByteArray(),
		river_mask: PackedByteArray = PackedByteArray(),
		pooled_lake_mask: PackedByteArray = PackedByteArray(),
		lava_mask: PackedByteArray = PackedByteArray(),
		clouds: PackedFloat32Array = PackedFloat32Array(),
		lake_freeze: PackedByteArray = PackedByteArray(),
		light_field: PackedFloat32Array = PackedFloat32Array()
	) -> String:
	var sb: PackedStringArray = PackedStringArray()
	var use_light: bool = light_field.size() == w * h
	var total: int = w * h
	var have_height: bool = _safe_size(height) == total
	var have_land: bool = _safe_size(is_land) == total
	var have_biome: bool = _safe_size(biomes) == total
	var have_beach: bool = _safe_size(beach_mask) == total
	var have_turq: bool = _safe_size(turquoise_mask) == total
	var have_turq_strength: bool = _safe_size(turquoise_strength) == total
	var have_water_dist: bool = _safe_size(water_distance) == total
	var have_shelf: bool = _safe_size(shelf_noise) == total
	var have_lake: bool = _safe_size(lake_mask) == total
	var have_river: bool = _safe_size(river_mask) == total
	var have_pool: bool = _safe_size(pooled_lake_mask) == total
	var have_lava: bool = _safe_size(lava_mask) == total
	var have_clouds: bool = _safe_size(clouds) == total
	var have_freeze: bool = _safe_size(lake_freeze) == total

	for y in range(h):
		for x in range(w):
			var i: int = x + y * w

			# defaults
			var glyph: String = " "
			var col: Color = Color(1,1,1,1)

			if have_land and have_height:
				if is_land[i] == 1:
					var biome_id: int = (biomes[i] if have_biome else BiomeClassifier.Biome.GRASSLAND)
					var is_beach: bool = have_beach and beach_mask[i] == 1
					col = _color_for_land(height[i], biome_id, is_beach)
					glyph = _glyph_for_biome(biome_id, is_beach)

					# lakes (override water visuals on land tiles marked as lakes)
					if have_lake and lake_mask[i] == 1:
						var is_frozen: bool = have_freeze and lake_freeze[i] == 1
						var shelf_val: float = (shelf_noise[i] if have_shelf else 0.0)
						col = (Color(0.75,0.85,0.9) if is_frozen else _color_for_water(height[i], sea_level, false, 0.0, 0.0, 1.0, shelf_val))
						glyph = ("░" if is_frozen else "≈")

					# rivers overlay (tint)
					if have_river and river_mask[i] == 1:
						col = col.lerp(Color(0.25,0.55,0.95), 0.65)
						glyph = "≈"

					# lava overlay
					if have_lava and lava_mask[i] == 1:
						col = col.lerp(Color(1.0, 0.35, 0.1), 0.85)
						glyph = "≈"
				else:
					# water tile
					var is_turq: bool = have_turq and turquoise_mask[i] == 1
					var turq_s: float = (turquoise_strength[i] if have_turq_strength else 0.0)
					var dist: float = (water_distance[i] if have_water_dist else 0.0)
					var shelf_val: float = (shelf_noise[i] if have_shelf else 0.0)
					col = _color_for_water(height[i], sea_level, is_turq, turq_s, dist, 1.0, shelf_val)
					glyph = "≈"

					# ocean ice sheet (if biome classifies as ice over ocean)
					if have_biome and biomes[i] == BiomeClassifier.Biome.ICE_SHEET:
						col = Color(0.85, 0.90, 0.95)
						glyph = "░"

			# Apply optional cloud shading (very light)
			if have_clouds:
				var c: float = clamp(clouds[i], 0.0, 1.0)
				if c > 0.0:
					col = col.lerp(Color(1,1,1,1), c * 0.25)

			# Optional light field multiplier (day/night)
			if use_light:
				var b: float = clamp(light_field[i], 0.0, 1.0)
				col = Color(col.r * b, col.g * b, col.b * b, col.a)

			sb.append("[color=%s]%s[/color]" % [col.to_html(true), glyph])
		sb.append("\n")

	return "".join(sb)

# Simple cloud-only overlay (if you need a separate layer)
func build_cloud_overlay(w: int, h: int, clouds: PackedFloat32Array) -> String:
	var sb: PackedStringArray = PackedStringArray()
	var has_buf := clouds.size() == w * h
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var c: float = (clamp(clouds[i], 0.0, 1.0) if has_buf else 0.0)
			if c > 0.0:
				var col := Color(1.0, 1.0, 1.0, 1.0)
				sb.append("[color=%s]█[/color]" % col.to_html(true))
			else:
				sb.append(" ")
		sb.append("\n")
	return "".join(sb)

# Public API used by Main.gd to fetch a single glyph for a tile.
# Kept simple and deterministic; extend with per-biome char sets if you want variety.
func glyph_for(x: int, y: int, is_land: bool, biome_id: int, is_beach: bool, rng_seed: int) -> String:
	if not is_land:
		return "≈"
	return _glyph_for_biome(biome_id, is_beach)

# Deterministic tiny hash if needed in the future for randomized glyph choices
static func _hash2(x: int, y: int, seed: int) -> int:
	var h: int = seed ^ (x * 374761393) ^ (y * 668265263)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return h & 0x7fffffff
