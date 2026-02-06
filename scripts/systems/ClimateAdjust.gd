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
			var local_day: float = 0.5 - 0.5 * cos(6.28318 * (float(params.get("time_of_day", 0.0)) + float(x) / float(max(1, w))))
			var night: float = 1.0 - local_day
			var warm: float = _smoothstep(0.30, 0.90, t)
			var coast_wet: float = 1.0 - _smoothstep(0.02, 0.45, dc)
			var interior: float = _smoothstep(0.18, 0.90, dc)
			var polar_dry: float = _smoothstep(0.65, 1.0, lat) * 0.22
			var land_px: bool = is_land[i] != 0
			var evap_ocean: float = 0.0
			var evap_land: float = 0.0
			var veg_potential: float = 0.0
			if land_px:
				evap_land = (0.08 + 0.20 * warm) * (0.25 + 0.75 * local_day)
				veg_potential = 0.55 * _smoothstep(0.30, 0.82, t) * (0.30 + 0.70 * coast_wet) * (1.0 - _smoothstep(0.72, 1.0, dc))
			else:
				evap_ocean = (0.34 + 0.48 * warm) * (0.45 + 0.55 * local_day)
			var transp: float = evap_land * veg_potential
			var trade_dry: float = interior * (0.04 + 0.11 * warm)
			var nocturnal_condense: float = (0.03 + 0.10 * night) * (0.35 + 0.65 * warm)
			var sea_mod: float = clamp(sea_level, -1.0, 1.0) * 0.08
			var m_seed: float = 0.48 + 0.18 * m_noise + 0.12 * m_adv + 0.10 * m_base
			var m_source: float = evap_ocean + transp + coast_wet * 0.12
			var m_sink: float = polar_dry + trade_dry + nocturnal_condense
			var target: float = clamp(0.62 + 0.26 * warm + 0.08 * night, 0.0, 1.0)
			if land_px:
				target = clamp(0.32 + 0.30 * veg_potential + 0.24 * coast_wet + 0.10 * night, 0.0, 1.0)
			var m: float = m_seed + m_source - m_sink + sea_mod + (ocean_frac - 0.5) * 0.06
			m = lerp(m, target, 0.26)
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

func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t: float = clamp((x - edge0) / max(0.0001, edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
