# File: res://scripts/WorldGenerator.gd
extends RefCounted

class_name WorldGenerator

class Config:
    var rng_seed: int = 0
    var width: int = 275
    var height: int = 62
    var octaves: int = 5
    var frequency: float = 0.02
    var lacunarity: float = 2.0
    var gain: float = 0.5
    var warp: float = 24.0
    var sea_level: float = 0.0

var config := Config.new()

var _noise := FastNoiseLite.new()
var _warp_noise := FastNoiseLite.new()

func _init() -> void:
    randomize()
    config.rng_seed = randi()
    _setup_noises()

func apply_config(dict: Dictionary) -> void:
    if dict.has("seed"):
        var s: String = str(dict["seed"]) if typeof(dict["seed"]) != TYPE_NIL else ""
        config.rng_seed = s.hash() if s.length() > 0 else randi()
    if dict.has("width"): config.width = max(4, int(dict["width"]))
    if dict.has("height"): config.height = max(4, int(dict["height"]))
    if dict.has("octaves"): config.octaves = max(1, int(dict["octaves"]))
    if dict.has("frequency"): config.frequency = float(dict["frequency"])
    if dict.has("lacunarity"): config.lacunarity = float(dict["lacunarity"])
    if dict.has("gain"): config.gain = float(dict["gain"]) 
    if dict.has("warp"): config.warp = float(dict["warp"]) 
    if dict.has("sea_level"): config.sea_level = float(dict["sea_level"]) 
    _setup_noises()

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

func clear() -> void:
    pass

func generate() -> PackedByteArray:
    # Returns a boolean grid encoded as bytes (1 land, 0 water)
    var w := config.width
    var h := config.height
    var out := PackedByteArray()
    out.resize(w * h)

    # Add a large-scale continental mask using low frequency
    var base_noise := FastNoiseLite.new()
    base_noise.seed = config.rng_seed ^ 1234567
    base_noise.noise_type = FastNoiseLite.TYPE_PERLIN
    base_noise.frequency = max(0.002, config.frequency * 0.4)
    base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    base_noise.fractal_octaves = 4
    base_noise.fractal_lacunarity = 2.0
    base_noise.fractal_gain = 0.5

    # Radial falloff to encourage continents, not world-covering land; center-biased
    var cx := float(w) * 0.5
    var cy := float(h) * 0.5
    var max_r := sqrt(cx * cx + cy * cy)

    for y in range(h):
        for x in range(w):

            # Domain warp
            var wx: float = _warp_noise.get_noise_2d(x * 0.8, y * 0.8) * config.warp
            var wy: float = _warp_noise.get_noise_2d((x + 1000.0) * 0.8, (y - 777.0) * 0.8) * config.warp
            var sx: float = x + wx
            var sy: float = y + wy

            # Multi-octave base
            var n: float = _noise.get_noise_2d(sx, sy)

            # Continental scale mask
            var c: float = base_noise.get_noise_2d(x * 0.5, y * 0.5)
            var height_val: float = 0.65 * n + 0.45 * c

            # Edge falloff to reduce wrapping artifacts vertically, but keep horizontal wrap-like feel
            var dx: float = float(x) - cx
            var dy: float = float(y) - cy
            var r: float = sqrt(dx * dx + dy * dy) / max_r
            var falloff: float = clamp(1.0 - r * 0.85, 0.0, 1.0)
            height_val = height_val * 0.85 + falloff * 0.15

            # Normalize-ish to [-1, 1]
            height_val = clamp(height_val, -1.0, 1.0)

            var i: int = x + y * w
            var is_land: bool = height_val > config.sea_level
            out[i] = 1 if is_land else 0
    return out


