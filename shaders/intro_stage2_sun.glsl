#[compute]
#version 450
// File: res://shaders/intro_stage2_sun.glsl
// Dedicated stage-2 (sun + orbital zone) intro compute shader.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform image2D out_tex;
layout(rgba32f, set = 0, binding = 1) uniform readonly image2D mycelium_tex;

layout(push_constant) uniform Params {
	int width;
	int height;
	int phase;
	int intro_phase;
	float phase_time;
	float total_time;
	float quote_alpha;
	float bigbang_progress;
	float star_alpha;
	float fade_alpha;
	float space_alpha;
	float pan_progress;
	float zoom_scale;
	float planet_x;
	float planet_preview_x;
	float orbit_y;
	float orbit_x_min;
	float orbit_x_max;
	float sun_start_x;
	float sun_start_y;
	float sun_end_x;
	float sun_end_y;
	float sun_radius;
	float zone_inner_radius;
	float zone_outer_radius;
	float planet_has_position;
	float moon_count;
	float moon_seed;
} PC;

const float TAU = 6.28318530718;
const float PI = 3.14159265359;
const int SHADER_PHASE_QUOTE = 0;
const int SHADER_PHASE_BIG_BANG = 1;
const int SHADER_PHASE_STAGE2 = 2;
const int INTRO_PHASE_CAMERA_PAN = 6;
const int INTRO_PHASE_PLANET_PLACE = 7;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i + vec2(0.0, 0.0));
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.55;
	for (int i = 0; i < 5; i++) {
		v += value_noise(p) * a;
		p *= 2.02;
		a *= 0.5;
	}
	return v;
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

mat2 rot2(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(c, -s, s, c);
}

vec2 flow_dir(vec2 p, float t) {
	float n0 = fbm(p * 0.95 + vec2(t * 0.18, -t * 0.12));
	float n1 = fbm(rot2(0.83) * p * 1.12 - vec2(t * 0.14, t * 0.16) + 7.3);
	float ang = (n0 * 2.0 - 1.0) * 2.4 + n1 * 3.2;
	return vec2(cos(ang), sin(ang));
}

vec4 hash4(vec4 n) {
	return fract(sin(n) * 1399763.5453123);
}

// Panteleymonov-style animated 4D noise field adapted for this shader.
float noise4q(vec4 x) {
	vec4 n3 = vec4(0.0, 0.25, 0.5, 0.75);
	vec4 p2 = floor(x.wwww + n3);
	vec4 b = floor(x.xxxx + n3) + floor(x.yyyy + n3) * 157.0 + floor(x.zzzz + n3) * 113.0;
	vec4 p1 = b + fract(p2 * 0.00390625) * vec4(164352.0, -164352.0, 163840.0, -163840.0);
	p2 = b + fract((p2 + 1.0) * 0.00390625) * vec4(164352.0, -164352.0, 163840.0, -163840.0);

	vec4 f1 = fract(x.xxxx + n3);
	vec4 f2 = fract(x.yyyy + n3);
	f1 = f1 * f1 * (3.0 - 2.0 * f1);
	f2 = f2 * f2 * (3.0 - 2.0 * f2);

	vec4 n1 = vec4(0.0, 1.0, 157.0, 158.0);
	vec4 n2 = vec4(113.0, 114.0, 270.0, 271.0);

	vec4 vs1 = mix(hash4(p1), hash4(n1.yyyy + p1), f1);
	vec4 vs2 = mix(hash4(n1.zzzz + p1), hash4(n1.wwww + p1), f1);
	vec4 vs3 = mix(hash4(p2), hash4(n1.yyyy + p2), f1);
	vec4 vs4 = mix(hash4(n1.zzzz + p2), hash4(n1.wwww + p2), f1);

	vs1 = mix(vs1, vs2, f2);
	vs3 = mix(vs3, vs4, f2);

	vs2 = mix(hash4(n2.xxxx + p1), hash4(n2.yyyy + p1), f1);
	vs4 = mix(hash4(n2.zzzz + p1), hash4(n2.wwww + p1), f1);
	vs2 = mix(vs2, vs4, f2);

	vs4 = mix(hash4(n2.xxxx + p2), hash4(n2.yyyy + p2), f1);
	vec4 vs5 = mix(hash4(n2.zzzz + p2), hash4(n2.wwww + p2), f1);
	vs4 = mix(vs4, vs5, f2);

	f1 = fract(x.zzzz + n3);
	f2 = fract(x.wwww + n3);
	f1 = f1 * f1 * (3.0 - 2.0 * f1);
	f2 = f2 * f2 * (3.0 - 2.0 * f2);

	vs1 = mix(vs1, vs2, f1);
	vs3 = mix(vs3, vs4, f1);
	vs1 = mix(vs1, vs3, f2);

	float r = dot(vs1, vec4(0.25));
	return r * r * (3.0 - 2.0 * r);
}

mat3 sun_corona_matrix(float anim) {
	vec2 rotate = vec2(anim * 0.025, -0.6);
	vec2 sins = sin(rotate);
	vec2 coss = cos(rotate);
	mat3 mr = mat3(
		vec3(coss.x, 0.0, sins.x),
		vec3(0.0, 1.0, 0.0),
		vec3(-sins.x, 0.0, coss.x)
	);
	return mat3(
		vec3(1.0, 0.0, 0.0),
		vec3(0.0, coss.y, sins.y),
		vec3(0.0, -sins.y, coss.y)
	) * mr;
}

float corona_ring(vec3 ray, vec3 pos, float r, float size) {
	float b = dot(ray, pos);
	float c = dot(pos, pos) - b * b;
	return max(0.0, (1.0 - size * abs(r - sqrt(max(0.0, c)))));
}

float corona_ring_ray_noise(vec3 ray, vec3 pos, float r, float size, mat3 mr, float anim) {
	float b = dot(ray, pos);
	vec3 pr = ray * b - pos;
	float c = length(pr);
	pr *= mr;
	pr = normalize(pr + vec3(1e-6));
	float s = max(0.0, (1.0 - size * abs(r - c)));
	float nd = noise4q(vec4(pr * 1.0, -anim + c)) * 2.0;
	nd = pow(nd, 2.0);
	float n = 0.4;
	float ns = 1.0;
	if (c > r) {
		n = noise4q(vec4(pr * 10.0, -anim + c));
		ns = noise4q(vec4(pr * 50.0, -anim * 2.5 + c * 2.0)) * 2.0;
		// Extra octave for finer plasma filaments.
		ns = ns * 0.55 + noise4q(vec4(pr * 150.0, -anim * 4.0 + c * 3.2)) * 0.45;
	}
	float grain = noise4q(vec4(pr * 220.0, -anim * 5.4 + c * 4.6));
	n = n * n * nd * ns;
	n *= 0.82 + grain * 0.35;
	return pow(s, 4.0) + s * s * n;
}

float corona_noise_texture(vec2 x) {
	// Keep corona noise fully procedural to avoid external image dependencies.
	float n0 = value_noise(x * 0.80 + vec2(13.7, -9.2));
	float n1 = value_noise(rot2(0.73) * x * 1.65 + vec2(-5.4, 7.1));
	float n2 = value_noise(rot2(-0.48) * x * 3.10 + vec2(17.3, 3.8));
	return clamp(n0 * 0.62 + n1 * 0.28 + n2 * 0.10, 0.0, 1.0);
}

float corona_ray_fbm(vec2 p) {
	float z = 2.0;
	float rz = -0.05;
	mat2 m2 = mat2(0.80, 0.60, -0.60, 0.80);
	p *= 0.25;
	for (int i = 1; i < 6; i++) {
		rz += abs((corona_noise_texture(p) - 0.5) * 2.0) / z;
		z *= 2.0;
		p = p * 2.0 * m2;
	}
	return rz;
}

