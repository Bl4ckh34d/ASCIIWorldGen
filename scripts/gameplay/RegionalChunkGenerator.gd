extends RefCounted
class_name RegionalChunkGenerator

const PoiRegistry = preload("res://scripts/gameplay/PoiRegistry.gd")
const RegionalGenParams = preload("res://scripts/gameplay/RegionalGenParams.gd")

enum Ground {
	GRASS = 0,
	DIRT = 1,
	SAND = 2,
	ROCK = 3,
	SNOW = 4,
	SWAMP = 5,
	WATER_SHALLOW = 6,
	WATER_DEEP = 7,
}

enum Obj {
	NONE = 0,
	TREE = 1,
	SHRUB = 2,
	BOULDER = 3,
	REED = 4,
}

const FLAG_BLOCKED: int = 1 << 0
const FLAG_SHALLOW_WATER: int = 1 << 1
const FLAG_DEEP_WATER: int = 1 << 2

var world_seed_hash: int = 1
var world_width: int = 1
var world_height: int = 1
var world_biome_ids: PackedInt32Array = PackedInt32Array()
var region_size: int = 96

var blend_band_m: int = 8
var border_warp_m: float = 2.0
var wade_depth_m: int = 3

var _world_period_x_m: int = 96
var _world_radius_x_m: float = 1.0

var _noise_elev: FastNoiseLite = FastNoiseLite.new()
var _noise_rugged: FastNoiseLite = FastNoiseLite.new()
var _noise_veg: FastNoiseLite = FastNoiseLite.new()
var _noise_rock: FastNoiseLite = FastNoiseLite.new()
var _noise_border: FastNoiseLite = FastNoiseLite.new()

func configure(seed_hash: int, world_w: int, world_h: int, biome_ids: PackedInt32Array, region_size_m: int = 96) -> void:
	world_seed_hash = seed_hash if seed_hash != 0 else 1
	world_width = max(1, world_w)
	world_height = max(1, world_h)
	world_biome_ids = biome_ids.duplicate()
	region_size = max(16, region_size_m)
	_world_period_x_m = world_width * region_size
	_world_radius_x_m = float(_world_period_x_m) / TAU
	_seed_noises()

func _seed_noises() -> void:
	_noise_elev.seed = world_seed_hash ^ 0x1A2B3C
	_noise_elev.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_elev.frequency = 0.012
	_noise_elev.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_elev.fractal_octaves = 4
	_noise_elev.fractal_lacunarity = 2.1
	_noise_elev.fractal_gain = 0.50

	_noise_rugged.seed = world_seed_hash ^ 0x55AA55
	_noise_rugged.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_rugged.frequency = 0.030
	_noise_rugged.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_rugged.fractal_octaves = 3
	_noise_rugged.fractal_lacunarity = 2.3
	_noise_rugged.fractal_gain = 0.45

	_noise_veg.seed = world_seed_hash ^ 0xBEEF11
	_noise_veg.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_veg.frequency = 0.055
	_noise_veg.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_veg.fractal_octaves = 2
	_noise_veg.fractal_lacunarity = 2.0
	_noise_veg.fractal_gain = 0.55

	_noise_rock.seed = world_seed_hash ^ 0xCAFE22
	_noise_rock.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_rock.frequency = 0.045

	_noise_border.seed = world_seed_hash ^ 0xD00D33
	_noise_border.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_border.frequency = 0.060

func generate_chunk(chunk_x: int, chunk_y: int, chunk_size: int) -> Dictionary:
	var cs: int = max(8, chunk_size)
	var ground := PackedByteArray()
	var obj := PackedByteArray()
	var flags := PackedByteArray()
	var heights := PackedFloat32Array()
	var biomes := PackedInt32Array()
	ground.resize(cs * cs)
	obj.resize(cs * cs)
	flags.resize(cs * cs)
	heights.resize(cs * cs)
	biomes.resize(cs * cs)
	ground.fill(Ground.GRASS)
	obj.fill(Obj.NONE)
	flags.fill(0)
	heights.fill(0.0)
	biomes.fill(7)

	for y in range(cs):
		for x in range(cs):
			var gx: int = chunk_x * cs + x
			var gy: int = chunk_y * cs + y
			gx = _wrap_x(gx)
			gy = _clamp_y(gy)
			var cell: Dictionary = sample_cell(gx, gy)
			var i: int = x + y * cs
			ground[i] = int(cell.get("ground", Ground.GRASS))
			obj[i] = int(cell.get("obj", Obj.NONE))
			flags[i] = int(cell.get("flags", 0))
			heights[i] = float(cell.get("height_raw", 0.0))
			biomes[i] = int(cell.get("biome", 7))
	return {
		"chunk_size": cs,
		"ground": ground,
		"obj": obj,
		"flags": flags,
		"height_raw": heights,
		"biome": biomes,
	}

