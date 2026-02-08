shader_type canvas_item;

// Procedural FF-style battle background (GPU-only).
// This is a scaffold: biome/day-night/weather variations are shader-driven and can later
// be replaced or augmented with hand-drawn textures per biome.

uniform float u_time = 0.0;
uniform float u_time_of_day = 0.5; // 0..1
uniform float u_cloud_coverage = 0.4; // 0..1
uniform float u_rain = 0.0; // 0..1
uniform vec3 u_biome_color = vec3(0.2, 0.8, 0.2);
uniform int u_kind = 0; // 0 plains, 1 forest, 2 hills, 3 mountains, 4 desert, 5 beach, 6 swamp, 7 snow
uniform vec4 u_moon0 = vec4(-1.0, -1.0, 0.0, 0.0);
uniform vec4 u_moon1 = vec4(-1.0, -1.0, 0.0, 0.0);
uniform vec4 u_moon2 = vec4(-1.0, -1.0, 0.0, 0.0);

const float TAU = 6.28318530718;

float _hash12(vec2 p) {
	// Deterministic hash 0..1
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float _noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = _hash12(i);
	float b = _hash12(i + vec2(1.0, 0.0));
	float c = _hash12(i + vec2(0.0, 1.0));
	float d = _hash12(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float _fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * _noise(p);
		p = p * 2.02 + vec2(17.3, -11.7);
		a *= 0.5;
	}
	return v;
}

vec3 _sky_color(float y, float day_factor, float sun_alt) {
	vec3 day_top = vec3(0.20, 0.50, 0.95);
	vec3 day_hz = vec3(0.78, 0.90, 1.00);
	vec3 night_top = vec3(0.02, 0.03, 0.07);
	vec3 night_hz = vec3(0.06, 0.06, 0.12);
	float hz_t = smoothstep(0.0, 0.60, y);
	vec3 sky_day = mix(day_top, day_hz, hz_t);
	vec3 sky_night = mix(night_top, night_hz, hz_t);
	vec3 sky = mix(sky_night, sky_day, day_factor);

	// Dawn/dusk tint near the horizon.
	float twi = 1.0 - smoothstep(0.08, 0.22, abs(sun_alt));
	vec3 warm = vec3(1.00, 0.55, 0.22);
	float warm_w = twi * (1.0 - smoothstep(0.25, 0.60, y)) * 0.55;
	sky = mix(sky, warm, warm_w);
	return sky;
}

float _silhouette_height(float x, float base, float amp) {
	float n = _fbm(vec2(x * 3.0, 2.1));
	return base - amp * n;
}

float _tree_line(float x, float base, float amp) {
	// Spiky treeline: combine coarse fbm with a high-frequency ridge.
	float n = _fbm(vec2(x * 2.2, 9.7));
	float ridge = abs(sin((x * 120.0) * TAU)) * 0.35;
	return base - amp * (0.65 * n + ridge);
}

vec3 _ground_color(float y, float hz, vec3 biome_col) {
	vec3 g0 = biome_col * vec3(0.55, 0.55, 0.55);
	vec3 g1 = biome_col * vec3(0.28, 0.28, 0.28);
	float t = smoothstep(hz, 1.0, y);
	return mix(g0, g1, t);
}

vec3 _draw_moon(vec2 uv, vec3 col, vec4 moon, float night_factor) {
	if (moon.z <= 0.0) {
		return col;
	}
	float d = length(uv - moon.xy);
	float edge = smoothstep(moon.z, moon.z - 0.006, d);
	float fill = 1.0 - edge;
	vec3 moon_col = vec3(0.95, 0.95, 0.98) * mix(0.35, 1.0, moon.w);
	return mix(col, moon_col, fill * night_factor);
}

