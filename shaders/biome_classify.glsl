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
layout(std430, set = 0, binding = 7) readonly buffer FertilityBuf { float fertility[]; } Fertility;
layout(std430, set = 0, binding = 8) readonly buffer BiomeNoiseFieldBuf { float biome_noise_field[]; } BiomeNoise;

layout(push_constant) uniform Params {
    int width;
    int height;
    float temp_min_c;
    float temp_max_c;
    float height_scale_m;
    float lapse_c_per_km;
    float freeze_temp_threshold_norm; // 0..1 in temperature normalized space
    float biome_noise_strength_c;     // degrees C jitter amplitude
    float moist_noise_strength;       // 0..1 jitter for moisture (primary)
    float biome_phase;                // animation phase
    float moist_noise_strength2;      // secondary moisture jitter (different frequency)
    float moist_island_factor;        // how strongly to pull towards neighbor avg to form islands
    float moist_elev_dry_factor;      // reduce moisture by elevation
    float min_h;                      // global min height for normalization
    float max_h;                      // global max height for normalization
    int has_desert_field; // 1 if buffer filled
    int has_biome_noise_field; // 1 if CPU-generated biome-noise buffer is bound
} PC;

// Biome IDs mirroring BiomeClassifier.gd enum
const int BIOME_OCEAN = 0;
const int BIOME_ICE_SHEET = 1;
const int BIOME_BEACH = 2;
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
const int BIOME_TUNDRA = 20;
const int BIOME_SAVANNA = 21;
const int BIOME_GLACIER = 24;
const int BIOME_SALT_DESERT = 28; // aligns with BiomeClassifier.gd

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

