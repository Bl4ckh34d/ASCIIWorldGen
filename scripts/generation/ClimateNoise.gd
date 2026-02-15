extends RefCounted

## Derives rough climate fields (temperature, moisture, precip) from latitude, longitude bands and turbulent noise

const DEFAULT_WIDTH: int = 275
const DEFAULT_HEIGHT: int = 62
const TEMP_NOISE_FREQ: float = 0.02
const MOIST_NOISE_FREQ: float = 0.02
const FLOW_NOISE_FREQ: float = 0.01
const FLOW_ADVECTION_PIXELS: float = 6.0
const PRECIP_SLOPE_SCALE: float = 3.0

const _DIST_INF: float = 1e9
const _DIST_AXIS: float = 1.0
const _DIST_DIAG: float = 1.4142

func _is_ocean_or_coast(x: int, y: int, w: int, h: int, is_land: PackedByteArray) -> bool:
	var i: int = x + y * w
	if is_land[i] == 0:
		return true
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var nx: int = x + dx
			var ny: int = y + dy
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var ni: int = nx + ny * w
			if is_land[ni] == 0:
				return true
	return false

func _fallback_distance_transform(w: int, h: int, is_land: PackedByteArray) -> PackedFloat32Array:
	var dist := PackedFloat32Array()
	dist.resize(w * h)
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			dist[i] = 0.0 if _is_ocean_or_coast(x, y, w, h, is_land) else _DIST_INF

	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var d: float = dist[i]
			if x > 0:
				d = min(d, dist[i - 1] + _DIST_AXIS)
			if y > 0:
				d = min(d, dist[i - w] + _DIST_AXIS)
			if x > 0 and y > 0:
				d = min(d, dist[i - w - 1] + _DIST_DIAG)
			if x + 1 < w and y > 0:
				d = min(d, dist[i - w + 1] + _DIST_DIAG)
			dist[i] = d

	for y in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			var i: int = x + y * w
			var d: float = dist[i]
			if x + 1 < w:
				d = min(d, dist[i + 1] + _DIST_AXIS)
			if y + 1 < h:
				d = min(d, dist[i + w] + _DIST_AXIS)
			if x + 1 < w and y + 1 < h:
				d = min(d, dist[i + w + 1] + _DIST_DIAG)
			if x > 0 and y + 1 < h:
				d = min(d, dist[i + w - 1] + _DIST_DIAG)
			dist[i] = d
	return dist