func sample_cell(gx: int, gy: int) -> Dictionary:
	var x: int = _wrap_x(gx)
	var y: int = _clamp_y(gy)

	# Biome blending (noise-pattern border).
	var blend: Dictionary = _blend_params_at(x, y)
	var surface_biome: int = int(blend.get("_biome_choice", 7))
	var wateriness: float = float(blend.get("water", 0.0))
	var sandiness: float = float(blend.get("sand", 0.0))
	var snowiness: float = float(blend.get("snow", 0.0))
	var swampiness: float = float(blend.get("swamp", 0.0))
	var trees: float = float(blend.get("trees", 0.0))
	var shrubs: float = float(blend.get("shrubs", 0.0))
	var rocks: float = float(blend.get("rocks", 0.0))
	var roughness: float = float(blend.get("roughness", 0.0))

	var elev: float = _sample_elevation(x, y, blend)
	var height_raw: float = elev

	var out_ground: int = Ground.GRASS
	var out_obj: int = Obj.NONE
	var out_flags: int = 0
	var out_biome: int = surface_biome

	# Water depth bands (walkable shallows; no swimming).
	# Note: wateriness is a blended parameter, so coastlines appear naturally where land meets ocean tiles.
	if wateriness >= 0.72:
		out_ground = Ground.WATER_DEEP
		out_flags |= FLAG_DEEP_WATER | FLAG_BLOCKED
		height_raw = -0.65
		out_biome = (1 if surface_biome == 1 else 0)
	elif wateriness >= 0.26:
		out_ground = Ground.WATER_SHALLOW
		out_flags |= FLAG_SHALLOW_WATER
		height_raw = -0.12
		out_biome = (1 if surface_biome == 1 else 0)
	else:
		# Land ground selection.
		if swampiness >= 0.55:
			out_ground = Ground.SWAMP
			out_biome = 10
		elif snowiness >= 0.65:
			out_ground = Ground.SNOW
			out_biome = 1
		elif sandiness >= 0.60:
			out_ground = Ground.SAND
			out_biome = 2
		else:
			var rockiness: float = clamp(rocks + elev * (0.65 + roughness * 0.55), 0.0, 1.0)
			if rockiness >= 0.68:
				out_ground = Ground.ROCK
			elif elev >= 0.58 and roughness >= 0.35 and rockiness >= 0.42:
				out_ground = Ground.DIRT
			else:
				out_ground = Ground.GRASS

		# Objects (vegetation / boulders).
		var veg_val: float = _noise01_veg(x, y)
		var rock_val: float = _noise01_rock(x, y)
		if out_ground == Ground.SWAMP:
			if veg_val <= clamp(shrubs * 0.40, 0.0, 0.45):
				out_obj = Obj.REED
		else:
			if veg_val <= clamp(trees, 0.0, 0.95):
				out_obj = Obj.TREE
			elif veg_val <= clamp(trees + shrubs, 0.0, 0.98):
				out_obj = Obj.SHRUB
			elif rock_val <= clamp(rocks, 0.0, 0.90):
				out_obj = Obj.BOULDER

		# Slope/cliff blocking (steep gradients are impassable).
		var slope: float = _estimate_slope(x, y, blend, elev)
		var slope_threshold: float = lerp(0.18, 0.10, clamp(roughness, 0.0, 1.0))
		if slope >= slope_threshold:
			out_flags |= FLAG_BLOCKED

	# Ensure deterministic POIs remain reachable (override terrain at POI origin cell).
	var poi: Dictionary = _poi_at_global(x, y)
	if not poi.is_empty():
		out_flags = 0
		out_obj = Obj.NONE
		if out_ground == Ground.WATER_DEEP:
			out_ground = Ground.SAND
		elif out_ground == Ground.WATER_SHALLOW:
			out_ground = Ground.SAND
		height_raw = max(height_raw, 0.02)
		out_biome = surface_biome

	return {
		"ground": out_ground,
		"obj": out_obj,
		"flags": out_flags,
		"height_raw": height_raw,
		"biome": out_biome,
	}

