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
const _DIR_W: int = 0
const _DIR_E: int = 1
const _DIR_N: int = 2
const _DIR_S: int = 3

var world_seed_hash: int = 1
var world_width: int = 1
var world_height: int = 1
var world_biome_ids: PackedInt32Array = PackedInt32Array()
var world_river_mask: PackedByteArray = PackedByteArray()
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
var _tile_river_layout_cache: Dictionary = {} # Vector2i(world_tile_x, world_tile_y) -> layout dictionary
var _poi_grid_step: int = 12

func configure(
		seed_hash: int,
		world_w: int,
		world_h: int,
		biome_ids: PackedInt32Array,
		region_size_m: int = 96,
		river_mask: PackedByteArray = PackedByteArray()
) -> void:
	world_seed_hash = seed_hash if seed_hash != 0 else 1
	world_width = max(1, world_w)
	world_height = max(1, world_h)
	world_biome_ids = biome_ids.duplicate()
	var expected_cells: int = world_width * world_height
	world_river_mask = river_mask.duplicate() if river_mask.size() == expected_cells else PackedByteArray()
	biome_overrides.clear()
	biome_transition_overrides.clear()
	region_size = max(16, region_size_m)
	_world_period_x_m = world_width * region_size
	_world_radius_x_m = float(_world_period_x_m) / TAU
	_biome_param_cache.clear()
	_macro_ocean_mask_cache.clear()
	_tile_river_layout_cache.clear()
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
	_tile_river_layout_cache.clear()

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
	var wx: int = int(floor(float(x) / float(max(1, region_size))))
	var wy: int = int(floor(float(y) / float(max(1, region_size))))
	var lx: int = x - wx * region_size
	var ly: int = y - wy * region_size
	var river_strength: float = _river_strength_at(x, y, wx, wy, lx, ly)
	if river_strength > 0.0001:
		# Regional rivers are rendered as meandering shallow channels.
		# Keep them mostly wadeable while still visible from distance.
		wateriness = max(wateriness, 0.28 + river_strength * 0.30)

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
		# Build patchy beach strips where dry land meets coastal influence.
		var shore_mix: float = clamp(sandiness * 0.95 + wateriness * 0.75, 0.0, 1.0)
		if out_ground == Ground.GRASS or out_ground == Ground.DIRT:
			var shore_noise: float = _noise01_rock(x + 211, y - 149)
			var shore_thresh: float = clamp(shore_mix * 0.92, 0.0, 0.88)
			if shore_mix >= 0.18 and shore_noise <= shore_thresh:
				out_ground = Ground.SAND
				out_biome = 2

		# Objects (vegetation / boulders).
		var veg_macro: float = _noise01_veg(x + 311, y - 173)
		var veg_micro: float = _noise01_veg(x - 97, y + 251)
		var rock_macro: float = _noise01_rock(x + 443, y - 89)
		var veg_val: float = _noise01_veg(x, y)
		var rock_val: float = _noise01_rock(x, y)
		if out_ground == Ground.SWAMP:
			var reed_chance: float = clamp(shrubs * (0.34 + veg_macro * 0.56) + wateriness * 0.22, 0.0, 0.70)
			if veg_val <= reed_chance:
				out_obj = Obj.REED
		else:
			var lushness: float = clamp(
				trees * (0.52 + veg_macro * 0.70 + veg_micro * 0.34)
				+ swampiness * 0.24
				- sandiness * 0.30
				- snowiness * 0.18,
				0.0,
				0.96
			)
			var shrub_chance: float = clamp(
				shrubs * (0.42 + veg_macro * 0.58 + (1.0 - lushness) * 0.18)
				+ swampiness * 0.08
				- sandiness * 0.12,
				0.0,
				0.92
			)
			var boulder_chance: float = clamp(
				rocks * (0.52 + roughness * 0.58 + rock_macro * 0.42)
				+ max(0.0, elev - 0.45) * 0.18,
				0.0,
				0.88
			)
			var shore_suppress: float = 1.0
			if out_ground == Ground.SAND:
				shore_suppress = 0.35
			lushness *= shore_suppress
			shrub_chance *= max(0.45, shore_suppress)
			if veg_val <= lushness:
				out_obj = Obj.TREE
			elif veg_val <= clamp(lushness + shrub_chance * (1.0 - lushness), 0.0, 0.98):
				out_obj = Obj.SHRUB
			elif rock_val <= boulder_chance:
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

