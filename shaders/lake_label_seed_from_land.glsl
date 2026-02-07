#[compute]
#version 450
// File: res://shaders/lake_label_seed_from_land.glsl
// Seeds water pixels from a land mask (1=land, 0=water) with unique labels.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer LandBuf { uint land[]; } Land;
layout(std430, set = 0, binding = 1) buffer LabelsBuf { int labels[]; } Lbl;

layout(push_constant) uniform Params {
	int width;
	int height;
	int _pad0;
	int _pad1;
} PC;

void main() {
	uint x = gl_GlobalInvocationID.x;
	uint y = gl_GlobalInvocationID.y;
	if (x >= uint(PC.width) || y >= uint(PC.height)) {
		return;
	}
	int i = int(x) + int(y) * PC.width;
	Lbl.labels[i] = (Land.land[i] == 0u) ? (i + 1) : 0;
}
