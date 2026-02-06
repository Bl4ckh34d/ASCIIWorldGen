#[compute]
#version 450
// File: res://shaders/intro_mycelium_sim.glsl
// Persistent mycelium-style feedback simulation used during intro big-bang.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform readonly image2D src_tex;
layout(rgba32f, set = 0, binding = 1) uniform writeonly image2D dst_tex;

layout(push_constant) uniform Params {
	int width;
	int height;
	int reset_state;
	int _pad_i0;
	float total_time;
	float phase_time;
	float bigbang_progress;
	float fade_alpha;
	float seed_alpha;
	float dt;
	float _pad_f0;
	float _pad_f1;
} PC;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	return vec2(
		hash12(p + vec2(17.3, 51.7)),
		hash12(p + vec2(63.1, 11.9))
	);
}

vec4 obstacle_field(vec2 p) {
	const float cell_size = 0.115;
	const float rad_min = 0.014;
	const float rad_max = 0.041;
	vec2 base = floor(p / cell_size);
	vec2 best_n = vec2(0.0, 1.0);
	float best_pen = 0.0;
	float best_score = -1.0;
	float near_shell = 0.0;

	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 cell = base + vec2(float(i), float(j));
			vec2 rnd = hash22(cell * 1.31 + vec2(19.2, 7.7));
			vec2 center = (cell + 0.15 + rnd * 0.70) * cell_size;
			float radius = mix(rad_min, rad_max, hash12(cell + vec2(31.4, 15.9)));
			float center_r = length(center);
			float obstacle_active = smoothstep(0.12, 0.26, center_r) * (1.0 - smoothstep(1.58, 2.05, center_r));
			vec2 d = p - center;
			float dl = length(d);
			vec2 n = (dl > 0.0001) ? (d / dl) : vec2(1.0, 0.0);
			float pen = max(radius - dl, 0.0) * obstacle_active;
			float shell_w = exp(-abs(dl - radius) * 48.0) * obstacle_active;
			float score = max(pen * 28.0, shell_w);
			if (score > best_score) {
				best_score = score;
				best_n = n;
			}
			if (pen > best_pen) {
				best_pen = pen;
			}
			near_shell += shell_w;
		}
	}

	return vec4(best_n, best_pen, near_shell);
}

ivec2 wrap_xy(ivec2 p) {
	ivec2 dim = ivec2(max(1, PC.width), max(1, PC.height));
	int x = p.x % dim.x;
	int y = p.y % dim.y;
	if (x < 0) {
		x += dim.x;
	}
	if (y < 0) {
		y += dim.y;
	}
	return ivec2(x, y);
}

vec4 load_state(ivec2 p) {
	return imageLoad(src_tex, wrap_xy(p));
}

vec4 sample_state_uv(vec2 uv) {
	vec2 size = vec2(float(max(1, PC.width)), float(max(1, PC.height)));
	vec2 px = clamp(uv * size, vec2(0.0), size - vec2(1.0));
	return load_state(ivec2(px));
}