func _has_macro_river(wx: int, wy: int) -> bool:
	var expected_cells: int = world_width * world_height
	if expected_cells <= 0 or world_river_mask.size() != expected_cells:
		return false
	if wy < 0 or wy >= world_height:
		return false
	var x: int = posmod(wx, world_width)
	var i: int = x + wy * world_width
	if i < 0 or i >= world_river_mask.size():
		return false
	return int(world_river_mask[i]) != 0

func _neighbor_river_dirs(wx: int, wy: int) -> Array[int]:
	var out: Array[int] = []
	if _has_macro_river(wx - 1, wy):
		out.append(_DIR_W)
	if _has_macro_river(wx + 1, wy):
		out.append(_DIR_E)
	if _has_macro_river(wx, wy - 1):
		out.append(_DIR_N)
	if _has_macro_river(wx, wy + 1):
		out.append(_DIR_S)
	return out

func _hash01_tile(wx: int, wy: int, salt: int) -> float:
	var h: int = ("reg_river_tile|%d|%d|%d|%d" % [world_seed_hash, wx, wy, salt]).hash()
	return float(abs(h % 1000003)) / 1000003.0

func _hash01_pair(ax: int, ay: int, bx: int, by: int, salt: int) -> float:
	var h: int = ("reg_river_pair|%d|%d|%d|%d|%d|%d" % [world_seed_hash, ax, ay, bx, by, salt]).hash()
	return float(abs(h % 1000003)) / 1000003.0

func _opposite_dir(dir: int) -> int:
	match dir:
		_DIR_W:
			return _DIR_E
		_DIR_E:
			return _DIR_W
		_DIR_N:
			return _DIR_S
		_DIR_S:
			return _DIR_N
		_:
			return _DIR_E

func _turn_left_dir(dir: int) -> int:
	match dir:
		_DIR_N:
			return _DIR_W
		_DIR_W:
			return _DIR_S
		_DIR_S:
			return _DIR_E
		_DIR_E:
			return _DIR_N
		_:
			return _DIR_W

func _turn_right_dir(dir: int) -> int:
	match dir:
		_DIR_N:
			return _DIR_E
		_DIR_E:
			return _DIR_S
		_DIR_S:
			return _DIR_W
		_DIR_W:
			return _DIR_N
		_:
			return _DIR_E

func _dir_score(wx: int, wy: int, dir: int, salt: int) -> float:
	return _hash01_tile(wx + dir * 17, wy - dir * 23, salt + dir * 101)

