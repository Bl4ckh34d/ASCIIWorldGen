#[compute]
#version 450
// File: res://shaders/lithology_classify.glsl
// Classify per-cell lithology (rock type) from terrain/climate fields.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer HeightBuf { float height_data[]; } Height;
layout(std430, set = 0, binding = 1) readonly buffer LandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) readonly buffer TempBuf { float temp_norm[]; } Temp;
layout(std430, set = 0, binding = 3) readonly buffer MoistBuf { float moist_norm[]; } Moist;
layout(std430, set = 0, binding = 4) readonly buffer DesertFieldBuf { float desert_field[]; } DesertField; // optional 0..1
layout(std430, set = 0, binding = 5) readonly buffer LavaBuf { float lava_mask[]; } Lava;
layout(std430, set = 0, binding = 6) writeonly buffer OutRockBuf { int out_rock[]; } OutRock;

layout(push_constant) uniform Params {
	int width;
	int height;
	int seed;
	int has_desert_field;
	float min_h;
	float max_h;
	float noise_x_scale;
	float _pad0;
} PC;

const int ROCK_BASALTIC = 0;
const int ROCK_GRANITIC = 1;
const int ROCK_SEDIMENTARY_CLASTIC = 2;
const int ROCK_LIMESTONE = 3;
const int ROCK_METAMORPHIC = 4;
const int ROCK_VOLCANIC_ASH = 5;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33 + float(PC.seed % 97));
	return fract((p3.x + p3.y) * p3.z);
}

int idx_wrap_x(int x, int y) {
	int xx = (x + PC.width) % PC.width;
	return xx + y * PC.width;
}

void main() {
	uint gx = gl_GlobalInvocationID.x;
	uint gy = gl_GlobalInvocationID.y;
	if (gx >= uint(PC.width) || gy >= uint(PC.height)) {
		return;
	}
	int x = int(gx);
	int y = int(gy);
	int i = x + y * PC.width;

	if (Land.is_land[i] == 0u) {
		OutRock.out_rock[i] = ROCK_BASALTIC;
		return;
	}

	float h0 = Height.height_data[i];
	float t = clamp01(Temp.temp_norm[i]);
	float m = clamp01(Moist.moist_norm[i]);
	float dry = 1.0 - m;
	float elev = clamp01((h0 - PC.min_h) / max(0.0001, (PC.max_h - PC.min_h)));

	float slope_sum = 0.0;
	int slope_count = 0;
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) continue;
			int ny = y + oy;
			if (ny < 0 || ny >= PC.height) continue;
			int j = idx_wrap_x(x + ox, ny);
			slope_sum += abs(h0 - Height.height_data[j]);
			slope_count++;
		}
	}
	float slope = clamp01((slope_count > 0 ? (slope_sum / float(slope_count)) : 0.0) / 0.06);
	float flatness = 1.0 - slope;

	float province = hash12(vec2(float(x) * max(0.0001, PC.noise_x_scale), float(y)));
	if (PC.has_desert_field == 1) {
		province = clamp01(DesertField.desert_field[i]);
	}

	float lava = Lava.lava_mask[i];
	if (lava > 0.5) {
		OutRock.out_rock[i] = (province > 0.58) ? ROCK_VOLCANIC_ASH : ROCK_BASALTIC;
		return;
	}

	float sedimentary_score = (1.0 - elev) * 0.55 + flatness * 0.28 + m * 0.17;
	float limestone_score = m * 0.45 + flatness * 0.25 + (1.0 - elev) * 0.18 + (1.0 - abs(t - 0.62)) * 0.12;
	float metamorphic_score = elev * 0.52 + slope * 0.36 + dry * 0.12;
	float granitic_score = elev * 0.33 + slope * 0.20 + (1.0 - province) * 0.30 + dry * 0.17;
	float basaltic_score = province * 0.34 + dry * 0.20 + t * 0.16 + elev * 0.10 + 0.20;
	float ash_score = max(0.0, (t - 0.74)) * 0.55 + dry * 0.20 + province * 0.25;

	if (dry > 0.55 && flatness > 0.58) {
		sedimentary_score += 0.18;
		limestone_score += 0.05;
	}
	if (elev > 0.70 && slope > 0.35) {
		metamorphic_score += 0.22;
		granitic_score += 0.11;
	}
	if (m > 0.68 && elev < 0.45) {
		limestone_score += 0.17;
	}

	int best = ROCK_BASALTIC;
	float best_score = basaltic_score;
	if (granitic_score > best_score) { best = ROCK_GRANITIC; best_score = granitic_score; }
	if (sedimentary_score > best_score) { best = ROCK_SEDIMENTARY_CLASTIC; best_score = sedimentary_score; }
	if (limestone_score > best_score) { best = ROCK_LIMESTONE; best_score = limestone_score; }
	if (metamorphic_score > best_score) { best = ROCK_METAMORPHIC; best_score = metamorphic_score; }
	if (ash_score > best_score) { best = ROCK_VOLCANIC_ASH; best_score = ash_score; }

	OutRock.out_rock[i] = best;
}