void main() {
	ivec2 ip = ivec2(gl_GlobalInvocationID.xy);
	if (ip.x >= PC.width || ip.y >= PC.height) {
		return;
	}

	vec2 res = vec2(float(max(1, PC.width)), float(max(1, PC.height)));
	vec2 uv = (vec2(ip) + vec2(0.5)) / res;
	vec2 aspect = vec2(res.x / max(1.0, res.y), 1.0);
	vec2 p = (uv - 0.5) * aspect * 2.0;
	float r = length(p);
	vec2 radial = (r > 0.0001) ? (p / r) : vec2(0.0, 1.0);
	vec2 tangent = vec2(-radial.y, radial.x);

	bool reset = PC.reset_state > 0;
	vec4 cur = vec4(0.0);
	vec4 navg = vec4(0.0);
	if (!reset) {
		cur = load_state(ip);
		vec4 nsum = vec4(0.0);
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				nsum += load_state(ip + ivec2(i, j));
			}
		}
		navg = nsum / 9.0;
	}

	float progress = max(PC.bigbang_progress, 0.0);
	float explosion = smoothstep(0.0, 0.14, progress) * (1.0 - smoothstep(1.30, 2.35, progress));
	float ring_t = smoothstep(0.0, 1.0, clamp(progress * 1.65, 0.0, 1.0));
	float shell_r = mix(0.015, 1.35, ring_t);
	float shell = exp(-abs(r - shell_r) * mix(26.0, 9.5, ring_t));
	float core = exp(-r * 24.0);
	vec4 obst = obstacle_field(p);
	float obstacle_gate = smoothstep(0.00, 0.16, progress) * (1.0 - smoothstep(1.45, 2.45, progress));

	vec2 vel = cur.xy;
	vel = mix(vel, navg.xy, 0.14);

	float swirl_gain = explosion * (0.050 + shell * 0.090);
	float burst_gain = explosion * (0.035 + shell * 0.040);
	vec2 noise_dir = vec2(
		hash12(vec2(ip) + vec2(13.1, 91.7)),
		hash12(vec2(ip) + vec2(77.4, 19.6))
	) * 2.0 - 1.0;
	vec2 turb_dir = vec2(
		hash12(p * 19.0 + vec2(PC.total_time * 1.13, -PC.total_time * 0.77)),
		hash12(p * 17.0 + vec2(-PC.total_time * 0.89, PC.total_time * 1.27))
	) * 2.0 - 1.0;
	float turbulence = explosion * 0.015 + obstacle_gate * min(obst.w * 0.020, 0.110);

	vel += tangent * swirl_gain;
	vel += radial * burst_gain;
	vel += noise_dir * (0.0100 * explosion);
	vel += turb_dir * turbulence;

	float spray_window = smoothstep(0.01, 0.22, progress) * (1.0 - smoothstep(0.90, 1.75, progress));
	float spray_front_r = mix(0.02, 1.20, smoothstep(0.0, 1.0, progress));
	float spray_front = exp(-abs(r - spray_front_r) * mix(140.0, 34.0, clamp(progress, 0.0, 1.0)));
	float ang = atan(p.y, p.x);
	vec2 spray_push = vec2(0.0);
	float spray_mask = 0.0;
	const int SPRAY_COUNT = 10;
	for (int si = 0; si < SPRAY_COUNT; si++) {
		float sfi = float(si);
		float base_ang = (sfi + 0.5) * (6.28318530718 / float(SPRAY_COUNT));
		float jitter = (hash12(vec2(sfi * 9.13, 2.71)) * 2.0 - 1.0) * 0.42;
		float drift = sin(PC.total_time * (0.48 + 0.09 * sfi) + sfi * 1.73) * 0.26;
		float jet_ang = base_ang + jitter + drift;
		float da = abs(atan(sin(ang - jet_ang), cos(ang - jet_ang)));
		float jet_width = mix(0.060, 0.22, clamp(progress, 0.0, 1.0));
		float jet = exp(-da * (16.0 / max(jet_width, 0.001)));
		float jet_noise = 0.55 + 0.45 * hash12(vec2(sfi * 13.7, floor(PC.total_time * 16.0)));
		float jet_weight = jet * spray_front * jet_noise;
		spray_mask = max(spray_mask, jet_weight);
		spray_push += vec2(cos(jet_ang), sin(jet_ang)) * jet_weight;
	}
	if (length(spray_push) > 0.0001) {
		spray_push = normalize(spray_push);
	}
	vel += spray_push * (0.20 * spray_window + 0.30 * spray_mask * spray_window);

	// Click-like burst seeding: dense stochastic front launched from center.
	float burst_front_r = mix(0.02, 1.10, smoothstep(0.0, 0.95, progress));
	float burst_front = exp(-abs(r - burst_front_r) * 34.0);
	float burst_pulse = smoothstep(0.0, 0.05, progress) * (1.0 - smoothstep(0.10, 0.65, progress));
	float burst_rand = hash12(vec2(ip) + vec2(5.1, 88.6));
	float burst_hit = step(1.0 - clamp(burst_front * burst_pulse * 0.70, 0.0, 1.0), burst_rand);
	if (burst_hit > 0.0) {
		float a = hash12(vec2(ip) + vec2(43.2, 9.7)) * 6.28318530718;
		vec2 rand_dir = vec2(cos(a), sin(a));
		vec2 emit_dir = normalize(mix(rand_dir, radial, 0.7));
		vel += emit_dir * (0.18 + 0.34 * hash12(vec2(ip) + vec2(7.3, 14.1)));
	}

	// Collision with invisible micro-obstacles to create turbulent branching.
	float shell_contact = clamp(obst.w * 0.22, 0.0, 1.0);
	if (obstacle_gate > 0.0 && (obst.z > 0.0001 || shell_contact > 0.02)) {
		float vn = dot(vel, obst.xy);
		if (vn < 0.0) {
			vel -= obst.xy * vn * (2.8 + obst.z * 32.0 + shell_contact * 1.6);
		}
		vel += obst.xy * (0.08 + obst.z * 0.80 + shell_contact * 0.24);
		vec2 slip = vec2(-obst.xy.y, obst.xy.x);
		float slip_rand = hash12(vec2(ip) + vec2(93.1, 27.4)) * 2.0 - 1.0;
		vel += slip * slip_rand * (0.05 + obst.z * 0.34 + shell_contact * 0.22);
	}

	vel *= 0.992;

	float vmax = 2.45;
	float vlen = length(vel);
	if (vlen > vmax) {
		vel *= vmax / vlen;
	}

	vec2 back_uv = uv - vel * (0.0130 * max(0.2, PC.dt));
	vec4 adv = reset ? vec4(0.0) : sample_state_uv(back_uv);

	float density = mix(cur.z, adv.z, 0.70);
	float hue = mix(cur.w, adv.w, 0.62);
	density = mix(density, navg.z, 0.10);
	hue = mix(hue, navg.w, 0.06);

	float filament_noise = hash12(vec2(ip) * 0.83 + vec2(PC.total_time * 0.77, -PC.total_time * 0.58));
	float core_seed = core * smoothstep(0.0, 0.18, progress);
	float ring_seed = shell * smoothstep(0.02, 0.85, progress);
	float spark_seed = smoothstep(0.84, 1.0, filament_noise) * exp(-r * 7.0) * smoothstep(0.08, 0.95, progress);
	float inject = (core_seed * 1.35 + ring_seed * 0.65 + spark_seed * 0.88) * PC.seed_alpha;
	inject *= (1.0 - smoothstep(1.20, 2.35, progress));
	float burst_seed = burst_hit * (0.55 + 0.35 * hash12(vec2(ip) + vec2(4.9, 12.2)));
	inject = max(inject, burst_seed * burst_pulse);
	float spray_seed = spray_mask * spray_window * (0.60 + 0.25 * hash12(vec2(ip) + vec2(11.1, 3.8)));
	inject = max(inject, spray_seed);

	density = max(density * 0.992, inject);
	density += shell * explosion * 0.010;
	density += min(obst.w * 0.0024, 0.028) * obstacle_gate;
	density *= (1.0 - clamp(PC.fade_alpha, 0.0, 1.0) * 0.12);
	density = clamp(density, 0.0, 1.0);

	float base_h = fract(0.56 + hash12(vec2(ip) * 0.17) * 0.18 + PC.total_time * 0.015);
	float shell_shift = shell * 0.11;
	float obstacle_shift = min(obst.w * 0.03, 0.08) * obstacle_gate;
	float target_h = fract(base_h + shell_shift + obstacle_shift);
	float hue_blend = clamp(inject * 0.75 + density * 0.04 + obstacle_gate * obst.z * 8.0, 0.0, 1.0);
	hue = mix(hue, target_h, hue_blend);

	imageStore(dst_tex, ip, vec4(vel, density, hue));
}
