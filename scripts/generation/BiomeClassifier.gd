# File: res://scripts/generation/BiomeClassifier.gd
extends RefCounted

const BiomeRules = preload("res://scripts/systems/BiomeRules.gd")

enum Biome {
	# Water
	OCEAN = 0,
	ICE_SHEET = 1,
	BEACH = 2,

	# Desert triad
	DESERT_ICE = 5,
	DESERT_SAND = 3,
	WASTELAND = 4,
	# (Scorched desert maps to same visuals; extreme becomes LAVA_FIELD)

	# Grassland triad
	FROZEN_GRASSLAND = 29,
	GRASSLAND = 7,
	SCORCHED_GRASSLAND = 36,

	# Steppe triad
	FROZEN_STEPPE = 30,
	STEPPE = 6,
	SCORCHED_STEPPE = 37,

	# Meadow/Prairie collapsed into Grassland

	# Savanna triad
	FROZEN_SAVANNA = 33,
	SAVANNA = 21,
	SCORCHED_SAVANNA = 40,

	# Hills triad
	FROZEN_HILLS = 34,
	HILLS = 16,
	SCORCHED_HILLS = 41,

	# Foothills collapsed into Hills

	# Forest triad (multiple normals share one frozen/scorched)
	FROZEN_FOREST = 22,
	TROPICAL_FOREST = 11,
	BOREAL_FOREST = 12,
	CONIFER_FOREST = 13,
	TEMPERATE_FOREST = 14,
	RAINFOREST = 15,
	SCORCHED_FOREST = 27,

	# Wetland triad
	FROZEN_MARSH = 23, # Frozen Swamp
	SWAMP = 10,
	# Scorched Swamp reuses SCORCHED_FOREST

	# Cold band (acts as its own class)
	TUNDRA = 20,

	# Mountains and high relief
	GLACIER = 24,
	MOUNTAINS = 18,
	ALPINE = 19,

	# Specials
	LAVA_FIELD = 25,
	VOLCANIC_BADLANDS = 26,
	SALT_DESERT = 28,
}

## Produces smooth biomes using temperature & moisture with soft thresholds

