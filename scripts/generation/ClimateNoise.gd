extends RefCounted

## Derives rough climate fields (temperature, moisture, precip) from latitude, longitude bands and turbulent noise

func generate(params: Dictionary, height: PackedFloat32Array, is_land: PackedByteArray) -> Dictionary:
	var w: int = int(params.get("width", 275))
	var h: int = int(params.get("height", 62))
	var rng_seed: int = int(params.get("seed", 0))
	var temp_base_offset: float = float(params.get("temp_base_offset", 0.0))
	var temp_scale: float = float(params.get("temp_scale", 1.0))
	var moist_base_offset: float = float(params.get("moist_base_offset", 0.0))
	var moist_scale: float = float(params.get("moist_scale", 1.0))
	var continentality_scale: float = float(params.get("continentality_scale", 1.0))

	var temp_noise := FastNoiseLite.new()
	temp_noise.seed = rng_seed ^ 0x5151
	temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	temp_noise.frequency = 0.02

	var moist_noise := FastNoiseLite.new()
	moist_noise.seed = rng_seed ^ 0xA1A1
	moist_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	moist_noise.frequency = 0.02

	# Vector-field-like turbulence for moisture advection
	var flow_u := FastNoiseLite.new()
	var flow_v := FastNoiseLite.new()
	flow_u.seed = rng_seed ^ 0xC0FE
	flow_v.seed = rng_seed ^ 0xF00D
	flow_u.noise_type = FastNoiseLite.TYPE_SIMPLEX
	flow_v.noise_type = FastNoiseLite.TYPE_SIMPLEX
	flow_u.frequency = 0.01
	flow_v.frequency = 0.01

	var temperature := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	var precip := PackedFloat32Array()
	var distance_to_coast := PackedFloat32Array()
	temperature.resize(w * h)
	moisture.resize(w * h)
	precip.resize(w * h)
	distance_to_coast.resize(w * h)

	# Precompute distance to coast (0 at ocean or immediate coast; grows inland)
	var inf := 1e9
	for i in range(w * h):
		distance_to_coast[i] = inf
	var q: Array = []
	for y0 in range(h):
		for x0 in range(w):
			var i0: int = x0 + y0 * w
			if is_land[i0] == 0:
				distance_to_coast[i0] = 0.0
				q.append(i0)
			else:
				# land cell adjacent to ocean gets distance 0 too (coastline)
				var coast := false
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var nx := x0 + dx
						var ny := y0 + dy
						if nx < 0 or ny < 0 or nx >= w or ny >= h:
							continue
						var ni := nx + ny * w
						if is_land[ni] == 0:
							coast = true
							break
				if coast:
					distance_to_coast[i0] = 0.0
					q.append(i0)
	while q.size() > 0:
		var cur: int = q.pop_front()
		var cx: int = cur % w
		var cy: int = int(float(cur) / float(w))
		var base_d: float = distance_to_coast[cur]
		for dy2 in range(-1, 2):
			for dx2 in range(-1, 2):
				if dx2 == 0 and dy2 == 0:
					continue
				var nx2 := cx + dx2
				var ny2 := cy + dy2
				if nx2 < 0 or ny2 < 0 or nx2 >= w or ny2 >= h:
					continue
				var ni2 := nx2 + ny2 * w
				var step: float = 1.0 if abs(dx2) + abs(dy2) == 1 else 1.4142
				var nd := base_d + step
				if nd < distance_to_coast[ni2]:
					distance_to_coast[ni2] = nd
					q.append(ni2)

	for y in range(h):
		# Latitude 0 at equator, 1 at poles
		var lat: float = abs(float(y) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
		for x in range(w):
			var i: int = x + y * w
			var elev_cool: float = clamp((height[i] - 0.1) * 0.7, 0.0, 1.0)
			var zonal: float = 0.5 + 0.5 * sin(6.28318 * float(y) / float(h) * 3.0)
			# Temperature latitudinal profile: quick warm-up from poles, slower approach to equator
			var u: float = 1.0 - lat
			var t_lat: float = 0.65 * pow(u, 0.8) + 0.35 * pow(u, 1.6)
			var t: float = t_lat * 0.82 + zonal * 0.15 - elev_cool * 0.9 + 0.18 * temp_noise.get_noise_2d(x, y)
			# Continentality: farther from coast → stronger extremes
			var dc: float = clamp(distance_to_coast[i] / float(max(1, w)), 0.0, 1.0) * continentality_scale
			var t_anom := (t - 0.5) * (1.0 + 0.8 * dc)
			t = clamp(0.5 + t_anom, 0.0, 1.0)
			t = clamp((t + temp_base_offset - 0.5) * temp_scale + 0.5, 0.0, 1.0)
			# Base humidity from zonal bands and noise
			var m_base: float = 0.5 + 0.3 * sin(6.28318 * float(y) / float(h) * 3.0)
			var m_noise: float = 0.3 * moist_noise.get_noise_2d(x + 100.0, y - 50.0)
			# Turbulent advection
			var adv_u: float = flow_u.get_noise_2d(x * 0.5, y * 0.5)
			var adv_v: float = flow_v.get_noise_2d((x + 1000.0) * 0.5, (y - 777.0) * 0.5)
			var sx: float = clamp(float(x) + adv_u * 6.0, 0.0, float(w - 1))
			var sy: float = clamp(float(y) + adv_v * 6.0, 0.0, float(h - 1))
			var m_adv: float = 0.2 * moist_noise.get_noise_2d(sx, sy)
			# Polar dryness bias
			var polar_dry: float = 0.20 * lat
			var m: float = m_base + m_noise + m_adv - polar_dry
			m = clamp((m + moist_base_offset - 0.5) * moist_scale + 0.5, 0.0, 1.0)
			# Precip proxy
			var slope_y: float = 0.0
			if y > 0 and y < h - 1:
				slope_y = height[i] - height[i - w]
			var rain_orography: float = clamp(0.5 + slope_y * 3.0, 0.0, 1.0)
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
