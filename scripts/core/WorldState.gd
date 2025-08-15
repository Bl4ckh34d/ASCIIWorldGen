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
var lava_temp_threshold_c: float = 55.0
var ocean_fraction: float = 0.0

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
var time_scale: float = 1.0
var tick_days: float = 1.0 / 120.0

func configure(w: int, h: int, new_seed: int) -> void:
    width = max(1, w)
    height = max(1, h)
    rng_seed = new_seed
    _allocate_all()

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

func index_of(x: int, y: int) -> int:
    return x + y * width


