#[compute]
#version 450
// File: res://shaders/biome_transition.glsl

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer OldBiomeBuf { int old_biome[]; } OldB;
layout(std430, set = 0, binding = 1) readonly buffer NewBiomeBuf { int new_biome[]; } NewB;
layout(std430, set = 0, binding = 2) writeonly buffer OutBiomeBuf { int out_biome[]; } OutB;

layout(push_constant) uniform Params {
	int width;
	int height;
	int seed;
	int epoch;
	float step_general;
	float step_cryosphere;
	float seed_floor_general;
	float seed_floor_cryosphere;
	float front_q0;
	float front_q1;
	float front_gamma;
	float cryo_polar_seed_boost;
} PC;

const int BIOME_ICE_SHEET = 1;
const int BIOME_GLACIER = 24;

uint hash_u32(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

float hash01(uint x) {
	return float(hash_u32(x)) / 4294967295.0;
}

bool is_cryosphere(int b) {
	return b == BIOME_ICE_SHEET || b == BIOME_GLACIER;
}

int idx_wrap_x(int x, int y) {
	int xx = (x + PC.width) % PC.width;
	return xx + y * PC.width;
}

void main() {
	uint x = gl_GlobalInvocationID.x;
	uint y = gl_GlobalInvocationID.y;
	if (x >= uint(PC.width) || y >= uint(PC.height)) {
		return;
	}
	int i = int(x) + int(y) * PC.width;
	int old_b = OldB.old_biome[i];
	int new_b = NewB.new_biome[i];
	if (old_b == new_b) {
		OutB.out_biome[i] = old_b;
		return;
	}
	bool cryo = is_cryosphere(old_b) || is_cryosphere(new_b);
	float step = clamp(cryo ? PC.step_cryosphere : PC.step_general, 0.0, 1.0);
	if (step <= 0.0) {
		OutB.out_biome[i] = old_b;
		return;
	}
	if (step >= 1.0) {
		OutB.out_biome[i] = new_b;
		return;
	}
	// Front-coupled adoption: transitions accelerate when neighboring tiles
	// are already in the target biome; isolated flips are rare "seed" events.
	int nb_total = 0;
	int nb_match = 0;
	for (int oy = -1; oy <= 1; ++oy) {
		for (int ox = -1; ox <= 1; ++ox) {
			if (ox == 0 && oy == 0) continue;
			int ny = int(y) + oy;
			if (ny < 0 || ny >= PC.height) continue;
			int j = idx_wrap_x(int(x) + ox, ny);
			nb_total += 1;
			if (OldB.old_biome[j] == new_b) {
				nb_match += 1;
			}
		}
	}
	float q = (nb_total > 0) ? (float(nb_match) / float(nb_total)) : 0.0;
	float q0 = min(PC.front_q0, PC.front_q1);
	float q1 = max(PC.front_q0, PC.front_q1);
	float front = smoothstep(q0, q1, q);
	front = pow(clamp(front, 0.0, 1.0), max(0.01, PC.front_gamma));
	float seed_floor = cryo ? PC.seed_floor_cryosphere : PC.seed_floor_general;
	float p = step * mix(seed_floor, 1.0, front);
	bool into_cryo = is_cryosphere(new_b) && !is_cryosphere(old_b);
	if (into_cryo) {
		// Poleward seeding bias: cryosphere tends to nucleate near poles first,
		// then spread equatorward via the neighborhood front term.
		float lat = abs((float(y) / max(1.0, float(PC.height - 1))) - 0.5) * 2.0; // 0 eq .. 1 poles
		float pole_seed = PC.cryo_polar_seed_boost * lat * lat;
		p += step * pole_seed * (1.0 - q);
	}
	p = clamp(p, 0.0, 1.0);
	uint idx = uint(i);
	uint h = idx ^ uint(PC.seed) ^ (uint(PC.epoch) * 0x9e3779b9u);
	float r = hash01(h);
	OutB.out_biome[i] = (r < p) ? new_b : old_b;
}
