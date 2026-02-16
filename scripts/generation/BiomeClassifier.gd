# File: res://scripts/generation/BiomeClassifier.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

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

const MIN_M_RAINFOREST: float = 0.75
const MIN_M_TROPICAL_FOREST: float = 0.60
const MIN_M_TEMPERATE_FOREST: float = 0.50
const MIN_M_CONIFER_FOREST: float = 0.45
const MIN_M_BOREAL_FOREST: float = 0.40
const MIN_M_SWAMP: float = 0.65
const MIN_M_GRASSLAND: float = 0.25
const MIN_M_STEPPE: float = 0.15

const OCEAN_ICE_THRESHOLD_C: float = -10.0
const OCEAN_ICE_WIGGLE_C: float = 1.0
const GLACIER_WIGGLE_MUL: float = 1.5

var _rules: BiomeRules = BiomeRules.new()
var _noise_seed: int = -2147483648
var _desert_noise: FastNoiseLite = FastNoiseLite.new()
var _glacier_noise: FastNoiseLite = FastNoiseLite.new()
var _glacier_mask_noise: FastNoiseLite = FastNoiseLite.new()
var _ice_noise: FastNoiseLite = FastNoiseLite.new()

func classify(
	params: Dictionary,
	is_land: PackedByteArray,
	height: PackedFloat32Array,
	temperature: PackedFloat32Array,
	moisture: PackedFloat32Array,
	beach_mask: PackedByteArray
) -> PackedInt32Array:
	var w: int = int(params.get("width", 275))
	var h: int = int(params.get("height", 62))
	var size: int = max(0, w * h)
	if size <= 0:
		return PackedInt32Array()
	if not _validate_inputs(size, is_land, height, temperature, moisture, beach_mask):
		return PackedInt32Array()

	var rng_seed: int = int(params.get("seed", 0))
	var glacier_phase: float = float(params.get("glacier_phase", 0.0))
	var temp_min_c: float = float(params.get("temp_min_c", -40.0))
	var temp_max_c: float = float(params.get("temp_max_c", 45.0))
	var height_scale_m: float = float(params.get("height_scale_m", 4000.0))
	var lapse_c_per_km: float = float(params.get("lapse_c_per_km", 5.5))
	var xscale: float = float(params.get("noise_x_scale", 1.0))
	var freeze_t: float = float(params.get("freeze_temp_threshold", 0.15))
	var smooth_enabled: bool = VariantCastsUtil.to_bool(params.get("biome_smoothing_enabled", true))

	var desert_field: PackedFloat32Array = params.get("desert_noise_field", PackedFloat32Array())
	var ice_wiggle_field: PackedFloat32Array = params.get("ice_wiggle_field", PackedFloat32Array())
	var use_desert_field: bool = desert_field.size() == size
	var use_ice_field: bool = ice_wiggle_field.size() == size

	_ensure_noise_cache(rng_seed)

	var out := PackedInt32Array()
	out.resize(size)
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var lat: float = abs(float(y) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
			if is_land[i] == 0:
				out[i] = _classify_ocean_cell(i, x, y, temperature, ice_wiggle_field, use_ice_field, xscale, temp_min_c, temp_max_c)
				continue
			if beach_mask[i] != 0:
				out[i] = Biome.BEACH
				continue
			out[i] = _classify_land_cell(
				i,
				x,
				y,
				lat,
				height,
				temperature,
				moisture,
				desert_field,
				ice_wiggle_field,
				use_desert_field,
				use_ice_field,
				xscale,
				temp_min_c,
				temp_max_c,
				height_scale_m,
				lapse_c_per_km,
				freeze_t,
				glacier_phase
			)

	var blended: PackedInt32Array = out
	if smooth_enabled:
		blended = _majority_smooth_3x3(out, w, h)

	_reapply_ocean_ice(
		blended,
		w,
		h,
		is_land,
		temperature,
		ice_wiggle_field,
		use_ice_field,
		xscale,
		temp_min_c,
		temp_max_c
	)
	_reapply_land_glacier(
		blended,
		w,
		h,
		is_land,
		height,
		temperature,
		moisture,
		ice_wiggle_field,
		use_ice_field,
		xscale,
		temp_min_c,
		temp_max_c,
		height_scale_m,
		lapse_c_per_km
	)
	return blended

func _validate_inputs(
	size: int,
	is_land: PackedByteArray,
	height: PackedFloat32Array,
	temperature: PackedFloat32Array,
	moisture: PackedFloat32Array,
	beach_mask: PackedByteArray
) -> bool:
	return is_land.size() == size \
		and height.size() == size \
		and temperature.size() == size \
		and moisture.size() == size \
		and beach_mask.size() == size

func _ensure_noise_cache(rng_seed: int) -> void:
	if _noise_seed == rng_seed:
		return
	_noise_seed = rng_seed

	_desert_noise.seed = rng_seed ^ 0xBEEF
	_desert_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_desert_noise.frequency = 0.008

	_glacier_noise.seed = rng_seed ^ 0x6ACE
	_glacier_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_glacier_noise.frequency = 0.01

	_glacier_mask_noise.seed = rng_seed ^ 0xA17C5
	_glacier_mask_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_glacier_mask_noise.frequency = 0.18
	_glacier_mask_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_glacier_mask_noise.fractal_octaves = 4
	_glacier_mask_noise.fractal_lacunarity = 2.1
	_glacier_mask_noise.fractal_gain = 0.47

	_ice_noise.seed = rng_seed ^ 0x1CE
	_ice_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ice_noise.frequency = 0.01

func _classify_ocean_cell(
	i: int,
	x: int,
	y: int,
	temperature: PackedFloat32Array,
	ice_wiggle_field: PackedFloat32Array,
	use_ice_field: bool,
	xscale: float,
	temp_min_c: float,
	temp_max_c: float
) -> int:
	var t_norm: float = temperature[i]
	var t_c: float = _norm_to_celsius(t_norm, temp_min_c, temp_max_c)
	var wiggle: float = ice_wiggle_field[i] if use_ice_field else _ice_noise.get_noise_2d(float(x) * xscale, float(y))
	var threshold_c: float = OCEAN_ICE_THRESHOLD_C + wiggle * OCEAN_ICE_WIGGLE_C
	return Biome.ICE_SHEET if t_c <= threshold_c else Biome.OCEAN

func _classify_land_cell(
	i: int,
	x: int,
	y: int,
	lat: float,
	height: PackedFloat32Array,
	temperature: PackedFloat32Array,
	moisture: PackedFloat32Array,
	desert_field: PackedFloat32Array,
	ice_wiggle_field: PackedFloat32Array,
	use_desert_field: bool,
	use_ice_field: bool,
	xscale: float,
	temp_min_c: float,
	temp_max_c: float,
	height_scale_m: float,
	lapse_c_per_km: float,
	freeze_t: float,
	glacier_phase: float
) -> int:
	var t: float = temperature[i]
	var m: float = moisture[i]
	var elev_norm: float = height[i]
	var elev_m: float = elev_norm * height_scale_m

	var t_c0: float = _norm_to_celsius(t, temp_min_c, temp_max_c)
	var t_c_adj: float = t_c0 - lapse_c_per_km * (elev_m / 1000.0)
	var t_eff: float = _celsius_to_norm(t_c_adj, temp_min_c, temp_max_c)

	var wig: float = (ice_wiggle_field[i] if use_ice_field else _glacier_noise.get_noise_2d(float(x) * xscale, float(y))) * GLACIER_WIGGLE_MUL
	var snowline_c: float = -2.0 + wig
	var can_glacier: bool = _is_glacier_candidate(elev_m, t_c0, t_c_adj, m, snowline_c)
	if can_glacier:
		var px: float = float(x) * xscale + 37.0 * glacier_phase
		var py: float = float(y) + 71.0 * glacier_phase
		var gmask: float = _glacier_mask_noise.get_noise_2d(px, py) * 0.5 + 0.5
		if gmask <= 0.333:
			return Biome.GLACIER

	if t_eff <= freeze_t:
		var is_polar: bool = lat >= 0.66
		var low_elev: bool = elev_m <= 800.0
		if is_polar and low_elev and m < 0.30:
			return Biome.DESERT_ICE

	if t_c_adj > -10.0 and t_c_adj <= 2.0 and m >= 0.30:
		return Biome.TUNDRA

	var choice: int = _rules.classify_cell(t_c_adj, m, elev_norm, true)
	if can_glacier and (choice == Biome.MOUNTAINS or choice == Biome.HILLS) and elev_m >= 2200.0:
		choice = Biome.ALPINE

	if choice == Biome.WASTELAND and t > 0.60 and m < 0.40:
		var noise_val: float = _sample_desert_noise(i, x, y, desert_field, use_desert_field, xscale)
		var sand_prob: float = clamp(0.25 + 0.6 * clamp((t - 0.60) * 2.4, 0.0, 1.0), 0.0, 0.98)
		choice = Biome.DESERT_SAND if noise_val < sand_prob else Biome.WASTELAND

	choice = _apply_high_elevation_forest_guard(choice, elev_m, m, t_eff)
	choice = _enforce_humidity(choice, m, t, t_c0, t_eff, lat, elev_m, _sample_desert_noise(i, x, y, desert_field, use_desert_field, xscale))
	return choice

func _is_glacier_candidate(elev_m: float, t_c0: float, t_c_adj: float, moisture: float, snowline_c: float) -> bool:
	if elev_m >= 1800.0 and t_c_adj <= snowline_c and moisture >= 0.25:
		return true
	if t_c0 <= -18.0 and moisture >= 0.20:
		return true
	return false

func _sample_desert_noise(
	i: int,
	x: int,
	y: int,
	desert_field: PackedFloat32Array,
	use_desert_field: bool,
	xscale: float
) -> float:
	if use_desert_field:
		return desert_field[i]
	return _desert_noise.get_noise_2d(float(x) * xscale, float(y)) * 0.5 + 0.5

func _apply_high_elevation_forest_guard(choice: int, elev_m: float, m: float, t_eff: float) -> int:
	if choice != Biome.RAINFOREST and choice != Biome.TROPICAL_FOREST:
		return choice
	if elev_m < 2000.0:
		return choice
	if m > 0.6 and t_eff > 0.45:
		return Biome.TEMPERATE_FOREST
	if m > 0.45 and t_eff > 0.35:
		return Biome.BOREAL_FOREST
	if m > 0.35:
		return Biome.GRASSLAND
	return Biome.STEPPE

func _enforce_humidity(
	choice: int,
	m: float,
	t: float,
	t_c0: float,
	t_eff: float,
	lat: float,
	elev_m: float,
	desert_noise_val: float
) -> int:
	if m < MIN_M_STEPPE:
		if t_c0 <= -2.0:
			var is_polar: bool = lat >= 0.66
			var low_elev: bool = elev_m <= 800.0
			if is_polar and low_elev and m < 0.30:
				return Biome.DESERT_ICE
			return Biome.TUNDRA if m >= 0.20 else Biome.WASTELAND
		var heat_bias: float = clamp((t - 0.60) * 2.4, 0.0, 1.0)
		var sand_prob: float = clamp(0.25 + 0.6 * heat_bias, 0.0, 0.98)
		var low_elev_hot: bool = elev_m <= 600.0
		var equatorial: bool = lat <= 0.33
		if low_elev_hot and equatorial and desert_noise_val < sand_prob:
			return Biome.DESERT_SAND
		return Biome.WASTELAND

	if m < MIN_M_GRASSLAND:
		return Biome.STEPPE

	if choice == Biome.RAINFOREST and m < MIN_M_RAINFOREST:
		if m >= MIN_M_TROPICAL_FOREST:
			return Biome.TROPICAL_FOREST
		if m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
			return Biome.TEMPERATE_FOREST
		if m >= MIN_M_CONIFER_FOREST:
			return Biome.BOREAL_FOREST
		return Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
	if choice == Biome.TROPICAL_FOREST and m < MIN_M_TROPICAL_FOREST:
		if m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
			return Biome.TEMPERATE_FOREST
		if m >= MIN_M_CONIFER_FOREST:
			return Biome.BOREAL_FOREST
		return Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
	if choice == Biome.TEMPERATE_FOREST and m < MIN_M_TEMPERATE_FOREST:
		if m >= MIN_M_CONIFER_FOREST:
			return Biome.BOREAL_FOREST
		return Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
	if choice == Biome.CONIFER_FOREST and m < MIN_M_CONIFER_FOREST:
		return Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
	if choice == Biome.BOREAL_FOREST and m < MIN_M_BOREAL_FOREST:
		# Avoid self-assignment loops when moisture drops below boreal threshold.
		return Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
	if choice == Biome.SWAMP and m < MIN_M_SWAMP:
		if m >= MIN_M_TEMPERATE_FOREST and t_eff > 0.45:
			return Biome.TEMPERATE_FOREST
		if m >= MIN_M_CONIFER_FOREST:
			return Biome.CONIFER_FOREST
		return Biome.GRASSLAND if m >= MIN_M_GRASSLAND else Biome.STEPPE
	if choice == Biome.GRASSLAND and m < MIN_M_GRASSLAND:
		return Biome.STEPPE
	return choice

func _majority_smooth_3x3(src: PackedInt32Array, w: int, h: int) -> PackedInt32Array:
	var blended := PackedInt32Array()
	blended.resize(w * h)
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var counts: Dictionary = {}
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var bi: int = src[nx + ny * w]
					counts[bi] = int(counts.get(bi, 0)) + 1
			var best_biome: int = src[i]
			var best_count: int = -1
			for k in counts.keys():
				var cnt: int = int(counts[k])
				if cnt > best_count:
					best_count = cnt
					best_biome = int(k)
			blended[i] = best_biome
	return blended

func _reapply_ocean_ice(
	blended: PackedInt32Array,
	w: int,
	h: int,
	is_land: PackedByteArray,
	temperature: PackedFloat32Array,
	ice_wiggle_field: PackedFloat32Array,
	use_ice_field: bool,
	xscale: float,
	temp_min_c: float,
	temp_max_c: float
) -> void:
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if is_land[i] != 0:
				continue
			var t_norm: float = temperature[i]
			var t_c: float = _norm_to_celsius(t_norm, temp_min_c, temp_max_c)
			var wiggle: float = ice_wiggle_field[i] if use_ice_field else _ice_noise.get_noise_2d(float(x) * xscale, float(y))
			var threshold_c: float = OCEAN_ICE_THRESHOLD_C + wiggle * OCEAN_ICE_WIGGLE_C
			if t_c <= threshold_c:
				blended[i] = Biome.ICE_SHEET

func _reapply_land_glacier(
	blended: PackedInt32Array,
	w: int,
	h: int,
	is_land: PackedByteArray,
	height: PackedFloat32Array,
	temperature: PackedFloat32Array,
	moisture: PackedFloat32Array,
	ice_wiggle_field: PackedFloat32Array,
	use_ice_field: bool,
	xscale: float,
	temp_min_c: float,
	temp_max_c: float,
	height_scale_m: float,
	lapse_c_per_km: float
) -> void:
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if is_land[i] == 0:
				continue
			var elev_m: float = height[i] * height_scale_m
			var t_c0: float = _norm_to_celsius(temperature[i], temp_min_c, temp_max_c)
			var t_c_adj: float = t_c0 - lapse_c_per_km * (elev_m / 1000.0)
			var wig: float = (ice_wiggle_field[i] if use_ice_field else _glacier_noise.get_noise_2d(float(x) * xscale, float(y))) * GLACIER_WIGGLE_MUL
			var snowline_c: float = -2.0 + wig
			if _is_glacier_candidate(elev_m, t_c0, t_c_adj, moisture[i], snowline_c):
				blended[i] = Biome.GLACIER

func _norm_to_celsius(t_norm: float, temp_min_c: float, temp_max_c: float) -> float:
	return temp_min_c + t_norm * (temp_max_c - temp_min_c)

func _celsius_to_norm(t_c: float, temp_min_c: float, temp_max_c: float) -> float:
	return clamp((t_c - temp_min_c) / max(0.001, (temp_max_c - temp_min_c)), 0.0, 1.0)
