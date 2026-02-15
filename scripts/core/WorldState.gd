# File: res://scripts/core/WorldState.gd
extends RefCounted

## Central SoA container for world fields. Allocates fixed-size PackedArrays
## for performance and easy cross-system sharing. Initially used as a data
## holder; systems will progressively transition to read/write these buffers.

class_name _WorldStateInternal

var width: int = 0
var height: int = 0
var rng_seed: int = 0

# Metadata for rendering and conversions
var height_scale_m: float = 6000.0
var temp_min_c: float = -40.0
var temp_max_c: float = 70.0
var lava_temp_threshold_c: float = 120.0
var ocean_fraction: float = 0.0
var height_min_cache: float = 0.0
var height_max_cache: float = 1.0
var land_cell_count_cache: int = 0
var ocean_cell_count_cache: int = 0
var _height_cache_valid: bool = false
var _land_cache_valid: bool = false

# Topography
var height_field: PackedFloat32Array = PackedFloat32Array()

# Land–sea
var is_land: PackedByteArray = PackedByteArray()
var coast_distance: PackedFloat32Array = PackedFloat32Array()
var turquoise_water: PackedByteArray = PackedByteArray()
var turquoise_strength: PackedFloat32Array = PackedFloat32Array()
var beach: PackedByteArray = PackedByteArray()

# Hydro
var flow_dir: PackedInt32Array = PackedInt32Array()
var flow_accum: PackedFloat32Array = PackedFloat32Array()
var river: PackedByteArray = PackedByteArray()
var lake: PackedByteArray = PackedByteArray()
var lake_id: PackedInt32Array = PackedInt32Array()
var lava: PackedByteArray = PackedByteArray()

# Climate
var temperature: PackedFloat32Array = PackedFloat32Array()
var moisture: PackedFloat32Array = PackedFloat32Array()
var precip: PackedFloat32Array = PackedFloat32Array()

# Biomes
var biome_id: PackedInt32Array = PackedInt32Array()

# Time metadata (simulation)
var simulation_time_days: float = 0.0
var time_scale: float = 0.2
var tick_days: float = 1.0 / 1440.0

func configure(w: int, h: int, new_seed: int) -> void:
	width = max(1, w)
	height = max(1, h)
	rng_seed = new_seed
	_allocate_all()
	invalidate_all_caches()

func size() -> int:
	return width * height

func clear_fields() -> void:
	var n: int = size()
	if n <= 0:
		return
	for i in range(n):
		if i < height_field.size(): height_field[i] = 0.0
		if i < is_land.size(): is_land[i] = 0
		if i < coast_distance.size(): coast_distance[i] = 0.0
		if i < turquoise_water.size(): turquoise_water[i] = 0
		if i < turquoise_strength.size(): turquoise_strength[i] = 0.0
		if i < beach.size(): beach[i] = 0
		if i < flow_dir.size(): flow_dir[i] = 0
		if i < flow_accum.size(): flow_accum[i] = 0.0
		if i < river.size(): river[i] = 0
		if i < lake.size(): lake[i] = 0
		if i < lake_id.size(): lake_id[i] = 0
		if i < lava.size(): lava[i] = 0
		if i < temperature.size(): temperature[i] = 0.0
		if i < moisture.size(): moisture[i] = 0.0
		if i < precip.size(): precip[i] = 0.0
		if i < biome_id.size(): biome_id[i] = 0
	invalidate_all_caches()

func _allocate_all() -> void:
	var n: int = size()
	if n <= 0:
		return
	height_field.resize(n)
	is_land.resize(n)
	coast_distance.resize(n)
	turquoise_water.resize(n)
	turquoise_strength.resize(n)
	beach.resize(n)
	flow_dir.resize(n)
	flow_accum.resize(n)
	river.resize(n)
	lake.resize(n)
	lake_id.resize(n)
	lava.resize(n)
	temperature.resize(n)
	moisture.resize(n)
	precip.resize(n)
	biome_id.resize(n)
	invalidate_all_caches()

func index_of(x: int, y: int) -> int:
	return x + y * width

func invalidate_height_cache() -> void:
	_height_cache_valid = false

func invalidate_land_cache() -> void:
	_land_cache_valid = false

func invalidate_all_caches() -> void:
	_height_cache_valid = false
	_land_cache_valid = false

func recompute_height_cache() -> void:
	if height_field.is_empty():
		height_min_cache = 0.0
		height_max_cache = 1.0
		_height_cache_valid = true
		return
	var min_h: float = height_field[0]
	var max_h: float = height_field[0]
	for i in range(height_field.size()):
		var v: float = height_field[i]
		if v < min_h:
			min_h = v
		if v > max_h:
			max_h = v
	height_min_cache = min_h
	height_max_cache = max_h
	_height_cache_valid = true

func recompute_land_cache() -> void:
	var n: int = size()
	var land_cells: int = 0
	for i in range(min(n, is_land.size())):
		if is_land[i] != 0:
			land_cells += 1
	land_cell_count_cache = land_cells
	ocean_cell_count_cache = max(0, n - land_cells)
	ocean_fraction = float(ocean_cell_count_cache) / float(max(1, n))
	_land_cache_valid = true

func get_height_range_cached() -> Vector2:
	if not _height_cache_valid:
		recompute_height_cache()
	return Vector2(height_min_cache, height_max_cache)

func get_ocean_fraction_cached() -> float:
	if not _land_cache_valid:
		recompute_land_cache()
	return ocean_fraction