func generate(params: Dictionary, height: PackedFloat32Array, is_land: PackedByteArray) -> Dictionary:
	var w: int = int(params.get("width", DEFAULT_WIDTH))
	var h: int = int(params.get("height", DEFAULT_HEIGHT))
	if w <= 0 or h <= 0:
		push_error("ClimateNoise.generate(): invalid dimensions (%d x %d)." % [w, h])
		return {
			"temperature": PackedFloat32Array(),
			"moisture": PackedFloat32Array(),
			"precip": PackedFloat32Array(),
			"distance_to_coast": PackedFloat32Array(),
		}
	var size: int = w * h
	if height.size() != size or is_land.size() != size:
		push_error("ClimateNoise.generate(): input array size mismatch (height=%d, land=%d, expected=%d)." % [height.size(), is_land.size(), size])
		return {
			"temperature": PackedFloat32Array(),
			"moisture": PackedFloat32Array(),
			"precip": PackedFloat32Array(),
			"distance_to_coast": PackedFloat32Array(),
		}
	var rng_seed: int = int(params.get("seed", 0))
	var temp_base_offset: float = float(params.get("temp_base_offset", 0.0))
	var temp_scale: float = float(params.get("temp_scale", 1.0))
	var moist_base_offset: float = float(params.get("moist_base_offset", 0.0))
	var moist_scale: float = float(params.get("moist_scale", 1.0))
	var continentality_scale: float = float(params.get("continentality_scale", 1.0))
	var _sea_level: float = float(params.get("sea_level", 0.0))

	var xscale: float = float(params.get("noise_x_scale", 1.0))
	var temp_noise := FastNoiseLite.new()
	temp_noise.seed = rng_seed ^ 0x5151
	temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	temp_noise.frequency = TEMP_NOISE_FREQ

	var moist_noise := FastNoiseLite.new()
	moist_noise.seed = rng_seed ^ 0xA1A1
	moist_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	moist_noise.frequency = MOIST_NOISE_FREQ

	# Vector-field-like turbulence for moisture advection
	var flow_u := FastNoiseLite.new()
	var flow_v := FastNoiseLite.new()
	flow_u.seed = rng_seed ^ 0xC0FE
	flow_v.seed = rng_seed ^ 0xF00D
	flow_u.noise_type = FastNoiseLite.TYPE_SIMPLEX
	flow_v.noise_type = FastNoiseLite.TYPE_SIMPLEX
	flow_u.frequency = FLOW_NOISE_FREQ
	flow_v.frequency = FLOW_NOISE_FREQ

	var temperature := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	var precip := PackedFloat32Array()
	var distance_to_coast := PackedFloat32Array()
	temperature.resize(w * h)
	moisture.resize(w * h)
	precip.resize(w * h)
	distance_to_coast.resize(w * h)

	# Global ocean fraction to modulate world humidity (high sea -> wetter; low sea -> drier).
	var ocean_frac_param: float = float(params.get("ocean_fraction", -1.0))
	var ocean_frac: float = ocean_frac_param
	if ocean_frac < 0.0 or ocean_frac > 1.0:
		var ocean_cells: int = 0
		for i0 in range(w * h):
			if is_land[i0] == 0:
				ocean_cells += 1
		ocean_frac = float(ocean_cells) / max(1.0, float(w * h))
	else:
		ocean_frac = clamp(ocean_frac, 0.0, 1.0)

	# Precompute distance to coast (0 at ocean or immediate coast; grows inland).
	# Prefer GPU-provided shared field from DistanceTransformCompute. Fallback remains O(n).
	var provided: PackedFloat32Array = params.get("distance_to_coast", PackedFloat32Array())
	if provided.size() == w * h:
		distance_to_coast = provided
	else:
		distance_to_coast = _fallback_distance_transform(w, h, is_land)

	for y in range(h):
		# Latitude 0 at equator, 1 at poles
		var lat: float = abs(float(y) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
		var y_scaled: float = float(y) * xscale
		for x in range(w):
			var i: int = x + y * w
			var elev_cool: float = clamp((height[i] - 0.1) * 0.7, 0.0, 1.0)
			var zonal: float = 0.5 + 0.5 * sin(6.28318 * float(y) / float(h) * 3.0)
			# Temperature latitudinal profile: quick warm-up from poles, slower approach to equator
			var u: float = 1.0 - lat
			var t_lat: float = 0.65 * pow(u, 0.8) + 0.35 * pow(u, 1.6)
			# Build temperature components
			var t_base: float = t_lat * 0.82 + zonal * 0.15 - elev_cool * 0.9
			var t_noise: float = 0.18 * temp_noise.get_noise_2d(x * xscale, y_scaled)
			var t_raw: float = t_base + t_noise
			# Continentality: farther from coast -> stronger extremes (scale around baseline, not global 0.5)
			var dc: float = clamp(distance_to_coast[i] / float(max(1, w)), 0.0, 1.0) * continentality_scale
			var factor: float = (1.0 + 0.8 * dc)
			var t: float = clamp(t_base + (t_raw - t_base) * factor, 0.0, 1.0)
			t = clamp((t + temp_base_offset - 0.5) * temp_scale + 0.5, 0.0, 1.0)
			# Base humidity from zonal bands and noise
			var m_base: float = 0.5 + 0.3 * sin(6.28318 * float(y) / float(h) * 3.0)
			var m_noise: float = 0.3 * moist_noise.get_noise_2d(x * xscale + 100.0, y_scaled - 50.0)
			# Turbulent advection
			var adv_u: float = flow_u.get_noise_2d(x * 0.5 * xscale, y_scaled * 0.5)
			var adv_v: float = flow_v.get_noise_2d((x * xscale + 1000.0) * 0.5, (y_scaled - 777.0) * 0.5)
			var sx: float = clamp(float(x) + adv_u * FLOW_ADVECTION_PIXELS, 0.0, float(w - 1))
			var sy: float = clamp(float(y) + adv_v * FLOW_ADVECTION_PIXELS, 0.0, float(h - 1))
			var m_adv: float = 0.2 * moist_noise.get_noise_2d(sx * xscale, sy * xscale)
			# Polar dryness bias
			var polar_dry: float = 0.20 * lat
			var m: float = m_base + m_noise + m_adv - polar_dry
			# Global humidity modulation by ocean coverage (0..1) and sea level slider (-1..1)
			# 1) Ocean fraction effect: high ocean -> wetter, low ocean -> drier
			var humid_amp: float = lerp(0.40, 1.60, ocean_frac)
			var humid_bias: float = lerp(-0.30, 0.30, ocean_frac)
			m = (m - 0.5) * humid_amp + 0.5 + humid_bias
			# 2) Additional sea level effect even when ocean coverage saturates
			var s_norm: float = clamp(_sea_level, -1.0, 1.0)
			var dryness_strength: float = max(0.0, -s_norm)
			var wet_strength: float = max(0.0, s_norm)
			var amp2: float = 1.0 + 0.5 * wet_strength - 0.5 * dryness_strength
			var bias2: float = 0.25 * wet_strength - 0.25 * dryness_strength
			m = (m - 0.5) * amp2 + 0.5 + bias2
			# Final per-world offsets and scaling
			m = clamp((m + moist_base_offset - 0.5) * moist_scale + 0.5, 0.0, 1.0)
			# Precip proxy
			var slope_y: float = 0.0
			if y > 0 and y < h - 1:
				slope_y = height[i] - height[i - w]
			var rain_orography: float = clamp(0.5 + slope_y * PRECIP_SLOPE_SCALE, 0.0, 1.0)
			var p: float = clamp((m * rain_orography), 0.0, 1.0)
			temperature[i] = clamp(t, 0.0, 1.0)
			moisture[i] = clamp(m, 0.0, 1.0)
			precip[i] = p

	return {
		"temperature": temperature,
		"moisture": moisture,
		"precip": precip,
		"distance_to_coast": distance_to_coast,
	}