// Cheap animated noise using trigonometric mixing; fast and good enough to break bands
float tri_noise(uint x, uint y, float phase) {
    float fx = float(x);
    float fy = float(y);
    float n1 = sin((fx * 0.043 + fy * 0.037) + phase * 2.1);
    float n2 = sin((fx * 0.019 - fy * 0.051) - phase * 1.3);
    return clamp((0.66 * n1 + 0.34 * n2) * 0.5 + 0.5, 0.0, 1.0);
}

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
    float f = clamp01(Fertility.fertility[i]);
    float elev = Height.height_data[i];
    bool is_land = (IsLand.is_land_data[i] != 0u);
    bool is_beach = (Beach.beach_mask[i] != 0u);

    float t_c0 = PC.temp_min_c + t_norm * (PC.temp_max_c - PC.temp_min_c);
    // Apply small animated jitter to reduce horizontal banding (temperature)
    float n1 = tri_noise(x, y, PC.biome_phase);
    if (PC.has_biome_noise_field == 1) {
        n1 = clamp01(BiomeNoise.biome_noise_field[i]);
    }
    t_c0 += (PC.biome_noise_strength_c) * (n1 - 0.5) * 2.0;
    // Moisture variability: multi-frequency jitter + neighbor-driven islanding + topo dryness
    float raw_m = Moist.moist_norm[i];
    // secondary noise (different frequency blend)
    float n2 = sin((float(x) * 0.087 + float(y) * 0.023) - PC.biome_phase * 1.7);
    float n2u = clamp(n2 * 0.5 + 0.5, 0.0, 1.0);
    if (PC.has_biome_noise_field == 1) {
        int x2 = (int(x) + max(1, W / 3)) % W;
        int y2 = (int(y) + max(1, PC.height / 5)) % PC.height;
        int j2 = x2 + y2 * W;
        n2u = clamp01(BiomeNoise.biome_noise_field[j2]);
    }
    float m_j = clamp01(raw_m + PC.moist_noise_strength * (n1 - 0.5) + PC.moist_noise_strength2 * (n2u - 0.5));
    // neighbor average to introduce split/merge islands
    float sum_nb = 0.0; int cnt = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int nx = int(x) + dx; int ny = int(y) + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= PC.height) continue;
            int j = nx + ny * W;
            sum_nb += clamp01(Moist.moist_norm[j]);
            cnt++;
        }
    }
    float m_nb = (cnt > 0) ? (sum_nb / float(cnt)) : raw_m;
    float island_mix = clamp(PC.moist_island_factor * n2u, 0.0, 1.0);
    float m_eff = clamp01(mix(m_j, m_nb, island_mix));
    // reduce moisture at higher elevations to reflect orographic dryness
    m_eff = clamp01(m_eff * (1.0 - PC.moist_elev_dry_factor * clamp01(elev)));
    // Fertile substrate improves vegetation retention; infertile substrate dries out quickly.
    float fert_moist_bonus = (f - 0.5) * 0.26;
    float fert_hot_penalty = clamp((t_c0 - 28.0) / 24.0, 0.0, 1.0) * clamp((0.55 - f) * 1.8, 0.0, 1.0) * 0.14;
    m = clamp01(m_eff + fert_moist_bonus - fert_hot_penalty);
    float wood_penalty = clamp((0.58 - f) * 0.42, 0.0, 0.28);
    float m_forest = clamp01(m - wood_penalty);
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

    // Remove hard freeze-to-ice-desert. Let base classifier run and apply
    // frozen variants later in post-processing based on temperature.

    // Relief-first bands using global min/max to approximate top percentiles
    float elev_norm = clamp01((elev - PC.min_h) / max(0.0001, (PC.max_h - PC.min_h)));
    // Keep alpine/mountains strict to preserve top 1%/5%
    if (elev_norm >= 0.99) { Out.out_biome[i] = BIOME_ALPINE; return; }       // top 1%
    if (elev_norm >= 0.94) { Out.out_biome[i] = BIOME_MOUNTAINS; return; }    // next 5%
    // Apply temperature/noise-driven jitter to break up homogenous hills/foothills
    float hnoise = tri_noise(x * 2u, y * 2u, PC.biome_phase * 0.7 + 1.234);
    if (PC.has_biome_noise_field == 1) {
        int x3 = (int(x) * 5 + int(y) * 3 + 17) % W;
        int y3 = (int(y) * 7 + int(x) * 2 + 11) % PC.height;
        int j3 = x3 + y3 * W;
        hnoise = clamp01(BiomeNoise.biome_noise_field[j3]);
    }
    float t_mid = clamp(1.0 - abs((t_c0 - 15.0) / 25.0), 0.0, 1.0); // strongest near ~15C
    float jitter = 0.03 * t_mid * ((hnoise - 0.5) * 2.0);
    float elev_j = clamp01(elev_norm + jitter);
    if (elev_j >= 0.87) { Out.out_biome[i] = BIOME_FOOTHILLS; return; }       // next ~7% with jittered edges
    if (elev_j >= 0.78) {
        // Forest overrides hills: check forests before returning hills
        if (t_c0 <= 8.0 && m_forest >= 0.50) { Out.out_biome[i] = BIOME_BOREAL_FOREST; return; }
        if (t_c0 <= 18.0) {
            if (m_forest >= 0.60) { Out.out_biome[i] = BIOME_TEMPERATE_FOREST; return; }
            if (m_forest >= 0.45) { Out.out_biome[i] = BIOME_CONIFER_FOREST; return; }
        }
        if (t_c0 <= 30.0) {
            if (m_forest >= 0.55) { Out.out_biome[i] = BIOME_RAINFOREST; return; }
        }
        Out.out_biome[i] = BIOME_HILLS; return;
    }

    // Temperature/moisture bands
    if (t_c0 <= -10.0) {
        Out.out_biome[i] = BIOME_DESERT_ICE;
        return;
    }
    if (t_c0 <= 2.0) {
        Out.out_biome[i] = (m >= 0.30) ? BIOME_TUNDRA : BIOME_WASTELAND;
        return;
    }
    if (t_c0 <= 8.0) {
        Out.out_biome[i] = (m_forest >= 0.50) ? BIOME_BOREAL_FOREST : BIOME_STEPPE;
        return;
    }
    if (t_c0 <= 18.0) {
        if (m_forest >= 0.60) { Out.out_biome[i] = BIOME_TEMPERATE_FOREST; return; }
        if (m_forest >= 0.45) { Out.out_biome[i] = BIOME_CONIFER_FOREST; return; }
        if (m >= 0.25) { Out.out_biome[i] = BIOME_GRASSLAND; return; }
        if (m >= 0.20) { Out.out_biome[i] = BIOME_STEPPE; return; }
        Out.out_biome[i] = BIOME_WASTELAND;
        return;
    }
    if (t_c0 <= 30.0) {
        if (m_forest >= 0.70) { Out.out_biome[i] = BIOME_RAINFOREST; return; }
        if (m_forest >= 0.55) { Out.out_biome[i] = BIOME_TROPICAL_FOREST; return; }
        if (m >= 0.40) { Out.out_biome[i] = BIOME_SAVANNA; return; }
        if (m >= 0.30) { Out.out_biome[i] = BIOME_GRASSLAND; return; }
        Out.out_biome[i] = BIOME_WASTELAND;
        return;
    }

    // t_c0 > 30 C
    float infertile_heat = clamp((0.48 - f) * 0.24, -0.08, 0.16);
    if (m < (0.40 + infertile_heat)) {
        // Desert split: sand vs rock using optional desert_field
        if (PC.has_desert_field == 1) {
            float heat_bias = clamp((t_norm - 0.60) * 2.4, 0.0, 1.0);
            float sand_prob = clamp(0.25 + 0.6 * heat_bias, 0.0, 0.98);
            float n = clamp01(DesertField.desert_field[i]);
            Out.out_biome[i] = (n < sand_prob) ? BIOME_DESERT_SAND : BIOME_WASTELAND;
        } else {
            Out.out_biome[i] = BIOME_WASTELAND;
        }
        return;
    }

    Out.out_biome[i] = BIOME_STEPPE;
}


