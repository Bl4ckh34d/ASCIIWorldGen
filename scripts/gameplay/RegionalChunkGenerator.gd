extends RefCounted
class_name RegionalChunkGenerator


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
const _OCEAN_C: int = 1 << 0
const _OCEAN_W: int = 1 << 1
const _OCEAN_E: int = 1 << 2
const _OCEAN_N: int = 1 << 3
const _OCEAN_S: int = 1 << 4
const _OCEAN_NW: int = 1 << 5
const _OCEAN_NE: int = 1 << 6
const _OCEAN_SW: int = 1 << 7
const _OCEAN_SE: int = 1 << 8

var world_seed_hash: int = 1
var world_width: int = 1
var world_height: int = 1
var world_biome_ids: PackedInt32Array = PackedInt32Array()
var biome_overrides: Dictionary = {} # Vector2i(wx, wy) -> biome_id override
var biome_transition_overrides: Dictionary = {} # Vector2i(wx, wy) -> {from_biome,to_biome,progress}
var region_size: int = 96

var blend_band_m: int = 8
var border_warp_m: float = 2.0
var wade_depth_m: int = 3
# Prevent "neighbor takeover" on the first/last column of a world tile.
# Keeping edge influence below 0.5 avoids mirrored double-rims at tile seams.
var edge_neighbor_influence_max: float = 0.48

var _world_period_x_m: int = 96
var _world_radius_x_m: float = 1.0

var _noise_elev: FastNoiseLite = FastNoiseLite.new()
var _noise_rugged: FastNoiseLite = FastNoiseLite.new()
var _noise_veg: FastNoiseLite = FastNoiseLite.new()
var _noise_rock: FastNoiseLite = FastNoiseLite.new()
var _noise_border: FastNoiseLite = FastNoiseLite.new()
var _biome_param_cache: Dictionary = {} # biome_id -> RegionalGenParams dictionary
var _active_sample_cache: bool = false
var _active_blend_cache: Dictionary = {} # Vector2i(global_x, global_y) -> blended params
var _active_elev_cache: Dictionary = {} # Vector2i(global_x, global_y) -> float elevation
var _active_noise_x_cache: Dictionary = {} # wrapped_global_x -> Vector2(rx, rz)
var _macro_ocean_mask_cache: Dictionary = {} # Vector2i(world_tile_x, world_tile_y) -> bitmask
var _poi_grid_step: int = 12

func configure(seed_hash: int, world_w: int, world_h: int, biome_ids: PackedInt32Array, region_size_m: int = 96) -> void:
	world_seed_hash = seed_hash if seed_hash != 0 else 1
	world_width = max(1, world_w)
	world_height = max(1, world_h)
	world_biome_ids = biome_ids.duplicate()
	biome_overrides.clear()
	biome_transition_overrides.clear()
	region_size = max(16, region_size_m)
	_world_period_x_m = world_width * region_size
	_world_radius_x_m = float(_world_period_x_m) / TAU
	_biome_param_cache.clear()
	_macro_ocean_mask_cache.clear()
	_poi_grid_step = max(1, int(PoiRegistry.POI_GRID_STEP))
	_seed_noises()

func set_biome_overrides(overrides: Dictionary) -> void:
	# Optional: used to patch snapshot mismatches at runtime (e.g., click-selected biome).
	if typeof(overrides) != TYPE_DICTIONARY or overrides.is_empty():
		biome_overrides.clear()
		_macro_ocean_mask_cache.clear()
		return
	biome_overrides = overrides.duplicate(true)
	_macro_ocean_mask_cache.clear()

func set_biome_transition_overrides(overrides: Dictionary) -> void:
	# Optional gradual transitions keyed by world tile.
	# Entry schema: { from_biome: int, to_biome: int, progress: float 0..1 }.
	if typeof(overrides) != TYPE_DICTIONARY or overrides.is_empty():
		biome_transition_overrides.clear()
		_macro_ocean_mask_cache.clear()
		return
	biome_transition_overrides = overrides.duplicate(true)
	_macro_ocean_mask_cache.clear()

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
	var poi_cells: Dictionary = {} # idx -> {type, id}
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
	_active_sample_cache = true
	_active_blend_cache.clear()
	_active_elev_cache.clear()
	_active_noise_x_cache.clear()

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
			var poi_type: String = String(cell.get("poi_type", ""))
			if not poi_type.is_empty():
				poi_cells[i] = {
					"type": poi_type,
					"id": String(cell.get("poi_id", "")),
				}
	_active_sample_cache = false
	_active_blend_cache.clear()
	_active_elev_cache.clear()
	_active_noise_x_cache.clear()
	return {
		"chunk_size": cs,
		"ground": ground,
		"obj": obj,
		"flags": flags,
		"height_raw": heights,
		"biome": biomes,
		"poi_cells": poi_cells,
	}

