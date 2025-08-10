# File: res://scripts/WorldGenerator.gd
extends RefCounted

const TerrainNoise = preload("res://scripts/generation/TerrainNoise.gd")
var ClimateNoise = load("res://scripts/generation/ClimateNoise.gd")
const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

class Config:
	var rng_seed: int = 0
	var width: int = 320
	var height: int = 60
	var octaves: int = 5
	var frequency: float = 0.02
	var lacunarity: float = 2.0
	var gain: float = 0.5
	var warp: float = 24.0
	var sea_level: float = 0.0
	# Shore/turquoise controls
	var shallow_threshold: float = 0.20
	var shore_band: float = 6.0
	var shore_noise_mult: float = 4.0
	# Polar cap control
	var polar_cap_frac: float = 0.12
	# Height to meters scale (for info panel)
	var height_scale_m: float = 6000.0
	# Temperature extremes per seed (for Celsius scaling and lava)
	var temp_min_c: float = -40.0
	var temp_max_c: float = 70.0
	var lava_temp_threshold_c: float = 55.0
	# Climate jitter and continentality
	var temp_base_offset: float = 0.25
	var temp_scale: float = 1.0
	var moist_base_offset: float = 0.1
	var moist_scale: float = 1.0
	var continentality_scale: float = 1.2
	# Mountain radiance influence
	var mountain_cool_amp: float = 0.15
	var mountain_wet_amp: float = 0.10
	var mountain_radiance_passes: int = 3

var config := Config.new()

var _noise := FastNoiseLite.new()
var _warp_noise := FastNoiseLite.new()
var _shore_noise := FastNoiseLite.new()

var last_height: PackedFloat32Array = PackedFloat32Array()
var last_is_land: PackedByteArray = PackedByteArray()
var last_turquoise_water: PackedByteArray = PackedByteArray()
var last_beach: PackedByteArray = PackedByteArray()
var last_biomes: PackedInt32Array = PackedInt32Array()
var last_water_distance: PackedFloat32Array = PackedFloat32Array()
var last_turquoise_strength: PackedFloat32Array = PackedFloat32Array()
var last_temperature: PackedFloat32Array = PackedFloat32Array()
var last_moisture: PackedFloat32Array = PackedFloat32Array()
var last_distance_to_coast: PackedFloat32Array = PackedFloat32Array()
var last_lava: PackedByteArray = PackedByteArray()
var last_ocean_fraction: float = 0.0

func _init() -> void:
	randomize()
	config.rng_seed = randi()
	_setup_noises()
	_setup_temperature_extremes()

