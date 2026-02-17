#[compute]
#version 450
// File: res://shaders/river_freeze_gate.glsl
// Removes river cells on freezing land or frozen-family biome cells.
// This approximates "rivers become frozen channels/glacier-fed ice flow"
// until local temperatures thaw sufficiently.

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
	float thaw_c;
} PC;

const int BIOME_DESERT_ICE = 5;
const int BIOME_TUNDRA = 20;
const int BIOME_FROZEN_FOREST = 22;
const int BIOME_FROZEN_MARSH = 23;
const int BIOME_FROZEN_GRASSLAND = 29;
const int BIOME_FROZEN_MEADOW = 31;
const int BIOME_FROZEN_PRAIRIE = 32;
const int BIOME_FROZEN_STEPPE = 30;
const int BIOME_FROZEN_SAVANNA = 33;
const int BIOME_FROZEN_HILLS = 34;
const int BIOME_FROZEN_FOOTHILLS = 35;

bool is_frozen_family(int biome_id) {
	return biome_id == BIOME_DESERT_ICE
		|| biome_id == BIOME_TUNDRA
		|| biome_id == BIOME_FROZEN_FOREST
		|| biome_id == BIOME_FROZEN_MARSH
		|| biome_id == BIOME_FROZEN_GRASSLAND
		|| biome_id == BIOME_FROZEN_MEADOW
		|| biome_id == BIOME_FROZEN_PRAIRIE
		|| biome_id == BIOME_FROZEN_STEPPE
		|| biome_id == BIOME_FROZEN_SAVANNA
		|| biome_id == BIOME_FROZEN_HILLS
		|| biome_id == BIOME_FROZEN_FOOTHILLS
		|| biome_id == PC.glacier_biome_id;
}

void main() {
	uint x = gl_GlobalInvocationID.x;
	uint y = gl_GlobalInvocationID.y;
	if (x >= uint(PC.width) || y >= uint(PC.height)) return;
	int i = int(x) + int(y) * PC.width;

	if (River.river[i] == 0u) return;
	if (Land.is_land[i] == 0u) return;

	float t_norm = clamp(Temp.temp_norm[i], 0.0, 1.0);
	float t_c = mix(PC.temp_min_c, PC.temp_max_c, t_norm);
	int bid = Biome.biome_id[i];
	bool glacier_cell = (bid == PC.glacier_biome_id);
	bool frozen_family = is_frozen_family(bid);
	bool freeze = false;
	if (frozen_family) {
		if (glacier_cell) {
			// Allow only rare warm meltwater in glacier cells.
			float melt_c = max(5.5, PC.thaw_c + 3.0);
			freeze = (t_c <= melt_c);
		} else {
			// Non-glacial frozen biomes keep surface rivers suppressed.
			freeze = true;
		}
	} else {
		freeze = (t_c <= PC.freeze_c);
	}
	if (freeze) {
		River.river[i] = 0u;
	}
}