func sample_cell(gx: int, gy: int) -> Dictionary:
	var x: int = _wrap_x(gx)
	var y: int = _clamp_y(gy)

	# Biome blending (noise-pattern border).
	var blend: Dictionary = _blend_params_cached(x, y)
	var surface_biome: int = int(blend.get("_biome_choice", 7))
	var wateriness: float = float(blend.get("water", 0.0))
	var sandiness: float = float(blend.get("sand", 0.0))
	var snowiness: float = float(blend.get("snow", 0.0))
	var swampiness: float = float(blend.get("swamp", 0.0))
	var trees: float = float(blend.get("trees", 0.0))
	var shrubs: float = float(blend.get("shrubs", 0.0))
	var rocks: float = float(blend.get("rocks", 0.0))
	var roughness: float = float(blend.get("roughness", 0.0))

	var elev: float = _sample_elevation_cached(x, y, blend)
	var height_raw: float = elev

	var out_ground: int = Ground.GRASS
	var out_obj: int = Obj.NONE
	var out_flags: int = 0
	var out_biome: int = surface_biome
	var out_poi_type: String = ""
	var out_poi_id: String = ""

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
		var slope: float = _estimate_slope(x, y, elev)
		var slope_threshold: float = lerp(0.18, 0.10, clamp(roughness, 0.0, 1.0))
		if slope >= slope_threshold:
			out_flags |= FLAG_BLOCKED

	# Ensure deterministic POIs remain reachable (override terrain at POI origin cell).
	var poi: Dictionary = {}
	if posmod(x, _poi_grid_step) == 0 and posmod(y, _poi_grid_step) == 0:
		poi = _poi_at_global(x, y)
	if not poi.is_empty():
		out_poi_type = String(poi.get("type", ""))
		out_poi_id = String(poi.get("id", ""))
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
		"poi_type": out_poi_type,
		"poi_id": out_poi_id,
	}

func _poi_at_global(gx: int, gy: int) -> Dictionary:
	var rs: float = float(max(1, region_size))
	var wx: int = int(floor(float(gx) / rs))
	var wy: int = int(floor(float(gy) / rs))
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
	var key := Vector2i(x, y)
	if biome_overrides.has(key):
		return int(biome_overrides.get(key, 7))
	var i: int = x + y * world_width
	if i < 0 or i >= world_biome_ids.size():
		return 7
	return int(world_biome_ids[i])

func _resolved_world_biome_at_sample(wx: int, wy: int, gx_sample: int, gy_sample: int) -> int:
	var x: int = posmod(wx, world_width)
	var y: int = clamp(wy, 0, world_height - 1)
	var key := Vector2i(x, y)
	var base_id: int = get_world_biome_id(x, y)
	if not biome_transition_overrides.has(key):
		return base_id
	var vv: Variant = biome_transition_overrides.get(key, {})
	if typeof(vv) != TYPE_DICTIONARY:
		return base_id
	var tr_data: Dictionary = vv as Dictionary
	var from_id: int = int(tr_data.get("from_biome", base_id))
	var to_id: int = int(tr_data.get("to_biome", base_id))
	var progress: float = clamp(float(tr_data.get("progress", 1.0)), 0.0, 1.0)
	if progress <= 0.0001:
		return from_id
	if progress >= 0.9999 or from_id == to_id:
		return to_id
	# Non-homogeneous transition: per-cell threshold with deterministic tile bias.
	var n0: float = clamp(_noise_border_periodic(gx_sample + x * 17 + 29, gy_sample + y * 11 - 37) * 0.5 + 0.5, 0.0, 1.0)
	var n1: float = _noise01_veg(gx_sample + x * 23 + 7, gy_sample + y * 19 - 5)
	var patch: float = clamp(0.65 * n0 + 0.35 * n1, 0.0, 1.0)
	var tile_bias: float = (float(abs(int(("reg_tile_bias|%d|%d|%d" % [world_seed_hash, x, y]).hash()) % 1000)) / 1000.0 - 0.5) * 0.14
	var threshold: float = clamp(progress + tile_bias, 0.0, 1.0)
	return to_id if patch <= threshold else from_id