vec3 shadertoy_corona(vec2 np, float t) {
	// Nimitz-style settings/flow.
	const float ray_brightness = 10.0;
	const float gamma = 5.0;
	const float ray_density = 4.5;
	const float curvature = 15.0;
	const float size = 0.1;

	float rn = length(np);
	vec2 ndir = np / max(1e-5, rn);
	// Anchor corona radius to the sun limb instead of the center point.
	float edge_r = max(0.0, rn - 1.0);
	vec2 uv = ndir * (edge_r * curvature * size);
	float r = length(uv);
	vec2 tangent = vec2(-ndir.y, ndir.x);
	// Build a non-linear tangential flow field so rays bend as they travel out.
	float bend0 = corona_noise_texture(ndir * 91.0 + vec2(edge_r * 33.0 + t * 0.23, edge_r * 19.0 - t * 0.17));
	float bend1 = corona_noise_texture(rot2(0.83) * ndir * 67.0 + vec2(edge_r * 21.0 - t * 0.19, edge_r * 29.0 + t * 0.13));
	float bend2 = corona_noise_texture(rot2(-0.61) * ndir * 123.0 + vec2(edge_r * 41.0 + t * 0.11, -edge_r * 37.0 - t * 0.15));
	float bend = (bend0 - 0.5) * 1.10 + (bend1 - 0.5) * 0.72 + (bend2 - 0.5) * 0.44;
	float bend_gain = 0.22 + smoothstep(0.0, 1.1, edge_r) * 1.35;
	vec2 ray_dir = normalize(rot2(bend * bend_gain) * ndir);

	// Radius-dependent lateral drift to avoid perfectly straight spokes.
	float lateral0 = corona_noise_texture(ray_dir * 73.0 + vec2(edge_r * 55.0 - t * 0.27, edge_r * 18.0 + t * 0.21)) - 0.5;
	float lateral1 = corona_noise_texture(ray_dir.yx * 59.0 + vec2(-edge_r * 27.0 + t * 0.19, edge_r * 47.0 - t * 0.14)) - 0.5;
	vec2 lateral = vec2(lateral0, lateral1) * (0.32 + edge_r * 0.88);
	float tt = -t * 0.33;
	float x = dot(ray_dir, vec2(0.5, 0.0)) + tt;
	float y = dot(ray_dir, vec2(0.0, 0.5)) + tt;
	vec2 sample_p = vec2(r + y * ray_density, r + x * ray_density);
	sample_p += vec2(dot(lateral, tangent), dot(lateral, ray_dir));
	sample_p += tangent * (bend * edge_r * 0.42);
	float val = corona_ray_fbm(sample_p);
	float val2 = corona_ray_fbm(sample_p * 1.31 + vec2(13.7, -9.2) + ray_dir * 0.75 + tangent * (bend * 0.58));
	float val3 = corona_ray_fbm(rot2(0.47) * sample_p * 0.87 + vec2(-7.9, 5.4));
	val = max(val, val2 * 0.93);
	val = mix(val, val3, 0.24);
	float g = gamma * 0.02 - 0.1;
	val = smoothstep(g, ray_brightness + g + 0.001, val);
	val = sqrt(max(0.0, val));
	// Keep sharp rays, but add dense filament occupancy for a heavier plasma look.
	float ray = smoothstep(0.44, 0.95, val);
	ray = pow(ray, 1.20);
	float soft = smoothstep(0.26, 0.88, val) * 0.58;
	float plume = smoothstep(0.62, 0.98, val) * smoothstep(0.04, 0.85, edge_r);
	float hot = smoothstep(0.86, 1.0, val);
	vec3 cor_deep = vec3(0.98, 0.24, 0.02);
	vec3 cor_hot = vec3(1.0, 0.72, 0.08);
	vec3 cor_core = vec3(1.0, 0.84, 0.40);
	vec3 col = mix(cor_deep, cor_hot, clamp(ray + soft * 0.4, 0.0, 1.0));
	col = mix(col, cor_core, hot * 0.85);
	col += cor_hot * plume * 0.52;
	col *= (ray + soft + plume * 0.35);
	return col;
}

float bump_soft_profile(float h) {
	h = clamp(h, 0.0, 1.0);
	float s = smoothstep(0.14, 0.90, h);
	return mix(h, s, 0.72);
}

vec2 sun_sine_warp(vec2 p, float t) {
	p = (p + 3.0) * 4.6;
	float tw = t * 0.18 + sin(t * 0.07) * 0.35;
	for (int i = 0; i < 3; i++) {
		p += cos(p.yx * 2.8 + vec2(tw, 1.57)) / 4.2;
		p += sin(p.yx * 1.14 + tw + vec2(1.57, 0.0)) / 3.5;
		p *= 1.23;
	}
	p += fract(sin(p + vec2(13.0, 7.0)) * 500000.0) * 0.006 - 0.003;
	return mod(p, 1.55) - 0.775;
}

// Continuous sibling of sun_sine_warp used to share the same morph behavior
// across multiple surface layers without introducing modular discontinuities.
vec2 sun_sine_morph_delta(vec2 p, float t) {
	vec2 q = (p + 3.0) * 5.4;
	vec2 q0 = q;
	float tw = t * 0.18 + sin(t * 0.07) * 0.35;
	float amp = 1.0;
	vec2 delta = vec2(0.0);
	for (int i = 0; i < 3; i++) {
		vec2 d = cos(q.yx * 3.3 + vec2(tw, 1.57)) / 4.9;
		d += sin(q.yx * 1.42 + tw + vec2(1.57, 0.0)) / 3.9;
		q += d;
		delta += d * amp;
		q *= 1.25;
		amp *= 0.62;
	}
	return (q - q0) / 5.4 + delta * 0.15;
}

float honey_cells(vec2 p, float t) {
	float slow_t = t * 0.16;
	vec2 q = p * 3.4;
	q += vec2(sin(slow_t * 0.90), cos(slow_t * 0.70)) * 0.18;
	float w0 = sin(q.x + slow_t * 0.35);
	float w1 = sin(dot(q, vec2(0.5, 0.8660254)) - slow_t * 0.28 + 1.10);
	float w2 = sin(dot(q, vec2(-0.5, 0.8660254)) + slow_t * 0.24 - 0.90);
	float tri = (w0 + w1 + w2) / 3.0;
	float cell = smoothstep(0.10, 0.88, 1.0 - abs(tri));
	float pocket = fbm(q * 1.35 + vec2(2.3, -1.4) + vec2(slow_t * 0.33, -slow_t * 0.27));
	return clamp(cell * 0.72 + pocket * 0.28, 0.0, 1.0);
}

float sun_bump_height(vec2 p, float t) {
	float slow_t = t * 0.52;
	float h = length(sun_sine_warp(p, slow_t)) * 0.7071;
	h = bump_soft_profile(h);
	float fine0 = fbm(p * 4.2 + vec2(-slow_t * 0.12, slow_t * 0.10));
	float fine1 = fbm(p * 9.6 + vec2(slow_t * 0.24, -slow_t * 0.20));
	float comb = honey_cells(p * 3.4, slow_t * 0.78);
	float micro = noise4q(vec4(vec3(p * 14.5 + vec2(83.23, 34.34), comb * 2.4 + 67.453), slow_t * 1.35));
	h = mix(h, fine0, 0.22);
	h = mix(h, fine1, 0.14);
	h = mix(h, comb, 0.12);
	h = mix(h, micro, 0.10);
	return smoothstep(0.12, 0.92, clamp(h, 0.0, 1.0));
}

// Rounded Voronoi field for photosphere-like granulation cells with periodic tiling.
// x = nearest-cell distance, y = edge distance (small near borders), z = cell id noise
vec3 sun_granule_voronoi(vec2 p, vec2 tile, float t) {
	vec2 p_wrap = mod(p, tile);
	vec2 p_norm = p_wrap / max(tile, vec2(1.0));
	vec2 warp0 = vec2(
		sin((p_norm.y + 0.20 * sin(p_norm.x * TAU * 2.2)) * TAU * 4.9),
		cos((p_norm.x + 0.18 * cos(p_norm.y * TAU * 1.9)) * TAU * 4.2)
	);
	vec2 warp1 = vec2(
		sin((p_norm.x + p_norm.y) * TAU * 6.1),
		cos((p_norm.x - p_norm.y) * TAU * 5.3)
	);
	float warp_morph0 = 0.5 + 0.5 * sin(t * 0.18 + dot(p_norm, vec2(11.0, 7.0)) * TAU);
	float warp_morph1 = 0.5 + 0.5 * cos(t * 0.14 - dot(p_norm, vec2(8.0, 13.0)) * TAU);
	p_wrap = mod(p_wrap + warp0 * mix(0.36, 0.50, warp_morph0) + warp1 * mix(0.18, 0.30, warp_morph1), tile);
	vec2 ip = floor(p_wrap);
	float d1 = 1e9;
	float d2 = 1e9;
	float cell_id = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 o = vec2(float(i), float(j));
			vec2 cell = mod(ip + o, tile);
			float h0 = hash12(cell + vec2(17.0, 91.0));
			float h1 = hash12(cell + vec2(53.0, 27.0));
			float h2 = hash12(cell + vec2(11.0, 63.0));
			float h3 = hash12(cell + vec2(87.0, 149.0));
			float h4 = hash12(cell + vec2(191.0, 37.0));
			float jitter_amp = mix(0.34, 1.22, h2);
			vec2 jitter = (vec2(h0, h1) - 0.5) * jitter_amp;
			jitter += vec2(
				cos(t * 0.09 + h0 * TAU + h2 * 3.1),
				sin(t * 0.08 + h1 * TAU + h2 * 5.3)
			) * mix(0.07, 0.16, h2);
			vec2 center = cell + vec2(0.5) + jitter * 0.84;
			vec2 r = center - p_wrap;
			r -= tile * round(r / tile);
			vec2 rr = r * vec2(mix(0.74, 1.38, h3), mix(0.74, 1.38, h4));
			rr += rr.yx * (h2 - 0.5) * 0.38;
			float d = dot(rr, rr) + (h2 - 0.5) * 0.50;
			if (d < d1) {
				d2 = d1;
				d1 = d;
				cell_id = hash12(cell + vec2(211.7, 73.1));
			} else if (d < d2) {
				d2 = d;
			}
		}
	}
	float f1 = sqrt(max(0.0, d1));
	float edge = sqrt(max(0.0, d2)) - f1;
	return vec3(f1, edge, cell_id);
}

float sun_voronoi_bump_height(vec3 vor) {
	float edge = 1.0 - smoothstep(0.014, 0.205, vor.y);
	float center = 1.0 - smoothstep(0.08, 0.47, vor.x);
	float cell = smoothstep(0.040, 0.34, vor.y);
	float ridge = pow(edge, 1.2);
	float cell_variation = 0.85 + vor.z * 0.35;
	float h = cell * 0.78 + center * 0.32 - ridge * 0.18 * cell_variation;
	return clamp(h, 0.0, 1.0);
}