func _poi_at_global(gx: int, gy: int) -> Dictionary:
	var wx: int = int(gx / region_size)
	var wy: int = int(gy / region_size)
	var lx: int = gx - wx * region_size
	var ly: int = gy - wy * region_size
	wx = posmod(wx, world_width)
	wy = clamp(wy, 0, world_height - 1)
	var biome_id: int = get_world_biome_id(wx, wy)
	return PoiRegistry.get_poi_at(world_seed_hash, wx, wy, lx, ly, biome_id)

func get_world_biome_id(wx: int, wy: int) -> int:
	if world_biome_ids.size() != world_width * world_height:
		return 7
	var x: int = posmod(wx, world_width)
	var y: int = clamp(wy, 0, world_height - 1)
	var i: int = x + y * world_width
	if i < 0 or i >= world_biome_ids.size():
		return 7
	return int(world_biome_ids[i])

func _blend_params_at(gx: int, gy: int) -> Dictionary:
	var wx: int = int(gx / region_size)
	var wy: int = int(gy / region_size)
	var lx: int = gx - wx * region_size
	var ly: int = gy - wy * region_size

	# Distance-based blend weights in a small band near tile borders.
	var band: float = float(max(1, blend_band_m))
	var lx_f: float = float(lx)
	var ly_f: float = float(ly)
	# Perturb the effective local coordinate to make borders irregular.
	lx_f = clamp(lx_f + (_noise_border_periodic(gx, gy) * border_warp_m), 0.0, float(region_size - 1))
	ly_f = clamp(ly_f + (_noise_border_periodic(gx + 97, gy - 53) * border_warp_m), 0.0, float(region_size - 1))

	var x_w: float = _smooth01(clamp((band - lx_f) / band, 0.0, 1.0))
	var x_e: float = _smooth01(clamp((band - (float(region_size - 1) - lx_f)) / band, 0.0, 1.0))
	var y_n: float = _smooth01(clamp((band - ly_f) / band, 0.0, 1.0))
	var y_s: float = _smooth01(clamp((band - (float(region_size - 1) - ly_f)) / band, 0.0, 1.0))

	var x_c: float = clamp(1.0 - x_w - x_e, 0.0, 1.0)
	var y_c: float = clamp(1.0 - y_n - y_s, 0.0, 1.0)

	var weights: Dictionary = {
		Vector2i(0, 0): x_c * y_c,
		Vector2i(-1, 0): x_w * y_c,
		Vector2i(1, 0): x_e * y_c,
		Vector2i(0, -1): x_c * y_n,
		Vector2i(0, 1): x_c * y_s,
		Vector2i(-1, -1): x_w * y_n,
		Vector2i(1, -1): x_e * y_n,
		Vector2i(-1, 1): x_w * y_s,
		Vector2i(1, 1): x_e * y_s,
	}

	var out: Dictionary = {}
	var sum_w: float = 0.0
	for k in weights.keys():
		sum_w += float(weights[k])
	if sum_w <= 0.0001:
		var base_id: int = get_world_biome_id(wx, wy)
		var p0: Dictionary = RegionalGenParams.params_for_biome(base_id)
		p0["_biome_choice"] = base_id
		p0["_biome_dominant"] = base_id
		return p0

	for k in weights.keys():
		var w: float = float(weights[k]) / sum_w
		if w <= 0.00001:
			continue
		var ox: int = int(k.x)
		var oy: int = int(k.y)
		var bid: int = get_world_biome_id(wx + ox, wy + oy)
		var p: Dictionary = RegionalGenParams.params_for_biome(bid)
		for key in p.keys():
			out[key] = float(out.get(key, 0.0)) + float(p[key]) * w

	# Also expose a deterministic biome choice for rendering (patchy border blend).
	var order := [
		Vector2i(0, 0),
		Vector2i(-1, 0),
		Vector2i(1, 0),
		Vector2i(0, -1),
		Vector2i(0, 1),
		Vector2i(-1, -1),
		Vector2i(1, -1),
		Vector2i(-1, 1),
		Vector2i(1, 1),
	]
	var dominant_id: int = get_world_biome_id(wx, wy)
	var dominant_w: float = -1.0
	for off in order:
		var ww: float = float(weights.get(off, 0.0)) / sum_w
		if ww > dominant_w:
			dominant_w = ww
			dominant_id = get_world_biome_id(wx + off.x, wy + off.y)
	var r: float = clamp((_noise_border_periodic(gx + 191, gy + 73) * 0.5 + 0.5), 0.0, 0.99999)
	var acc: float = 0.0
	var chosen_id: int = dominant_id
	for off2 in order:
		var ww2: float = float(weights.get(off2, 0.0)) / sum_w
		if ww2 <= 0.0:
			continue
		acc += ww2
		if r <= acc:
			chosen_id = get_world_biome_id(wx + off2.x, wy + off2.y)
			break
	out["_biome_choice"] = chosen_id
	out["_biome_dominant"] = dominant_id
	return out