func _select_river_pair(wx: int, wy: int, center_has_river: bool, neighbor_dirs: Array[int]) -> Array[int]:
	var dirs: Array[int] = neighbor_dirs.duplicate()
	if dirs.is_empty():
		if not center_has_river:
			return []
		var first: int = [_DIR_W, _DIR_E, _DIR_N, _DIR_S][int(floor(_hash01_tile(wx, wy, 811) * 4.0)) % 4]
		var second: int = _opposite_dir(first)
		if _hash01_tile(wx, wy, 829) < 0.35:
			var side_dirs: Array[int] = [_turn_left_dir(first), _turn_right_dir(first)]
			second = side_dirs[int(floor(_hash01_tile(wx, wy, 839) * 2.0)) % 2]
		return [first, second]
	if dirs.size() == 1:
		var first1: int = int(dirs[0])
		var second1: int = _opposite_dir(first1)
		if _hash01_tile(wx, wy, 853) < 0.40:
			var side_dirs1: Array[int] = [_turn_left_dir(first1), _turn_right_dir(first1)]
			second1 = side_dirs1[int(floor(_hash01_tile(wx, wy, 859) * 2.0)) % 2]
		return [first1, second1]
	if dirs.has(_DIR_W) and dirs.has(_DIR_E) and dirs.has(_DIR_N) and dirs.has(_DIR_S):
		return ([_DIR_W, _DIR_E] if _hash01_tile(wx, wy, 863) < 0.5 else [_DIR_N, _DIR_S])
	if dirs.has(_DIR_W) and dirs.has(_DIR_E):
		if not dirs.has(_DIR_N) and not dirs.has(_DIR_S):
			return [_DIR_W, _DIR_E]
		if _hash01_tile(wx, wy, 877) < 0.72:
			return [_DIR_W, _DIR_E]
	if dirs.has(_DIR_N) and dirs.has(_DIR_S):
		if not dirs.has(_DIR_W) and not dirs.has(_DIR_E):
			return [_DIR_N, _DIR_S]
		if _hash01_tile(wx, wy, 883) < 0.72:
			return [_DIR_N, _DIR_S]
	var first_pick: int = int(dirs[0])
	var first_score: float = -1.0
	for dv in dirs:
		var d: int = int(dv)
		var s: float = _dir_score(wx, wy, d, 907)
		if s > first_score:
			first_score = s
			first_pick = d
	var second_pick: int = _opposite_dir(first_pick)
	var second_score: float = -1.0
	for dv2 in dirs:
		var d2: int = int(dv2)
		if d2 == first_pick:
			continue
		var s2: float = _dir_score(wx, wy, d2, 919)
		if d2 == _opposite_dir(first_pick):
			s2 += 0.16
		if s2 > second_score:
			second_score = s2
			second_pick = d2
	if second_pick == first_pick:
		second_pick = _opposite_dir(first_pick)
	return [first_pick, second_pick]

func _shared_edge_offset01(wx: int, wy: int, dir: int) -> float:
	var ax: int = posmod(wx, world_width)
	var ay: int = clamp(wy, 0, world_height - 1)
	var bx: int = ax
	var by: int = ay
	match dir:
		_DIR_W:
			bx = posmod(ax - 1, world_width)
		_DIR_E:
			bx = posmod(ax + 1, world_width)
		_DIR_N:
			by = ay - 1
		_DIR_S:
			by = ay + 1
		_:
			bx = posmod(ax + 1, world_width)
	if by < 0 or by >= world_height:
		return 0.5
	var k0x: int = ax
	var k0y: int = ay
	var k1x: int = bx
	var k1y: int = by
	if k0x > k1x or (k0x == k1x and k0y > k1y):
		var tx: int = k0x
		var ty: int = k0y
		k0x = k1x
		k0y = k1y
		k1x = tx
		k1y = ty
	return clamp(0.18 + _hash01_pair(k0x, k0y, k1x, k1y, 947) * 0.64, 0.12, 0.88)

func _edge_point_for_dir(wx: int, wy: int, dir: int) -> Vector2:
	var t: float = _shared_edge_offset01(wx, wy, dir)
	match dir:
		_DIR_W:
			return Vector2(0.0, t)
		_DIR_E:
			return Vector2(1.0, t)
		_DIR_N:
			return Vector2(t, 0.0)
		_DIR_S:
			return Vector2(t, 1.0)
		_:
			return Vector2(0.5, 0.5)