vec2 sun_spherical_warp_coord(vec3 n, float t) {
	vec2 p = n.xy / max(0.30, n.z + 0.56);
	p += flow_dir(p * 2.2, t * 0.12) * 0.016;
	p += vec2(sin(t * 0.08 + p.y * 1.8), cos(t * 0.07 + p.x * 1.7)) * 0.007;
	return p;
}

float filament_field(vec2 p, float t, float scale, float thickness) {
	vec2 q = p * scale;
	float n0 = fbm(q + vec2(t * 0.17, -t * 0.13));
	float n1 = fbm(rot2(0.65) * q * 1.17 - vec2(t * 0.11, t * 0.09) + 11.7);
	float n = n0 * 0.68 + n1 * 0.32;
	float ridge = abs(n * 2.0 - 1.0);
	float line = clamp(1.0 - ridge / max(0.001, thickness), 0.0, 1.0);
	return line * line;
}

float planet_surface_height(vec2 s, float t) {
	float n0 = fbm(s * 8.2 + vec2(7.1, -4.3) + vec2(t * 0.03, -t * 0.02));
	float n1 = fbm(rot2(0.67) * s * 14.6 + vec2(-t * 0.06, t * 0.05) + vec2(-2.6, 3.8));
	vec2 drift = flow_dir(s * 2.4, t * 0.22) * 0.20;
	float veins = filament_field(s * 6.6 + drift, t * 0.25, 8.8, 0.23);
	float patch_val = smoothstep(0.20, 0.88, fbm(s * 4.8 + vec2(t * 0.05, -t * 0.04) + 11.3));
	return clamp(n0 * 0.46 + n1 * 0.24 + veins * 0.20 + patch_val * 0.10, 0.0, 1.0);
}

float flare_rnd(float w) {
	return fract(sin(w) * 1000.0);
}

float flare_reg_shape(vec2 p, int n) {
	float a = atan(p.x, p.y) + 0.2;
	float b = TAU / float(n);
	return smoothstep(0.5, 0.51, cos(floor(0.5 + a / b) * b - a) * length(p));
}

vec3 flare_circle(vec2 p, float size, float dist, vec2 drift) {
	float l = length(p + drift * (dist * 4.0)) + size * 0.5;
	float c = max(0.01 - pow(max(length(p + drift * dist), 1e-4), size * 1.4), 0.0) * 50.0;
	float c1 = max(0.001 - pow(max(l - 0.3, 1e-4), 1.0 / 40.0) + sin(l * 30.0), 0.0) * 3.0;
	float c2 = max(0.04 / pow(max(length(p - drift * dist * 0.5 + 0.09), 1e-4), 1.0), 0.0) / 20.0;
	float s = max(0.01 - pow(flare_reg_shape(p * 5.0 + drift * dist * 5.0 + 0.9, 6), 1.0), 0.0) * 5.0;
	vec3 color = cos(vec3(0.44, 0.24, 0.2) * 8.0 + dist * 4.0) * 0.5 + 0.5;
	vec3 f = (c + c1 + c2 + s) * color;
	return max(f - 0.01, vec3(0.0));
}

vec3 star_layer_colored(vec2 uv, float t, float scale, float pan_shift, float threshold, vec2 seed_bias) {
	vec2 su = fract(uv + vec2(pan_shift, 0.0));
	vec2 cell = floor(su * vec2(float(PC.width), float(PC.height)) * scale);
	float h = hash12(cell + seed_bias);
	float s = smoothstep(threshold, 1.0, h);
	float tw = 0.5 + 0.5 * sin(t * (1.4 + hash12(cell + 5.7) * 2.8) + hash12(cell + 12.3) * TAU);
	float lum = s * tw;
	float tint_pick = hash12(cell + seed_bias * 1.73 + vec2(73.1, 19.7));
	float blue_mask = step(0.989, tint_pick);
	float red_mask = step(0.976, tint_pick) * (1.0 - blue_mask);
	vec3 warm_col = vec3(0.95, 0.90, 0.74);
	vec3 red_col = vec3(0.96, 0.58, 0.50);
	vec3 blue_col = vec3(0.56, 0.70, 1.0);
	vec3 star_col = warm_col * (1.0 - red_mask - blue_mask);
	star_col += red_col * red_mask;
	star_col += blue_col * blue_mask;
	return star_col * lum;
}

vec3 stage2_star_sky(vec2 uv, float t, float pan, float alpha) {
	vec3 l0 = star_layer_colored(uv, t, 0.70, pan * 0.035, 0.9982, vec2(17.3, 41.7));
	vec3 l1 = star_layer_colored(uv, t, 1.25, pan * 0.080, 0.9988, vec2(51.8, 13.4));
	vec3 l2 = star_layer_colored(uv, t, 1.95, pan * 0.160, 0.9992, vec2(9.6, 77.2));
	vec3 s = l0 * 0.95 + l1 * 0.70 + l2 * 0.45;
	return s * alpha;
}

vec3 render_quote(vec2 uv, float t) {
	// Scene 1 starts in pure black before the big bang.
	return vec3(0.0);
}

vec4 sample_mycelium(vec2 uv) {
	vec2 size = vec2(float(max(1, PC.width)), float(max(1, PC.height)));
	vec2 px = clamp(uv * size, vec2(0.0), size - vec2(1.0));
	return imageLoad(mycelium_tex, ivec2(px));
}