func apply_config(dict: Dictionary) -> void:
	if dict.has("seed"):
		var s: String = str(dict["seed"]) if typeof(dict["seed"]) != TYPE_NIL else ""
		config.rng_seed = s.hash() if s.length() > 0 else randi()
	if dict.has("width"):
		config.width = max(4, int(dict["width"]))
	if dict.has("height"):
		config.height = max(4, int(dict["height"]))
	if dict.has("octaves"):
		config.octaves = max(1, int(dict["octaves"]))
	if dict.has("frequency"):
		config.frequency = float(dict["frequency"]) 
	if dict.has("lacunarity"):
		config.lacunarity = float(dict["lacunarity"]) 
	if dict.has("gain"):
		config.gain = float(dict["gain"]) 
	if dict.has("warp"):
		config.warp = float(dict["warp"]) 
	if dict.has("sea_level"):
		config.sea_level = float(dict["sea_level"]) 
	if dict.has("shallow_threshold"):
		config.shallow_threshold = float(dict["shallow_threshold"]) 
	if dict.has("shore_band"):
		config.shore_band = float(dict["shore_band"]) 
	if dict.has("shore_noise_mult"):
		config.shore_noise_mult = clamp(float(dict["shore_noise_mult"]), 0.1, 20.0)
	if dict.has("polar_cap_frac"):
		config.polar_cap_frac = clamp(float(dict["polar_cap_frac"]), 0.0, 0.5)
	if dict.has("height_scale_m"):
		config.height_scale_m = float(dict["height_scale_m"]) 
	if dict.has("temp_min_c"):
		config.temp_min_c = float(dict["temp_min_c"]) 
	if dict.has("temp_max_c"):
		config.temp_max_c = float(dict["temp_max_c"]) 
	if dict.has("lava_temp_threshold_c"):
		config.lava_temp_threshold_c = float(dict["lava_temp_threshold_c"]) 
	if dict.has("temp_base_offset"):
		config.temp_base_offset = float(dict["temp_base_offset"]) 
	if dict.has("temp_scale"):
		config.temp_scale = float(dict["temp_scale"]) 
	if dict.has("moist_base_offset"):
		config.moist_base_offset = float(dict["moist_base_offset"]) 
	if dict.has("moist_scale"):
		config.moist_scale = float(dict["moist_scale"]) 
	if dict.has("continentality_scale"):
		config.continentality_scale = float(dict["continentality_scale"]) 
	if dict.has("mountain_cool_amp"):
		config.mountain_cool_amp = float(dict["mountain_cool_amp"]) 
	if dict.has("mountain_wet_amp"):
		config.mountain_wet_amp = float(dict["mountain_wet_amp"]) 
	if dict.has("mountain_radiance_passes"):
		config.mountain_radiance_passes = int(dict["mountain_radiance_passes"]) 
	_setup_noises()
	# Only randomize temperature extremes if caller didn't override both
	var override_extremes: bool = dict.has("temp_min_c") and dict.has("temp_max_c")
	if not override_extremes:
		_setup_temperature_extremes()

func _setup_noises() -> void:
	_noise.seed = config.rng_seed
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.frequency = config.frequency
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = config.octaves
	_noise.fractal_lacunarity = config.lacunarity
	_noise.fractal_gain = config.gain

	_warp_noise.seed = config.rng_seed ^ 0x9E3779B9
	_warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_warp_noise.frequency = config.frequency * 1.5
	_warp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_warp_noise.fractal_octaves = 3
	_warp_noise.fractal_lacunarity = 2.0
	_warp_noise.fractal_gain = 0.5

	_shore_noise.seed = config.rng_seed ^ 0xA5F1523D
	_shore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_shore_noise.frequency = max(0.01, config.frequency * 4.0)
	_shore_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_shore_noise.fractal_octaves = 3
	_shore_noise.fractal_lacunarity = 2.0
	_shore_noise.fractal_gain = 0.5

func _setup_temperature_extremes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.rng_seed) ^ 0x1234ABCD
	config.temp_min_c = lerp(-50.0, -15.0, rng.randf())
	config.temp_max_c = lerp(35.0, 85.0, rng.randf())
	config.lava_temp_threshold_c = clamp(config.lava_temp_threshold_c, config.temp_min_c, config.temp_max_c)

func clear() -> void:
	pass

