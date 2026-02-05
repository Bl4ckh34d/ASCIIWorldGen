#[compute]
#version 450
// File: res://shaders/biome_overrides_lava.glsl

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Inputs (set = 0)
layout(std430, set = 0, binding = 0) buffer BiomeBuf { int biomes[]; } Bio;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) buffer TempBuf { float temp_norm[]; } Temp;
layout(std430, set = 0, binding = 3) buffer MoistBuf { float moist_norm[]; } Moist;

// Outputs
layout(std430, set = 0, binding = 4) buffer OutBiomeBuf { int out_biomes[]; } OutB;
layout(std430, set = 0, binding = 5) buffer LavaBuf { float lava_mask[]; } Lava;
layout(std430, set = 0, binding = 6) buffer LakeBuf { uint lake_mask[]; } Lake; // optional for salt flats

layout(push_constant) uniform Params {
    int width;
    int height;
    float temp_min_c;
    float temp_max_c;
    float lava_temp_threshold_c;
    float update_lava;
} PC;

// Biome IDs (subset used here) -- must match BiomeClassifier.gd
const int BIOME_DESERT_SAND = 3;
const int BIOME_WASTELAND = 4;
const int BIOME_DESERT_ICE = 5;
const int BIOME_STEPPE = 6;
const int BIOME_GRASSLAND = 7;
const int BIOME_SWAMP = 10;
const int BIOME_BOREAL_FOREST = 12;
const int BIOME_CONIFER_FOREST = 13;
const int BIOME_TEMPERATE_FOREST = 14;
const int BIOME_RAINFOREST = 15;
const int BIOME_HILLS = 16;
const int BIOME_FOOTHILLS = 17;
const int BIOME_MOUNTAINS = 18;
const int BIOME_ALPINE = 19;
const int BIOME_SAVANNA = 21;
const int BIOME_FROZEN_FOREST = 22;
const int BIOME_FROZEN_MARSH = 23;
const int BIOME_GLACIER = 24;
const int BIOME_LAVA_FIELD = 25;
const int BIOME_SALT_DESERT = 28;
const int BIOME_FROZEN_GRASSLAND = 29;
const int BIOME_FROZEN_STEPPE = 30;
const int BIOME_FROZEN_MEADOW = 31;
const int BIOME_FROZEN_PRAIRIE = 32;
const int BIOME_FROZEN_SAVANNA = 33;
const int BIOME_FROZEN_HILLS = 34;
const int BIOME_FROZEN_FOOTHILLS = 35;
const int BIOME_SCORCHED_GRASSLAND = 36;
const int BIOME_SCORCHED_STEPPE = 37;
const int BIOME_SCORCHED_MEADOW = 38;
const int BIOME_SCORCHED_PRAIRIE = 39;
const int BIOME_SCORCHED_SAVANNA = 40;
const int BIOME_SCORCHED_HILLS = 41;
const int BIOME_SCORCHED_FOOTHILLS = 42;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int W = PC.width;
    int i = int(x) + int(y) * W;

    int b = Bio.biomes[i];
    bool land = (Land.is_land[i] != 0u);
    float t_norm = clamp01(Temp.temp_norm[i]);
    float m = clamp01(Moist.moist_norm[i]);
    float t_c = PC.temp_min_c + t_norm * (PC.temp_max_c - PC.temp_min_c);

    int out_b = b;
    float lava = Lava.lava_mask[i];
    if (land) {
        // Hot override: at high temps, remove forests/grass and move to dry biomes
        if (t_c >= 45.0 && t_c < PC.lava_temp_threshold_c) {
            if (m < 0.40) {
                // Split desert by heat; here pick rock by default (sand split handled in classifier via noise)
                out_b = BIOME_WASTELAND;
            } else {
                if (b == BIOME_MOUNTAINS || b == BIOME_ALPINE) {
                    if (m < 0.35) {
                        out_b = BIOME_WASTELAND;
                    }
                } else {
                    out_b = BIOME_STEPPE;
                }
            }
        }
        // Extreme hot: above lava threshold, but only on land
        if (PC.update_lava > 0.5 && t_c >= PC.lava_temp_threshold_c) {
            lava = 1.0;
        }
        // Cold handling: assign frozen variants (prefer variants over DESERT_ICE except very dry cases)
        if (t_c <= -5.0) {
            if (out_b != BIOME_GLACIER) {
                if (out_b == BIOME_SWAMP) out_b = BIOME_FROZEN_MARSH; else
                if (out_b == BIOME_BOREAL_FOREST || out_b == BIOME_CONIFER_FOREST || out_b == BIOME_TEMPERATE_FOREST || out_b == BIOME_RAINFOREST) out_b = BIOME_FROZEN_FOREST; else
                if (out_b == BIOME_GRASSLAND) out_b = BIOME_FROZEN_GRASSLAND; else
                if (out_b == BIOME_STEPPE) out_b = BIOME_FROZEN_STEPPE; else
                if (out_b == BIOME_SAVANNA) out_b = BIOME_FROZEN_SAVANNA; else
                if (out_b == BIOME_HILLS) out_b = BIOME_FROZEN_HILLS; else
                if (out_b == BIOME_FOOTHILLS) out_b = BIOME_FROZEN_FOOTHILLS; else {
                    // If extremely dry, keep to deserts
                    if (m >= 0.25) { out_b = BIOME_DESERT_ICE; } else { out_b = BIOME_WASTELAND; }
                }
            }
        } else if (t_c >= 45.0 && lava == 0u) {
            // Scorched variants for hot, non-lava areas
            if (out_b == BIOME_GRASSLAND) out_b = BIOME_SCORCHED_GRASSLAND; else
            if (out_b == BIOME_STEPPE) out_b = BIOME_SCORCHED_STEPPE; else
            if (out_b == BIOME_SAVANNA) out_b = BIOME_SCORCHED_SAVANNA; else
            if (out_b == BIOME_HILLS) out_b = BIOME_SCORCHED_HILLS; else
            if (out_b == BIOME_FOOTHILLS) out_b = BIOME_SCORCHED_FOOTHILLS;
        }
    }
    // Salt desert: where lakes used to be but dried under heat on land
    if (land) {
        uint was_lake = Lake.lake_mask[i];
        if (was_lake != 0u) {
            // Dry lake -> salt flats when sufficiently hot and not lava
            if (t_c >= 53.0 && t_c < PC.lava_temp_threshold_c) {
                out_b = BIOME_SALT_DESERT;
            }
        }
    }

    OutB.out_biomes[i] = out_b;
    Lava.lava_mask[i] = lava;
}

