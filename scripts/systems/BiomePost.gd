# File: res://scripts/systems/BiomePost.gd
extends RefCounted

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

func apply_overrides_and_lava(w: int, h: int, is_land: PackedByteArray, temperature: PackedFloat32Array, moisture: PackedFloat32Array, biomes: PackedInt32Array, temp_min_c: float, temp_max_c: float, lava_temp_threshold_c: float, lake_mask: PackedByteArray = PackedByteArray()) -> Dictionary:
	var out_biomes := biomes
	var lava := PackedByteArray()
	lava.resize(w * h)
	for i in range(w * h):
		lava[i] = 0
	# Hot override >= 45 °C (do not dry out below this)
	var t_hot_c: float = 45.0
	# Frozen/scorched thresholds for variant assignment
	var t_frozen_c: float = -5.0
	var t_scorched_c: float = 45.0
	var n := FastNoiseLite.new()
	# Deterministic seed derived from temp range
	n.seed = int(int(temp_min_c) ^ int(temp_max_c)) ^ 0xBEEF
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.008
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if is_land.size() != w * h or is_land[i] == 0:
				continue
			var t_norm: float = (temperature[i] if i < temperature.size() else 0.5)
			var t_c: float = temp_min_c + t_norm * (temp_max_c - temp_min_c)
			if t_c >= t_hot_c and t_c < lava_temp_threshold_c:
				var m: float = (moisture[i] if i < moisture.size() else 0.5)
				var b: int = out_biomes[i]
				if m < 0.40:
					var hot: float = clamp((t_norm - 0.60) * 2.4, 0.0, 1.0)
					var noise_val: float = n.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
					var sand_prob: float = clamp(0.25 + 0.6 * hot, 0.0, 0.98)
					out_biomes[i] = BiomeClassifier.Biome.DESERT_SAND if noise_val < sand_prob else BiomeClassifier.Biome.WASTELAND
				else:
					if b == BiomeClassifier.Biome.MOUNTAINS or b == BiomeClassifier.Biome.ALPINE or b == BiomeClassifier.Biome.HILLS:
						if m < 0.35:
							out_biomes[i] = BiomeClassifier.Biome.WASTELAND
						# else keep relief biome
					else:
						out_biomes[i] = BiomeClassifier.Biome.STEPPE
			# Cold handling: prefer frozen variants of the underlying biome over Ice Desert
			if t_c <= t_frozen_c:
				# Keep mountainous glaciers as is
				if out_biomes[i] != BiomeClassifier.Biome.GLACIER:
					match out_biomes[i]:
						BiomeClassifier.Biome.SWAMP:
							out_biomes[i] = BiomeClassifier.Biome.FROZEN_MARSH
						BiomeClassifier.Biome.BOREAL_FOREST, BiomeClassifier.Biome.CONIFER_FOREST, BiomeClassifier.Biome.TEMPERATE_FOREST, BiomeClassifier.Biome.RAINFOREST, BiomeClassifier.Biome.TROPICAL_FOREST:
							out_biomes[i] = BiomeClassifier.Biome.FROZEN_FOREST
						BiomeClassifier.Biome.GRASSLAND:
							out_biomes[i] = BiomeClassifier.Biome.FROZEN_GRASSLAND
						BiomeClassifier.Biome.STEPPE:
							out_biomes[i] = BiomeClassifier.Biome.FROZEN_STEPPE
						BiomeClassifier.Biome.SAVANNA:
							out_biomes[i] = BiomeClassifier.Biome.FROZEN_SAVANNA
						BiomeClassifier.Biome.HILLS:
							out_biomes[i] = BiomeClassifier.Biome.FROZEN_HILLS
			elif t_c >= t_scorched_c and lava[i] == 0:
				match out_biomes[i]:
					BiomeClassifier.Biome.GRASSLAND:
						out_biomes[i] = BiomeClassifier.Biome.SCORCHED_GRASSLAND
					BiomeClassifier.Biome.STEPPE:
						out_biomes[i] = BiomeClassifier.Biome.SCORCHED_STEPPE
					# Meadow/Prairie merged into Grassland
					BiomeClassifier.Biome.SAVANNA:
						out_biomes[i] = BiomeClassifier.Biome.SCORCHED_SAVANNA
					BiomeClassifier.Biome.HILLS:
						out_biomes[i] = BiomeClassifier.Biome.SCORCHED_HILLS
					# Foothills merged into Hills
			# Lava mask
			if t_c >= lava_temp_threshold_c:
				lava[i] = 1
			# Salt desert: where lakes existed and dried under heat on land (but not lava)
			if lava[i] == 0 and lake_mask.size() == w * h and lake_mask[i] != 0 and t_c >= 53.0 and t_c < lava_temp_threshold_c:
				out_biomes[i] = BiomeClassifier.Biome.SALT_DESERT
	return {
		"biomes": out_biomes,
		"lava": lava,
	}