func generate() -> PackedByteArray:
	var w: int = config.width
	var h: int = config.height
	var params := {
		"width": w,
		"height": h,
		"seed": config.rng_seed,
		"frequency": config.frequency,
		"octaves": config.octaves,
		"lacunarity": config.lacunarity,
		"gain": config.gain,
		"warp": config.warp,
		"sea_level": config.sea_level,
		"wrap_x": true,
		"temp_base_offset": config.temp_base_offset,
		"temp_scale": config.temp_scale,
		"moist_base_offset": config.moist_base_offset,
		"moist_scale": config.moist_scale,
		"continentality_scale": config.continentality_scale,
		"temp_min_c": config.temp_min_c,
		"temp_max_c": config.temp_max_c,
	}

	# Step 1: terrain
	var terrain := TerrainNoise.new().generate(params)
	last_height = terrain["height"]
	last_is_land = terrain["is_land"]
	# Track ocean coverage fraction for rendering transitions
	var ocean_count: int = 0
	for i_count in range(w * h):
		if last_is_land[i_count] == 0:
			ocean_count += 1
	last_ocean_fraction = float(ocean_count) / float(max(1, w * h))

	# Rivers disabled for now; refresh land mask only
	for iy in range(h):
		for ix in range(w):
			var ii: int = ix + iy * w
			last_is_land[ii] = 1 if last_height[ii] > config.sea_level else 0

	# Step 2: shoreline features (turquoise water & beaches)
	var shallow_threshold: float = config.shallow_threshold
	var size: int = w * h
	last_turquoise_water.resize(size)
	last_beach.resize(size)
	last_water_distance.resize(size)
	last_turquoise_strength.resize(size)
	for i in range(size):
		last_turquoise_water[i] = 0
		last_beach[i] = 0
		last_water_distance[i] = 0.0
		last_turquoise_strength[i] = 0.0
	for y in range(h):
		for x in range(w):
			var i2: int = x + y * w
			if last_is_land[i2] == 0:
				var depth: float = config.sea_level - last_height[i2]
				if depth >= 0.0 and depth <= shallow_threshold:
					var near_land: bool = false
					for dy2 in range(-1, 2):
						if near_land:
							break
						for dx2 in range(-1, 2):
							if dx2 == 0 and dy2 == 0:
								continue
							var nx: int = (x + dx2 + w) % w
							var ny: int = y + dy2
							if ny < 0 or ny >= h:
								continue
							var ni: int = nx + ny * w
							if last_is_land[ni] != 0:
								near_land = true
								break
					if near_land:
						var nval: float = _shore_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
						if nval > 0.55:
							last_turquoise_water[i2] = 1
							for dy3 in range(-1, 2):
								for dx3 in range(-1, 2):
									if dx3 == 0 and dy3 == 0:
										continue
									var nx2: int = (x + dx3 + w) % w
									var ny2: int = y + dy3
									if ny2 < 0 or ny2 >= h:
										continue
									var ni2: int = nx2 + ny2 * w
									if last_is_land[ni2] != 0:
										last_beach[ni2] = 1

	# Step 2b: distance to nearest land
	var frontier: Array = []
	var visited := PackedByteArray()
	visited.resize(size)
	for i3 in range(size):
		visited[i3] = 0
		if last_is_land[i3] != 0:
			frontier.append(i3)
	while frontier.size() > 0:
		var next_frontier: Array = []
		for idx in frontier:
			var x0: int = int(idx) % w
			var y0: int = floori(float(idx) / float(w))
			for dy4 in range(-1, 2):
				for dx4 in range(-1, 2):
					if dx4 == 0 and dy4 == 0:
						continue
					var nx3: int = (x0 + dx4 + w) % w
					var ny3: int = y0 + dy4
					if ny3 < 0 or ny3 >= h:
						continue
					var ni3: int = nx3 + ny3 * w
					if visited[ni3] != 0:
						continue
					visited[ni3] = 1
					var step_cost: float = 1.0
					if abs(dx4) + abs(dy4) != 1:
						step_cost = 1.4142
					var d: float = last_water_distance[idx] + step_cost
					if last_is_land[ni3] == 0:
						if last_water_distance[ni3] == 0.0:
							last_water_distance[ni3] = d
						else:
							last_water_distance[ni3] = min(last_water_distance[ni3], d)
						next_frontier.append(ni3)
		frontier = next_frontier

	# Step 2c: continuous turquoise strength
	var shallow_thresh2: float = config.shallow_threshold
	var shore_band: float = config.shore_band
	for y2 in range(h):
		for x2 in range(w):
			var j: int = x2 + y2 * w
			if last_is_land[j] != 0:
				last_turquoise_strength[j] = 0.0
				continue
			var depth2: float = config.sea_level - last_height[j]
			if depth2 < 0.0:
				depth2 = 0.0
			var s_depth: float = clamp(1.0 - depth2 / shallow_thresh2, 0.0, 1.0)
			var s_dist: float = 1.0 - clamp(last_water_distance[j] / shore_band, 0.0, 1.0)
			var nval: float = _shore_noise.get_noise_2d(float(x2), float(y2)) * 0.5 + 0.5
			var t: float = clamp((nval - 0.45) / 0.15, 0.0, 1.0)
			var s_noise: float = t * t * (3.0 - 2.0 * t)
			var strength: float = clamp(s_depth * s_dist * s_noise, 0.0, 1.0)
			last_turquoise_strength[j] = strength
			last_turquoise_water[j] = 1 if strength > 0.5 else 0

	# Step 3: climate
	var climate: Dictionary = ClimateNoise.new().generate(params, last_height, last_is_land)
	last_temperature = climate["temperature"]
	last_moisture = climate["moisture"]
	last_distance_to_coast = climate.get("distance_to_coast", PackedFloat32Array())

	# Mountain radiance: cool and moisten around mountains/alpine to disrupt bands
	_apply_mountain_radiance(w, h)

	# Step 4: biomes (pass freeze threshold)
	var params2 := params.duplicate()
	params2["freeze_temp_threshold"] = 0.16
	params2["height_scale_m"] = config.height_scale_m
	params2["lapse_c_per_km"] = 5.5
	last_biomes = BiomeClassifier.new().classify(params2, last_is_land, last_height, last_temperature, last_moisture, last_beach)

	# Step 4c: ensure every land cell has a valid biome id
	_ensure_valid_biomes()

	# Step 4c1: hot override — above ~30°C push to deserts/badlands
	_apply_hot_temperature_override(w, h)

	# Step 4c2: cold override — below ~2°C snow/ice dominates depending on humidity
	_apply_cold_temperature_override(w, h)

	# Step 4b: ensure ocean ice sheets are present from classifier immediately
	for yo in range(h):
		for xo in range(w):
			var io := xo + yo * w
			if last_is_land[io] == 0:
				# If classifier marked this ocean cell as ICE_SHEET, keep it
				if last_biomes[io] == BiomeClassifier.Biome.ICE_SHEET:
					continue
				# Otherwise keep as Ocean (already set by classifier)
				pass

	return last_is_land