func _tile_river_layout(wx: int, wy: int) -> Dictionary:
	var tx: int = posmod(wx, world_width)
	var ty: int = clamp(wy, 0, world_height - 1)
	var key := Vector2i(tx, ty)
	if _tile_river_layout_cache.has(key):
		var cv: Variant = _tile_river_layout_cache.get(key, {})
		if typeof(cv) == TYPE_DICTIONARY:
			return cv as Dictionary
	var center_has_river: bool = _has_macro_river(tx, ty)
	var neighbor_dirs: Array[int] = _neighbor_river_dirs(tx, ty)
	if not center_has_river and neighbor_dirs.size() < 2:
		var none := {"valid": false}
		_tile_river_layout_cache[key] = none
		return none
	var pair: Array[int] = _select_river_pair(tx, ty, center_has_river, neighbor_dirs)
	if pair.size() < 2:
		var none2 := {"valid": false}
		_tile_river_layout_cache[key] = none2
		return none2
	var d0: int = int(pair[0])
	var d1: int = int(pair[1])
	if d0 == d1:
		var none3 := {"valid": false}
		_tile_river_layout_cache[key] = none3
		return none3
	var p0: Vector2 = _edge_point_for_dir(tx, ty, d0)
	var p1: Vector2 = _edge_point_for_dir(tx, ty, d1)
	var span: Vector2 = p1 - p0
	if span.length() <= 0.02:
		var none4 := {"valid": false}
		_tile_river_layout_cache[key] = none4
		return none4
	var dir_v: Vector2 = span.normalized()
	var perp: Vector2 = Vector2(-dir_v.y, dir_v.x)
	var bend_sign: float = -1.0 if _hash01_tile(tx, ty, 971) < 0.5 else 1.0
	var amp: float = 0.10 + _hash01_tile(tx, ty, 977) * 0.15
	if neighbor_dirs.size() >= 3:
		amp *= 0.65
	var along: float = (_hash01_tile(tx, ty, 983) - 0.5) * 0.18
	var pm: Vector2 = (p0 + p1) * 0.5 + perp * (amp * bend_sign) + dir_v * along
	pm.x = clamp(pm.x, 0.05, 0.95)
	pm.y = clamp(pm.y, 0.05, 0.95)
	var width: float = 0.024 + _hash01_tile(tx, ty, 991) * 0.020
	if center_has_river and neighbor_dirs.size() >= 2:
		width += 0.006
	var out := {
		"valid": true,
		"p0": p0,
		"pm": pm,
		"p1": p1,
		"width": clamp(width, 0.016, 0.065),
	}
	_tile_river_layout_cache[key] = out
	return out

func _distance_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var len2: float = ab.length_squared()
	if len2 <= 0.0000001:
		return p.distance_to(a)
	var t: float = clamp((p - a).dot(ab) / len2, 0.0, 1.0)
	var q: Vector2 = a + ab * t
	return p.distance_to(q)

func _river_strength_at(gx: int, gy: int, wx: int, wy: int, lx: int, ly: int) -> float:
	var layout: Dictionary = _tile_river_layout(wx, wy)
	if not bool(layout.get("valid", false)):
		return 0.0
	var p0: Vector2 = layout.get("p0", Vector2(0.0, 0.5))
	var pm: Vector2 = layout.get("pm", Vector2(0.5, 0.5))
	var p1: Vector2 = layout.get("p1", Vector2(1.0, 0.5))
	var denom: float = float(max(1, region_size - 1))
	var u: float = clamp(float(lx) / denom, 0.0, 1.0)
	var v: float = clamp(float(ly) / denom, 0.0, 1.0)
	var p: Vector2 = Vector2(u, v)
	var d: float = min(_distance_to_segment(p, p0, pm), _distance_to_segment(p, pm, p1))
	var base_w: float = float(layout.get("width", 0.032))
	var edge_noise: float = (_noise_border_periodic(gx + wx * 17 + 31, gy + wy * 19 - 47) * 0.5) * 0.010
	var width_here: float = clamp(base_w + edge_noise, 0.012, 0.090)
	if d >= width_here:
		return 0.0
	return clamp((width_here - d) / max(width_here, 0.0001), 0.0, 1.0)