vec3 render_bigbang(vec2 uv, float t) {
	float progress_raw = max(PC.bigbang_progress, 0.0);
	float timeline = clamp(progress_raw, 0.0, 1.0);
	float ignition = 1.0 - pow(1.0 - clamp(timeline / 0.11, 0.0, 1.0), 3.0);
	// Base expansion during early normalized phase.
	float s_curve = timeline * timeline * (3.0 - 2.0 * timeline);
	float expand_accel = pow(s_curve, 1.85);
	float expand = pow(timeline, 1.62);
	// Keep acceleration rising beyond timeline=1.0 (no late slowdown).
	float late_tail = max(progress_raw - 0.82, 0.0);
	float late_tail_pow = pow(late_tail, 2.30);
	float plasma_alpha = clamp(PC.quote_alpha, 0.0, 1.0);
	vec2 aspect = vec2(float(PC.width) / max(1.0, float(PC.height)), 1.0);
	vec2 q = (uv - 0.5) * aspect * 2.0;
	float r = length(q);
	vec4 my_edge_state = sample_mycelium(uv);
	float my_edge_density = clamp(my_edge_state.z, 0.0, 1.0);
	// The whole effect starts as a tiny central singularity and expands outwards.
	float spread = mix(0.004, 2.30, expand_accel) + 0.95 * late_tail_pow;
	float edge_noise = fbm(q * 6.4 + vec2(t * 0.31, -t * 0.27));
	float edge_irregular = (edge_noise - 0.5) * 0.20 + (my_edge_density - 0.5) * 0.42;
	float edge_gate = smoothstep(0.03, 0.55, timeline) * (1.0 - smoothstep(1.55, 2.35, progress_raw));
	float local_spread = max(0.006, spread * (1.0 + edge_irregular * edge_gate));
	float envelope = smoothstep(local_spread + 0.10, local_spread - 0.018, r);
	vec2 qn = q / max(0.001, local_spread);
	float rn = length(qn);
	float a = atan(qn.y, qn.x);
	float spiral_fade = 1.0 - smoothstep(0.56, 1.08, progress_raw);

	vec2 adv = flow_dir(qn * (1.6 + ignition * 0.9), t * 1.9 + expand * 8.0);
	vec2 warp = qn + adv * (0.40 - 0.18 * expand) * (0.24 + 0.76 * spiral_fade);

	float core = exp(-rn * mix(44.0, 5.2, ignition));
	float shell_r = mix(0.04, 1.70, expand_accel) + 0.58 * pow(late_tail, 2.20);
	float shock = exp(-abs(rn - shell_r) * mix(34.0, 9.0, expand)) * (1.0 - expand * 0.20);
	float shock_front = exp(-abs(rn - shell_r) * mix(68.0, 14.0, expand)) * (1.0 - expand * 0.08);

	float fil0 = filament_field(warp, t + ignition * 3.0, 8.0, 0.22);
	float fil1 = filament_field(rot2(1.12) * warp + vec2(1.7, -1.2), t * 1.1 + 17.0, 11.0, 0.20);
	float fil2 = filament_field(rot2(-0.74) * warp + vec2(-2.1, 1.8), t * 0.9 + 7.0, 15.0, 0.18);
	float filaments = max(fil0, max(fil1 * 0.90, fil2 * 0.74));
	filaments *= (1.0 - smoothstep(0.08, 1.12, rn));
	filaments *= (0.28 + 0.92 * smoothstep(0.01, 0.24, ignition));
	filaments *= spiral_fade;

	float branch_wave = sin(a * (17.0 - ignition * 5.0) - rn * 18.0 + t * 2.8);
	float branches = pow(clamp(branch_wave * 0.5 + 0.5, 0.0, 1.0), 9.0);
	branches *= exp(-rn * 1.5) * (1.0 - expand * 0.25);
	branches *= spiral_fade;

	float mist = fbm(warp * 4.5 + vec2(t * 0.24, -t * 0.21));
	mist = smoothstep(0.28, 0.88, mist) * (1.0 - smoothstep(0.04, 1.20, rn));
	mist *= (0.58 + 0.58 * (1.0 - expand * 0.25));
	float dense_glow = smoothstep(1.10, 0.0, rn) * (1.0 - expand * 0.22);

	float hue_base = fract(0.06 + t * 0.028 + rn * 0.31 + filaments * 0.35 + a / TAU * 0.18);
	vec3 trail_col = hsv2rgb(vec3(hue_base, 0.87, 1.0));
	vec3 alt_col = hsv2rgb(vec3(fract(hue_base + 0.19), 0.74, 1.0));
	vec3 plasma_col = vec3(0.0);
	plasma_col += trail_col * (filaments * 1.65 + branches * 1.10);
	plasma_col += alt_col * (mist * 0.55 + shock * 1.20);
	plasma_col += vec3(1.0, 0.95, 0.90) * core * 2.6;
	plasma_col += vec3(1.0, 0.78, 0.34) * dense_glow * 1.10;
	plasma_col += vec3(1.0, 0.92, 0.64) * shock_front * 1.45;

	for (int i = 0; i < 24; i++) {
		float fi = float(i) / 24.0;
		float seed = fi * 139.17 + 7.31;
		float ang = fi * TAU + sin(seed + t * 0.45) * 0.55;
		float speed = mix(0.35, 1.25, fract(seed * 0.173));
		vec2 head = vec2(cos(ang), sin(ang)) * expand_accel * speed * 0.92;
		vec2 drift = flow_dir(head * 4.0 + qn * 2.1 + vec2(seed), t + seed);
		head += drift * 0.07 * (1.0 - expand_accel);
		float d = length(qn - head);
		float trail = exp(-d * mix(18.0, 36.0, fi)) * (1.0 - expand * 0.18);
		float th = fract(fi + t * 0.09 + expand * 0.26);
		vec3 tc = hsv2rgb(vec3(th, 0.93, 1.0));
		plasma_col += tc * trail * 0.46;
	}

	vec3 col = plasma_col * plasma_alpha;

	// Initial singularity flash.
	float flash = exp(-PC.phase_time * 65.0);
	col += vec3(1.0, 0.96, 0.90) * flash * 1.65;

	float post_glow = exp(-r * 2.8) * smoothstep(0.16, 1.0, expand) * 0.30;
	col += vec3(0.34, 0.50, 0.92) * post_glow;

	// Mycelium layer from the external feedback simulation texture.
	vec4 my_state = my_edge_state;
	float my_density = clamp(my_state.z, 0.0, 1.0);
	float my_hue = fract(my_state.w);
	float my_reveal = smoothstep(0.02, 0.20, timeline) * (1.0 - smoothstep(1.08, 2.25, progress_raw));
	float my_shell_boost = exp(-abs(rn - shell_r) * mix(22.0, 10.0, expand));
	vec3 my_base = hsv2rgb(vec3(fract(my_hue + 0.08), 0.60, 0.92));
	vec3 my_trail = hsv2rgb(vec3(my_hue, 0.90, 1.0));
	vec3 my_col = mix(my_base, my_trail, clamp(my_density * 0.95, 0.0, 1.0));
	my_col += vec3(1.0, 0.86, 0.58) * my_shell_boost * my_density * 0.24;
	float my_alpha = my_density * my_reveal * plasma_alpha * (1.0 - PC.fade_alpha * 0.55);
	col = col * 0.82 + my_col * (my_alpha * 2.35);

	float my_fringe = smoothstep(0.10, 0.85, my_density) * edge_gate;
	float envelope_mix = clamp(envelope + my_fringe * 0.35, 0.0, 1.0);
	col *= envelope_mix;
	col = 1.0 - exp(-col * 1.55);
	col *= (1.0 - clamp(PC.fade_alpha, 0.0, 1.0));

	// Fade the big-bang core first while it expands, revealing stars behind it.
	float core_clear_t = smoothstep(0.22, 1.85, progress_raw);
	float core_clear_edge = mix(0.04, 0.66, core_clear_t);
	float core_clear_feather = mix(0.05, 0.16, core_clear_t);
	float core_clear = (1.0 - smoothstep(
		core_clear_edge - core_clear_feather,
		core_clear_edge + core_clear_feather,
		rn
	)) * core_clear_t;
	col *= (1.0 - core_clear);

	// Shadertoy-inspired lens flare flash: rings + spikes + bright core, bounded in radius.
	float flash_total = 0.30;
	float flash_t = clamp(PC.phase_time / flash_total, 0.0, 1.0);
	float flash_expand = smoothstep(0.0, 1.0, clamp(flash_t / 0.46, 0.0, 1.0));
	float flash_collapse = smoothstep(0.52, 1.0, flash_t);
	float flash_radius = mix(0.015, 2.90, flash_expand);
	flash_radius = mix(flash_radius, 0.012, flash_collapse);
	float flash_env = smoothstep(0.0, 0.12, flash_t) * (1.0 - smoothstep(0.86, 1.0, flash_t));
	vec2 fuv = q / max(0.001, flash_radius * 2.35 + 0.02);
	vec2 mm = vec2(0.0);

	vec3 flare = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		float fi = float(i);
		float size = pow(flare_rnd(fi * 2000.0) * 1.8, 2.0) + 1.41;
		float dist = flare_rnd(fi * 20.0) * 3.0 - 0.3;
		flare += flare_circle(fuv, size, dist, mm);
	}

	float a_fl = atan(fuv.y - mm.y, fuv.x - mm.x);
	float l_fl = max(length(fuv - mm), 1e-4);
	float spikes = max(0.1 / pow(l_fl * 5.0, 5.0), 0.0) * abs(sin(a_fl * 5.0 + cos(a_fl * 9.0))) / 20.0;
	spikes += max(0.1 / pow(l_fl * 10.0, 1.0 / 20.0), 0.0);
	spikes += abs(sin(a_fl * 3.0 + cos(a_fl * 9.0))) * abs(sin(a_fl * 9.0)) / 8.0;
	vec3 flare_core = max(0.10 / pow(l_fl * 4.0, 0.5), 0.0) * vec3(0.78, 0.82, 1.0) * 2.8;
	flare += vec3(spikes) * vec3(1.0, 0.96, 0.90) + flare_core;

	float flash_bound = exp(-pow(r / max(0.001, flash_radius * 1.32 + 0.03), 2.2));
	float flash_tail = exp(-r / max(0.001, flash_radius * 2.50 + 0.08));
	float flash_mix = flash_env * (flash_bound * 0.92 + flash_tail * 0.34);
	col += flare * flash_mix * 0.42;

	// Use the exact same star generator as scene-2 for continuity.
	// During scene-1 we add a center-origin burst warp, then decay into the static field.
	float star_emit_t = max(progress_raw - 1.00, 0.0);
	float star_burst = smoothstep(0.0, 1.0, clamp(star_emit_t / 0.85, 0.0, 1.0));
	float star_expand = 1.0 + pow(star_emit_t, 1.36) * 1.70;
	vec2 uv_burst = 0.5 + (uv - 0.5) / max(1.0, star_expand);
	float burst_weight = star_burst * exp(-star_emit_t * 1.45);
	float drift_blend = smoothstep(0.0, 1.0, clamp(PC.fade_alpha, 0.0, 1.0));
	float star_gate = max(clamp(PC.star_alpha, 0.0, 1.0), smoothstep(0.02, 0.22, timeline) * 0.72);

	vec3 base_sky = 1.0 - exp(-stage2_star_sky(uv, t, 0.0, 1.0) * 1.20);
	vec3 burst_sky = 1.0 - exp(-stage2_star_sky(uv_burst, t, 0.0, 1.18) * 1.25);
	vec3 stars_mix = mix(burst_sky, base_sky, drift_blend);
	float persistent_reveal = smoothstep(1.20, 1.90, progress_raw);
	col += (base_sky * persistent_reveal * 1.12 + stars_mix * burst_weight * 1.05) * star_gate;

	return col;
}

vec2 apply_zoom_uv(vec2 uv) {
	float z = max(1.0, PC.zoom_scale);
	float px = PC.planet_x;
	if (PC.intro_phase == INTRO_PHASE_PLANET_PLACE && PC.planet_has_position < 0.5) {
		px = PC.planet_preview_x;
	}
	vec2 center_uv = vec2(px / max(1.0, float(PC.width)), PC.orbit_y / max(1.0, float(PC.height)));
	return center_uv + (uv - center_uv) / z;
}

