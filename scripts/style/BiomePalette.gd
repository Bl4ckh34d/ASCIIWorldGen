# File: res://scripts/style/BiomePalette.gd
extends RefCounted

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

func color_for_biome(biome: int, is_beach: bool) -> Color:
	if is_beach:
		return Color(1.0, 0.98, 0.90)
	match biome:
		BiomeClassifier.Biome.ICE_SHEET:
			return Color(0.95, 0.98, 1.0)
		BiomeClassifier.Biome.GLACIER:
			return Color(0.96, 0.99, 1.0)
		BiomeClassifier.Biome.TUNDRA:
			return Color(0.85, 0.90, 0.85)
		BiomeClassifier.Biome.SAVANNA:
			return Color(0.60, 0.70, 0.35)
		BiomeClassifier.Biome.FROZEN_FOREST:
			return Color(0.88, 0.94, 0.92)
		BiomeClassifier.Biome.FROZEN_MARSH:
			return Color(0.90, 0.95, 0.96)
		BiomeClassifier.Biome.TROPICAL_FOREST:
			return Color(0.12, 0.78, 0.28)
		BiomeClassifier.Biome.DESERT_SAND:
			return Color(0.90, 0.85, 0.55)
		BiomeClassifier.Biome.WASTELAND:
			return Color(0.70, 0.65, 0.50)
		BiomeClassifier.Biome.DESERT_ICE:
			return Color(0.90, 0.95, 1.0)
		BiomeClassifier.Biome.STEPPE:
			return Color(0.65, 0.75, 0.50)
		BiomeClassifier.Biome.GRASSLAND:
			return Color(0.20, 0.80, 0.20)
		BiomeClassifier.Biome.SWAMP:
			return Color(0.25, 0.45, 0.25)
		BiomeClassifier.Biome.BOREAL_FOREST:
			return Color(0.20, 0.55, 0.25)
		# Conifer merged into Boreal
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return Color(0.15, 0.70, 0.25)
		BiomeClassifier.Biome.RAINFOREST:
			return Color(0.10, 0.75, 0.30)
		BiomeClassifier.Biome.HILLS:
			return Color(0.35, 0.55, 0.25)
		# Foothills merged into Hills
		BiomeClassifier.Biome.MOUNTAINS:
			return Color(0.50, 0.50, 0.50)
		BiomeClassifier.Biome.ALPINE:
			return Color(0.85, 0.85, 0.90)
		# Frozen variants
		BiomeClassifier.Biome.FROZEN_FOREST:
			return Color(0.88, 0.94, 0.96)
		BiomeClassifier.Biome.FROZEN_MARSH:
			return Color(0.90, 0.95, 0.98)
		BiomeClassifier.Biome.FROZEN_GRASSLAND:
			# Keep frozen grass in the same cool, desaturated family as frozen forest/steppe.
			return Color(0.87, 0.93, 0.95)
		BiomeClassifier.Biome.FROZEN_STEPPE:
			return Color(0.85, 0.90, 0.96)
		# Frozen Meadow/Prairie merged into Frozen Grassland
		BiomeClassifier.Biome.FROZEN_SAVANNA:
			return Color(0.86, 0.92, 0.95)
		BiomeClassifier.Biome.FROZEN_HILLS:
			return Color(0.88, 0.92, 0.96)
		# Scorched variants
		BiomeClassifier.Biome.SCORCHED_GRASSLAND:
			return Color(0.72, 0.62, 0.34)
		BiomeClassifier.Biome.SCORCHED_STEPPE:
			return Color(0.74, 0.64, 0.37)
		# Scorched Meadow/Prairie merged into Scorched Grassland
		BiomeClassifier.Biome.SCORCHED_SAVANNA:
			return Color(0.78, 0.69, 0.40)
		BiomeClassifier.Biome.SCORCHED_HILLS:
			return Color(0.66, 0.57, 0.36)
		BiomeClassifier.Biome.LAVA_FIELD:
			return Color(0.14, 0.13, 0.12)
		BiomeClassifier.Biome.SALT_DESERT:
			# Bright saline crust: white with slight cyan hint
			return Color(0.95, 0.97, 1.0)
		_:
			return Color(0.30, 0.70, 0.25)
