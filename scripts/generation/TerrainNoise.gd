# File: res://scripts/generation/TerrainNoise.gd
extends RefCounted

## Generates base height and land mask using FBM + continental mask + domain warp

func generate(params: Dictionary) -> Dictionary:
	var w: int = int(params.get("width", 275))
	var h: int = int(params.get("height", 62))
	var sea_level: float = float(params.get("sea_level", 0.0))
	var rng_seed: int = int(params.get("seed", 0))
	var frequency: float = float(params.get("frequency", 0.02))
	var octaves: int = int(params.get("octaves", 5))
	var lacunarity: float = float(params.get("lacunarity", 2.0))
	var gain: float = float(params.get("gain", 0.5))
	var warp: float = float(params.get("warp", 24.0))
	var wrap_x: bool = bool(params.get("wrap_x", true))

	var noise := FastNoiseLite.new()
	noise.seed = rng_seed
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_lacunarity = lacunarity
	noise.fractal_gain = gain

	var warp_noise := FastNoiseLite.new()
	warp_noise.seed = rng_seed ^ 0x9E3779B9
	warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp_noise.frequency = frequency * 1.5
	warp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	warp_noise.fractal_octaves = 3
	warp_noise.fractal_lacunarity = 2.0
	warp_noise.fractal_gain = 0.5

	var base_noise := FastNoiseLite.new()
	base_noise.seed = rng_seed ^ 1234567
	base_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	base_noise.frequency = max(0.002, frequency * 0.4)
	base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	base_noise.fractal_octaves = 4
	base_noise.fractal_lacunarity = 2.0
	base_noise.fractal_gain = 0.5

	var height := PackedFloat32Array()
	var is_land := PackedByteArray()
	height.resize(w * h)
	is_land.resize(w * h)

	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.5
	var max_r: float = sqrt(cx * cx + cy * cy)

	for y in range(h):
		for x in range(w):
			var wx: float
			var wy: float
			if wrap_x:
				# Wrap domain-warp along X by blending samples at x and x+w
				var w0 := warp_noise.get_noise_2d(x * 0.8, y * 0.8)
				var w1 := warp_noise.get_noise_2d((x + float(w)) * 0.8, y * 0.8)
				var t := float(x) / float(max(1, w))
				wx = lerp(w0, w1, t) * warp
				var v0 := warp_noise.get_noise_2d((x + 1000.0) * 0.8, (y - 777.0) * 0.8)
				var v1 := warp_noise.get_noise_2d((x + 1000.0 + float(w)) * 0.8, (y - 777.0) * 0.8)
				wy = lerp(v0, v1, t) * warp
			else:
				wx = warp_noise.get_noise_2d(x * 0.8, y * 0.8) * warp
				wy = warp_noise.get_noise_2d((x + 1000.0) * 0.8, (y - 777.0) * 0.8) * warp
			var sx: float = x + wx
			var sy: float = y + wy
			var n: float
			var c: float
			if wrap_x:
				# Tileable sampling for base terrain and continental mask
				var n0 := noise.get_noise_2d(sx, sy)
				var n1 := noise.get_noise_2d(sx + float(w), sy)
				var t2 := float(x) / float(max(1, w))
				n = lerp(n0, n1, t2)
				var c0 := base_noise.get_noise_2d(x * 0.5, y * 0.5)
				var c1 := base_noise.get_noise_2d((x + float(w)) * 0.5, y * 0.5)
				c = lerp(c0, c1, t2)
			else:
				n = noise.get_noise_2d(sx, sy)
				c = base_noise.get_noise_2d(x * 0.5, y * 0.5)
			var hval: float = 0.65 * n + 0.45 * c

			if not wrap_x:
				var dx: float = float(x) - cx
				var dy: float = float(y) - cy
				var r: float = sqrt(dx * dx + dy * dy) / max_r
				var falloff: float = clamp(1.0 - r * 0.85, 0.0, 1.0)
				hval = hval * 0.85 + falloff * 0.15
			# For wrap_x, skip radial falloff to preserve seamless seam
			hval = clamp(hval, -1.0, 1.0)

			var i: int = x + y * w
			height[i] = hval
			is_land[i] = 1 if hval > sea_level else 0

	return {
		"height": height,
		"is_land": is_land,
	}
