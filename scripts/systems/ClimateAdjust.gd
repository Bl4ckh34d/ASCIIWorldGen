# File: res://scripts/systems/ClimateAdjust.gd
extends RefCounted

## Fast pass recombining base fields with coast distance and user scalars.

func evaluate(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, base: Dictionary, params: Dictionary, distance_to_coast: PackedFloat32Array) -> Dictionary:
	var temp_noise: Object = base["temp_noise"]
	var moist_noise: Object = base["moist_noise"]
	var flow_u: Object = base["flow_u"]
	var flow_v: Object = base["flow_v"]

	var temp_base_offset: float = float(params.get("temp_base_offset", 0.0))
	var temp_scale: float = float(params.get("temp_scale", 1.0))
	var moist_base_offset: float = float(params.get("moist_base_offset", 0.0))
	var moist_scale: float = float(params.get("moist_scale", 1.0))
	var continentality_scale: float = float(params.get("continentality_scale", 1.0))
	var sea_level: float = float(params.get("sea_level", 0.0))

	var temperature := PackedFloat32Array(); temperature.resize(w * h)
	var moisture := PackedFloat32Array(); moisture.resize(w * h)
	var precip := PackedFloat32Array(); precip.resize(w * h)

	# Global ocean fraction
	var ocean_cells: int = 0
	for i0 in range(w * h):
		if is_land[i0] == 0:
			ocean_cells += 1
	var ocean_frac: float = float(ocean_cells) / max(1.0, float(w * h))

	var xscale: float = float(params.get("noise_x_scale", 1.0))
	# Anchored baseline: mean land height, so lapse doesn’t shift when sea level slider moves
	var land_sum: float = 0.0
	var land_count: int = 0
	for i_bl in range(w * h):
		if is_land[i_bl] != 0:
			land_sum += height[i_bl]
			land_count += 1
	var _anchored_baseline: float = (land_sum / float(max(1, land_count)))
	for y in range(h):
		var lat: float = abs(float(y) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
		var y_scaled: float = float(y) * xscale
		for x in range(w):
			var i: int = x + y * w
			# Apply elevation cooling above an anchored baseline (mean land height) to avoid global shifts with sea slider
			var rel_elev: float = max(0.0, height[i] - _anchored_baseline)
			var elev_cool: float = clamp(rel_elev * 1.2, 0.0, 1.0)
			var zonal: float = 0.5 + 0.5 * sin(6.28318 * float(y) / float(h) * 3.0)
			var u: float = 1.0 - lat
			var t_lat: float = 0.65 * pow(u, 0.8) + 0.35 * pow(u, 1.6)
			# Build temperature components
			var t_base: float = t_lat * 0.82 + zonal * 0.15 - elev_cool * 0.9
			var t_noise: float = 0.18 * temp_noise.get_noise_2d(x * xscale, y_scaled)
			var t_raw: float = t_base + t_noise
			# Continentality scales deviation around baseline (latitude/elevation/zonal), not global midpoint
			var dc: float = clamp(distance_to_coast[i] / float(max(1, w)), 0.0, 1.0) * continentality_scale
			var factor: float = (1.0 + 0.8 * dc)
			var t: float = clamp(t_base + (t_raw - t_base) * factor, 0.0, 1.0)
			# Seasonal term (CPU parity with shader). UI can set amplitudes; default 0 keeps parity.
			var season_phase: float = float(params.get("season_phase", 0.0))
			var season_amp_equator: float = float(params.get("season_amp_equator", 0.0))
			var season_amp_pole: float = float(params.get("season_amp_pole", 0.0))
			var season_ocean_damp: float = float(params.get("season_ocean_damp", 0.0))
			var amp_lat: float = lerp(season_amp_equator, season_amp_pole, pow(lat, 1.2))
			var cont_amp: float = 0.2 + 0.8 * dc
			var amp_cont: float = lerp(season_ocean_damp, 1.0, cont_amp)
			var season: float = amp_lat * amp_cont * cos(6.28318 * season_phase)
			t = clamp(t + season, 0.0, 1.0)
			t = clamp((t + temp_base_offset - 0.5) * temp_scale + 0.5, 0.0, 1.0)
			var m_base: float = 0.5 + 0.3 * sin(6.28318 * float(y) / float(h) * 3.0)
			var m_noise: float = 0.3 * moist_noise.get_noise_2d(x * xscale + 100.0, y_scaled - 50.0)
			var adv_u: float = flow_u.get_noise_2d(x * 0.5 * xscale, y_scaled * 0.5)
			var adv_v: float = flow_v.get_noise_2d((x * xscale + 1000.0) * 0.5, (y_scaled - 777.0) * 0.5)
			var sx: float = clamp(float(x) + adv_u * 6.0, 0.0, float(w - 1))
			var sy: float = clamp(float(y) + adv_v * 6.0, 0.0, float(h - 1))
			var m_adv: float = 0.2 * moist_noise.get_noise_2d(sx * xscale, sy * xscale)
			var polar_dry: float = 0.20 * lat
			var m: float = m_base + m_noise + m_adv - polar_dry
			var humid_amp: float = lerp(0.40, 1.60, ocean_frac)
			var humid_bias: float = lerp(-0.30, 0.30, ocean_frac)
			m = (m - 0.5) * humid_amp + 0.5 + humid_bias
			var s_norm: float = clamp(sea_level, -1.0, 1.0)
			var dryness_strength: float = max(0.0, -s_norm)
			var wet_strength: float = max(0.0, s_norm)
			var amp2: float = 1.0 + 0.5 * wet_strength - 0.5 * dryness_strength
			var bias2: float = 0.25 * wet_strength - 0.25 * dryness_strength
			m = (m - 0.5) * amp2 + 0.5 + bias2
			m = clamp((m + moist_base_offset - 0.5) * moist_scale + 0.5, 0.0, 1.0)
			# Precip proxy
			var slope_y: float = 0.0
			if y > 0 and y < h - 1:
				slope_y = height[i] - height[i - w]
			var rain_orography: float = clamp(0.5 + slope_y * 3.0, 0.0, 1.0)
			var p: float = clamp((m * rain_orography), 0.0, 1.0)
			temperature[i] = t
			moisture[i] = m
			precip[i] = p

	return {
		"temperature": temperature,
		"moisture": moisture,
		"precip": precip,
	}
