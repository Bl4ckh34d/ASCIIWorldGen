#[compute]
#version 450
// File: res://shaders/lake_label_apply_boundary.glsl
// Filters boundary-connected water labels into inland lake mask + id.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer LabelBuf { int labels[]; } Lbl;
layout(std430, set = 0, binding = 1) readonly buffer FlagsBuf { int flags[]; } Flags;
layout(std430, set = 0, binding = 2) buffer LakeBuf { uint lake[]; } LakeOut;
layout(std430, set = 0, binding = 3) buffer LakeIdBuf { int lake_id[]; } LakeIdOut;

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
	int lbl = Lbl.labels[i];
	if (lbl > 0 && Flags.flags[lbl] == 0) {
		LakeOut.lake[i] = 1u;
		LakeIdOut.lake_id[i] = lbl;
	} else {
		LakeOut.lake[i] = 0u;
		LakeIdOut.lake_id[i] = 0;
	}
}