func quick_update_sea_level(new_sea_level: float) -> PackedByteArray:
	# Fast path: only recompute artifacts depending on sea level.
	# Requires that base terrain (last_height) already exists.
	config.sea_level = new_sea_level
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_height.size() != size:
		# No terrain yet; fallback to full generation
		return generate()
	# 1) Recompute land mask
	if last_is_land.size() != size:
		last_is_land.resize(size)
	for i in range(size):
		last_is_land[i] = 1 if last_height[i] > config.sea_level else 0
	# Update ocean fraction
	var ocean_ct: int = 0
	for ii in range(size):
		if last_is_land[ii] == 0:
			ocean_ct += 1
	last_ocean_fraction = float(ocean_ct) / float(max(1, size))
	# 2) Recompute shoreline features (turquoise, beaches) and distance to land
	if last_turquoise_water.size() != size:
		last_turquoise_water.resize(size)
	if last_beach.size() != size:
		last_beach.resize(size)
	if last_water_distance.size() != size:
		last_water_distance.resize(size)
	if last_turquoise_strength.size() != size:
		last_turquoise_strength.resize(size)
	for i2 in range(size):
		last_turquoise_water[i2] = 0
		last_beach[i2] = 0
		last_water_distance[i2] = 0.0
		last_turquoise_strength[i2] = 0.0
	# 2a) mark turquoise and beaches near coast within shallow threshold
	var shallow_threshold: float = config.shallow_threshold
	for y in range(h):
		for x in range(w):
			var idx: int = x + y * w
			if last_is_land[idx] == 0:
				var depth: float = config.sea_level - last_height[idx]
				if depth >= 0.0 and depth <= shallow_threshold:
					var near_land: bool = false
					for dy in range(-1, 2):
						if near_land:
							break
						for dx in range(-1, 2):
							if dx == 0 and dy == 0:
								continue
							var nx: int = x + dx
							var ny: int = y + dy
							if nx < 0 or ny < 0 or nx >= w or ny >= h:
								continue
							var ni: int = nx + ny * w
							if last_is_land[ni] != 0:
								near_land = true
								break
					if near_land:
						var nval: float = _shore_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
						if nval > 0.55:
							last_turquoise_water[idx] = 1
							for dy2 in range(-1, 2):
								for dx2 in range(-1, 2):
									if dx2 == 0 and dy2 == 0:
										continue
									var nx2: int = x + dx2
									var ny2: int = y + dy2
									if nx2 < 0 or ny2 < 0 or nx2 >= w or ny2 >= h:
										continue
									var ni2: int = nx2 + ny2 * w
									if last_is_land[ni2] != 0:
										last_beach[ni2] = 1
	# 2b) recompute distance to nearest land (BFS wave)
	var frontier: Array = []
	var visited := PackedByteArray()
	visited.resize(size)
	for i3 in range(size):
		visited[i3] = 0
		if last_is_land[i3] != 0:
			frontier.append(i3)
	while frontier.size() > 0:
		var next_frontier: Array = []
		for idx2 in frontier:
			var x0: int = int(idx2) % w
			var y0: int = floori(float(idx2) / float(w))
			for dy3 in range(-1, 2):
				for dx3 in range(-1, 2):
					if dx3 == 0 and dy3 == 0:
						continue
					var nx3: int = x0 + dx3
					var ny3: int = y0 + dy3
					if nx3 < 0 or ny3 < 0 or nx3 >= w or ny3 >= h:
						continue
					var ni3: int = nx3 + ny3 * w
					if visited[ni3] != 0:
						continue
					visited[ni3] = 1
					var step_cost: float = 1.0
					if abs(dx3) + abs(dy3) != 1:
						step_cost = 1.4142
					var d: float = last_water_distance[idx2] + step_cost
					if last_is_land[ni3] == 0:
						if last_water_distance[ni3] == 0.0:
							last_water_distance[ni3] = d
						else:
							last_water_distance[ni3] = min(last_water_distance[ni3], d)
						next_frontier.append(ni3)
		frontier = next_frontier
	# 2c) continuous turquoise strength
	var shallow_thresh2: float = config.shallow_threshold
	var shore_band: float = config.shore_band
	for y2 in range(h):
		for x2 in range(w):
			var j: int = x2 + y2 * w
			if last_is_land[j] != 0:
				last_turquoise_strength[j] = 0.0
				continue
			var depth2: float = config.sea_level - last_height[j]
			if depth2 < 0.0:
				depth2 = 0.0
			var s_depth: float = clamp(1.0 - depth2 / shallow_thresh2, 0.0, 1.0)
			var s_dist: float = 1.0 - clamp(last_water_distance[j] / shore_band, 0.0, 1.0)
			var nval: float = _shore_noise.get_noise_2d(float(x2), float(y2)) * 0.5 + 0.5
			var t: float = clamp((nval - 0.45) / 0.15, 0.0, 1.0)
			var s_noise: float = t * t * (3.0 - 2.0 * t)
			var strength: float = clamp(s_depth * s_dist * s_noise, 0.0, 1.0)
			last_turquoise_strength[j] = strength
			last_turquoise_water[j] = 1 if strength > 0.5 else 0
	# 3) Recompute climate fields to reflect new coastline and sea coverage
	var params := {
		"width": w,
		"height": h,
		"seed": config.rng_seed,
		"frequency": config.frequency,
		"octaves": config.octaves,
		"lacunarity": config.lacunarity,
		"gain": config.gain,
		"warp": config.warp,
		"sea_level": config.sea_level,
		"temp_base_offset": config.temp_base_offset,
		"temp_scale": config.temp_scale,
		"moist_base_offset": config.moist_base_offset,
		"moist_scale": config.moist_scale,
		"continentality_scale": config.continentality_scale,
		"temp_min_c": config.temp_min_c,
		"temp_max_c": config.temp_max_c,
	}
	var climate: Dictionary = ClimateNoise.new().generate(params, last_height, last_is_land)
	last_temperature = climate["temperature"]
	last_moisture = climate["moisture"]
	last_distance_to_coast = climate.get("distance_to_coast", PackedFloat32Array())

	# 5) Reclassify biomes using updated climate
	var params2 := params.duplicate()
	params2["freeze_temp_threshold"] = 0.16
	params2["height_scale_m"] = config.height_scale_m
	params2["lapse_c_per_km"] = 5.5
	last_biomes = BiomeClassifier.new().classify(params2, last_is_land, last_height, last_temperature, last_moisture, last_beach)
	_ensure_valid_biomes()
	_apply_hot_temperature_override(w, h)
	_apply_cold_temperature_override(w, h)

	# 6) Update lava mask based on new temperatures
	last_lava.resize(size)
	for li in range(size):
		last_lava[li] = 0
	for ylv in range(h):
		for xlv in range(w):
			var ii: int = xlv + ylv * w
			# Rivers disabled; lava mask only by temperature
			var t_norm: float = (last_temperature[ii] if ii < last_temperature.size() else 0.0)
			var t_c: float = config.temp_min_c + t_norm * (config.temp_max_c - config.temp_min_c)
			if t_c >= config.lava_temp_threshold_c:
				last_lava[ii] = 1
	return last_is_land

