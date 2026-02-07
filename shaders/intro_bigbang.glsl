#[compute]
#version 450
// File: res://shaders/intro_bigbang.glsl
// GPU intro effect for quote + big-bang phases.

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
const int SHADER_PHASE_QUOTE = 0;
const int SHADER_PHASE_BIG_BANG = 1;

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

float filament_field(vec2 p, float t, float scale, float thickness) {
	vec2 q = p * scale;
	float n0 = fbm(q + vec2(t * 0.17, -t * 0.13));
	float n1 = fbm(rot2(0.65) * q * 1.17 - vec2(t * 0.11, t * 0.09) + 11.7);
	float n = n0 * 0.68 + n1 * 0.32;
	float ridge = abs(n * 2.0 - 1.0);
	float line = clamp(1.0 - ridge / max(0.001, thickness), 0.0, 1.0);
	return line * line;
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

vec3 intro_star_sky(vec2 uv, float t, float pan, float alpha) {
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

vec4 sample_mycelium_morph(vec2 uv, vec2 p, float t, float spread, float progress) {
	// Make the mycelium sampling domain expand with the big-bang envelope
	// instead of staying mostly screen-locked.
	float spread_n = clamp((spread - 0.018) / max(0.0001, 2.30 - 0.018), 0.0, 1.0);
	float uv_zoom = mix(1.0, 0.24, spread_n);
	float burst = smoothstep(0.02, 0.75, progress) * (1.0 - smoothstep(1.30, 2.30, progress));
	vec2 radial = (dot(p, p) > 1e-6) ? normalize(p) : vec2(0.0, 1.0);
	vec2 base_uv = 0.5 + (uv - 0.5) * uv_zoom + radial * burst * (0.008 + 0.022 * spread_n);
	base_uv = fract(base_uv);

	float morph_t = t * mix(0.92, 1.55, spread_n) + progress * 0.45;
	vec2 p_morph = p * mix(1.00, 1.28, spread_n);
	vec2 w0 = flow_dir(p_morph * 1.45 + vec2(morph_t * 0.19, -morph_t * 0.15), morph_t * 0.71);
	vec2 w1 = flow_dir(rot2(1.11) * p_morph * 2.05 + vec2(-morph_t * 0.27, morph_t * 0.22) + 9.3, morph_t * 0.93);
	vec2 w2 = flow_dir(rot2(-0.63) * p_morph * 3.10 + w0 * 1.7 - w1 * 1.2 + vec2(morph_t * 0.31, morph_t * 0.26) - 4.7, morph_t * 1.17);
	vec2 d0 = w0 * 0.016 + w2 * 0.010;
	vec2 d1 = w1 * 0.018 - w0 * 0.009;
	vec2 d2 = w2 * 0.015 + w1 * 0.008;
	vec2 uv0 = fract(base_uv + d0);
	vec2 uv1 = fract(base_uv + d1);
	vec2 uv2 = fract(base_uv + d2);
	float m0 = fbm(p_morph * 3.3 + vec2(morph_t * 0.29, -morph_t * 0.23) + w0 * 3.0);
	float m1 = fbm(rot2(0.71) * p_morph * 5.7 + vec2(-morph_t * 0.18, morph_t * 0.27) + w1 * 2.2 + 13.2);
	float blend_a = smoothstep(0.22, 0.78, m0);
	float blend_b = smoothstep(0.20, 0.82, m1);
	vec4 s0 = sample_mycelium(uv0);
	vec4 s1 = sample_mycelium(uv1);
	vec4 s2 = sample_mycelium(uv2);
	vec4 m01 = mix(s0, s1, blend_a);
	return mix(m01, s2, 0.10 + blend_b * 0.62);
}

vec3 render_bigbang(vec2 uv, float t) {
	float progress_raw = max(PC.bigbang_progress, 0.0);
	float timeline = clamp(progress_raw, 0.0, 1.0);
	float ignition = 1.0 - pow(1.0 - clamp(timeline / 0.11, 0.0, 1.0), 3.0);
	// Base expansion during early normalized phase.
	float s_curve = timeline * timeline * (3.0 - 2.0 * timeline);
	float expand_accel = pow(s_curve, 1.55);
	float expand = pow(timeline, 1.62);
	// Keep acceleration rising beyond timeline=1.0 (no late slowdown).
	float late_tail = max(progress_raw - 0.82, 0.0);
	float late_tail_pow = pow(late_tail, 2.30);
	float plasma_alpha = clamp(PC.quote_alpha, 0.0, 1.0);
	vec2 aspect = vec2(float(PC.width) / max(1.0, float(PC.height)), 1.0);
	vec2 q = (uv - 0.5) * aspect * 2.0;
	float r = length(q);
	float spread = mix(0.018, 2.30, expand_accel) + 0.95 * late_tail_pow;
	vec4 my_edge_state = sample_mycelium_morph(uv, q, t, spread, progress_raw);
	float my_edge_density_raw = clamp(my_edge_state.z, 0.0, 1.0);
	float edge_n0 = fbm(q * 4.4 + vec2(t * 0.47, -t * 0.39));
	float edge_n1 = fbm(rot2(0.92) * q * 7.2 + vec2(-t * 0.33, t * 0.41) + edge_n0 * 2.0 + 5.6);
	float my_edge_density = clamp(my_edge_density_raw * (0.58 + 0.95 * edge_n1), 0.0, 1.0);
	// The whole effect starts as a tiny central singularity and expands outwards.
	float edge_noise = fbm(q * 6.4 + vec2(t * 0.31, -t * 0.27));
	float edge_irregular = (edge_noise - 0.5) * 0.20 + (my_edge_density - 0.5) * 0.42;
	float pattern_on = smoothstep(0.12, 0.46, PC.phase_time);
	// Keep the mycelium layer active after a short intro ramp-in.
	float pattern_visible = smoothstep(0.02, 0.20, timeline);
	float edge_gate = pattern_on * (1.0 - smoothstep(1.55, 2.35, progress_raw));
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

	float branch_noise0 = fbm(warp * 6.8 + vec2(t * 0.63, -t * 0.57));
	float branch_noise1 = fbm(rot2(0.93) * warp * 11.4 + vec2(-t * 0.41, t * 0.46) + 13.4);
	float branch_mix = branch_noise0 * 0.62 + branch_noise1 * 0.38;
	float branches = smoothstep(0.70, 0.96, branch_mix);
	branches *= exp(-rn * 1.5) * (1.0 - expand * 0.25);
	branches *= spiral_fade;

	float mist = fbm(warp * 4.5 + vec2(t * 0.24, -t * 0.21));
	mist = smoothstep(0.28, 0.88, mist) * (1.0 - smoothstep(0.04, 1.20, rn));
	mist *= (0.58 + 0.58 * (1.0 - expand * 0.25));
	float dense_glow = smoothstep(1.10, 0.0, rn) * (1.0 - expand * 0.22);
	// Fast-fading white veil: keep the initial flashy core, remove the long-lived washout.
	float white_veil_fade = 1.0 - smoothstep(0.03, 0.46, progress_raw);

	float hue_base = fract(0.06 + t * 0.028 + rn * 0.31 + filaments * 0.35 + a / TAU * 0.18);
	vec3 trail_col = hsv2rgb(vec3(hue_base, 0.87, 1.0));
	vec3 alt_col = hsv2rgb(vec3(fract(hue_base + 0.19), 0.74, 1.0));
	vec3 plasma_col = vec3(0.0);
	plasma_col += trail_col * (filaments * 1.65 + branches * 1.10);
	plasma_col += alt_col * (mist * 0.55 + shock * 1.20);
	plasma_col += vec3(1.0, 0.95, 0.90) * core * 2.6 * white_veil_fade;
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

	float post_glow = exp(-r * 2.8) * smoothstep(0.16, 1.0, expand) * 0.30;
	col += vec3(0.34, 0.50, 0.92) * post_glow;

	// Mycelium layer from the external feedback simulation texture.
	vec4 my_state = sample_mycelium_morph(uv, qn, t * 1.12, spread, progress_raw);
	float my_density_raw = clamp(my_state.z, 0.0, 1.0);
	float morph_phase = clamp((spread - 0.018) / max(0.0001, 2.30 - 0.018), 0.0, 1.0);
	// Accelerate both spatial frequency growth and temporal morph speed over the explosion timeline.
	float accel_n = clamp(progress_raw / 1.85, 0.0, 1.0);
	float accel_curve = pow(accel_n, 1.75);
	float noise_scale = mix(1.0, 2.45, accel_curve);
	float morph_speed = mix(1.0, 2.20, accel_curve);
	float morph_t = t * mix(1.0, 1.48, morph_phase) * morph_speed + progress_raw * (0.36 + 0.52 * accel_curve);
	vec2 color_uv = qn * noise_scale;
	float my_morph_noise0 = fbm(color_uv * 5.2 + vec2(morph_t * 0.68, -morph_t * 0.61));
	float my_morph_noise1 = fbm(rot2(1.13) * color_uv * 8.1 + vec2(-morph_t * 0.52, morph_t * 0.57) + my_morph_noise0 * 2.4 + 21.7);
	float my_morph_noise2 = fbm(color_uv * 12.0 + vec2(my_morph_noise0, -my_morph_noise1) * 2.8 + vec2(morph_t * 0.94, morph_t * 0.83) - 17.3);
	float my_struct = clamp(my_morph_noise0 * 0.35 + my_morph_noise1 * 0.40 + my_morph_noise2 * 0.45, 0.0, 1.0);
	// Keep psychedelic modulation tied to simulated density so empty regions stay dark.
	float my_density = clamp(
		my_density_raw * (0.48 + 1.12 * my_struct + (my_morph_noise2 - 0.5) * 0.26),
		0.0,
		1.0
	);
	float psy_noise = fbm(color_uv * 3.6 + vec2(morph_t * 0.42, -morph_t * 0.37));
	float psy_noise2 = fbm(rot2(0.57) * color_uv * 6.2 + vec2(-morph_t * 0.35, morph_t * 0.31) + psy_noise * 2.0 + 8.7);
	float psy_phase = morph_t * 1.05 + (psy_noise * 2.0 - 1.0) * 2.4 + (psy_noise2 * 2.0 - 1.0) * 1.9;
	float hue_wobble = 0.22 * sin(psy_phase * 1.2) + 0.16 * sin(psy_phase * 2.1 + 1.7);
	float my_hue = fract(my_state.w + hue_wobble);
	// Enforce center-out reveal envelope for mycelium contribution.
	float my_envelope = smoothstep(local_spread + 0.14, local_spread - 0.022, r);
	float my_reveal = pattern_on * pattern_visible * my_envelope * (1.0 - smoothstep(1.08, 2.25, progress_raw));
	float my_shell_boost = exp(-abs(rn - shell_r) * mix(22.0, 10.0, expand));
	float swirl = 0.5 + 0.5 * sin(psy_phase * 1.6 + my_density * 5.0);
	vec3 my_base = hsv2rgb(vec3(fract(my_hue + 0.10 + 0.08 * sin(psy_phase * 0.8)), 0.90, 1.0));
	vec3 my_trail = hsv2rgb(vec3(fract(my_hue + 0.34 * swirl), 0.98, 1.0));
	vec3 my_alt = hsv2rgb(vec3(fract(my_hue + 0.62 - 0.20 * swirl), 0.98, 1.0));
	vec3 my_col = mix(my_base, my_trail, clamp(my_density * 0.95, 0.0, 1.0));
	my_col = mix(my_col, my_alt, 0.32 + 0.24 * sin(psy_phase * 1.3));
	vec3 neon_cyan = vec3(0.14, 1.00, 0.94);
	vec3 neon_magenta = vec3(1.00, 0.18, 0.96);
	float neon_mix = 0.5 + 0.5 * sin(psy_phase * 0.92 + rn * 8.0 + my_density * 4.2);
	vec3 neon_col = mix(neon_cyan, neon_magenta, neon_mix);
	my_col = mix(my_col, neon_col, clamp(my_density * 0.62 + my_shell_boost * 0.26, 0.0, 1.0));
	vec3 my_luma = vec3(dot(my_col, vec3(0.2126, 0.7152, 0.0722)));
	my_col = mix(my_luma, my_col, 1.36) * 1.22;
	my_col += vec3(1.0, 0.86, 0.58) * my_shell_boost * my_density * 0.34;
	float my_alpha = my_density * my_reveal * plasma_alpha * (1.0 - PC.fade_alpha * 0.55);
	col = col * 0.78 + my_col * (my_alpha * 2.95);
	float my_bloom_shell = exp(-abs(rn - shell_r) * 6.2);
	float my_bloom_body = smoothstep(0.20, 0.96, my_density) * exp(-rn * 0.86);
	float my_bloom = (my_bloom_shell * 0.58 + my_bloom_body * 0.74) * my_reveal;
	col += neon_col * (my_bloom * my_alpha * 1.20);

	float my_fringe = smoothstep(0.10, 0.85, my_density) * edge_gate * pattern_visible * my_envelope;
	float envelope_mix = clamp(envelope + my_fringe * 0.35, 0.0, 1.0);
	col *= envelope_mix;
	col = 1.0 - exp(-col * 1.55);
	float post_neon_bloom = my_bloom * (0.26 + 0.72 * my_density) * (1.0 - PC.fade_alpha * 0.65);
	col += neon_col * post_neon_bloom * 0.24;
	float fade_n = clamp(PC.fade_alpha, 0.0, 1.0);
	float fade_sat = smoothstep(0.18, 1.0, fade_n);
	float col_luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(col_luma), col, 1.0 + 0.58 * fade_sat);
	float chroma_tail = fade_sat * (1.0 - fade_n);
	vec3 tail_col = mix(neon_col, trail_col, 0.45);
	col += tail_col * (0.10 + 0.22 * my_bloom) * chroma_tail;
	col *= (1.0 - fade_n);

	// Fade the big-bang core first while it expands, revealing stars behind it.
	float core_clear_n = clamp((progress_raw - 0.14) / max(0.0001, 1.30 - 0.14), 0.0, 1.0);
	// End-weighted acceleration so corners clear sooner instead of lingering.
	float core_clear_t = core_clear_n * 0.15 + pow(core_clear_n, 2.40) * 0.85;
	// Extend final radius enough to catch screen corners at typical aspect ratios.
	float core_clear_edge = mix(0.05, 1.18, core_clear_t);
	// Keep transition sharper near the end so remaining corners don't wear off slowly.
	float core_clear_feather = mix(0.040, 0.070, core_clear_t);
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
	float flash_radius = mix(0.015, 2.90, flash_expand);
	// Grow only, then fade out quickly in the same time window previously used for collapse.
	float flash_fade = 1.0 - smoothstep(0.52, 1.0, flash_t);
	float flash_env = smoothstep(0.0, 0.12, flash_t) * flash_fade;
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
	// Keep twinkle phase continuous across scene-1 -> scene-2 transition.
	float star_twinkle_t = PC.total_time;

	vec3 base_sky = 1.0 - exp(-intro_star_sky(uv, star_twinkle_t, 0.0, 1.0) * 1.20);
	vec3 burst_sky = 1.0 - exp(-intro_star_sky(uv_burst, star_twinkle_t, 0.0, 1.18) * 1.25);
	vec3 stars_mix = mix(burst_sky, base_sky, drift_blend);
	// The persistent layer also starts compact, then eases to the stable starfield.
	float persistent_reveal = smoothstep(1.20, 1.90, progress_raw);
	float persistent_settle_n = clamp((progress_raw - 1.08) / max(0.0001, 3.25 - 1.08), 0.0, 1.0);
	float persistent_settle_log = log2(1.0 + 15.0 * persistent_settle_n) / log2(16.0);
	float persistent_settle = persistent_settle_log * persistent_settle_log * persistent_settle_log;
	persistent_settle *= (persistent_settle_log * (persistent_settle_log * 6.0 - 15.0) + 10.0);
	// Start with a compact (small) starfield and expand into the stable final state.
	float persistent_zoom = mix(0.42, 1.0, persistent_settle);
	vec2 uv_persistent = 0.5 + (uv - 0.5) / max(0.0001, persistent_zoom);
	vec3 persistent_sky = 1.0 - exp(-intro_star_sky(uv_persistent, star_twinkle_t, 0.0, 1.0) * 1.20);
	col += (persistent_sky * persistent_reveal * 1.12 + stars_mix * burst_weight * 1.05) * star_gate;

	return col;
}

void main() {
	uvec2 gid = gl_GlobalInvocationID.xy;
	if (gid.x >= uint(PC.width) || gid.y >= uint(PC.height)) {
		return;
	}
	vec2 uv = (vec2(gid) + vec2(0.5)) / vec2(float(PC.width), float(PC.height));
	vec3 color = vec3(0.0);

	if (PC.phase == SHADER_PHASE_QUOTE) {
		color = render_quote(uv, PC.phase_time);
	} else if (PC.phase == SHADER_PHASE_BIG_BANG) {
		// Use phase-local time so the burst starts from pristine initial state.
		color = render_bigbang(uv, PC.phase_time);
	}

	color = clamp(color, 0.0, 1.0);
	imageStore(out_tex, ivec2(gid), vec4(color, 1.0));
}
