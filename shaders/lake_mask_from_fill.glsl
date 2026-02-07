#[compute]
#version 450
// File: res://shaders/lake_mask_from_fill.glsl
// Marks lake cells where filled drainage surface stands above terrain on land.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer HeightBuf { float height[]; } H;
layout(std430, set = 0, binding = 1) readonly buffer LandBuf { uint is_land[]; } L;
layout(std430, set = 0, binding = 2) readonly buffer EBuf { float e[]; } E;
layout(std430, set = 0, binding = 3) buffer LakeOutBuf { uint lake[]; } OutLake;

layout(push_constant) uniform Params {
	int total_cells;
	int _pad0;
	int _pad1;
	int _pad2;
} PC;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(PC.total_cells)) {
		return;
	}
	if (L.is_land[i] == 0u) {
		OutLake.lake[i] = 0u;
		return;
	}
	OutLake.lake[i] = (E.e[i] > H.height[i] + 1e-6) ? 1u : 0u;
}