func get_width() -> int:
	return config.width

func get_height() -> int:
	return config.height

func get_cell_info(x: int, y: int) -> Dictionary:
	if x < 0 or y < 0 or x >= config.width or y >= config.height:
		return {}
	var i: int = x + y * config.width
	var h_val: float = 0.0
	var land: bool = false
	if i >= 0 and i < last_height.size():
		h_val = last_height[i]
	if i >= 0 and i < last_is_land.size():
		land = last_is_land[i] != 0
	var beach: bool = false
	var turq: bool = false
	if i >= 0 and i < last_beach.size():
		beach = last_beach[i] != 0
	if i >= 0 and i < last_turquoise_water.size():
		turq = last_turquoise_water[i] != 0
	var is_lava: bool = false
	if i >= 0 and i < last_lava.size():
		is_lava = last_lava[i] != 0
	var biome_id: int = -1
	var biome_name: String = "Ocean"
	if i >= 0 and i < last_biomes.size():
		var bid: int = last_biomes[i]
		if land:
			biome_id = bid
			biome_name = _biome_to_string(bid)
		else:
			# Allow special ocean biomes like ICE_SHEET to show in info instead of generic Ocean
			if bid == BiomeClassifier.Biome.ICE_SHEET:
				biome_id = bid
				biome_name = _biome_to_string(bid)
			else:
				biome_id = -1
				biome_name = "Ocean"
	# Convert normalized temperature to Celsius using per-seed extremes
	var t_norm: float = (last_temperature[i] if i < last_temperature.size() else 0.5)
	var temp_c: float = config.temp_min_c + t_norm * (config.temp_max_c - config.temp_min_c)
	var humidity: float = (last_moisture[i] if i < last_moisture.size() else 0.5)
	return {
		"height": h_val,
		"is_land": land,
		"is_beach": beach,
		"is_turquoise_water": turq,
		"is_lava": is_lava,
		"biome": biome_id,
		"biome_name": biome_name,
		"temp_c": temp_c,
		"humidity": humidity,
	}

