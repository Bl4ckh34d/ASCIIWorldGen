#[compute]
#version 450
// File: res://shaders/fertility_lithology_update.glsl
// Update bedrock exposure and fertility in-place.
// Lithology changes only on exposed non-vegetated land.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer RockBuf { int rock_type[]; } Rock;
layout(std430, set = 0, binding = 1) readonly buffer RockCandidateBuf { int rock_candidate[]; } Cand;
layout(std430, set = 0, binding = 2) readonly buffer BiomeBuf { int biome_id[]; } Bio;
layout(std430, set = 0, binding = 3) readonly buffer LandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 4) readonly buffer MoistBuf { float moist_norm[]; } Moist;
layout(std430, set = 0, binding = 5) readonly buffer FlowBuf { float flow_accum[]; } Flow;
layout(std430, set = 0, binding = 6) readonly buffer LavaBuf { float lava_mask[]; } Lava;
layout(std430, set = 0, binding = 7) buffer FertilityBuf { float fertility[]; } Fert;

layout(push_constant) uniform Params {
	int width;
	int height;
	float dt_days;
	float weathering_rate;
	float humus_rate;
	float flow_scale;
} PC;

const int ROCK_BASALTIC = 0;
const int ROCK_GRANITIC = 1;
const int ROCK_SEDIMENTARY_CLASTIC = 2;
const int ROCK_LIMESTONE = 3;
const int ROCK_METAMORPHIC = 4;
const int ROCK_VOLCANIC_ASH = 5;

const int BIOME_STEPPE = 6;
const int BIOME_GRASSLAND = 7;
const int BIOME_SWAMP = 10;
const int BIOME_TROPICAL_FOREST = 11;
const int BIOME_BOREAL_FOREST = 12;
const int BIOME_CONIFER_FOREST = 13;
const int BIOME_TEMPERATE_FOREST = 14;
const int BIOME_RAINFOREST = 15;
const int BIOME_TUNDRA = 20;
const int BIOME_SAVANNA = 21;
const int BIOME_FROZEN_FOREST = 22;
const int BIOME_FROZEN_MARSH = 23;
const int BIOME_FROZEN_GRASSLAND = 29;
const int BIOME_FROZEN_STEPPE = 30;
const int BIOME_FROZEN_SAVANNA = 33;
const int BIOME_SCORCHED_GRASSLAND = 36;
const int BIOME_SCORCHED_STEPPE = 37;
const int BIOME_SCORCHED_SAVANNA = 40;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

bool is_vegetated_biome(int b) {
	return (
		b == BIOME_STEPPE || b == BIOME_GRASSLAND || b == BIOME_SWAMP ||
		b == BIOME_TROPICAL_FOREST || b == BIOME_BOREAL_FOREST ||
		b == BIOME_CONIFER_FOREST || b == BIOME_TEMPERATE_FOREST || b == BIOME_RAINFOREST ||
		b == BIOME_TUNDRA || b == BIOME_SAVANNA ||
		b == BIOME_FROZEN_FOREST || b == BIOME_FROZEN_MARSH ||
		b == BIOME_FROZEN_GRASSLAND || b == BIOME_FROZEN_STEPPE || b == BIOME_FROZEN_SAVANNA ||
		b == BIOME_SCORCHED_GRASSLAND || b == BIOME_SCORCHED_STEPPE || b == BIOME_SCORCHED_SAVANNA
	);
}

float base_fertility_for_rock(int rock) {
	if (rock == ROCK_BASALTIC) return 0.86;
	if (rock == ROCK_VOLCANIC_ASH) return 0.78;
	if (rock == ROCK_LIMESTONE) return 0.68;
	if (rock == ROCK_SEDIMENTARY_CLASTIC) return 0.54;
	if (rock == ROCK_METAMORPHIC) return 0.46;
	if (rock == ROCK_GRANITIC) return 0.34;
	return 0.50;
}

void main() {
	uint gx = gl_GlobalInvocationID.x;
	uint gy = gl_GlobalInvocationID.y;
	if (gx >= uint(PC.width) || gy >= uint(PC.height)) return;

	int x = int(gx);
	int y = int(gy);
	int i = x + y * PC.width;

	float dt = max(0.0, PC.dt_days);
	float moist = clamp01(Moist.moist_norm[i]);
	float flow = max(0.0, Flow.flow_accum[i]);
	float flow_drive = flow / (flow + max(1.0, PC.flow_scale));
	float prev_fert = clamp01(Fert.fertility[i]);

	if (Land.is_land[i] == 0u) {
		float cool_target = 0.04;
		float cool_alpha = clamp(dt * 0.03, 0.0, 1.0);
		Fert.fertility[i] = mix(prev_fert, cool_target, cool_alpha);
		return;
	}

	int rock_prev = Rock.rock_type[i];
	int rock_now = rock_prev;
	int cand = Cand.rock_candidate[i];
	float lava = Lava.lava_mask[i];
	bool vegetated = is_vegetated_biome(Bio.biome_id[i]);

	if (lava > 0.5) {
		rock_now = cand;
		Rock.rock_type[i] = rock_now;
		float lava_target = base_fertility_for_rock(rock_now) * 0.30;
		float lava_alpha = clamp(dt * 0.45, 0.0, 1.0);
		Fert.fertility[i] = mix(prev_fert, lava_target, lava_alpha);
		return;
	}

	if (!vegetated && cand != rock_prev) {
		float weather = clamp01(moist * 0.65 + flow_drive * 0.35);
		float adopt_prob = clamp(dt * PC.weathering_rate * (0.30 + 0.70 * weather), 0.0, 1.0);
		float rnd = hash12(vec2(float(x) + float(rock_prev) * 0.61, float(y) + float(cand) * 0.37));
		if (rnd < adopt_prob) {
			rock_now = cand;
		}
	}
	Rock.rock_type[i] = rock_now;

	float base_fert = base_fertility_for_rock(rock_now);
	float fert_out = prev_fert;
	if (vegetated) {
		float humus_bonus = 0.08 + 0.22 * moist + 0.08 * flow_drive;
		float target = clamp01(base_fert + humus_bonus);
		float alpha = clamp(dt * PC.humus_rate * (0.45 + 0.55 * moist), 0.0, 1.0);
		fert_out = mix(prev_fert, target, alpha);
	} else {
		float weather_signal = clamp01(0.5 * moist + 0.5 * flow_drive);
		float target = clamp01(base_fert * (0.55 + 0.45 * weather_signal) + 0.06 * flow_drive);
		float alpha = clamp(dt * PC.weathering_rate * (0.35 + 0.65 * weather_signal), 0.0, 1.0);
		fert_out = mix(prev_fert, target, alpha);
	}
	Fert.fertility[i] = clamp01(fert_out);
}

