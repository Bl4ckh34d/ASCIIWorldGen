#[compute]
#version 450
// File: res://shaders/river_freeze_gate.glsl
// Removes river cells on freezing land or glacier biome cells.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer RiverBuf { uint river[]; } River;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) buffer TempBuf { float temp_norm[]; } Temp;
layout(std430, set = 0, binding = 3) buffer BiomeBuf { int biome_id[]; } Biome;

layout(push_constant) uniform Params {
	int width;
	int height;
	int glacier_biome_id;
	int _pad0;
	float temp_min_c;
	float temp_max_c;
	float freeze_c;
	float _pad1;
} PC;

void main() {
	uint x = gl_GlobalInvocationID.x;
	uint y = gl_GlobalInvocationID.y;
	if (x >= uint(PC.width) || y >= uint(PC.height)) return;
	int i = int(x) + int(y) * PC.width;

	if (River.river[i] == 0u) return;
	if (Land.is_land[i] == 0u) return;

	float t_norm = clamp(Temp.temp_norm[i], 0.0, 1.0);
	float t_c = mix(PC.temp_min_c, PC.temp_max_c, t_norm);
	bool freeze = (Biome.biome_id[i] == PC.glacier_biome_id) || (t_c <= PC.freeze_c);
	if (freeze) {
		River.river[i] = 0u;
	}
}
