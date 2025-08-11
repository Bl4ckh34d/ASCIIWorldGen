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


