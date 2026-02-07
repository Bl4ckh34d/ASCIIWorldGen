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
	float _pad0;
	float _pad1;
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
	uint idx = uint(i);
	uint h = idx ^ uint(PC.seed) ^ (uint(PC.epoch) * 0x9e3779b9u);
	float r = hash01(h);
	OutB.out_biome[i] = (r < step) ? new_b : old_b;
}