func _blend_params_at(gx: int, gy: int) -> Dictionary:
	var rs: float = float(max(1, region_size))
	var wx: int = int(floor(float(gx) / rs))
	var wy: int = int(floor(float(gy) / rs))
	var lx: int = gx - wx * region_size
	var ly: int = gy - wy * region_size

	# Distance-based blend weights in a small band near tile borders.
	var band: float = float(max(1, blend_band_m))
	var lx_f: float = float(lx)
	var ly_f: float = float(ly)
	# Perturb the effective local coordinate to make borders irregular.
	lx_f = clamp(lx_f + (_noise_border_periodic(gx, gy) * border_warp_m), 0.0, float(region_size - 1))
	ly_f = clamp(ly_f + (_noise_border_periodic(gx + 97, gy - 53) * border_warp_m), 0.0, float(region_size - 1))

	var edge_cap: float = clamp(edge_neighbor_influence_max, 0.0, 0.4999)
	var x_w: float = _smooth01(clamp((band - lx_f) / band, 0.0, 1.0)) * edge_cap
	var x_e: float = _smooth01(clamp((band - (float(region_size - 1) - lx_f)) / band, 0.0, 1.0)) * edge_cap
	var y_n: float = _smooth01(clamp((band - ly_f) / band, 0.0, 1.0)) * edge_cap
	var y_s: float = _smooth01(clamp((band - (float(region_size - 1) - ly_f)) / band, 0.0, 1.0)) * edge_cap

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
		var base_id: int = _resolved_world_biome_at_sample(wx, wy, gx, gy)
		var p0: Dictionary = _params_for_biome_cached(base_id).duplicate(true)
		p0["_biome_choice"] = base_id
		p0["_biome_dominant"] = base_id
		return p0

	for k in weights.keys():
		var w: float = float(weights[k]) / sum_w
		if w <= 0.00001:
			continue
		var ox: int = int(k.x)
		var oy: int = int(k.y)
		# Evaluate all candidate macro tiles at the same global sample point.
		# Using shifted sample points causes mirrored seam stripes at tile borders.
		var bid: int = _resolved_world_biome_at_sample(wx + ox, wy + oy, gx, gy)
		var p: Dictionary = _params_for_biome_cached(bid)
		for key in p.keys():
			out[key] = float(out.get(key, 0.0)) + float(p[key]) * w
	var coast_influence: float = _coastal_ocean_influence(wx, wy, gx, gy, lx_f, ly_f)
	if coast_influence > 0.00001:
		_apply_coastal_bias(out, coast_influence, gx, gy)

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
	var dominant_id: int = _resolved_world_biome_at_sample(wx, wy, gx, gy)
	var dominant_w: float = -1.0
	for off in order:
		var ww: float = float(weights.get(off, 0.0)) / sum_w
		if ww > dominant_w:
			dominant_w = ww
			dominant_id = _resolved_world_biome_at_sample(wx + off.x, wy + off.y, gx, gy)
	var r: float = clamp((_noise_border_periodic(gx + 191, gy + 73) * 0.5 + 0.5), 0.0, 0.99999)
	var acc: float = 0.0
	var chosen_id: int = dominant_id
	for off2 in order:
		var ww2: float = float(weights.get(off2, 0.0)) / sum_w
		if ww2 <= 0.0:
			continue
		acc += ww2
		if r <= acc:
			chosen_id = _resolved_world_biome_at_sample(wx + off2.x, wy + off2.y, gx, gy)
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

func _estimate_slope(gx: int, gy: int, elev_here: float) -> float:
	var e_r: float = _sample_elevation_cached(_wrap_x(gx + 1), gy)
	var e_l: float = _sample_elevation_cached(_wrap_x(gx - 1), gy)
	var e_d: float = _sample_elevation_cached(gx, _clamp_y(gy + 1))
	var e_u: float = _sample_elevation_cached(gx, _clamp_y(gy - 1))
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
	var nx: Vector2 = _noise_coords_for_x(gx)
	return _noise_elev.get_noise_3d(float(nx.x), float(gy), float(nx.y)) * 0.5 + 0.5

func _noise01_rugged(gx: int, gy: int) -> float:
	var nx: Vector2 = _noise_coords_for_x(gx)
	return _noise_rugged.get_noise_3d(float(nx.x), float(gy), float(nx.y)) * 0.5 + 0.5

func _noise01_veg(gx: int, gy: int) -> float:
	var nx: Vector2 = _noise_coords_for_x(gx)
	return _noise_veg.get_noise_3d(float(nx.x), float(gy), float(nx.y)) * 0.5 + 0.5

