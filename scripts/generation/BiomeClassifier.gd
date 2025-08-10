# File: res://scripts/generation/BiomeClassifier.gd
extends RefCounted

enum Biome {
	OCEAN,
	ICE_SHEET,
	BEACH,
	DESERT_SAND,
	DESERT_ROCK,
	DESERT_ICE,
	STEPPE,
	GRASSLAND,
	MEADOW,
	PRAIRIE,
	SWAMP,
	TROPICAL_FOREST,
	BOREAL_FOREST,
	CONIFER_FOREST,
	TEMPERATE_FOREST,
	RAINFOREST,
	HILLS,
	FOOTHILLS,
	MOUNTAINS,
	ALPINE,
	TUNDRA,
	SAVANNA,
	FROZEN_FOREST,
	FROZEN_MARSH,
	GLACIER,
	LAVA_FIELD,
	VOLCANIC_BADLANDS,
	SCORCHED_FOREST,
}

## Produces smooth biomes using temperature & moisture with soft thresholds

func classify(params: Dictionary, is_land: PackedByteArray, height: PackedFloat32Array, temperature: PackedFloat32Array, moisture: PackedFloat32Array, beach_mask: PackedByteArray) -> PackedInt32Array:
	var w: int = int(params.get("width", 275))
	var h: int = int(params.get("height", 62))
	var rng_seed: int = int(params.get("seed", 0))
	var temp_min_c: float = float(params.get("temp_min_c", -40.0))
	var temp_max_c: float = float(params.get("temp_max_c", 45.0))
	var height_scale_m: float = float(params.get("height_scale_m", 4000.0))
	var lapse_c_per_km: float = float(params.get("lapse_c_per_km", 5.5))
	# Humidity minima (0..1 moisture scale)
	var MIN_M_RAINFOREST := 0.75
	var MIN_M_TROPICAL_FOREST := 0.60
	var MIN_M_TEMPERATE_FOREST := 0.50
	var MIN_M_CONIFER_FOREST := 0.45
	var MIN_M_BOREAL_FOREST := 0.40
	var MIN_M_SWAMP := 0.65
	var MIN_M_MEADOW := 0.35
	var MIN_M_PRAIRIE := 0.30
	var MIN_M_GRASSLAND := 0.25
	var MIN_M_STEPPE := 0.15

	# Shared desert noise for sand vs rock choice
	var desert_noise := FastNoiseLite.new()
	desert_noise.seed = rng_seed ^ 0xBEEF
	desert_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	desert_noise.frequency = 0.008
	# Glacier wiggle noise for snowline randomness
	var glacier_noise := FastNoiseLite.new()
	glacier_noise.seed = rng_seed ^ 0x6ACE
	glacier_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	glacier_noise.frequency = 0.01
	var out := PackedInt32Array()
	out.resize(w * h)

	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if is_land[i] == 0:
				# Ocean ice sheet when very cold (below ~ -10°C ±1°C wiggle)
				var t_norm_o: float = temperature[i]
				var t_c: float = temp_min_c + t_norm_o * (temp_max_c - temp_min_c)
				var ice_noise_o := FastNoiseLite.new()
				ice_noise_o.seed = rng_seed ^ 0x1CE
				ice_noise_o.noise_type = FastNoiseLite.TYPE_SIMPLEX
				ice_noise_o.frequency = 0.01
				var wiggle: float = ice_noise_o.get_noise_2d(float(x), float(y)) # -1..1
				var threshold_c: float = -10.0 + wiggle * 1.0
				out[i] = Biome.ICE_SHEET if t_c <= threshold_c else Biome.OCEAN
				continue
			if beach_mask[i] != 0:
				out[i] = Biome.BEACH
				continue
			var t: float = temperature[i]
			var m: float = moisture[i]
			var elev: float = height[i]
			# Apply elevation (adiabatic) cooling to temperature for biome decisions
			var elev_m: float = elev * height_scale_m
			var t_c0: float = temp_min_c + t * (temp_max_c - temp_min_c)
			var t_c_adj: float = t_c0 - lapse_c_per_km * (elev_m / 1000.0)
			var t_eff: float = clamp((t_c_adj - temp_min_c) / max(0.001, (temp_max_c - temp_min_c)), 0.0, 1.0)

			# Mountain/polar glacier rule before generic freeze
			var wig: float = glacier_noise.get_noise_2d(float(x), float(y)) * 1.5 # -1.5..1.5
			var snowline_c: float = -2.0 + wig # -3.5 .. -0.5 °C
			var is_glacier: bool = false
			if elev_m >= 1800.0 and t_c_adj <= snowline_c and m >= 0.25:
				is_glacier = true
			elif t_c0 <= -18.0 and m >= 0.20:
				is_glacier = true
			if is_glacier:
				out[i] = Biome.GLACIER
				continue

			# Global freeze rule: if temperature below threshold, classify as ice desert
			var freeze_t: float = float(params.get("freeze_temp_threshold", 0.15))
			if t_eff <= freeze_t:
				out[i] = Biome.DESERT_ICE
				continue

			# Tundra band: moderately cold but not deep-freeze; requires some moisture
			if t_c_adj > -10.0 and t_c_adj <= 2.0 and m >= 0.30:
				out[i] = Biome.TUNDRA
				continue

			# Soft thresholds via smoothstep-like blends
			var cold: float = clamp((0.45 - t_eff) * 3.0, 0.0, 1.0)
			var hot: float = clamp((t_eff - 0.60) * 2.4, 0.0, 1.0)
			var dry: float = clamp((0.40 - m) * 2.6, 0.0, 1.0)
			var wet: float = clamp((m - 0.70) * 2.6, 0.0, 1.0)
			var high: float = clamp((elev - 0.5) * 2.0, 0.0, 1.0)
			var alpine: float = clamp((elev - 0.8) * 5.0, 0.0, 1.0)

			var choice := Biome.GRASSLAND
			if high > 0.5: # lower mountains threshold (elev > ~0.75)
				if alpine > 0.4: # lower alpine threshold (elev > ~0.88)
					choice = Biome.ALPINE
				else:
					choice = Biome.MOUNTAINS
			elif dry > 0.6 and cold < 0.6:
				# Hot-dry desert rule. Cool dry areas become rock desert; warm/hot dry become sand vs rock by smooth noise.
				if t < 0.60:
					choice = Biome.DESERT_ROCK
				else:
					var noise_val: float = desert_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
					# Bias sand probability by heat; hotter → more sand
					var sand_prob: float = clamp(0.25 + 0.6 * hot, 0.0, 0.98)
					choice = Biome.DESERT_SAND if noise_val < sand_prob else Biome.DESERT_ROCK
			elif cold > 0.6 and dry > 0.4:
				choice = Biome.DESERT_ICE
			elif wet > 0.6 and hot > 0.4:
				choice = Biome.RAINFOREST
			elif m > 0.55 and t_eff > 0.5:
				choice = Biome.TROPICAL_FOREST
			# Warm band savanna (18..30 °C approx) before grassland/steppe
			elif t_c_adj > 18.0 and t_c_adj <= 30.0 and m >= 0.40:
				choice = Biome.SAVANNA
			elif wet > 0.55 and cold > 0.45:
				choice = Biome.SWAMP
			elif cold > 0.65:
				choice = Biome.BOREAL_FOREST
			elif cold > 0.55 and m >= 0.35:
				choice = Biome.FROZEN_FOREST
			elif m > 0.6 and t > 0.5:
				choice = Biome.TEMPERATE_FOREST
			elif m > 0.4 and t > 0.4:
				choice = Biome.CONIFER_FOREST
			elif m > 0.3 and t > 0.3:
				choice = Biome.MEADOW
			elif m > 0.25 and t > 0.35:
				choice = Biome.PRAIRIE
			elif m > 0.2 and t > 0.25:
				choice = Biome.STEPPE
			elif high > 0.25:
				choice = Biome.FOOTHILLS
			elif high > 0.15:
				choice = Biome.HILLS
			else:
				choice = Biome.GRASSLAND

			# Prevent lush tropical/rainforest at very high elevations (e.g., Tibetan Plateau)
			if (choice == Biome.RAINFOREST or choice == Biome.TROPICAL_FOREST):
				if elev_m >= 2000.0:
					if m > 0.6 and t_eff > 0.45:
						choice = Biome.TEMPERATE_FOREST
					elif m > 0.45 and t_eff > 0.35:
						choice = Biome.CONIFER_FOREST
					elif m > 0.35:
						choice = Biome.MEADOW
					else:
						choice = Biome.STEPPE

			# Enforce humidity minima and dry fallbacks
			if m < MIN_M_STEPPE:
				if t_c0 <= -2.0:
					choice = Biome.DESERT_ICE
				else:
					var noise_val2: float = desert_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
					var sand_prob2: float = clamp(0.25 + 0.6 * hot, 0.0, 0.98)
					choice = Biome.DESERT_SAND if noise_val2 < sand_prob2 else Biome.DESERT_ROCK
			elif m < MIN_M_GRASSLAND:
				choice = Biome.STEPPE
			else:
				if choice == Biome.RAINFOREST and m < MIN_M_RAINFOREST:
					if m >= MIN_M_TROPICAL_FOREST:
						choice = Biome.TROPICAL_FOREST
					elif m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
						choice = Biome.TEMPERATE_FOREST
					elif m >= MIN_M_CONIFER_FOREST:
						choice = Biome.CONIFER_FOREST
					elif m >= MIN_M_GRASSLAND:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE
				elif choice == Biome.TROPICAL_FOREST and m < MIN_M_TROPICAL_FOREST:
					if m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
						choice = Biome.TEMPERATE_FOREST
					elif m >= MIN_M_CONIFER_FOREST:
						choice = Biome.CONIFER_FOREST
					elif m >= MIN_M_GRASSLAND:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE
				elif choice == Biome.TEMPERATE_FOREST and m < MIN_M_TEMPERATE_FOREST:
					if m >= MIN_M_CONIFER_FOREST:
						choice = Biome.CONIFER_FOREST
					elif m >= MIN_M_GRASSLAND:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE
				elif choice == Biome.CONIFER_FOREST and m < MIN_M_CONIFER_FOREST:
					choice = Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
				elif choice == Biome.BOREAL_FOREST and m < MIN_M_BOREAL_FOREST:
					choice = Biome.CONIFER_FOREST if m >= MIN_M_CONIFER_FOREST else (Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE)
				elif choice == Biome.SWAMP and m < MIN_M_SWAMP:
					if m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
						choice = Biome.TEMPERATE_FOREST
					elif m >= MIN_M_CONIFER_FOREST:
						choice = Biome.CONIFER_FOREST
					elif m >= MIN_M_GRASSLAND:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE
				elif choice == Biome.MEADOW and m < MIN_M_MEADOW:
					choice = Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
				elif choice == Biome.PRAIRIE and m < MIN_M_PRAIRIE:
					choice = Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
				elif choice == Biome.GRASSLAND and m < MIN_M_GRASSLAND:
					choice = Biome.STEPPE

			# Heat-driven overrides
			var t_c_adj2: float = t_c_adj
			if t_c_adj2 >= 55.0:
				if choice == Biome.MOUNTAINS or choice == Biome.ALPINE or choice == Biome.HILLS or choice == Biome.FOOTHILLS:
					choice = Biome.VOLCANIC_BADLANDS
				elif choice == Biome.RAINFOREST or choice == Biome.TROPICAL_FOREST or choice == Biome.TEMPERATE_FOREST or choice == Biome.CONIFER_FOREST or choice == Biome.BOREAL_FOREST or choice == Biome.SWAMP:
					choice = Biome.SCORCHED_FOREST
				else:
					choice = Biome.LAVA_FIELD
			elif t_c_adj2 >= 30.0:
				if m < 0.40:
					var noise_val3: float = desert_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
					var sand_prob3: float = clamp(0.25 + 0.6 * (t_eff - 0.60) * 2.4, 0.0, 0.98)
					choice = Biome.DESERT_SAND if noise_val3 < sand_prob3 else Biome.DESERT_ROCK
				elif m < 0.55:
					choice = Biome.SAVANNA
				elif m < 0.65:
					choice = Biome.PRAIRIE

			out[i] = choice

	# Smooth blend pass (3x3 mode filter) to reduce hard edges
	var blended := PackedInt32Array()
	blended.resize(w * h)
	for y2 in range(h):
		for x2 in range(w):
			var i2 := x2 + y2 * w
			var counts := {}
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx := x2 + dx
					var ny := y2 + dy
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var bi := out[nx + ny * w]
					counts[bi] = int(counts.get(bi, 0)) + 1
			var best_biome := out[i2]
			var best_count := -1
			for k in counts.keys():
				var cnt: int = counts[k]
				if cnt > best_count:
					best_count = cnt
					best_biome = k
			blended[i2] = best_biome

	# Re-apply ocean ice sheet after smoothing so it isn't lost to majority ocean
	var ice_noise_b := FastNoiseLite.new()
	ice_noise_b.seed = rng_seed ^ 0x1CE
	ice_noise_b.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ice_noise_b.frequency = 0.01
	for yo in range(h):
		for xo in range(w):
			var io := xo + yo * w
			if is_land[io] != 0:
				continue
			var t_norm := temperature[io]
			var t_c := temp_min_c + t_norm * (temp_max_c - temp_min_c)
			var wiggle := ice_noise_b.get_noise_2d(float(xo), float(yo)) # -1..1
			var threshold_c := -10.0 + wiggle * 1.0
			if t_c <= threshold_c:
				blended[io] = Biome.ICE_SHEET

	# Re-apply land glaciers after smoothing so they aren't lost to neighbors
	var glacier_noise_b := FastNoiseLite.new()
	glacier_noise_b.seed = rng_seed ^ 0x6ACE
	glacier_noise_b.noise_type = FastNoiseLite.TYPE_SIMPLEX
	glacier_noise_b.frequency = 0.01
	for yl in range(h):
		for xl in range(w):
			var il := xl + yl * w
			if is_land[il] == 0:
				continue
			var elev_l := height[il]
			var elev_m_l := elev_l * height_scale_m
			var t_norm_l := temperature[il]
			var t_c0_l := temp_min_c + t_norm_l * (temp_max_c - temp_min_c)
			var t_c_adj_l := t_c0_l - lapse_c_per_km * (elev_m_l / 1000.0)
			var wig2 := glacier_noise_b.get_noise_2d(float(xl), float(yl)) * 1.5
			var snowline_c2 := -2.0 + wig2
			if elev_m_l >= 1800.0 and t_c_adj_l <= snowline_c2 and moisture[il] >= 0.25:
				blended[il] = Biome.GLACIER
			elif t_c0_l <= -18.0 and moisture[il] >= 0.20:
				blended[il] = Biome.GLACIER

	return blended