func _biome_to_string(b: int) -> String:
	match b:
		BiomeClassifier.Biome.ICE_SHEET:
			return "Ice Sheet"
		BiomeClassifier.Biome.OCEAN:
			return "Ocean"
		BiomeClassifier.Biome.BEACH:
			return "Beach"
		BiomeClassifier.Biome.DESERT_SAND:
			return "Sand Desert"
		BiomeClassifier.Biome.DESERT_ROCK:
			return "Rock Desert"
		BiomeClassifier.Biome.DESERT_ICE:
			return "Ice Desert"
		BiomeClassifier.Biome.STEPPE:
			return "Steppe"
		BiomeClassifier.Biome.GRASSLAND:
			return "Grassland"
		BiomeClassifier.Biome.MEADOW:
			return "Meadow"
		BiomeClassifier.Biome.PRAIRIE:
			return "Prairie"
		BiomeClassifier.Biome.SWAMP:
			return "Swamp"
		BiomeClassifier.Biome.BOREAL_FOREST:
			return "Boreal Forest"
		BiomeClassifier.Biome.CONIFER_FOREST:
			return "Conifer Forest"
		BiomeClassifier.Biome.TEMPERATE_FOREST:
			return "Temperate Forest"
		BiomeClassifier.Biome.RAINFOREST:
			return "Rainforest"
		BiomeClassifier.Biome.HILLS:
			return "Hills"
		BiomeClassifier.Biome.FOOTHILLS:
			return "Foothills"
		BiomeClassifier.Biome.MOUNTAINS:
			return "Mountains"
		BiomeClassifier.Biome.ALPINE:
			return "Alpine"
		_:
			return "Grassland"

