#[compute]
#version 450
// File: res://shaders/biome_classify.glsl

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Input buffers (set = 0)
layout(std430, set = 0, binding = 0) buffer HeightBuf { float height_data[]; } Height;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land_data[]; } IsLand;
layout(std430, set = 0, binding = 2) buffer TempBuf { float temp_norm[]; } Temp;
layout(std430, set = 0, binding = 3) buffer MoistBuf { float moist_norm[]; } Moist;
layout(std430, set = 0, binding = 4) buffer BeachBuf { uint beach_mask[]; } Beach;
layout(std430, set = 0, binding = 5) buffer DesertFieldBuf { float desert_field[]; } DesertField; // optional (0..1)
layout(std430, set = 0, binding = 6) buffer OutBiomeBuf { int out_biome[]; } Out;

layout(push_constant) uniform Params {
    int width;
    int height;
    float temp_min_c;
    float temp_max_c;
    float height_scale_m;
    float lapse_c_per_km;
    float freeze_temp_threshold_norm; // 0..1 in temperature normalized space
    int has_desert_field; // 1 if buffer filled
} PC;

// Biome IDs mirroring BiomeClassifier.gd enum
const int BIOME_OCEAN = 0;
const int BIOME_ICE_SHEET = 1;
const int BIOME_BEACH = 2;
const int BIOME_DESERT_SAND = 3;
const int BIOME_DESERT_ROCK = 4;
const int BIOME_DESERT_ICE = 5;
const int BIOME_STEPPE = 6;
const int BIOME_GRASSLAND = 7;
const int BIOME_MEADOW = 8;
const int BIOME_PRAIRIE = 9;
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
const int BIOME_TUNDRA = 20;
const int BIOME_SAVANNA = 21;
const int BIOME_GLACIER = 24;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int W = PC.width;
    int i = int(x) + int(y) * W;

    float t_norm = clamp01(Temp.temp_norm[i]);
    float m = clamp01(Moist.moist_norm[i]);
    float elev = Height.height_data[i];
    bool is_land = (IsLand.is_land_data[i] != 0u);
    bool is_beach = (Beach.beach_mask[i] != 0u);

    float t_c0 = PC.temp_min_c + t_norm * (PC.temp_max_c - PC.temp_min_c);
    float elev_m = elev * PC.height_scale_m;
    float t_c_adj = t_c0 - PC.lapse_c_per_km * (elev_m / 1000.0);

    if (!is_land) {
        if (t_c0 <= -10.0) {
            Out.out_biome[i] = BIOME_ICE_SHEET;
        } else {
            Out.out_biome[i] = BIOME_OCEAN;
        }
        return;
    }

    if (is_beach) {
        Out.out_biome[i] = BIOME_BEACH;
        return;
    }

    // Glacier rule prior to generic classification
    if ((elev_m >= 1800.0 && t_c_adj <= -2.0 && m >= 0.25) || (t_c0 <= -18.0 && m >= 0.20)) {
        Out.out_biome[i] = BIOME_GLACIER;
        return;
    }

    // Global freeze based on normalized effective temperature
    float t_eff_norm = clamp01((t_c_adj - PC.temp_min_c) / max(0.001, (PC.temp_max_c - PC.temp_min_c)));
    if (t_eff_norm <= PC.freeze_temp_threshold_norm) {
        Out.out_biome[i] = BIOME_DESERT_ICE;
        return;
    }

    // Relief first bands
    float elev_norm = clamp01(elev);
    if (elev_norm > 0.80) { Out.out_biome[i] = BIOME_ALPINE; return; }
    if (elev_norm > 0.60) { Out.out_biome[i] = BIOME_MOUNTAINS; return; }
    if (elev_norm > 0.40) { Out.out_biome[i] = BIOME_FOOTHILLS; return; }
    if (elev_norm > 0.30) { Out.out_biome[i] = BIOME_HILLS; return; }

    // Temperature/moisture bands
    if (t_c0 <= -10.0) {
        Out.out_biome[i] = BIOME_DESERT_ICE;
        return;
    }
    if (t_c0 <= 2.0) {
        Out.out_biome[i] = (m >= 0.30) ? BIOME_TUNDRA : BIOME_DESERT_ROCK;
        return;
    }
    if (t_c0 <= 8.0) {
        Out.out_biome[i] = (m >= 0.50) ? BIOME_BOREAL_FOREST : BIOME_STEPPE;
        return;
    }
    if (t_c0 <= 18.0) {
        if (m >= 0.60) { Out.out_biome[i] = BIOME_TEMPERATE_FOREST; return; }
        if (m >= 0.45) { Out.out_biome[i] = BIOME_CONIFER_FOREST; return; }
        if (m >= 0.35) { Out.out_biome[i] = BIOME_MEADOW; return; }
        if (m >= 0.25) { Out.out_biome[i] = BIOME_PRAIRIE; return; }
        if (m >= 0.20) { Out.out_biome[i] = BIOME_STEPPE; return; }
        Out.out_biome[i] = BIOME_DESERT_ROCK;
        return;
    }
    if (t_c0 <= 30.0) {
        if (m >= 0.70) { Out.out_biome[i] = BIOME_RAINFOREST; return; }
        if (m >= 0.55) { Out.out_biome[i] = BIOME_TROPICAL_FOREST; return; }
        if (m >= 0.40) { Out.out_biome[i] = BIOME_SAVANNA; return; }
        if (m >= 0.30) { Out.out_biome[i] = BIOME_GRASSLAND; return; }
        Out.out_biome[i] = BIOME_DESERT_ROCK;
        return;
    }

    // t_c0 > 30 °C
    if (m < 0.40) {
        // Desert split: sand vs rock using optional desert_field
        if (PC.has_desert_field == 1) {
            float heat_bias = clamp((t_norm - 0.60) * 2.4, 0.0, 1.0);
            float sand_prob = clamp(0.25 + 0.6 * heat_bias, 0.0, 0.98);
            float n = clamp01(DesertField.desert_field[i]);
            Out.out_biome[i] = (n < sand_prob) ? BIOME_DESERT_SAND : BIOME_DESERT_ROCK;
        } else {
            Out.out_biome[i] = BIOME_DESERT_ROCK;
        }
        return;
    }

    Out.out_biome[i] = BIOME_STEPPE;
}


