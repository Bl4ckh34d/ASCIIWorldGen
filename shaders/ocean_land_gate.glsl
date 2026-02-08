#[compute]
#version 450
// File: res://shaders/ocean_land_gate.glsl
// Inland water should not become ocean: reconcile is_land with lake mask.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer LandBuf { uint land[]; } Land;
layout(std430, set = 0, binding = 1) buffer LakeBuf { uint lake[]; } Lake;
layout(std430, set = 0, binding = 2) buffer LakeIdBuf { int lake_id[]; } LakeId;

layout(push_constant) uniform Params {
	int width;
	int height;
	int keep_lakes;
	int _pad0;
} PC;

void main() {
	uint x = gl_GlobalInvocationID.x;
	uint y = gl_GlobalInvocationID.y;
	if (x >= uint(PC.width) || y >= uint(PC.height)) {
		return;
	}
	int i = int(x) + int(y) * PC.width;
	if (Lake.lake[i] != 0u) {
		// Lakes are inland water bodies on land, not ocean.
		Land.land[i] = 1u;
		if (PC.keep_lakes == 0) {
			Lake.lake[i] = 0u;
			LakeId.lake_id[i] = 0;
		}
	}
}

