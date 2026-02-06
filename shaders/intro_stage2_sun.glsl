#[compute]
#version 450
// File: res://shaders/intro_stage2_sun.glsl
// Dedicated stage-2 (sun + orbital zone) intro compute shader.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform image2D out_tex;
layout(rgba32f, set = 0, binding = 1) uniform readonly image2D mycelium_tex;
layout(rgba8, set = 0, binding = 2) uniform readonly image2D corona_noise_tex;

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
	float _pad0;
	float _pad1;
} PC;

const float TAU = 6.28318530718;
const int SHADER_PHASE_QUOTE = 0;
const int SHADER_PHASE_BIG_BANG = 1;
const int SHADER_PHASE_STAGE2 = 2;
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
	ivec2 sz = imageSize(corona_noise_tex);
	if (sz.x <= 0 || sz.y <= 0) {
		return 0.5;
	}
	vec2 uv = fract(x * 0.01);
	ivec2 pix = ivec2(floor(uv * vec2(sz)));
	pix = clamp(pix, ivec2(0), sz - ivec2(1));
	return imageLoad(corona_noise_tex, pix).r;
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
	p = (p + 3.0) * 3.2;
	float tw = t * 0.18 + sin(t * 0.07) * 0.35;
	for (int i = 0; i < 3; i++) {
		p += cos(p.yx * 2.0 + vec2(tw, 1.57)) / 3.6;
		p += sin(p.yx * 0.78 + tw + vec2(1.57, 0.0)) / 2.9;
		p *= 1.18;
	}
	p += fract(sin(p + vec2(13.0, 7.0)) * 500000.0) * 0.008 - 0.004;
	return mod(p, 2.0) - 1.0;
}

float honey_cells(vec2 p, float t) {
	float slow_t = t * 0.16;
	vec2 q = p * 2.25;
	q += vec2(sin(slow_t * 0.90), cos(slow_t * 0.70)) * 0.22;
	float w0 = sin(q.x + slow_t * 0.35);
	float w1 = sin(dot(q, vec2(0.5, 0.8660254)) - slow_t * 0.28 + 1.10);
	float w2 = sin(dot(q, vec2(-0.5, 0.8660254)) + slow_t * 0.24 - 0.90);
	float tri = (w0 + w1 + w2) / 3.0;
	float cell = smoothstep(0.10, 0.88, 1.0 - abs(tri));
	float pocket = fbm(q * 0.85 + vec2(2.3, -1.4) + vec2(slow_t * 0.33, -slow_t * 0.27));
	return clamp(cell * 0.72 + pocket * 0.28, 0.0, 1.0);
}

float sun_bump_height(vec2 p, float t) {
	float slow_t = t * 0.52;
	float h = length(sun_sine_warp(p, slow_t)) * 0.7071;
	h = bump_soft_profile(h);
	float fine0 = fbm(p * 2.8 + vec2(-slow_t * 0.12, slow_t * 0.10));
	float fine1 = fbm(p * 6.4 + vec2(slow_t * 0.24, -slow_t * 0.20));
	float comb = honey_cells(p * 2.3, slow_t * 0.78);
	float micro = noise4q(vec4(vec3(p * 9.5 + vec2(83.23, 34.34), comb * 2.4 + 67.453), slow_t * 1.35));
	h = mix(h, fine0, 0.22);
	h = mix(h, fine1, 0.14);
	h = mix(h, comb, 0.12);
	h = mix(h, micro, 0.10);
	return smoothstep(0.12, 0.92, clamp(h, 0.0, 1.0));
}

