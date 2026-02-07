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
layout(std430, set = 0, binding = 7) readonly buffer RockBuf { int rock_type[]; } Rock;

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
const int BIOME_TROPICAL_FOREST = 11;
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

const int ROCK_BASALTIC = 0;
const int ROCK_GRANITIC = 1;
const int ROCK_SEDIMENTARY_CLASTIC = 2;
const int ROCK_LIMESTONE = 3;
const int ROCK_METAMORPHIC = 4;
const int ROCK_VOLCANIC_ASH = 5;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

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
    // Full lava-update passes (world generation / explicit biome refresh) must
    // start from a clean slate; otherwise stale lava from prior worlds can persist.
    if (PC.update_lava > 0.5) {
        lava = 0.0;
    }
    int rock = Rock.rock_type[i];
    if (land) {
        // Hot override: at high temps, remove forests/grass and move to dry biomes
        if (t_c >= 45.0 && t_c < PC.lava_temp_threshold_c) {
            float hot_band = clamp((t_c - 45.0) / max(0.001, (PC.lava_temp_threshold_c - 45.0)), 0.0, 1.0);
            float split_n = hash12(vec2(float(x), float(y)));
            bool rock_sandy = (rock == ROCK_SEDIMENTARY_CLASTIC || rock == ROCK_LIMESTONE || rock == ROCK_VOLCANIC_ASH);
            bool rock_rocky = (rock == ROCK_GRANITIC || rock == ROCK_METAMORPHIC || rock == ROCK_BASALTIC);
            if (m < 0.40) {
                float sand_bias = -0.08 - 0.18 * hot_band;
                if (rock_sandy) {
                    sand_bias += 0.24;
                }
                if (rock == ROCK_VOLCANIC_ASH) {
                    sand_bias += 0.10;
                }
                float sand_thresh = clamp(0.52 + sand_bias, 0.12, 0.92);
                if (split_n < sand_thresh) {
                    out_b = BIOME_DESERT_SAND;
                } else {
                    out_b = BIOME_WASTELAND;
                }
            } else {
                // Reduce the old blanket "hot -> steppe" behavior.
                if (m < 0.46) {
                    if (b == BIOME_RAINFOREST || b == BIOME_TROPICAL_FOREST || b == BIOME_TEMPERATE_FOREST || b == BIOME_CONIFER_FOREST || b == BIOME_BOREAL_FOREST || b == BIOME_SWAMP) {
                        if (rock_rocky) {
                            out_b = BIOME_HILLS;
                        } else {
                            out_b = BIOME_SAVANNA;
                        }
                    } else if (b == BIOME_GRASSLAND) {
                        if (rock_rocky) {
                            out_b = BIOME_STEPPE;
                        } else {
                            out_b = BIOME_SAVANNA;
                        }
                    } else if (b == BIOME_MOUNTAINS || b == BIOME_ALPINE) {
                        if (m < 0.35) {
                            out_b = BIOME_WASTELAND;
                        }
                    }
                } else {
                    if (b == BIOME_RAINFOREST || b == BIOME_TROPICAL_FOREST || b == BIOME_SWAMP) {
                        out_b = BIOME_SAVANNA;
                    }
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
        } else if (t_c >= 45.0 && lava <= 0.5) {
            // Scorched variants for hot, non-lava areas
            if (out_b == BIOME_GRASSLAND) out_b = BIOME_SCORCHED_GRASSLAND; else
            if (out_b == BIOME_STEPPE) out_b = BIOME_SCORCHED_STEPPE; else
            if (out_b == BIOME_SAVANNA) out_b = BIOME_SCORCHED_SAVANNA; else
            if (out_b == BIOME_HILLS) out_b = BIOME_SCORCHED_HILLS; else
            if (out_b == BIOME_FOOTHILLS || out_b == BIOME_MOUNTAINS || out_b == BIOME_ALPINE) out_b = BIOME_SCORCHED_HILLS;
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
