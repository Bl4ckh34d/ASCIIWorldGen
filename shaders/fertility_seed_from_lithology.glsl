#[compute]
#version 450
// File: res://shaders/fertility_seed_from_lithology.glsl
// Seed/relax fertility from lithology, moisture, and lava (GPU-only).

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer RockBuf { int rock_type[]; } Rock;
layout(std430, set = 0, binding = 1) readonly buffer LandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) readonly buffer MoistBuf { float moist_norm[]; } Moist;
layout(std430, set = 0, binding = 3) readonly buffer LavaBuf { float lava_mask[]; } Lava;
layout(std430, set = 0, binding = 4) buffer FertilityBuf { float fertility[]; } Fert;

layout(push_constant) uniform Params {
	int width;
	int height;
	int reset_existing;
	int _pad0;
	float water_blend;
	float land_blend;
	float _pad1;
	float _pad2;
} PC;

const int ROCK_BASALTIC = 0;
const int ROCK_GRANITIC = 1;
const int ROCK_SEDIMENTARY_CLASTIC = 2;
const int ROCK_LIMESTONE = 3;
const int ROCK_METAMORPHIC = 4;
const int ROCK_VOLCANIC_ASH = 5;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

float base_fertility_for_rock(int rock) {
	if (rock == ROCK_BASALTIC) return 0.86;
	if (rock == ROCK_VOLCANIC_ASH) return 0.78;
	if (rock == ROCK_LIMESTONE) return 0.68;
	if (rock == ROCK_SEDIMENTARY_CLASTIC) return 0.54;
	if (rock == ROCK_METAMORPHIC) return 0.46;
	if (rock == ROCK_GRANITIC) return 0.34;
	return 0.50;
}

void main() {
	uint gx = gl_GlobalInvocationID.x;
	uint gy = gl_GlobalInvocationID.y;
	if (gx >= uint(PC.width) || gy >= uint(PC.height)) return;

	int i = int(gx) + int(gy) * PC.width;
	float prev = clamp01(Fert.fertility[i]);
	bool reset = (PC.reset_existing != 0);

	if (Land.is_land[i] == 0u) {
		float target_w = 0.04;
		Fert.fertility[i] = reset ? target_w : clamp01(mix(prev, target_w, clamp01(PC.water_blend)));
		return;
	}

	int rock = Rock.rock_type[i];
	float base = base_fertility_for_rock(rock);
	float moist = clamp01(Moist.moist_norm[i]);
	float target = clamp01(base * (0.78 + 0.22 * moist));
	if (Lava.lava_mask[i] > 0.5) {
		target = min(target, base * 0.30);
	}
	Fert.fertility[i] = reset ? target : clamp01(mix(prev, target, clamp01(PC.land_blend)));
}