vec3 render_stage2(vec2 uv, float t) {
	float space = clamp(PC.space_alpha, 0.0, 1.0);
	float pan = clamp(PC.pan_progress, 0.0, 1.0);
	vec2 uvw = apply_zoom_uv(uv);
	vec2 aspect = vec2(float(PC.width) / max(1.0, float(PC.height)), 1.0);

	vec3 col = stage2_star_sky(uvw, t, pan, space);

	vec2 sun_px = mix(vec2(PC.sun_start_x, PC.sun_start_y), vec2(PC.sun_end_x, PC.sun_end_y), pan);
	vec2 sun_uv = sun_px / vec2(float(PC.width), float(PC.height));
	vec2 rel = (uvw - sun_uv) * aspect;
	float r = length(rel);
	float sun_r = PC.sun_radius / max(1.0, float(PC.height));
	// Scene-2 should spawn the sun immediately at load (no fade-in).
	float sun_reveal = space;
	float sun_dist = r / max(0.0001, sun_r);
	float sun_halo_window = sun_r * 4.0 + 0.10;
	if (r <= sun_halo_window) {
		// Stronger near-limb bloom bridge to make the star read as a hot emitter.
		float glow_out = max(0.0, sun_dist - 1.0);
		float back_glow_peak = exp(-pow(glow_out * 9.5, 2.0));
		float back_glow_tail = exp(-glow_out * 6.4);
		float back_glow_gate = smoothstep(0.997, 1.018, sun_dist) * (1.0 - smoothstep(1.22, 1.58, sun_dist));
		vec3 back_glow = vec3(1.0, 0.88, 0.22) * back_glow_peak * 0.42;
		back_glow += vec3(1.0, 0.95, 0.42) * back_glow_tail * 0.18;
		col += back_glow * sun_reveal * back_glow_gate;
		// Wide halo for "strong bloom" impression in pure-shader 2D rendering.
		float halo_mid = exp(-pow(glow_out * 2.8, 1.35));
		float halo_far = exp(-glow_out * 2.4);
		float halo_gate = smoothstep(1.00, 1.08, sun_dist) * (1.0 - smoothstep(2.90, 3.60, sun_dist));
		vec3 sun_halo = vec3(1.0, 0.78, 0.22) * halo_mid * 0.34;
		sun_halo += vec3(1.0, 0.90, 0.55) * halo_far * 0.14;
		col += sun_halo * sun_reveal * halo_gate;
	}

	float sun_heavy_window = sun_r * 2.9 + 0.06;
	if (r <= sun_heavy_window) {
		float sun_body = smoothstep(sun_r + 0.0025, sun_r - 0.0015, r);
		vec2 np = rel / max(0.0001, sun_r);
		float np_len2 = dot(np, np);
		float hemisphere = sqrt(max(0.0, 1.0 - min(np_len2, 1.0)));
		vec3 sphere_n = normalize(vec3(np, hemisphere));
		// Seam-safe spin: move surface phase without rotating into a discontinuous projection.
		float sun_spin = t * 0.22;
		float sun_spin_uv = sun_spin * 0.38;
		vec2 surf_uv = sun_spherical_warp_coord(sphere_n, t);
		surf_uv.x += sun_spin_uv;
		vec2 warp_p = surf_uv * 4.7;
		float flow0 = filament_field(warp_p * 1.35 + flow_dir(warp_p * 1.8, t * 0.24) * 0.22, t * 0.24, 8.4, 0.30);
		float flow1 = filament_field(rot2(0.52) * warp_p * 1.70 + vec2(-t * 0.08, t * 0.06), t * 0.19, 10.1, 0.28);
		float honey_mask = honey_cells(warp_p * 1.28, t * 0.38);
		float detail_noise = noise4q(vec4(sphere_n * 40.0 + vec3(83.23, 34.34, 67.453), t * 0.78 + sun_spin * 0.62));
		detail_noise = smoothstep(0.38, 0.92, detail_noise);
		// Keep Voronoi advection synced with photosphere spin; slower scalar avoids apparent over-rotation.
		float granule_spin = sun_spin_uv * 0.27;
		// Equal-area spherical mapping for more uniform granule cell size across the disc.
		float granule_u = fract(atan(sphere_n.x, sphere_n.z) / TAU + 0.5 + granule_spin);
		float granule_v = sphere_n.y * 0.5 + 0.5;
		vec2 granule_uv = vec2(granule_u, granule_v);
		vec2 granule_tile = vec2(228.0, 116.0);
		vec2 granule_p = granule_uv * granule_tile;
		float voronoi_morph_t = t * 0.46;
		float shared_morph_t = t * 0.34 * 0.52;
		vec2 shared_morph = sun_sine_morph_delta(warp_p, shared_morph_t);
		granule_p += shared_morph * (granule_tile * vec2(0.020, 0.020));
		vec2 granule_anchor_warp0 = vec2(
			fbm(granule_uv * 17.0 + vec2(4.3, 9.7)),
			fbm(rot2(0.87) * granule_uv * 23.0 + vec2(11.9, 1.6))
		) - 0.5;
		vec2 granule_anchor_warp1 = vec2(
			fbm(granule_uv * 38.0 + vec2(17.4, 5.2)),
			fbm(rot2(-0.49) * granule_uv * 33.0 + vec2(2.1, 13.3))
		) - 0.5;
		float granule_pulse_own = 0.5 + 0.5 * sin(voronoi_morph_t * 0.33 + dot(granule_uv, vec2(7.1, 5.3)) * TAU);
		float granule_pulse_shared = 0.5 + 0.5 * sin(shared_morph_t * 0.74 + dot(granule_uv, vec2(5.9, 8.1)) * TAU);
		float granule_pulse = mix(granule_pulse_own, granule_pulse_shared, 0.45);
		granule_p += granule_anchor_warp0 * mix(4.2, 4.9, granule_pulse);
		granule_p += granule_anchor_warp1 * mix(1.2, 1.6, granule_pulse);
		float vor_morph_t = voronoi_morph_t + shared_morph_t * 0.65;
		vec3 vor = sun_granule_voronoi(granule_p, granule_tile, vor_morph_t);
		float edge_fuzz = fbm(granule_uv * 54.0 + vec2(7.2, -4.1));
		float edge_wobble0 = fbm(granule_p * 0.31 + vec2(vor.z * 31.7, -vor.z * 17.9));
		float edge_wobble1 = fbm(rot2(0.73) * granule_p * 0.41 + vec2(vor.z * 13.4, vor.z * 29.1));
		float edge_pulse = 0.5 + 0.5 * sin(vor_morph_t * 0.92 + vor.z * TAU + edge_fuzz * 2.8);
		float edge_shift = (edge_fuzz - 0.5) * mix(0.016, 0.028, edge_pulse) + (edge_wobble0 - 0.5) * mix(0.010, 0.020, 1.0 - edge_pulse);
		float edge_metric = vor.y + (edge_wobble0 - 0.5) * 0.11 + (edge_wobble1 - 0.5) * 0.08;
		float core_metric = vor.x + (edge_wobble1 - 0.5) * 0.05;
		float vor_edge = 1.0 - smoothstep(0.014 + edge_shift, 0.205 + edge_shift, edge_metric);
		float vor_cell = smoothstep(0.040 + edge_shift * 0.5, 0.34 + edge_shift * 0.5, edge_metric);
		float vor_center = 1.0 - smoothstep(0.08, 0.47, core_metric);
		float granule = clamp(vor_cell * 0.66 + vor_center * 0.34, 0.0, 1.0);
		vor_edge = smoothstep(0.0, 1.0, clamp(pow(vor_edge, 0.62), 0.0, 1.0));
		float bump_e = 0.42;
		float h = sun_voronoi_bump_height(vor);
		float hxp = sun_voronoi_bump_height(sun_granule_voronoi(granule_p + vec2(bump_e, 0.0), granule_tile, vor_morph_t));
		float hyp = sun_voronoi_bump_height(sun_granule_voronoi(granule_p + vec2(0.0, bump_e), granule_tile, vor_morph_t));
		float hx = hxp - h;
		float hy = hyp - h;
		vec3 tangent_x = normalize(vec3(1.0, 0.0, -sphere_n.x / max(0.10, sphere_n.z)));
		vec3 tangent_y = normalize(vec3(0.0, 1.0, -sphere_n.y / max(0.10, sphere_n.z)));
		float bump_strength = 0.94;
		vec3 surf_n = normalize(sphere_n - tangent_x * hx * bump_strength - tangent_y * hy * bump_strength);
		vec3 light_dir = normalize(vec3(cos(t * 0.18) * 0.28, sin(t * 0.14) * 0.22, 0.93));
		float ndl = clamp(dot(surf_n, light_dir), 0.0, 1.0);
		float ndl_diff = pow(ndl, 1.22);
		float fres = pow(1.0 - clamp(surf_n.z, 0.0, 1.0), 2.6);
		float veins = smoothstep(0.22, 0.84, mix(flow0, flow1, 0.36));
		veins = mix(veins, honey_mask, 0.24);
		veins = mix(veins, detail_noise, 0.10);
		veins = mix(veins, granule, 0.30);
		veins = clamp(veins - vor_edge * 0.030, 0.0, 1.0);
		float core_grad = exp(-r / max(0.0001, sun_r * 0.55));
		float limb = smoothstep(sun_r * 0.58, sun_r * 0.995, r);

		vec3 sun_deep = vec3(0.54, 0.06, 0.00);
		vec3 sun_mid = vec3(0.98, 0.24, 0.02);
		vec3 sun_hot = vec3(1.0, 0.72, 0.08);
		vec3 sun_core = vec3(1.0, 0.84, 0.40);
		float color_mix0 = clamp(h * 0.42 + veins * 0.58, 0.0, 1.0);
		vec3 base_col = mix(sun_deep, sun_mid, color_mix0);
		base_col = mix(base_col, sun_hot, clamp(h * 0.28 + veins * 0.62, 0.0, 1.0));
		base_col = mix(base_col, sun_mid * 0.86 + sun_hot * 0.14, vor_edge * 0.16);
		base_col += sun_hot * vor_edge * 0.045;
		base_col += sun_hot * granule * (0.06 + 0.10 * vor.z);
		vec3 plasma = base_col;
		float ember = smoothstep(0.62, 0.98, detail_noise);
		plasma += vec3(1.0, 0.56, 0.06) * ember * (0.02 + 0.04 * veins);
		plasma = mix(plasma, sun_core, clamp(core_grad * 0.45 + pow(ndl, 2.4) * 0.22, 0.0, 1.0));
		plasma += sun_hot * veins * 0.24;
		plasma += sun_core * ndl_diff * 0.11;
		plasma += vec3(1.0, 0.82, 0.18) * fres * 0.15;
		plasma *= 1.00 + ndl_diff * 0.12;
		plasma *= (1.0 + limb * 0.18);
		plasma = 1.0 - exp(-plasma * 1.34);
		col = mix(col, plasma, sun_body * sun_reveal);

		float rn = length(np);
		vec3 cor_rays = shadertoy_corona(np, t);
		float outside_body = smoothstep(0.985, 1.02, rn);
		float far_fade = 1.0 - smoothstep(1.62, 2.65, rn);
		float corona_mask = outside_body * far_fade * sun_reveal;
		float limb_out = max(0.0, rn - 1.0);
		float limb_bridge = exp(-pow(limb_out * 34.0, 1.15)) * smoothstep(0.995, 1.018, rn) * sun_reveal;
		corona_mask = max(corona_mask, limb_bridge * 0.36);

		vec2 p_cor = np * 0.70710678;
		// Add explicit corona-space advection so all corona lobes visibly evolve.
		vec2 p_cor_anim = rot2(t * 0.036) * p_cor;
		p_cor_anim += flow_dir(p_cor * 2.1 + vec2(1.7, -2.3), t * 0.12) * 0.032;
		vec3 ray_cor = normalize(vec3(p_cor_anim, 2.0));
		vec3 pos_cor = vec3(0.0, 0.0, 3.0);
		mat3 mr_cor = sun_corona_matrix(t);
		float s3a = corona_ring_ray_noise(ray_cor, pos_cor, 0.96, 1.0, mr_cor, t);
		vec3 ray_cor_b = normalize(vec3(rot2(0.31 + t * 0.018) * p_cor_anim, 2.0));
		float s3b = corona_ring_ray_noise(ray_cor_b, pos_cor, 1.02, 0.95, mr_cor, t * 1.11 + 0.37);
		vec3 ray_cor_c = normalize(vec3(rot2(-0.63 - t * 0.014) * p_cor_anim, 2.0));
		float s3c = corona_ring_ray_noise(ray_cor_c, pos_cor, 0.99, 1.05, mr_cor, t * 1.29 - 0.41);
		float swirl_raw = max(max(s3a, s3b * 0.88), s3c * 0.92);
		float swirl_noise = corona_noise_texture(p_cor_anim * 67.0 + vec2(t * 0.21, -t * 0.17));
		swirl_raw += (swirl_noise - 0.5) * 0.10;
		float swirl_soft = smoothstep(0.06, 0.70, swirl_raw);
		float swirl_ridge = pow(smoothstep(0.30, 0.94, swirl_raw), 1.65);
		float swirl = clamp(swirl_soft * 0.62 + swirl_ridge * 1.38, 0.0, 1.0);
		float swirl_shell = smoothstep(1.02, 1.70, rn) * (1.0 - smoothstep(1.82, 2.15, rn));
		vec3 cor_swirl = mix(vec3(0.98, 0.24, 0.02), vec3(1.0, 0.84, 0.40), swirl) * swirl;
		cor_swirl *= 0.78 + swirl_shell * 0.92;
		vec3 bridge_col = vec3(1.0, 0.72, 0.22) * limb_bridge * 0.42;

		col += bridge_col;
		col += cor_rays * corona_mask * mix(1.85, 1.22, swirl * 0.78);
		col += cor_swirl * corona_mask * 2.10;
		col += vec3(1.0, 0.78, 0.24) * swirl_ridge * corona_mask * 0.68;
	}

	float inner = PC.zone_inner_radius / max(1.0, float(PC.height));
	float outer = PC.zone_outer_radius / max(1.0, float(PC.height));
	float bw = 0.0035;
	float band = smoothstep(inner - bw, inner + bw, r) * (1.0 - smoothstep(outer - bw, outer + bw, r));
	float band_reveal = sun_reveal * smoothstep(0.48, 1.0, pan);
	float zone_t_r = clamp((r - inner) / max(0.0001, outer - inner), 0.0, 1.0);
	// Keep gradient anchored to the radial band itself (no screen-space drift).
	float zone_t = zone_t_r;
	float zone_theta = atan(rel.y, rel.x);
	float band_pattern = 0.92 + 0.08 * sin(zone_theta * 12.0 + zone_t * 8.0);
	vec3 zone_hot = vec3(1.0, 0.30, 0.12);
	vec3 zone_mid = vec3(1.0, 0.86, 0.28);
	vec3 zone_cold = vec3(0.34, 0.64, 1.0);
	float t_hot_mid = smoothstep(0.0, 0.5, zone_t);
	float t_mid_cold = smoothstep(0.5, 1.0, zone_t);
	vec3 hot_to_mid = mix(zone_hot, zone_mid, t_hot_mid);
	vec3 mid_to_cold = mix(zone_mid, zone_cold, t_mid_cold);
	vec3 zone_col = mix(hot_to_mid, mid_to_cold, step(0.5, zone_t));
	col += zone_col * band * band_reveal * 0.36 * band_pattern;

	bool show_planet_system = (PC.intro_phase >= INTRO_PHASE_PLANET_PLACE);
	float system_reveal = 1.0;
	if (!show_planet_system && PC.intro_phase == INTRO_PHASE_CAMERA_PAN) {
		system_reveal = smoothstep(0.74, 0.90, clamp(PC.pan_progress, 0.0, 1.0));
		show_planet_system = system_reveal > 0.0001;
	}
	if (show_planet_system) {
		float xpix = uvw.x * float(PC.width);
		float ypix = uvw.y * float(PC.height);
		float orbit_y = PC.orbit_y;

		float px = PC.planet_x;
		if ((PC.intro_phase == INTRO_PHASE_PLANET_PLACE || PC.intro_phase == INTRO_PHASE_CAMERA_PAN) && PC.planet_has_position < 0.5) {
			px = PC.planet_preview_x;
		}
		float orbit_px = px; // Logical orbit position used for climate classification.
		if (PC.intro_phase == INTRO_PHASE_CAMERA_PAN && PC.planet_has_position < 0.5) {
			// During pan, keep the preview planet in the habitable-zone frame instead of screen-center lock.
			vec2 pan_track_offset = sun_px - vec2(PC.sun_end_x, PC.sun_end_y);
			px += pan_track_offset.x;
			orbit_y += pan_track_offset.y;
		}

		vec2 p_rel = vec2((xpix - px) / max(1.0, float(PC.height)), (ypix - orbit_y) / max(1.0, float(PC.height)));
		float pr = length(p_rel);
		vec2 sun_rel_planet = vec2(
			(sun_px.x - px) / max(1.0, float(PC.height)),
			(sun_px.y - orbit_y) / max(1.0, float(PC.height))
		);
		float p_rad_base = 17.0 / max(1.0, float(PC.height));
		const float PLANET_SCALE = 1.10;
		const float ORBIT_SCALE = 1.10;
		float p_rad = p_rad_base * PLANET_SCALE;
		float p_mask = smoothstep(p_rad + 0.002, p_rad - 0.001, pr);
			// Keep this rectangular for branch-friendly skipping, but large enough to avoid halo clipping.
			vec2 planet_window_half = vec2(100.0, 100.0) / max(1.0, float(PC.height));
			bool in_planet_window = abs(p_rel.x) <= planet_window_half.x && abs(p_rel.y) <= planet_window_half.y;
		const float ORBIT_MUL_MAX = 2.80 + 2.0 * 1.45 + 0.40;
		float max_orbit_r = p_rad_base * ORBIT_SCALE * ORBIT_MUL_MAX;
		float max_moon_r = p_rad * 0.50;
		vec2 moon_domain_half = vec2(
			max_orbit_r + max_moon_r + 12.0 / max(1.0, float(PC.height)),
			max_orbit_r * 0.22 + max_moon_r + 12.0 / max(1.0, float(PC.height))
		);
		bool in_moon_domain = abs(p_rel.x) <= moon_domain_half.x && abs(p_rel.y) <= moon_domain_half.y;

		if (in_planet_window) {
		vec2 p_local = p_rel / max(0.0001, p_rad);
		float p_l2 = dot(p_local, p_local);
		float p_z = sqrt(max(0.0, 1.0 - min(p_l2, 1.0)));
		vec3 p_norm = normalize(vec3(p_local, p_z));

		float p_spin = t * 0.07;
		vec2 p_surf = p_norm.xy / max(0.24, p_norm.z + 0.54);
		p_surf.x += p_spin;
		p_surf += flow_dir(p_surf * 2.3, t * 0.16) * 0.010;

		float p_h = planet_surface_height(p_surf, t);
		float p_eps = 0.022;
		float p_hx = planet_surface_height(p_surf + vec2(p_eps, 0.0), t) - p_h;
		float p_hy = planet_surface_height(p_surf + vec2(0.0, p_eps), t) - p_h;

		vec3 p_tangent_x = normalize(vec3(1.0, 0.0, -p_norm.x / max(0.10, p_norm.z)));
		vec3 p_tangent_y = normalize(vec3(0.0, 1.0, -p_norm.y / max(0.10, p_norm.z)));
		vec3 p_surf_n = normalize(p_norm - p_tangent_x * p_hx * 0.56 - p_tangent_y * p_hy * 0.56);

			float p_vein = filament_field(p_surf * 6.2 + flow_dir(p_surf * 3.1, t * 0.22) * 0.20, t * 0.27, 8.6, 0.24);
			float orbit_norm = clamp(
				(orbit_px - PC.orbit_x_min) / max(1.0, PC.orbit_x_max - PC.orbit_x_min),
				0.0,
				1.0
			);
		float center_bias = clamp(1.0 - abs(orbit_norm - 0.5) * 2.0, 0.0, 1.0);
		float habitable_center = pow(center_bias, 1.10);
		float hotness = 1.0 - smoothstep(0.0, 0.52, orbit_norm);
		float coldness = smoothstep(0.48, 1.0, orbit_norm);
		float climate_extreme = 1.0 - habitable_center;

		float water_frac = clamp(0.04 + habitable_center * 0.50 + coldness * 0.08 - hotness * 0.26, 0.015, 0.58);
		float cont0 = fbm(p_surf * 2.05 + vec2(17.3, -9.1) + vec2(t * 0.008, -t * 0.006));
		float cont1 = fbm(rot2(0.43) * p_surf * 3.20 + vec2(-6.7, 12.9) + vec2(-t * 0.006, t * 0.007));
		float continent_field = clamp(cont0 * 0.68 + cont1 * 0.32, 0.0, 1.0);
		continent_field = smoothstep(0.30, 0.80, continent_field);
		float terrain = clamp(continent_field * 0.74 + p_h * 0.30 + p_vein * 0.12 - 0.16, 0.0, 1.0);
		// Higher water_frac must produce higher sea level (more ocean coverage).
		float sea_level = clamp(water_frac, 0.02, 0.72);
		float coast_w = mix(0.032, 0.062, water_frac);
		float ocean_mask = 1.0 - smoothstep(sea_level - coast_w, sea_level + coast_w, terrain);
		float land_mask = 1.0 - ocean_mask;
		float coast_mask = smoothstep(sea_level - coast_w * 1.60, sea_level - coast_w * 0.20, terrain) *
			(1.0 - smoothstep(sea_level + coast_w * 0.20, sea_level + coast_w * 1.60, terrain));

		float lat_abs = abs(p_norm.y);
		float cap_start = mix(0.90, 0.20, pow(coldness, 1.20));
		cap_start = min(cap_start + hotness * 0.14, 0.95);
		float polar_band = smoothstep(cap_start, min(1.0, cap_start + 0.22), lat_abs);
		float freeze_global = smoothstep(0.74, 1.0, coldness) * (0.55 + 0.45 * climate_extreme);
		float freeze_amt = clamp(polar_band + freeze_global + coldness * 0.30, 0.0, 1.0);
		float snow_amt = clamp(freeze_amt * (0.42 + land_mask * 0.58), 0.0, 1.0);
		float ice_ocean_amt = clamp(freeze_amt * ocean_mask * (0.70 + 0.30 * coldness), 0.0, 1.0);

		float equator_heat = 1.0 - lat_abs;
		float equator_bias = smoothstep(0.10, 0.88, equator_heat);
		float moisture = clamp(water_frac * 1.35 + coast_mask * 0.62, 0.0, 1.0);
		float scorch = clamp(
			hotness * (0.24 + 0.96 * equator_bias) +
			hotness * (1.0 - moisture) * 0.38 +
			climate_extreme * hotness * 0.20,
			0.0,
			1.0
		);

		// Hot worlds: vegetation shifts toward higher latitudes; cold worlds: lush belt near equator.
		float veg_lat_center = mix(0.34, 0.64, hotness);
		veg_lat_center = mix(veg_lat_center, 0.14, coldness);
		float veg_lat_width = mix(0.28, 0.18, hotness);
		veg_lat_width = mix(veg_lat_width, 0.22, coldness);
		float veg_lat_band = exp(-pow((lat_abs - veg_lat_center) / max(0.06, veg_lat_width), 2.0));
		float veg_climate = mix(0.34, 1.20, habitable_center);
		veg_climate *= (1.0 - hotness * 0.76);
		veg_climate *= (1.0 - coldness * 0.34);
		veg_climate *= (0.52 + moisture * 0.86);
		float veg_noise = smoothstep(0.25, 0.70, fbm(p_surf * 9.8 + vec2(21.3, -7.9) + vec2(t * 0.03, -t * 0.02)));
		float vegetation = veg_climate * veg_lat_band * veg_noise * land_mask * (1.0 - snow_amt) * (1.0 - scorch * 0.82);
		vegetation = clamp(vegetation * 1.55 + coast_mask * 0.16, 0.0, 1.0);

		float ocean_depth = clamp((sea_level - terrain) / max(0.0001, sea_level), 0.0, 1.0);
		vec3 ocean_deep = mix(vec3(0.03, 0.16, 0.30), vec3(0.02, 0.14, 0.24), hotness);
		ocean_deep = mix(ocean_deep, vec3(0.06, 0.20, 0.32), coldness * 0.35);
		vec3 ocean_shallow = mix(vec3(0.09, 0.44, 0.54), vec3(0.12, 0.30, 0.40), hotness);
		ocean_shallow = mix(ocean_shallow, vec3(0.22, 0.48, 0.62), coldness * 0.25);
		vec3 ocean_col = mix(ocean_shallow, ocean_deep, smoothstep(0.0, 1.0, ocean_depth));
		ocean_col += vec3(0.03, 0.06, 0.08) * p_vein * 0.22;

		vec3 land_soil = mix(vec3(0.46, 0.34, 0.24), vec3(0.64, 0.52, 0.30), hotness);
		land_soil = mix(land_soil, vec3(0.42, 0.40, 0.38), coldness * 0.35);
		vec3 land_rock = vec3(0.42, 0.36, 0.32);
		vec3 land_green = mix(vec3(0.16, 0.44, 0.16), vec3(0.10, 0.62, 0.18), clamp(moisture * 0.82 + (1.0 - coldness) * 0.18, 0.0, 1.0));
		vec3 scorched_col = mix(vec3(0.56, 0.38, 0.14), vec3(0.82, 0.70, 0.38), clamp(hotness * equator_bias + 0.25, 0.0, 1.0));
		vec3 beach_col = mix(vec3(0.72, 0.62, 0.42), vec3(0.86, 0.78, 0.58), 0.35 + 0.65 * hotness);

		vec3 land_col = mix(land_soil, land_rock, smoothstep(0.55, 0.95, terrain));
		land_col = mix(land_col, land_green, clamp(vegetation, 0.0, 1.0));
		land_col = mix(land_col, scorched_col, scorch * (1.0 - snow_amt));
		land_col += vec3(0.05, 0.04, 0.03) * p_vein * 0.28;

		vec3 snow_col = vec3(0.92, 0.96, 1.0);
		vec3 ice_col = vec3(0.78, 0.90, 1.0);

		vec3 p_col = ocean_col * ocean_mask + land_col * land_mask;
		p_col = mix(p_col, beach_col, coast_mask * (1.0 - snow_amt) * (1.0 - ice_ocean_amt));
		p_col = mix(p_col, ice_col, ice_ocean_amt);
		p_col = mix(p_col, snow_col, snow_amt * land_mask + polar_band * 0.22);

		vec3 p_hot = vec3(1.0, 0.62, 0.20);
		vec3 p_core_col = vec3(1.0, 0.84, 0.42);
		vec3 p_cold_rim = vec3(0.72, 0.86, 1.0);

		vec3 planet_light_dir = normalize(vec3(sun_rel_planet, 0.92));
		float p_ndl = clamp(dot(p_surf_n, planet_light_dir), 0.0, 1.0);
		float p_wrap = clamp((dot(p_surf_n, planet_light_dir) + 0.30) / 1.30, 0.0, 1.0);
		float p_fres = pow(1.0 - clamp(p_surf_n.z, 0.0, 1.0), 2.2);
		vec2 sun_dir2 = normalize(sun_rel_planet + vec2(1e-5, 0.0));
		vec2 rim_dir = normalize(p_rel + vec2(1e-5, 0.0));
		float day_side = clamp(dot(rim_dir, sun_dir2) * 0.5 + 0.5, 0.0, 1.0);
		float day_boost = smoothstep(0.22, 1.0, day_side);
		float p_center = smoothstep(0.0, 0.96, p_norm.z);
		float p_shade = 0.30 + p_wrap * 0.84;
		p_col *= p_shade;
		p_col *= mix(0.74, 1.03, p_center);
		float hot_land = hotness * land_mask * (1.0 - snow_amt);
		p_col += vec3(0.20, 0.12, 0.05) * hot_land * (0.18 + 0.42 * equator_heat);
		p_col += mix(p_cold_rim, p_hot, hotness) * p_fres * mix(0.05, 0.11, hotness);
		p_col += mix(vec3(0.88, 0.96, 1.0), p_core_col, 0.35 + 0.65 * hotness) * pow(p_ndl, 2.6) * 0.11;
		float atmo_fres = pow(1.0 - clamp(p_norm.z, 0.0, 1.0), 2.8);
		vec3 atmo_in_col = mix(vec3(0.52, 0.68, 0.92), vec3(0.70, 0.84, 1.0), day_boost);
		float atmo_in_strength = (0.008 + 0.024 * day_boost) * (0.28 + 0.72 * coldness);
		p_col += atmo_in_col * atmo_fres * atmo_in_strength;
		p_col = 1.0 - exp(-p_col * 1.08);

		col = mix(col, p_col, p_mask * system_reveal);
		float d_out = max(0.0, pr - p_rad);
		float atm_halo_tight = exp(-d_out * 120.0) * step(p_rad, pr);
		float atm_halo_wide = exp(-d_out * 34.0) * step(p_rad, pr);
		float atm_halo = atm_halo_tight * 0.68 + atm_halo_wide * 0.32;
		vec3 atm_halo_col = mix(vec3(0.50, 0.68, 0.98), vec3(0.78, 0.90, 1.0), day_boost);
		col += atm_halo_col * atm_halo * (0.08 + 0.12 * day_boost) * system_reveal;
		float p_glow = exp(-max(0.0, pr - p_rad) * 45.0) * step(p_rad, pr);
		vec3 p_glow_col = mix(vec3(0.52, 0.70, 0.96), vec3(0.82, 0.92, 1.0), day_boost);
		p_glow_col = mix(p_glow_col, vec3(0.88, 0.96, 1.0), coldness * 0.45);
		col += p_glow_col * p_glow * (0.07 + 0.09 * day_boost + coldness * 0.03) * system_reveal;
		}

		if (in_moon_domain) {
			int moon_count = clamp(int(floor(PC.moon_count + 0.5)), 0, 3);
			float moon_seed = max(0.0001, PC.moon_seed);
			for (int mi = 0; mi < 3; mi++) {
				if (mi >= moon_count) {
					continue;
				}
			float fi = float(mi);
			float h0 = hash12(vec2(moon_seed * 0.071 + fi * 11.13, moon_seed * 0.037 + fi * 3.97));
			float h1 = hash12(vec2(moon_seed * 0.113 + fi * 7.21, moon_seed * 0.053 + fi * 5.61));
			float h2 = hash12(vec2(moon_seed * 0.167 + fi * 2.83, moon_seed * 0.029 + fi * 13.17));
			float h3 = hash12(vec2(moon_seed * 0.197 + fi * 17.11, moon_seed * 0.089 + fi * 19.73));
			float h4 = hash12(vec2(moon_seed * 0.251 + fi * 23.03, moon_seed * 0.131 + fi * 29.31));
			float h5 = hash12(vec2(moon_seed * 0.307 + fi * 31.39, moon_seed * 0.149 + fi * 37.71));

			// Keep moons on separated equatorial shells (side-view: mostly horizontal motion).
			float orbit_mul = 2.80 + fi * 1.45 + h0 * 0.40;
			float orbit_r = p_rad_base * orbit_mul * ORBIT_SCALE;
			float phase = h2 * TAU;
			float omega = (1.80 + h5 * 0.65) / pow(max(0.5, orbit_mul), 1.5);
			float ang = t * omega + phase;
			float orbit_incl = mix(0.05, 0.22, h3);
				vec2 m_off = vec2(cos(ang), sin(ang) * orbit_incl) * orbit_r;

				vec2 m_rel = p_rel - m_off;
				float m_rad = p_rad * mix(0.10, 0.50, h4);
				// Rectangular moon work window for cheaper branch culling.
				vec2 moon_window_half = vec2(m_rad + 0.0035);
				if (abs(m_rel.x) > moon_window_half.x || abs(m_rel.y) > moon_window_half.y) {
					continue;
				}
				float mr = length(m_rel);
				float m_mask = smoothstep(m_rad + 0.0018, m_rad - 0.0010, mr);
			// Alternate front/back visibility around the orbit.
			float moon_depth = sin(ang);
			float moon_front = step(0.0, moon_depth);
			float moon_visible_mask = m_mask * (1.0 - (1.0 - moon_front) * p_mask) * system_reveal;
			vec2 m_local = m_rel / max(0.0001, m_rad);
			float m_l2 = dot(m_local, m_local);
			float m_z = sqrt(max(0.0, 1.0 - min(m_l2, 1.0)));
			vec3 m_norm = normalize(vec3(m_local, m_z));

			// Moon day length tracks orbital period (tidal-lock baseline), with small deviation.
			float spin_ratio = 1.0 + (h1 - 0.5) * 0.18;
			// Very rare case: strong negative deviation can tip into mild retrograde.
			if (h5 > 0.992) {
				float retro_t = (h5 - 0.992) / 0.008;
				spin_ratio -= mix(1.05, 1.22, retro_t);
			}
			spin_ratio = clamp(spin_ratio, -0.22, 1.12);
			float spin_rate = omega * spin_ratio;
			float spin_ang = t * spin_rate + h1 * TAU;
			float spin_phase = spin_ang / TAU;
			// Equatorial spin mapping: poles stay at top/bottom (y-axis), not toward camera.
			float m_lon = atan(m_norm.x, m_norm.z) / TAU + 0.5;
			float m_lat = acos(clamp(m_norm.y, -1.0, 1.0)) / PI;
			vec2 m_uv = vec2(fract(m_lon + spin_phase + h0 * 0.37), clamp(m_lat + (h3 - 0.5) * 0.08, 0.0, 1.0));
			// Low-res moon shading budget: evaluate detail on a coarse 100x50 UV grid.
			vec2 moon_lod = vec2(100.0, 50.0);
			vec2 m_uv_lod = (floor(m_uv * moon_lod) + vec2(0.5)) / moon_lod;
			float patch0 = fbm(m_uv_lod * (2.8 + h4 * 1.8) + vec2(1.7, -2.3));
			float patch1 = fbm(rot2(0.97 + h5 * 0.24) * m_uv_lod * (5.6 + h2 * 2.4) + vec2(-3.7, 2.1));
			float patch_mix = clamp(patch0 * 0.68 + patch1 * 0.32, 0.0, 1.0);
			float crater_seed = fbm(rot2(0.73 + h4 * 0.30) * m_uv_lod * (14.0 + h5 * 4.0) + vec2(-4.0, 9.0));
			float crater_pit = pow(smoothstep(0.72, 0.99, crater_seed), 1.25);
			float crater_rim = smoothstep(0.50, 0.80, crater_seed) * (1.0 - crater_pit);

			float grey_base = 0.34 + (h3 - 0.5) * 0.30;
			float albedo = grey_base;
			albedo *= 0.78 + patch_mix * 0.48;
			albedo += crater_rim * 0.12;
			albedo -= crater_pit * 0.18;
			albedo = clamp(albedo, 0.10, 1.0);

			vec3 tint = vec3(
				0.92 + (h0 - 0.5) * 0.14,
				0.92 + (h1 - 0.5) * 0.14,
				0.92 + (h2 - 0.5) * 0.14
			);
			float tint_amt = 0.02 + h5 * 0.05;
			albedo *= 0.86 + (h4 - 0.5) * 0.34;

			vec2 moon_to_sun = sun_rel_planet - m_off;
			vec3 moon_light_dir = normalize(vec3(moon_to_sun, 0.92));
			float moon_ndl = clamp(dot(m_norm, moon_light_dir), 0.0, 1.0);
			float moon_fres = pow(1.0 - clamp(m_norm.z, 0.0, 1.0), 2.4);
			float moon_shade = 0.42 + moon_ndl * (0.60 + h2 * 0.16) + moon_fres * 0.10;

			vec3 moon_col = vec3(albedo) * moon_shade;
			moon_col *= mix(vec3(1.0), tint, tint_amt);
			moon_col += vec3(0.10) * crater_rim * (0.28 + moon_ndl * 0.62);
			moon_col -= vec3(0.10) * crater_pit * 0.48;
			moon_col = clamp(moon_col, 0.0, 1.0);
			col = mix(col, moon_col, moon_visible_mask);
			float moon_rim = exp(-abs(mr - m_rad) * 110.0);
			col += mix(vec3(0.78), tint, tint_amt * 0.7) * moon_rim * 0.05 * moon_visible_mask;
		}
		}

		if (PC.intro_phase == INTRO_PHASE_PLANET_PLACE && in_planet_window) {
			float pulse = 0.5 + 0.5 * sin(t * 4.0);
			float ring = exp(-abs(pr - p_rad * 1.10) * 95.0);
			col += vec3(1.0, 0.82, 0.35) * ring * (0.18 + 0.12 * pulse);
		}
	}

	col *= space;
	col = 1.0 - exp(-col * 1.20);
	return col;
}

void main() {
	uvec2 gid = gl_GlobalInvocationID.xy;
	if (gid.x >= uint(PC.width) || gid.y >= uint(PC.height)) {
		return;
	}
	vec2 uv = (vec2(gid) + vec2(0.5)) / vec2(float(PC.width), float(PC.height));
	float t = PC.total_time;
	vec3 color = vec3(0.0);

	color = render_stage2(uv, t);

	color = clamp(color, 0.0, 1.0);
	imageStore(out_tex, ivec2(gid), vec4(color, 1.0));
}
