#[compute]
#version 450
// File: res://shaders/lake_label_seed_from_mask.glsl
// Seeds each lake pixel with a unique label (i+1), zero elsewhere.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer MaskBuf { uint lake_mask[]; } M;
layout(std430, set = 0, binding = 1) buffer LabelsBuf { int labels[]; } L;

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
	L.labels[i] = (M.lake_mask[i] != 0u) ? int(i + 1u) : 0;
}
