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
	for y in range(h):
		var lat: float = abs(float(y) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
		for x in range(w):
			var i: int = x + y * w
			var elev_cool: float = clamp((height[i] - 0.1) * 0.7, 0.0, 1.0)
			var zonal: float = 0.5 + 0.5 * sin(6.28318 * float(y) / float(h) * 3.0)
			var u: float = 1.0 - lat
			var t_lat: float = 0.65 * pow(u, 0.8) + 0.35 * pow(u, 1.6)
			var t: float = t_lat * 0.82 + zonal * 0.15 - elev_cool * 0.9 + 0.18 * temp_noise.get_noise_2d(x * xscale, y)
			var dc: float = clamp(distance_to_coast[i] / float(max(1, w)), 0.0, 1.0) * continentality_scale
			var t_anom := (t - 0.5) * (1.0 + 0.8 * dc)
			t = clamp(0.5 + t_anom, 0.0, 1.0)
			t = clamp((t + temp_base_offset - 0.5) * temp_scale + 0.5, 0.0, 1.0)
			var m_base: float = 0.5 + 0.3 * sin(6.28318 * float(y) / float(h) * 3.0)
			var m_noise: float = 0.3 * moist_noise.get_noise_2d(x * xscale + 100.0, y - 50.0)
			var adv_u: float = flow_u.get_noise_2d(x * 0.5 * xscale, y * 0.5)
			var adv_v: float = flow_v.get_noise_2d((x * xscale + 1000.0) * 0.5, (y - 777.0) * 0.5)
			var sx: float = clamp(float(x) + adv_u * 6.0, 0.0, float(w - 1))
			var sy: float = clamp(float(y) + adv_v * 6.0, 0.0, float(h - 1))
			var m_adv: float = 0.2 * moist_noise.get_noise_2d(sx * xscale, sy)
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