func classify(params: Dictionary, is_land: PackedByteArray, height: PackedFloat32Array, temperature: PackedFloat32Array, moisture: PackedFloat32Array, beach_mask: PackedByteArray) -> PackedInt32Array:
	var w: int = int(params.get("width", 275))
	var h: int = int(params.get("height", 62))
	var rng_seed: int = int(params.get("seed", 0))
	var glacier_phase: float = float(params.get("glacier_phase", 0.0))
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
	# Fine mask to split glacier vs mountains/alpine at high elevations (~1/3 glacier)
	var glacier_mask_noise := FastNoiseLite.new()
	glacier_mask_noise.seed = rng_seed ^ 0xA17C5
	glacier_mask_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	# Increase frequency and use FBM to get finer, more detailed breakup
	glacier_mask_noise.frequency = 0.18
	glacier_mask_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	glacier_mask_noise.fractal_octaves = 4
	glacier_mask_noise.fractal_lacunarity = 2.1
	glacier_mask_noise.fractal_gain = 0.47
	var ice_noise_o := FastNoiseLite.new()
	ice_noise_o.seed = rng_seed ^ 0x1CE
	ice_noise_o.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ice_noise_o.frequency = 0.01
	var out := PackedInt32Array()
	out.resize(w * h)

	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			# Latitude 0 at equator, 1 at poles
			var lat: float = abs(float(y) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
			if is_land[i] == 0:
				# Ocean ice sheet when very cold (below ~ -10 degC +/-1 degC wiggle)
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
			var snowline_c: float = -2.0 + wig # -3.5 .. -0.5 degC
			# Candidate for glacier: cold enough at high elevation (or very cold overall) with some moisture
			var can_glacier: bool = false
			if elev_m >= 1800.0 and t_c_adj <= snowline_c and m >= 0.25:
				can_glacier = true
			elif t_c0 <= -18.0 and m >= 0.20:
				can_glacier = true
			if can_glacier:
				# Fine-grained split: ~1/3 glaciers, 2/3 mountains/alpine
				# Sample mask at higher spatial detail for less blobby regions
				# Evolve smoothly using a phase offset derived from sliders
				var px: float = float(x) * xscale + 37.0 * glacier_phase
				var py: float = float(y) + 71.0 * glacier_phase
				var gmask: float = glacier_mask_noise.get_noise_2d(px, py) * 0.5 + 0.5
				if gmask <= 0.333:
					out[i] = Biome.GLACIER
					continue

			# Global freeze rule: favor polar, low-elevation Ice Desert only; otherwise defer to relief/frozen variants
			var freeze_t: float = float(params.get("freeze_temp_threshold", 0.15))
			if t_eff <= freeze_t:
				var is_polar: bool = (lat >= 0.66)
				var low_elev: bool = (elev_m <= 800.0)
				if is_polar and low_elev and m < 0.30:
					out[i] = Biome.DESERT_ICE
					continue

			# Tundra band: moderately cold but not deep-freeze; requires some moisture
			if t_c_adj > -10.0 and t_c_adj <= 2.0 and m >= 0.30:
				out[i] = Biome.TUNDRA
				continue

			# Base choice via centralized rules
			var choice := BiomeRules.new().classify_cell(t_c_adj, m, elev, true)
			# If we were a glacier candidate but the mask routed us to relief, bias to Alpine at the very top
			if can_glacier and (choice == Biome.MOUNTAINS or choice == Biome.HILLS):
				if elev_m >= 2200.0:
					choice = Biome.ALPINE
			# If rules yield a desert base at high heat/dryness, apply sand vs rock via noise
			if choice == Biome.WASTELAND and t > 0.60 and m < 0.40:
				var noise_val: float = (desert_field[i] if use_desert_field else (desert_noise.get_noise_2d(float(x) * xscale, float(y)) * 0.5 + 0.5))
				var sand_prob: float = clamp(0.25 + 0.6 * clamp((t - 0.60) * 2.4, 0.0, 1.0), 0.0, 0.98)
				choice = Biome.DESERT_SAND if noise_val < sand_prob else Biome.WASTELAND

			# Prevent lush tropical/rainforest at very high elevations (e.g., Tibetan Plateau)
			if (choice == Biome.RAINFOREST or choice == Biome.TROPICAL_FOREST):
				if elev_m >= 2000.0:
					if m > 0.6 and t_eff > 0.45:
						choice = Biome.TEMPERATE_FOREST
					elif m > 0.45 and t_eff > 0.35:
						choice = Biome.BOREAL_FOREST
					elif m > 0.35:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE

			# Enforce humidity minima and dry fallbacks
			if m < MIN_M_STEPPE:
				if t_c0 <= -2.0:
					# No ice desert on mountains; restrict to polar lowlands only
					var is_polar2: bool = (lat >= 0.66)
					var low_elev2: bool = (elev_m <= 800.0)
					if is_polar2 and low_elev2 and m < 0.30:
						choice = Biome.DESERT_ICE
					else:
						# Prefer tundra/frozen steppe outside polar lowlands
						choice = Biome.TUNDRA if m >= 0.20 else Biome.WASTELAND
				else:
					# Hot deserts tied to low elevations near the equator
					var noise_val2: float = (desert_field[i] if use_desert_field else (desert_noise.get_noise_2d(float(x) * xscale, float(y)) * 0.5 + 0.5))
					var heat_bias: float = clamp((t - 0.60) * 2.4, 0.0, 1.0)
					var sand_prob2: float = clamp(0.25 + 0.6 * heat_bias, 0.0, 0.98)
					var low_elev_hot: bool = (elev_m <= 600.0)
					var equatorial: bool = (lat <= 0.33)
					if low_elev_hot and equatorial and noise_val2 < sand_prob2:
						choice = Biome.DESERT_SAND
					else:
						choice = Biome.WASTELAND
			elif m < MIN_M_GRASSLAND:
				choice = Biome.STEPPE
			else:
				if choice == Biome.RAINFOREST and m < MIN_M_RAINFOREST:
					if m >= MIN_M_TROPICAL_FOREST:
						choice = Biome.TROPICAL_FOREST
					elif m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
						choice = Biome.TEMPERATE_FOREST
					elif m >= MIN_M_CONIFER_FOREST:
						choice = Biome.BOREAL_FOREST
					elif m >= MIN_M_GRASSLAND:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE
				elif choice == Biome.TROPICAL_FOREST and m < MIN_M_TROPICAL_FOREST:
					if m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
						choice = Biome.TEMPERATE_FOREST
					elif m >= MIN_M_CONIFER_FOREST:
						choice = Biome.BOREAL_FOREST
					elif m >= MIN_M_GRASSLAND:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE
				elif choice == Biome.TEMPERATE_FOREST and m < MIN_M_TEMPERATE_FOREST:
					if m >= MIN_M_CONIFER_FOREST:
						choice = Biome.BOREAL_FOREST
					elif m >= MIN_M_GRASSLAND:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE
				elif choice == Biome.CONIFER_FOREST and m < MIN_M_CONIFER_FOREST:
					choice = Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
				elif choice == Biome.BOREAL_FOREST and m < MIN_M_BOREAL_FOREST:
					choice = Biome.BOREAL_FOREST if m >= MIN_M_CONIFER_FOREST else (Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE)
				elif choice == Biome.SWAMP and m < MIN_M_SWAMP:
					if m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
						choice = Biome.TEMPERATE_FOREST
					elif m >= MIN_M_CONIFER_FOREST:
						choice = Biome.CONIFER_FOREST
					elif m >= MIN_M_GRASSLAND:
						choice = Biome.GRASSLAND
					else:
						choice = Biome.STEPPE
				# Meadow/Prairie merged into Grassland
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
