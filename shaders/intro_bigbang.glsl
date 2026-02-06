#[compute]
#version 450
// File: res://shaders/intro_bigbang.glsl
// GPU intro effect for quote + big bang + scene-2 (sun/corona/planet) phases.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform image2D out_tex;

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

float filament_field(vec2 p, float t, float scale, float thickness) {
	vec2 q = p * scale;
	float n0 = fbm(q + vec2(t * 0.17, -t * 0.13));
	float n1 = fbm(rot2(0.65) * q * 1.17 - vec2(t * 0.11, t * 0.09) + 11.7);
	float n = n0 * 0.68 + n1 * 0.32;
	float ridge = abs(n * 2.0 - 1.0);
	float line = clamp(1.0 - ridge / max(0.001, thickness), 0.0, 1.0);
	return line * line;
}

float star_field_seed(vec2 uv, float t) {
	vec2 cell = floor(uv * vec2(float(PC.width), float(PC.height)) * 0.95);
	float h = hash12(cell + vec2(31.7, 17.3));
	float s = smoothstep(0.9952, 1.0, h);
	float tw = 0.5 + 0.5 * sin(t * (1.5 + hash12(cell) * 3.0) + hash12(cell + 5.0) * TAU);
	return s * tw;
}

float star_field_expanding(vec2 uv, float t, float expansion) {
	float spread = mix(0.035, 1.10, clamp(expansion, 0.0, 1.0));
	vec2 rel = uv - 0.5;
	vec2 src = rel / max(0.001, spread) + 0.5;
	float in_bounds = step(0.0, src.x) * step(0.0, src.y) * step(src.x, 1.0) * step(src.y, 1.0);
	float radial = smoothstep(1.18, 0.0, length(rel) / max(0.001, spread * 0.98));
	float stars = star_field_seed(src, t);
	return stars * in_bounds * radial;
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

vec3 render_bigbang(vec2 uv, float t) {
	float timeline = clamp(PC.bigbang_progress, 0.0, 1.0);
	float ignition = 1.0 - pow(1.0 - clamp(timeline / 0.11, 0.0, 1.0), 3.0);
	float burst_t = clamp(timeline / 0.16, 0.0, 1.0);
	float expand_accel = pow(burst_t, 1.15); // fast burst.
	float expand = 1.0 - exp(-3.0 * timeline);
	float star_expand = 1.0 - exp(-3.6 * timeline); // keeps expanding but slows naturally.
	float plasma_alpha = clamp(PC.quote_alpha, 0.0, 1.0);
	vec2 aspect = vec2(float(PC.width) / max(1.0, float(PC.height)), 1.0);
	vec2 q = (uv - 0.5) * aspect * 2.0;
	float r = length(q);
	// The whole effect starts as a tiny central singularity and expands outwards.
	float spread = mix(0.004, 1.95, expand_accel);
	float envelope = smoothstep(spread + 0.09, spread - 0.012, r);
	vec2 qn = q / max(0.001, spread);
	float rn = length(qn);
	float a = atan(qn.y, qn.x);

	vec2 adv = flow_dir(qn * (1.6 + ignition * 0.9), t * 1.9 + expand * 8.0);
	vec2 warp = qn + adv * (0.40 - 0.18 * expand);

	float core = exp(-rn * mix(44.0, 5.2, ignition));
	float shell_r = mix(0.04, 1.22, expand_accel);
	float shock = exp(-abs(rn - shell_r) * mix(34.0, 9.0, expand)) * (1.0 - expand * 0.20);
	float shock_front = exp(-abs(rn - shell_r) * mix(68.0, 14.0, expand)) * (1.0 - expand * 0.08);

	float fil0 = filament_field(warp, t + ignition * 3.0, 8.0, 0.22);
	float fil1 = filament_field(rot2(1.12) * warp + vec2(1.7, -1.2), t * 1.1 + 17.0, 11.0, 0.20);
	float fil2 = filament_field(rot2(-0.74) * warp + vec2(-2.1, 1.8), t * 0.9 + 7.0, 15.0, 0.18);
	float filaments = max(fil0, max(fil1 * 0.90, fil2 * 0.74));
	filaments *= (1.0 - smoothstep(0.08, 1.12, rn));
	filaments *= (0.28 + 0.92 * smoothstep(0.01, 0.24, ignition));

	float branch_wave = sin(a * (17.0 - ignition * 5.0) - rn * 18.0 + t * 2.8);
	float branches = pow(clamp(branch_wave * 0.5 + 0.5, 0.0, 1.0), 9.0);
	branches *= exp(-rn * 1.5) * (1.0 - expand * 0.25);

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

	float star_gate = max(clamp(PC.star_alpha, 0.0, 1.0), smoothstep(0.02, 0.22, timeline) * 0.72);
	float stars = star_field_expanding(uv, t, star_expand);
	col += vec3(stars) * vec3(0.74, 0.84, 1.0) * (0.85 * star_gate);

	float post_glow = exp(-r * 2.8) * smoothstep(0.16, 1.0, expand) * 0.30;
	col += vec3(0.34, 0.50, 0.92) * post_glow;

	// Mycelium growth layer (inspired by your web shader): seeded at singularity and
	// advected outward, blended behind the main plasma blast.
	float myc_spread = mix(0.003, 1.95, pow(timeline, 0.60));
	vec2 my_qn = q / max(0.001, myc_spread);
	float my_r = length(my_qn);
	float my_env = smoothstep(1.20, 0.0, my_r);
	vec2 my_adv = flow_dir(my_qn * 1.7 + vec2(t * 0.18, -t * 0.13), t * 1.25);
	vec2 my_warp = my_qn + my_adv * 0.42;
	float my_f0 = filament_field(my_warp, t * 0.9 + timeline * 5.0, 9.0, 0.21);
	float my_f1 = filament_field(rot2(0.72) * my_warp + vec2(1.8, -1.3), t * 1.1 + 13.0, 13.0, 0.19);
	float my_mist = smoothstep(0.32, 0.92, fbm(my_warp * 4.6 + vec2(t * 0.33, -t * 0.24)));
	float my_density = (max(my_f0, my_f1 * 0.90) * 0.84 + my_mist * 0.34) * my_env;
	float my_trails = 0.0;
	for (int i = 0; i < 28; i++) {
		float fi = float(i) / 28.0;
		float seed = fi * 97.0 + 19.1;
		float ang = fi * TAU + sin(seed + t * 0.36) * 0.42;
		float sp = mix(0.45, 1.35, fract(seed * 0.27));
		vec2 head = vec2(cos(ang), sin(ang)) * pow(timeline, 1.08) * sp * 1.05;
		head += flow_dir(head * 3.4 + my_qn * 1.7 + vec2(seed), t + seed) * 0.09 * (1.0 - timeline);
		float d = length(my_qn - head);
		my_trails += exp(-d * mix(14.0, 30.0, fi)) * (1.0 - timeline * 0.12);
	}
	my_density = clamp(my_density + my_trails * 0.11, 0.0, 1.0);
	float my_hue = fract(0.56 + t * 0.020 + my_density * 0.20 + fbm(my_warp * 2.6) * 0.08);
	vec3 my_base = hsv2rgb(vec3(fract(my_hue + 0.10), 0.64, 0.86));
	vec3 my_trail_col = hsv2rgb(vec3(my_hue, 0.92, 1.0));
	vec3 my_col = mix(my_base, my_trail_col, clamp(my_density * 0.84, 0.0, 1.0)) * my_density;
	float my_alpha = smoothstep(0.005, 0.18, timeline) * plasma_alpha * (1.0 - PC.fade_alpha * 0.35);
	col = col * 0.88 + my_col * (my_alpha * 2.10);

	col *= envelope;
	col = 1.0 - exp(-col * 1.55);
	col *= (1.0 - clamp(PC.fade_alpha, 0.0, 1.0));

	// Full-screen flash at singularity birth.
	float screen_flash = exp(-PC.phase_time * 19.0);
	col = mix(col, vec3(1.0), clamp(screen_flash * 1.35, 0.0, 1.0));
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
	float sun_reveal = space * smoothstep(0.06, 0.36, pan);

	float sun_body = smoothstep(sun_r + 0.0025, sun_r - 0.0015, r);
	vec2 np = rel / max(0.0001, sun_r);
	float surf0 = fbm(np * 4.2 + vec2(t * 0.20, -t * 0.16));
	float surf1 = fbm(rot2(0.84) * np * 9.6 + vec2(-t * 0.34, t * 0.27) + 5.7);
	float gran = smoothstep(0.42, 0.96, surf0 * 0.55 + surf1 * 0.45);
	float veins = filament_field(np * 2.4 + flow_dir(np * 2.8, t * 0.85) * 0.9, t * 0.8, 7.5, 0.19);
	float core_grad = exp(-r / max(0.0001, sun_r * 0.55));
	float limb = smoothstep(sun_r * 0.58, sun_r * 0.995, r);

	vec3 base_col = mix(vec3(0.84, 0.17, 0.03), vec3(1.0, 0.57, 0.12), gran);
	vec3 hot_col = mix(vec3(1.0, 0.72, 0.20), vec3(1.0, 0.95, 0.78), core_grad);
	vec3 plasma = mix(base_col, hot_col, 0.58 + 0.30 * veins);
	plasma += vec3(1.0, 0.74, 0.25) * veins * 0.22;
	plasma += vec3(1.0, 0.92, 0.70) * core_grad * 0.28;
	plasma *= (1.0 + limb * 0.18);
	plasma = 1.0 - exp(-plasma * 1.28);
	col = mix(col, plasma, sun_body * sun_reveal);

	float outside = step(sun_r, r);
	float d = max(0.0, r - sun_r);
	float halo0 = exp(-d * 22.0);
	float halo1 = exp(-d * 9.0);
	float cor_noise0 = fbm(np * 5.6 + vec2(t * 0.72, -t * 0.54));
	float cor_noise1 = filament_field(
		rot2(0.58) * np * 4.4 + flow_dir(np * 3.2, t * 0.84) * 1.35,
		t * 0.95,
		8.4,
		0.23
	);
	float cor_shape = smoothstep(0.26, 0.97, cor_noise0 * 0.58 + cor_noise1 * 0.42);
	float corona = outside * (halo0 * 0.92 + halo1 * 0.24) * cor_shape;
	vec3 cor_col = mix(vec3(1.0, 0.42, 0.08), vec3(1.0, 0.88, 0.33), cor_noise0);
	col += cor_col * corona * sun_reveal * 1.62;

	float inner = PC.zone_inner_radius / max(1.0, float(PC.height));
	float outer = PC.zone_outer_radius / max(1.0, float(PC.height));
	float bw = 0.0035;
	float band = smoothstep(inner - bw, inner + bw, r) * (1.0 - smoothstep(outer - bw, outer + bw, r));
	float band_reveal = sun_reveal * smoothstep(0.48, 1.0, pan);
	float shimmer = 0.82 + 0.18 * sin(uvw.y * float(PC.height) * 0.12 + t * 1.5);
	col += vec3(1.0, 0.88, 0.30) * band * band_reveal * 0.26 * shimmer;

	if (PC.intro_phase >= INTRO_PHASE_PLANET_PLACE) {
		float xpix = uvw.x * float(PC.width);
		float ypix = uvw.y * float(PC.height);
		float line = smoothstep(1.5, 0.2, abs(ypix - PC.orbit_y));
		float seg = step(PC.orbit_x_min, xpix) * step(xpix, PC.orbit_x_max);
		col += vec3(1.0, 0.93, 0.62) * line * seg * 0.72 * sun_reveal;

		float px = PC.planet_x;
		if (PC.intro_phase == INTRO_PHASE_PLANET_PLACE && PC.planet_has_position < 0.5) {
			px = PC.planet_preview_x;
		}
		vec2 p_rel = vec2((xpix - px) / max(1.0, float(PC.height)), (ypix - PC.orbit_y) / max(1.0, float(PC.height)));
		float pr = length(p_rel);
		float p_rad = 14.0 / max(1.0, float(PC.height));
		float p_mask = smoothstep(p_rad + 0.002, p_rad - 0.001, pr);
		float p_noise = fbm(p_rel * 14.0 + vec2(t * 0.9, -t * 0.7));
		float p_vein = filament_field(p_rel * 8.5 + vec2(t * 0.5, -t * 0.4), t * 0.6, 8.0, 0.24);
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

	if (PC.phase == SHADER_PHASE_QUOTE) {
		color = render_quote(uv, PC.phase_time);
	} else if (PC.phase == SHADER_PHASE_BIG_BANG) {
		// Use phase-local time so the burst starts from pristine initial state.
		color = render_bigbang(uv, PC.phase_time);
	} else if (PC.phase == SHADER_PHASE_STAGE2) {
		color = render_stage2(uv, t);
	}

	color = clamp(color, 0.0, 1.0);
	imageStore(out_tex, ivec2(gid), vec4(color, 1.0));
}