void fragment() {
	// Pixelate for retro feel.
	vec2 res = vec2(320.0, 180.0);
	vec2 uv = floor(UV * res) / res;

	float tod = fract(u_time_of_day);
	float sun_alt = sin((tod - 0.25) * TAU);
	float day_factor = smoothstep(-0.05, 0.12, sun_alt);
	float night_factor = 1.0 - day_factor;

	float horizon = 0.58;
	float amp = 0.06;
	float hz_line = horizon;
	if (u_kind == 1) { // forest
		hz_line = _tree_line(uv.x, horizon, 0.10);
	} else if (u_kind == 2) { // hills
		hz_line = _silhouette_height(uv.x, horizon, 0.08);
	} else if (u_kind == 3) { // mountains
		hz_line = _silhouette_height(uv.x, horizon, 0.13);
		// Add jaggedness
		hz_line -= abs(sin(uv.x * 18.0 * TAU)) * 0.02;
	} else if (u_kind == 4) { // desert
		hz_line = _silhouette_height(uv.x, horizon, 0.06) - sin(uv.x * 8.0 * TAU) * 0.01;
	} else if (u_kind == 5) { // beach
		hz_line = horizon + 0.01;
	} else if (u_kind == 6) { // swamp
		hz_line = _silhouette_height(uv.x, horizon, 0.05);
	} else if (u_kind == 7) { // snow
		hz_line = _silhouette_height(uv.x, horizon, 0.09);
	}

	vec3 col = vec3(0.0);
	bool is_sky = (uv.y < hz_line);

	// Sky base.
	vec3 sky = _sky_color(uv.y, day_factor, sun_alt);

	// Stars at night.
	if (night_factor > 0.2 && is_sky) {
		float s = _hash12(uv * vec2(900.0, 520.0) + vec2(12.3, 91.7));
		float star = step(0.9972, s) * (1.0 - smoothstep(0.0, hz_line, uv.y));
		sky += vec3(1.0) * star * 0.85 * night_factor;
	}

	// Moons at night.
	if (night_factor > 0.2 && is_sky) {
		sky = _draw_moon(uv, sky, u_moon0, night_factor);
		sky = _draw_moon(uv, sky, u_moon1, night_factor);
		sky = _draw_moon(uv, sky, u_moon2, night_factor);
	}

	// Clouds (simple fbm layer) with coverage control.
	if (is_sky) {
		vec2 wind = vec2(0.018, 0.006);
		float c = _fbm(uv * vec2(3.5, 2.1) + wind * u_time);
		float cloud = smoothstep(0.60 - u_cloud_coverage * 0.35, 0.92, c);
		float overcast = smoothstep(0.35, 0.95, u_cloud_coverage);
		vec3 cloud_col = mix(vec3(0.55, 0.58, 0.62), vec3(1.0), day_factor) * 0.95;
		sky = mix(sky, cloud_col, cloud * (0.25 + 0.55 * overcast));
		// Global overcast darkening.
		sky = mix(sky, vec3(0.34, 0.36, 0.40), overcast * (0.35 + 0.25 * night_factor));
		// Rain darkening.
		sky = mix(sky, sky * 0.72, clamp(u_rain, 0.0, 1.0));
	}

	// Ground base.
	vec3 ground_col = _ground_color(uv.y, hz_line, u_biome_color);
	// Kind-specific ground tint.
	if (u_kind == 4) { // desert
		ground_col = mix(ground_col, vec3(0.78, 0.70, 0.42), 0.55);
	} else if (u_kind == 5) { // beach
		ground_col = mix(ground_col, vec3(0.92, 0.86, 0.62), 0.65);
	} else if (u_kind == 3) { // mountains
		ground_col = mix(ground_col, vec3(0.44, 0.44, 0.46), 0.55);
	} else if (u_kind == 6) { // swamp
		ground_col = mix(ground_col, vec3(0.18, 0.28, 0.20), 0.65);
	} else if (u_kind == 7) { // snow
		ground_col = mix(ground_col, vec3(0.88, 0.92, 0.98), 0.75);
	}

	// Beach special: add an ocean band near the horizon.
	if (u_kind == 5 && !is_sky) {
		float shore = smoothstep(hz_line + 0.02, hz_line + 0.10, uv.y);
		float wave = sin((uv.x * 12.0 + u_time * 0.35) * TAU) * 0.006;
		float water_line = hz_line + 0.05 + wave;
		float water = smoothstep(water_line, water_line + 0.01, uv.y);
		vec3 ocean = vec3(0.10, 0.35, 0.65) * (0.55 + 0.45 * day_factor);
		ground_col = mix(ocean, ground_col, shore);
		ground_col = mix(ocean, ground_col, water);
	}

	col = sky;
	if (!is_sky) {
		col = ground_col;
	}

	// Rain streaks overlay.
	if (u_rain > 0.02) {
		float rmask = smoothstep(0.15, 1.0, u_rain);
		float streak = _noise(vec2(uv.x * 120.0, uv.y * 12.0 + u_time * 6.0));
		float lines = step(0.86, streak) * rmask;
		col = mix(col, col * 0.82 + vec3(0.55, 0.60, 0.70) * 0.18, lines * 0.65);
	}

	COLOR = vec4(col, 1.0);
}

