#[compute]
#version 450
// File: res://shaders/depression_fill_seed.glsl
// Seeds drainage elevation E:
// - ocean cells and vertical map edges get terrain height
// - inland cells start at a large sentinel

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer HeightBuf { float height[]; } H;
layout(std430, set = 0, binding = 1) readonly buffer LandBuf { uint is_land[]; } L;
layout(std430, set = 0, binding = 2) buffer EOutBuf { float e_out[]; } Eout;

layout(push_constant) uniform Params {
	int width;
	int height_px;
	int total_cells;
	int _pad0;
} PC;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(PC.total_cells)) {
		return;
	}
	int y = int(i) / PC.width;
	bool on_vert_edge = (y == 0 || y == PC.height_px - 1);
	bool ocean = (L.is_land[i] == 0u);
	Eout.e_out[i] = (ocean || on_vert_edge) ? H.height[i] : 1e9;
}
