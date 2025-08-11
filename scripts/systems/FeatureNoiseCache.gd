# File: res://scripts/systems/FeatureNoiseCache.gd
extends RefCounted

## Shared low-frequency noise fields used across systems (desert split,
## glacier wiggle, shore noise, continental shelf pattern). Building these
## up-front avoids per-cell noise instantiation in hot loops.

var width: int = 0
var height: int = 0
var rng_seed: int = 0
var noise_x_scale: float = 1.0

var desert_noise_field: PackedFloat32Array = PackedFloat32Array()     # 0..1
var ice_wiggle_field: PackedFloat32Array = PackedFloat32Array()       # -1..1
var shore_noise_field: PackedFloat32Array = PackedFloat32Array()      # 0..1
var shelf_value_noise_field: PackedFloat32Array = PackedFloat32Array()# 0..1

func build(params: Dictionary) -> void:
    width = int(params.get("width", 256))
    height = int(params.get("height", 128))
    rng_seed = int(params.get("seed", 0))
    var base_freq: float = float(params.get("frequency", 0.02))
    noise_x_scale = float(params.get("noise_x_scale", 1.0))
    var shelf_seed: int = int(params.get("shelf_seed", rng_seed ^ 0x5E1F))
    _allocate()
    _fill_desert_noise(rng_seed)
    _fill_ice_wiggle(rng_seed)
    _fill_shore_noise(rng_seed, max(0.01, base_freq * 4.0))
    _fill_shelf_value_noise(shelf_seed)

func _allocate() -> void:
    var n: int = max(0, width * height)
    desert_noise_field.resize(n)
    ice_wiggle_field.resize(n)
    shore_noise_field.resize(n)
    shelf_value_noise_field.resize(n)

func _fill_desert_noise(s: int) -> void:
    var n := FastNoiseLite.new()
    n.seed = s ^ 0x00BEEF
    n.noise_type = FastNoiseLite.TYPE_SIMPLEX
    n.frequency = 0.008
    var xscale: float = max(0.0001, noise_x_scale)
    for y in range(height):
        for x in range(width):
            var i: int = x + y * width
            desert_noise_field[i] = n.get_noise_2d(float(x) * xscale, float(y)) * 0.5 + 0.5

func _fill_ice_wiggle(s: int) -> void:
    var n := FastNoiseLite.new()
    n.seed = s ^ 0x0001CE
    n.noise_type = FastNoiseLite.TYPE_SIMPLEX
    n.frequency = 0.01
    var xscale2: float = max(0.0001, noise_x_scale)
    for y in range(height):
        for x in range(width):
            var i: int = x + y * width
            ice_wiggle_field[i] = n.get_noise_2d(float(x) * xscale2, float(y)) # -1..1

func _fill_shore_noise(s: int, freq: float) -> void:
    var n := FastNoiseLite.new()
    n.seed = s ^ 0xA5F1523D
    n.noise_type = FastNoiseLite.TYPE_SIMPLEX
    n.frequency = freq
    n.fractal_type = FastNoiseLite.FRACTAL_FBM
    n.fractal_octaves = 3
    n.fractal_lacunarity = 2.0
    n.fractal_gain = 0.5
    var xscale3: float = max(0.0001, noise_x_scale)
    for y in range(height):
        for x in range(width):
            var i: int = x + y * width
            shore_noise_field[i] = n.get_noise_2d(float(x) * xscale3, float(y)) * 0.5 + 0.5

func _fill_shelf_value_noise(s: int) -> void:
    # Coarse value-like noise as used by AsciiStyler for shelf variation.
    # Implement simple lattice hashing/interpolation here to avoid per-call cost.
    var scale: float = 20.0
    for y in range(height):
        for x in range(width):
            var i: int = x + y * width
            var sx: float = float(x) / max(0.0001, scale)
            var sy: float = float(y) / max(0.0001, scale)
            var xi: int = int(floor(sx))
            var yi: int = int(floor(sy))
            var tx: float = sx - float(xi)
            var ty: float = sy - float(yi)
            var h00: float = float(_hash(xi + 0, yi + 0, s) % 1000) / 1000.0
            var h10: float = float(_hash(xi + 1, yi + 0, s) % 1000) / 1000.0
            var h01: float = float(_hash(xi + 0, yi + 1, s) % 1000) / 1000.0
            var h11: float = float(_hash(xi + 1, yi + 1, s) % 1000) / 1000.0
            var nx0: float = lerp(h00, h10, tx)
            var nx1: float = lerp(h01, h11, tx)
            shelf_value_noise_field[i] = lerp(nx0, nx1, ty)

static func _hash(x: int, y: int, s: int) -> int:
    return abs(int(x) * 73856093 ^ int(y) * 19349663 ^ int(s) * 83492791)


