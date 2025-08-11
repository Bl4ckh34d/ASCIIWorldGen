# File: res://scripts/generation/BiomeClassifier.gd
extends RefCounted

const BiomeRules = preload("res://scripts/systems/BiomeRules.gd")

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
	var xscale: float = float(params.get("noise_x_scale", 1.0))
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

	# Optional prebuilt noise fields from FeatureNoiseCache
	var desert_field: PackedFloat32Array = params.get("desert_noise_field", PackedFloat32Array())
	var ice_wiggle_field: PackedFloat32Array = params.get("ice_wiggle_field", PackedFloat32Array())
	var use_desert_field: bool = desert_field.size() == w * h
	var use_ice_field: bool = ice_wiggle_field.size() == w * h
	# Shared desert noise for sand vs rock choice (fallback)
	var desert_noise := FastNoiseLite.new()
	desert_noise.seed = rng_seed ^ 0xBEEF
	desert_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	desert_noise.frequency = 0.008
	# Glacier/ice wiggle noise (fallback)
	var glacier_noise := FastNoiseLite.new()
	glacier_noise.seed = rng_seed ^ 0x6ACE
	glacier_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	glacier_noise.frequency = 0.01
	var ice_noise_o := FastNoiseLite.new()
	ice_noise_o.seed = rng_seed ^ 0x1CE
	ice_noise_o.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ice_noise_o.frequency = 0.01
	var out := PackedInt32Array()
	out.resize(w * h)

	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if is_land[i] == 0:
				# Ocean ice sheet when very cold (below ~ -10°C ±1°C wiggle)
				var t_norm_o: float = temperature[i]
				var t_c: float = temp_min_c + t_norm_o * (temp_max_c - temp_min_c)
				var wiggle: float = ice_wiggle_field[i] if use_ice_field else ice_noise_o.get_noise_2d(float(x) * xscale, float(y))
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
			var wig: float = (ice_wiggle_field[i] if use_ice_field else glacier_noise.get_noise_2d(float(x) * xscale, float(y))) * 1.5 # -1.5..1.5
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

			# Base choice via centralized rules
			var choice := BiomeRules.new().classify_cell(t_c_adj, m, elev, true)
			# If rules yield a desert base at high heat/dryness, apply sand vs rock via noise
			if choice == Biome.DESERT_ROCK and t > 0.60 and m < 0.40:
				var noise_val: float = (desert_field[i] if use_desert_field else (desert_noise.get_noise_2d(float(x) * xscale, float(y)) * 0.5 + 0.5))
				var sand_prob: float = clamp(0.25 + 0.6 * clamp((t - 0.60) * 2.4, 0.0, 1.0), 0.0, 0.98)
				choice = Biome.DESERT_SAND if noise_val < sand_prob else Biome.DESERT_ROCK

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
					var noise_val2: float = (desert_field[i] if use_desert_field else (desert_noise.get_noise_2d(float(x) * xscale, float(y)) * 0.5 + 0.5))
					var heat_bias: float = clamp((t - 0.60) * 2.4, 0.0, 1.0)
					var sand_prob2: float = clamp(0.25 + 0.6 * heat_bias, 0.0, 0.98)
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

			# Heat-driven overrides moved to BiomePost (centralized)

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
			var wiggle := ice_wiggle_field[io] if use_ice_field else ice_noise_b.get_noise_2d(float(xo) * xscale, float(yo)) # -1..1
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
			var wig2 := (ice_wiggle_field[il] if use_ice_field else glacier_noise_b.get_noise_2d(float(xl) * xscale, float(yl))) * 1.5
			var snowline_c2 := -2.0 + wig2
			if elev_m_l >= 1800.0 and t_c_adj_l <= snowline_c2 and moisture[il] >= 0.25:
				blended[il] = Biome.GLACIER
			elif t_c0_l <= -18.0 and moisture[il] >= 0.20:
				blended[il] = Biome.GLACIER

	return blended