func _ensure_valid_biomes() -> void:
	var w: int = config.width
	var h: int = config.height
	var size: int = w * h
	if last_biomes.size() != size:
		last_biomes.resize(size)
	for i in range(size):
		if last_is_land[i] == 0:
			# Preserve special ocean biomes like ICE_SHEET from classifier
			var prev: int = (last_biomes[i] if i < last_biomes.size() else BiomeClassifier.Biome.OCEAN)
			last_biomes[i] = prev if prev == BiomeClassifier.Biome.ICE_SHEET else BiomeClassifier.Biome.OCEAN
			continue
		if i < last_beach.size() and last_beach[i] != 0:
			last_biomes[i] = BiomeClassifier.Biome.BEACH
			continue
		var b: int = (last_biomes[i] if i < last_biomes.size() else -1)
		if b < 0 or b > BiomeClassifier.Biome.ALPINE:
			last_biomes[i] = _fallback_biome(i)

func _fallback_biome(i: int) -> int:
	# Deterministic fallback using same features as classifier
	var t: float = (last_temperature[i] if i < last_temperature.size() else 0.5)
	var m: float = (last_moisture[i] if i < last_moisture.size() else 0.5)
	var elev: float = (last_height[i] if i < last_height.size() else 0.0)
	# freeze check
	if t <= 0.16:
		return BiomeClassifier.Biome.DESERT_ICE
	var high: float = clamp((elev - 0.5) * 2.0, 0.0, 1.0)
	var alpine: float = clamp((elev - 0.8) * 5.0, 0.0, 1.0)
	var cold: float = clamp((0.45 - t) * 3.0, 0.0, 1.0)
	var hot: float = clamp((t - 0.60) * 2.4, 0.0, 1.0)
	var dry: float = clamp((0.40 - m) * 2.6, 0.0, 1.0)
	var wet: float = clamp((m - 0.70) * 2.6, 0.0, 1.0)
	if high > 0.6:
		return BiomeClassifier.Biome.ALPINE if alpine > 0.5 else BiomeClassifier.Biome.MOUNTAINS
	if dry > 0.6 and hot > 0.3:
		return BiomeClassifier.Biome.DESERT_SAND
	if dry > 0.6 and hot <= 0.3:
		return BiomeClassifier.Biome.DESERT_ROCK
	if cold > 0.6 and dry > 0.4:
		return BiomeClassifier.Biome.DESERT_ICE
	if wet > 0.6 and hot > 0.4:
		return BiomeClassifier.Biome.RAINFOREST
	if m > 0.55 and t > 0.5:
		return BiomeClassifier.Biome.TROPICAL_FOREST
	if wet > 0.5 and cold > 0.4:
		return BiomeClassifier.Biome.SWAMP
	if cold > 0.6:
		return BiomeClassifier.Biome.BOREAL_FOREST
	if m > 0.6 and t > 0.5:
		return BiomeClassifier.Biome.TEMPERATE_FOREST
	if m > 0.4 and t > 0.4:
		return BiomeClassifier.Biome.CONIFER_FOREST
	if m > 0.3 and t > 0.3:
		return BiomeClassifier.Biome.MEADOW
	if m > 0.25 and t > 0.35:
		return BiomeClassifier.Biome.PRAIRIE
	if m > 0.2 and t > 0.25:
		return BiomeClassifier.Biome.STEPPE
	if high > 0.3:
		return BiomeClassifier.Biome.FOOTHILLS
	if high > 0.2:
		return BiomeClassifier.Biome.HILLS
	return BiomeClassifier.Biome.GRASSLAND