vec2 sun_spherical_warp_coord(vec3 n, float t) {
	vec2 p = n.xy / max(0.30, n.z + 0.56);
	p += flow_dir(p * 1.45, t * 0.12) * 0.020;
	p += vec2(sin(t * 0.08 + p.y * 1.2), cos(t * 0.07 + p.x * 1.1)) * 0.008;
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

float star_layer(vec2 uv, float t, float scale, float pan_shift, float threshold, vec2 seed_bias) {
	vec2 su = fract(uv + vec2(pan_shift, 0.0));
	vec2 cell = floor(su * vec2(float(PC.width), float(PC.height)) * scale);
	float h = hash12(cell + seed_bias);
	float s = smoothstep(threshold, 1.0, h);
	float tw = 0.5 + 0.5 * sin(t * (1.4 + hash12(cell + 5.7) * 2.8) + hash12(cell + 12.3) * TAU);
	return s * tw;
}

vec3 stage2_star_sky(vec2 uv, float t, float pan, float alpha) {
	float l0 = star_layer(uv, t, 0.70, pan * 0.035, 0.9982, vec2(17.3, 41.7));
	float l1 = star_layer(uv, t, 1.25, pan * 0.080, 0.9988, vec2(51.8, 13.4));
	float l2 = star_layer(uv, t, 1.95, pan * 0.160, 0.9992, vec2(9.6, 77.2));
	float s = l0 * 0.95 + l1 * 0.70 + l2 * 0.45;
	return vec3(0.70, 0.80, 1.0) * s * alpha;
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

	// Singularity flash: center-origin wave reaches full screen in <0.2s, then dies quickly.
	float flash_expand_t = clamp(PC.phase_time / 0.18, 0.0, 1.0);
	float flash_decay_t = clamp((PC.phase_time - 0.10) / 0.15, 0.0, 1.0);
	float flash_intensity = 1.0 - flash_decay_t;
	float flash_radius = mix(0.015, 2.90, flash_expand_t * flash_expand_t * (3.0 - 2.0 * flash_expand_t));
	float flash_feather = mix(0.028, 0.24, flash_expand_t);
	float radial_flash = 1.0 - smoothstep(
		flash_radius - flash_feather,
		flash_radius + flash_feather,
		r
	);
	float center_flare = exp(-r * 58.0) * smoothstep(0.0, 0.10, PC.phase_time) * (1.0 - smoothstep(0.10, 0.25, PC.phase_time));
	float flash_mask = clamp(max(radial_flash, center_flare * 1.45), 0.0, 1.0) * flash_intensity;
	col = mix(col, vec3(1.0, 0.98, 0.94), flash_mask);

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
	// Reveal the sun early in the starfield->sun move so it doesn't look like
	// a late opacity fade while the camera is already panning.
	float sun_reveal = space * smoothstep(0.00, 0.12, pan);
	float sun_dist = r / max(0.0001, sun_r);
	// Tight back-glow layer behind sun/corona (kept intentionally compact).
	float back_glow_inner = exp(-pow(sun_dist * 2.7, 2.0));
	float back_glow_outer = exp(-pow(sun_dist * 1.6, 2.0));
	float back_glow_limb = exp(-abs(sun_dist - 1.0) * 15.0);
	vec3 back_glow = vec3(1.0, 0.84, 0.18) * back_glow_inner * 0.24;
	back_glow += vec3(1.0, 0.92, 0.32) * back_glow_outer * 0.17;
	back_glow += vec3(1.0, 0.74, 0.24) * back_glow_limb * 0.16;
	col += back_glow * sun_reveal;

	float sun_body = smoothstep(sun_r + 0.0025, sun_r - 0.0015, r);
	vec2 np = rel / max(0.0001, sun_r);
	float np_len2 = dot(np, np);
	float hemisphere = sqrt(max(0.0, 1.0 - min(np_len2, 1.0)));
	vec3 sphere_n = normalize(vec3(np, hemisphere));
	vec2 warp_p = sun_spherical_warp_coord(sphere_n, t) * 3.0;
	float h = sun_bump_height(warp_p, t * 0.34);
	float e = 0.018;
	float hx = sun_bump_height(warp_p + vec2(e, 0.0), t * 0.34) - h;
	float hy = sun_bump_height(warp_p + vec2(0.0, e), t * 0.34) - h;
	vec3 tangent_x = normalize(vec3(1.0, 0.0, -sphere_n.x / max(0.10, sphere_n.z)));
	vec3 tangent_y = normalize(vec3(0.0, 1.0, -sphere_n.y / max(0.10, sphere_n.z)));
	float bump_strength = 1.18;
	vec3 surf_n = normalize(sphere_n - tangent_x * hx * bump_strength - tangent_y * hy * bump_strength);
	vec3 light_dir = normalize(vec3(cos(t * 0.18) * 0.28, sin(t * 0.14) * 0.22, 0.93));
	float ndl = clamp(dot(surf_n, light_dir), 0.0, 1.0);
	float fres = pow(1.0 - clamp(surf_n.z, 0.0, 1.0), 2.2);
	float flow0 = filament_field(warp_p * 0.95 + flow_dir(warp_p * 1.2, t * 0.24) * 0.28, t * 0.24, 5.8, 0.34);
	float flow1 = filament_field(rot2(0.52) * warp_p * 1.20 + vec2(-t * 0.08, t * 0.06), t * 0.19, 7.2, 0.32);
	float honey_mask = honey_cells(warp_p * 0.92, t * 0.38);
	float detail_noise = noise4q(vec4(sphere_n * 24.0 + vec3(83.23, 34.34, 67.453), t * 0.78));
	detail_noise = smoothstep(0.38, 0.92, detail_noise);
	float veins = smoothstep(0.22, 0.84, mix(flow0, flow1, 0.36));
	veins = mix(veins, honey_mask, 0.24);
	veins = mix(veins, detail_noise, 0.10);
	float core_grad = exp(-r / max(0.0001, sun_r * 0.55));
	float limb = smoothstep(sun_r * 0.58, sun_r * 0.995, r);

	vec3 sun_deep = vec3(0.54, 0.06, 0.00);
	vec3 sun_mid = vec3(0.98, 0.24, 0.02);
	vec3 sun_hot = vec3(1.0, 0.72, 0.08);
	vec3 sun_core = vec3(1.0, 0.84, 0.40);
	float color_mix0 = clamp(h * 0.42 + veins * 0.58, 0.0, 1.0);
	vec3 base_col = mix(sun_deep, sun_mid, color_mix0);
	base_col = mix(base_col, sun_hot, clamp(h * 0.28 + veins * 0.62, 0.0, 1.0));
	vec3 plasma = base_col;
	float ember = smoothstep(0.62, 0.98, detail_noise);
	plasma += vec3(1.0, 0.56, 0.06) * ember * (0.02 + 0.04 * veins);
	plasma = mix(plasma, sun_core, clamp(core_grad * 0.45 + pow(ndl, 3.5) * 0.35, 0.0, 1.0));
	plasma += sun_hot * veins * 0.24;
	plasma += sun_core * ndl * 0.16;
	plasma += vec3(1.0, 0.82, 0.18) * fres * 0.26;
	plasma *= 1.00 + ndl * 0.22;
	plasma *= (1.0 + limb * 0.18);
	plasma = 1.0 - exp(-plasma * 1.34);
	col = mix(col, plasma, sun_body * sun_reveal);

	float rn = length(np);
	vec3 cor_rays = shadertoy_corona(np, t);
	float outside_body = smoothstep(0.985, 1.02, rn);
	float far_fade = 1.0 - smoothstep(1.55, 2.35, rn);
	float corona_mask = outside_body * far_fade * sun_reveal;
	float limb_bridge = exp(-abs(rn - 1.0) * 46.0) * sun_reveal;
	corona_mask = max(corona_mask, limb_bridge * 0.34);

	vec2 p_cor = np * 0.70710678;
	vec3 ray_cor = normalize(vec3(p_cor, 2.0));
	vec3 pos_cor = vec3(0.0, 0.0, 3.0);
	mat3 mr_cor = sun_corona_matrix(t);
	float s3a = corona_ring_ray_noise(ray_cor, pos_cor, 0.96, 1.0, mr_cor, t);
	vec3 ray_cor_b = normalize(vec3(rot2(0.31) * p_cor, 2.0));
	float s3b = corona_ring_ray_noise(ray_cor_b, pos_cor, 1.02, 0.95, mr_cor, t * 1.11 + 0.37);
	float swirl_raw = max(s3a, s3b * 0.88);
	float swirl_soft = smoothstep(0.07, 0.72, swirl_raw);
	float swirl_ridge = pow(smoothstep(0.34, 0.95, swirl_raw), 1.8);
	float swirl = clamp(swirl_soft * 0.55 + swirl_ridge * 1.25, 0.0, 1.0);
	float swirl_shell = smoothstep(1.02, 1.82, rn) * (1.0 - smoothstep(1.90, 2.35, rn));
	vec3 cor_swirl = mix(vec3(0.98, 0.24, 0.02), vec3(1.0, 0.84, 0.40), swirl) * swirl;
	cor_swirl *= 0.72 + swirl_shell * 0.78;
	vec3 bridge_col = vec3(1.0, 0.72, 0.22) * limb_bridge * 0.36;

	col += bridge_col;
	col += cor_rays * corona_mask * mix(1.72, 1.12, swirl * 0.75);
	col += cor_swirl * corona_mask * 1.62;
	col += vec3(1.0, 0.78, 0.24) * swirl_ridge * corona_mask * 0.32;

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

	if (PC.intro_phase >= INTRO_PHASE_PLANET_PLACE) {
		float xpix = uvw.x * float(PC.width);
		float ypix = uvw.y * float(PC.height);

		float px = PC.planet_x;
		if (PC.intro_phase == INTRO_PHASE_PLANET_PLACE && PC.planet_has_position < 0.5) {
			px = PC.planet_preview_x;
		}
		vec2 p_rel = vec2((xpix - px) / max(1.0, float(PC.height)), (ypix - PC.orbit_y) / max(1.0, float(PC.height)));
		float pr = length(p_rel);
		float p_rad = 14.0 / max(1.0, float(PC.height));
		float p_mask = smoothstep(p_rad + 0.002, p_rad - 0.001, pr);
		float p_noise = fbm(p_rel * 14.0 + vec2(t * 0.45, -t * 0.35));
		float p_vein = filament_field(p_rel * 8.5 + vec2(t * 0.25, -t * 0.2), t * 0.3, 8.0, 0.24);
		float p_core = exp(-pr / max(0.0001, p_rad * 0.55));
		vec3 p_col = mix(vec3(0.55, 0.09, 0.03), vec3(1.0, 0.42, 0.10), p_noise);
		p_col = mix(p_col, vec3(1.0, 0.72, 0.24), p_vein * 0.45);
		p_col += vec3(1.0, 0.84, 0.42) * p_core * 0.24;
		col = mix(col, p_col, p_mask);
		float p_glow = exp(-max(0.0, pr - p_rad) * 45.0) * step(p_rad, pr);
		col += vec3(1.0, 0.46, 0.14) * p_glow * 0.30;

		if (PC.intro_phase == INTRO_PHASE_PLANET_PLACE) {
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

