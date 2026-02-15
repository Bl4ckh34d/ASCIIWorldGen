#[compute]
#version 450
// File: res://shaders/society/wildlife_tick.glsl
//
// v0 wildlife tick:
// - updates a per-world-tile wildlife density field in [0..1]
// - density grows based on biome fertility and decays under human population pressure

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer BiomeBuf { int biome[]; } BBiome;
layout(std430, set = 0, binding = 1) buffer WildBuf { float wild[]; } BWild;
layout(std430, set = 0, binding = 2) buffer PopBuf  { float pop[]; } BPop;

layout(push_constant) uniform Params {
	int width;
	int height;
	int abs_day;
	int _pad0;
	float dt_days;
	float _pad1;
	float _pad2;
	float _pad3;
} PC;

float fertility_for_biome(int b) {
	// Very coarse; will be replaced by climate/biome-driven models.
	// Assumes 0/1 are ocean/ice. Everything else is "land" with varying fertility.
	if (b == 0 || b == 1) return 0.05;
	// Deserts (common ids in this project)
	if (b == 3 || b == 4 || b == 5 || b == 28) return 0.18;
	// Mountains
	if (b == 18 || b == 19 || b == 24 || b == 34 || b == 41) return 0.30;
	// Swamps
	if (b == 17) return 0.70;
	// Forest-ish
	if (b == 11 || b == 12 || b == 13 || b == 14 || b == 15 || b == 22 || b == 27) return 0.75;
	// Grasslands/steppe
	return 0.60;
}

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint total = uint(max(0, PC.width * PC.height));
	if (gid >= total) return;

	int b = BBiome.biome[int(gid)];
	float f = fertility_for_biome(b);

	float w = clamp(BWild.wild[int(gid)], 0.0, 1.0);
	float p = max(0.0, BPop.pop[int(gid)]);

	// Growth towards fertility baseline.
	float grow = (f - w) * 0.25;
	// Hunting/pressure: sublinear with pop to avoid instant collapse in v0.
	float pressure = clamp(sqrt(p) * 0.015, 0.0, 0.25);

	w = clamp(w + (grow - pressure) * PC.dt_days, 0.0, 1.0);
	BWild.wild[int(gid)] = w;
}

