# File: res://scripts/systems/BiomePost.gd
extends RefCounted

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

func apply_overrides_and_lava(w: int, h: int, is_land: PackedByteArray, temperature: PackedFloat32Array, moisture: PackedFloat32Array, biomes: PackedInt32Array, temp_min_c: float, temp_max_c: float, lava_temp_threshold_c: float) -> Dictionary:
	var out_biomes := biomes
	var lava := PackedByteArray()
	lava.resize(w * h)
	for i in range(w * h):
		lava[i] = 0
	# Hot override >= 30 °C
	var t_hot_c: float = 30.0
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
					out_biomes[i] = BiomeClassifier.Biome.DESERT_SAND if noise_val < sand_prob else BiomeClassifier.Biome.DESERT_ROCK
				else:
					if b == BiomeClassifier.Biome.MOUNTAINS or b == BiomeClassifier.Biome.ALPINE or b == BiomeClassifier.Biome.HILLS or b == BiomeClassifier.Biome.FOOTHILLS:
						if m < 0.35:
							out_biomes[i] = BiomeClassifier.Biome.DESERT_ROCK
						# else keep relief biome
					else:
						out_biomes[i] = BiomeClassifier.Biome.STEPPE
			# Cold override <= 2 °C
			var t_c_cold: float = 2.0
			if t_c <= t_c_cold:
				var m2: float = (moisture[i] if i < moisture.size() else 0.0)
				if m2 >= 0.25:
					out_biomes[i] = BiomeClassifier.Biome.DESERT_ICE
				else:
					out_biomes[i] = BiomeClassifier.Biome.DESERT_ROCK
			# Lava mask
			if t_c >= lava_temp_threshold_c:
				lava[i] = 1
	return {
		"biomes": out_biomes,
		"lava": lava,
	}