func _sample_elevation(gx: int, gy: int, blend: Dictionary) -> float:
	# Elevation is just a local proxy used for slope/cliff blocking and rough terrain breakup.
	var base_bias: float = float(blend.get("elev_bias", 0.0))
	var amp: float = float(blend.get("elev_amp", 0.22))
	var rough: float = float(blend.get("roughness", 0.0))
	var n0: float = _noise01_elev(gx, gy)
	var n1: float = _noise01_rugged(gx, gy)
	var elev: float = base_bias + (n0 - 0.5) * amp + (n1 - 0.5) * amp * (0.35 + rough * 0.85)
	return clamp(elev, 0.0, 1.0)

func _estimate_slope(gx: int, gy: int, blend: Dictionary, elev_here: float) -> float:
	var e_r: float = _sample_elevation(_wrap_x(gx + 1), gy, _blend_params_at(_wrap_x(gx + 1), gy))
	var e_l: float = _sample_elevation(_wrap_x(gx - 1), gy, _blend_params_at(_wrap_x(gx - 1), gy))
	var e_d: float = _sample_elevation(gx, _clamp_y(gy + 1), _blend_params_at(gx, _clamp_y(gy + 1)))
	var e_u: float = _sample_elevation(gx, _clamp_y(gy - 1), _blend_params_at(gx, _clamp_y(gy - 1)))
	var s: float = 0.0
	s = max(s, abs(elev_here - e_r))
	s = max(s, abs(elev_here - e_l))
	s = max(s, abs(elev_here - e_d))
	s = max(s, abs(elev_here - e_u))
	return s

func _wrap_x(gx: int) -> int:
	if _world_period_x_m <= 0:
		return gx
	return posmod(gx, _world_period_x_m)

func _clamp_y(gy: int) -> int:
	var max_y: int = world_height * region_size - 1
	return clamp(gy, 0, max_y)

func _noise01_elev(gx: int, gy: int) -> float:
	var theta: float = TAU * (float(_wrap_x(gx)) / max(1.0, float(_world_period_x_m)))
	var rx: float = cos(theta) * _world_radius_x_m
	var rz: float = sin(theta) * _world_radius_x_m
	return _noise_elev.get_noise_3d(rx, float(gy), rz) * 0.5 + 0.5

func _noise01_rugged(gx: int, gy: int) -> float:
	var theta: float = TAU * (float(_wrap_x(gx)) / max(1.0, float(_world_period_x_m)))
	var rx: float = cos(theta) * _world_radius_x_m
	var rz: float = sin(theta) * _world_radius_x_m
	return _noise_rugged.get_noise_3d(rx, float(gy), rz) * 0.5 + 0.5

func _noise01_veg(gx: int, gy: int) -> float:
	var theta: float = TAU * (float(_wrap_x(gx)) / max(1.0, float(_world_period_x_m)))
	var rx: float = cos(theta) * _world_radius_x_m
	var rz: float = sin(theta) * _world_radius_x_m
	return _noise_veg.get_noise_3d(rx, float(gy), rz) * 0.5 + 0.5

func _noise01_rock(gx: int, gy: int) -> float:
	var theta: float = TAU * (float(_wrap_x(gx)) / max(1.0, float(_world_period_x_m)))
	var rx: float = cos(theta) * _world_radius_x_m
	var rz: float = sin(theta) * _world_radius_x_m
	return _noise_rock.get_noise_3d(rx, float(gy), rz) * 0.5 + 0.5

func _noise_border_periodic(gx: int, gy: int) -> float:
	# Periodic in X using the same cylindrical mapping as other fields.
	# Returns -1..1
	var theta: float = TAU * (float(_wrap_x(gx)) / max(1.0, float(_world_period_x_m)))
	var rx: float = cos(theta) * _world_radius_x_m
	var rz: float = sin(theta) * _world_radius_x_m
	return _noise_border.get_noise_3d(rx, float(gy), rz)

func _smooth01(t: float) -> float:
	# Smoothstep(0..1)
	var x: float = clamp(t, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)