func _apply_mountain_radiance(w: int, h: int) -> void:
	var passes: int = max(0, config.mountain_radiance_passes)
	if passes == 0:
		return
	var cool_amp: float = config.mountain_cool_amp
	var wet_amp: float = config.mountain_wet_amp
	if last_biomes.size() != w * h:
		return
	for p in range(passes):
		var temp2 := last_temperature.duplicate()
		var moist2 := last_moisture.duplicate()
		for y in range(h):
			for x in range(w):
				var i: int = x + y * w
				var b: int = last_biomes[i]
				if b == BiomeClassifier.Biome.MOUNTAINS or b == BiomeClassifier.Biome.ALPINE:
					for dy in range(-2, 3):
						for dx in range(-2, 3):
							var nx: int = x + dx
							var ny: int = y + dy
							if nx < 0 or ny < 0 or nx >= w or ny >= h:
								continue
							var j: int = nx + ny * w
							var dist: float = sqrt(float(dx * dx + dy * dy))
							var fall: float = clamp(1.0 - dist / 3.0, 0.0, 1.0)
							temp2[j] = clamp(temp2[j] - cool_amp * fall / float(passes), 0.0, 1.0)
							moist2[j] = clamp(moist2[j] + wet_amp * fall / float(passes), 0.0, 1.0)
		last_temperature = temp2
		last_moisture = moist2

func _apply_hot_temperature_override(w: int, h: int) -> void:
	var t_c_threshold: float = 30.0
	var n := FastNoiseLite.new()
	n.seed = int(config.rng_seed) ^ 0xBEEF
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.008
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if last_is_land.size() != w * h or last_is_land[i] == 0:
				continue
			var t_norm: float = (last_temperature[i] if i < last_temperature.size() else 0.5)
			var t_c: float = config.temp_min_c + t_norm * (config.temp_max_c - config.temp_min_c)
			if t_c >= t_c_threshold and t_c < config.lava_temp_threshold_c:
				var m: float = (last_moisture[i] if i < last_moisture.size() else 0.5)
				var b: int = last_biomes[i]
				# Very dry → deserts
				if m < 0.40:
					var hot: float = clamp((t_norm - 0.60) * 2.4, 0.0, 1.0)
					var noise_val: float = n.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
					var sand_prob: float = clamp(0.25 + 0.6 * hot, 0.0, 0.98)
					last_biomes[i] = BiomeClassifier.Biome.DESERT_SAND if noise_val < sand_prob else BiomeClassifier.Biome.DESERT_ROCK
				else:
					# Hot but not very dry: keep relief unless quite dry
					if (b == BiomeClassifier.Biome.MOUNTAINS or b == BiomeClassifier.Biome.ALPINE or b == BiomeClassifier.Biome.HILLS or b == BiomeClassifier.Biome.FOOTHILLS):
						if m < 0.35:
							last_biomes[i] = BiomeClassifier.Biome.DESERT_ROCK
						# else keep relief biome
					else:
						last_biomes[i] = BiomeClassifier.Biome.STEPPE

func _apply_cold_temperature_override(w: int, h: int) -> void:
	var t_c_threshold: float = 2.0
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if last_is_land.size() != w * h or last_is_land[i] == 0:
				continue
			var t_norm: float = (last_temperature[i] if i < last_temperature.size() else 0.5)
			var t_c: float = config.temp_min_c + t_norm * (config.temp_max_c - config.temp_min_c)
			if t_c <= t_c_threshold:
				var m: float = (last_moisture[i] if i < last_moisture.size() else 0.0)
				if m >= 0.25:
					last_biomes[i] = BiomeClassifier.Biome.DESERT_ICE
				else:
					last_biomes[i] = BiomeClassifier.Biome.DESERT_ROCK