func _noise01_rock(gx: int, gy: int) -> float:
	var nx: Vector2 = _noise_coords_for_x(gx)
	return _noise_rock.get_noise_3d(float(nx.x), float(gy), float(nx.y)) * 0.5 + 0.5

func _noise_border_periodic(gx: int, gy: int) -> float:
	# Periodic in X using the same cylindrical mapping as other fields.
	# Returns -1..1
	var nx: Vector2 = _noise_coords_for_x(gx)
	return _noise_border.get_noise_3d(float(nx.x), float(gy), float(nx.y))

func _smooth01(t: float) -> float:
	# Smoothstep(0..1)
	var x: float = clamp(t, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func _params_for_biome_cached(biome_id: int) -> Dictionary:
	var bid: int = int(biome_id)
	var vv: Variant = _biome_param_cache.get(bid, null)
	if typeof(vv) == TYPE_DICTIONARY:
		return vv as Dictionary
	var p: Dictionary = RegionalGenParams.params_for_biome(bid)
	_biome_param_cache[bid] = p
	return p

func _blend_params_cached(gx: int, gy: int) -> Dictionary:
	gx = _wrap_x(gx)
	gy = _clamp_y(gy)
	var key := Vector2i(gx, gy)
	if _active_sample_cache:
		var vv: Variant = _active_blend_cache.get(key, null)
		if typeof(vv) == TYPE_DICTIONARY:
			return vv as Dictionary
	var blend: Dictionary = _blend_params_at(gx, gy)
	if _active_sample_cache:
		_active_blend_cache[key] = blend
	return blend

func _sample_elevation_cached(gx: int, gy: int, blend: Dictionary = {}) -> float:
	gx = _wrap_x(gx)
	gy = _clamp_y(gy)
	var key := Vector2i(gx, gy)
	if _active_sample_cache and _active_elev_cache.has(key):
		return float(_active_elev_cache.get(key, 0.0))
	var blend_d: Dictionary = blend
	if blend_d.is_empty():
		blend_d = _blend_params_cached(gx, gy)
	var elev: float = _sample_elevation(gx, gy, blend_d)
	if _active_sample_cache:
		_active_elev_cache[key] = elev
	return elev

func _noise_coords_for_x(gx: int) -> Vector2:
	var xw: int = _wrap_x(gx)
	if _active_sample_cache and _active_noise_x_cache.has(xw):
		var cv: Variant = _active_noise_x_cache.get(xw, Vector2.ZERO)
		if cv is Vector2:
			return cv as Vector2
	var theta: float = TAU * (float(xw) / max(1.0, float(_world_period_x_m)))
	var out := Vector2(cos(theta) * _world_radius_x_m, sin(theta) * _world_radius_x_m)
	if _active_sample_cache:
		_active_noise_x_cache[xw] = out
	return out

func _is_macro_ocean_biome(biome_id: int) -> bool:
	return biome_id == 0 or biome_id == 1

func _macro_ocean_mask(wx: int, wy: int) -> int:
	var tx: int = posmod(wx, world_width)
	var ty: int = clamp(wy, 0, world_height - 1)
	var key := Vector2i(tx, ty)
	if _macro_ocean_mask_cache.has(key):
		return int(_macro_ocean_mask_cache.get(key, 0))
	var mask: int = 0
	if _is_macro_ocean_biome(get_world_biome_id(tx, ty)):
		mask |= _OCEAN_C
	if _is_macro_ocean_biome(get_world_biome_id(tx - 1, ty)):
		mask |= _OCEAN_W
	if _is_macro_ocean_biome(get_world_biome_id(tx + 1, ty)):
		mask |= _OCEAN_E
	if _is_macro_ocean_biome(get_world_biome_id(tx, ty - 1)):
		mask |= _OCEAN_N
	if _is_macro_ocean_biome(get_world_biome_id(tx, ty + 1)):
		mask |= _OCEAN_S
	if _is_macro_ocean_biome(get_world_biome_id(tx - 1, ty - 1)):
		mask |= _OCEAN_NW
	if _is_macro_ocean_biome(get_world_biome_id(tx + 1, ty - 1)):
		mask |= _OCEAN_NE
	if _is_macro_ocean_biome(get_world_biome_id(tx - 1, ty + 1)):
		mask |= _OCEAN_SW
	if _is_macro_ocean_biome(get_world_biome_id(tx + 1, ty + 1)):
		mask |= _OCEAN_SE
	_macro_ocean_mask_cache[key] = mask
	return mask

func _coast_falloff(distance_norm: float, range_norm: float) -> float:
	if range_norm <= 0.0001:
		return 0.0
	return _smooth01(clamp((range_norm - distance_norm) / range_norm, 0.0, 1.0))

func _coastal_ocean_influence(wx: int, wy: int, gx: int, gy: int, lx_f: float, ly_f: float) -> float:
	var mask: int = _macro_ocean_mask(wx, wy)
	if (mask & _OCEAN_C) != 0:
		return 1.0
	if (mask & (_OCEAN_W | _OCEAN_E | _OCEAN_N | _OCEAN_S | _OCEAN_NW | _OCEAN_NE | _OCEAN_SW | _OCEAN_SE)) == 0:
		return 0.0
	var denom: float = float(max(1, region_size - 1))
	var u: float = clamp(lx_f / denom, 0.0, 1.0)
	var v: float = clamp(ly_f / denom, 0.0, 1.0)
	# Light domain warp to avoid axis-aligned coast pressure.
	u = clamp(u + _noise_border_periodic(gx + 131, gy - 89) * 0.08, 0.0, 1.0)
	v = clamp(v + _noise_border_periodic(gx - 63, gy + 147) * 0.08, 0.0, 1.0)

	var range_card: float = 0.62
	var range_corner: float = 0.82

	var card: float = 0.0
	if (mask & _OCEAN_W) != 0:
		card = max(card, _coast_falloff(u, range_card))
	if (mask & _OCEAN_E) != 0:
		card = max(card, _coast_falloff(1.0 - u, range_card))
	if (mask & _OCEAN_N) != 0:
		card = max(card, _coast_falloff(v, range_card))
	if (mask & _OCEAN_S) != 0:
		card = max(card, _coast_falloff(1.0 - v, range_card))

	var corner: float = 0.0
	if (mask & _OCEAN_NW) != 0:
		corner = max(corner, _coast_falloff(Vector2(u, v).length(), range_corner))
	if (mask & _OCEAN_NE) != 0:
		corner = max(corner, _coast_falloff(Vector2(1.0 - u, v).length(), range_corner))
	if (mask & _OCEAN_SW) != 0:
		corner = max(corner, _coast_falloff(Vector2(u, 1.0 - v).length(), range_corner))
	if (mask & _OCEAN_SE) != 0:
		corner = max(corner, _coast_falloff(Vector2(1.0 - u, 1.0 - v).length(), range_corner))
	# If two cardinal ocean neighbors meet at a corner, synthesize a soft radial cut
	# even when the diagonal tile is not ocean. This avoids blocky L-corners.
	if (mask & _OCEAN_W) != 0 and (mask & _OCEAN_N) != 0:
		corner = max(corner, _coast_falloff(Vector2(u, v).length(), range_corner * 0.90) * 0.82)
	if (mask & _OCEAN_E) != 0 and (mask & _OCEAN_N) != 0:
		corner = max(corner, _coast_falloff(Vector2(1.0 - u, v).length(), range_corner * 0.90) * 0.82)
	if (mask & _OCEAN_W) != 0 and (mask & _OCEAN_S) != 0:
		corner = max(corner, _coast_falloff(Vector2(u, 1.0 - v).length(), range_corner * 0.90) * 0.82)
	if (mask & _OCEAN_E) != 0 and (mask & _OCEAN_S) != 0:
		corner = max(corner, _coast_falloff(Vector2(1.0 - u, 1.0 - v).length(), range_corner * 0.90) * 0.82)

	return clamp(max(card, corner) + card * 0.10, 0.0, 1.0)

func _apply_coastal_bias(out: Dictionary, coast_influence: float, gx: int, gy: int) -> void:
	var n0: float = clamp(_noise_border_periodic(gx + 211, gy - 157) * 0.5 + 0.5, 0.0, 1.0)
	var shaped: float = clamp(coast_influence + (n0 - 0.5) * 0.24, 0.0, 1.0)
	var coast_push: float = _smooth01(clamp((shaped - 0.16) / 0.78, 0.0, 1.0))
	var water_base: float = float(out.get("water", 0.0))
	out["water"] = clamp(max(water_base, water_base * 0.50 + coast_push * 0.94), 0.0, 1.0)
	var sand_base: float = float(out.get("sand", 0.0))
	var shore_band: float = _smooth01(clamp((shaped - 0.10) / 0.42, 0.0, 1.0))
	shore_band *= 1.0 - _smooth01(clamp((shaped - 0.66) / 0.28, 0.0, 1.0))
	out["sand"] = clamp(max(sand_base, sand_base * 0.72 + shore_band * 0.48), 0.0, 1.0)
