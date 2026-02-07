#[compute]
#version 450
// File: res://shaders/biome_reapply.glsl
// Re-apply ocean ice sheet and land glacier masks after biome smoothing

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer InBiome { int in_biome[]; } InB;
layout(std430, set = 0, binding = 1) buffer OutBiome { int out_biome[]; } OutB;
layout(std430, set = 0, binding = 2) buffer IsLand { uint is_land[]; } Land;
layout(std430, set = 0, binding = 3) buffer HeightBuf { float height_data[]; } Height;
layout(std430, set = 0, binding = 4) buffer TempBuf { float temp_norm[]; } Temp;
layout(std430, set = 0, binding = 5) buffer MoistBuf { float moist_norm[]; } Moist;
layout(std430, set = 0, binding = 6) buffer IceWiggleBuf { float ice_wiggle[]; } Ice;

layout(push_constant) uniform Params {
    int width;
    int height;
    float temp_min_c;
    float temp_max_c;
    float height_scale_m;
    float lapse_c_per_km;
    float ocean_ice_base_thresh_c; // e.g. -10.0
    float ocean_ice_wiggle_amp_c;  // e.g. 1.0
} PC;

// Biome IDs (keep in sync with BiomeClassifier.gd)
const int BIOME_OCEAN = 0;
const int BIOME_ICE_SHEET = 1;
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
const int BIOME_TUNDRA = 20;
const int BIOME_GLACIER = 24;
const int BIOME_FROZEN_GRASSLAND = 29;
const int BIOME_FROZEN_STEPPE = 30;
const int BIOME_FROZEN_SAVANNA = 33;
const int BIOME_FROZEN_HILLS = 34;
const int BIOME_FROZEN_FOOTHILLS = 35;
const int BIOME_SCORCHED_GRASSLAND = 36;
const int BIOME_SCORCHED_STEPPE = 37;
const int BIOME_SCORCHED_SAVANNA = 40;
const int BIOME_SCORCHED_HILLS = 41;
const int BIOME_SCORCHED_FOOTHILLS = 42;
const float GLACIER_ELEV_FORM_C = -4.5;
const float GLACIER_ELEV_HOLD_C = 1.8;
const float GLACIER_DEEP_FORM_C = -20.0;
const float GLACIER_DEEP_HOLD_C = -11.0;
const float GLACIER_ELEV_FORM_MOIST = 0.27;
const float GLACIER_ELEV_HOLD_MOIST = 0.20;
const float GLACIER_DEEP_FORM_MOIST = 0.20;
const float GLACIER_DEEP_HOLD_MOIST = 0.18;

float clamp01(float v){ return clamp(v, 0.0, 1.0); }

float hash12(vec2 p){
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p){
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i + vec2(0.0, 0.0));
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm3(vec2 p){
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 3; i++){
        v += value_noise(p) * a;
        p *= 2.02;
        a *= 0.5;
    }
    return v;
}

bool is_frozen_family(int b) {
    return b == BIOME_FROZEN_FOREST
        || b == BIOME_FROZEN_MARSH
        || b == BIOME_FROZEN_GRASSLAND
        || b == BIOME_FROZEN_STEPPE
        || b == BIOME_FROZEN_SAVANNA
        || b == BIOME_FROZEN_HILLS
        || b == BIOME_FROZEN_FOOTHILLS;
}

int thaw_to_base(int b) {
    if (b == BIOME_FROZEN_FOREST) return BIOME_BOREAL_FOREST;
    if (b == BIOME_FROZEN_MARSH) return BIOME_SWAMP;
    if (b == BIOME_FROZEN_GRASSLAND) return BIOME_GRASSLAND;
    if (b == BIOME_FROZEN_STEPPE) return BIOME_STEPPE;
    if (b == BIOME_FROZEN_SAVANNA) return BIOME_SAVANNA;
    if (b == BIOME_FROZEN_HILLS) return BIOME_HILLS;
    if (b == BIOME_FROZEN_FOOTHILLS) return BIOME_FOOTHILLS;
    return b;
}

int normalize_hot_variants(int b) {
    if (b == BIOME_SCORCHED_GRASSLAND) return BIOME_GRASSLAND;
    if (b == BIOME_SCORCHED_STEPPE) return BIOME_STEPPE;
    if (b == BIOME_SCORCHED_SAVANNA) return BIOME_SAVANNA;
    if (b == BIOME_SCORCHED_HILLS) return BIOME_HILLS;
    if (b == BIOME_SCORCHED_FOOTHILLS) return BIOME_FOOTHILLS;
    return b;
}

int freeze_target(int b) {
    if (b == BIOME_SWAMP) return BIOME_FROZEN_MARSH;
    if (b == BIOME_BOREAL_FOREST || b == BIOME_CONIFER_FOREST || b == BIOME_TEMPERATE_FOREST
        || b == BIOME_RAINFOREST || b == BIOME_TROPICAL_FOREST) return BIOME_FROZEN_FOREST;
    if (b == BIOME_GRASSLAND) return BIOME_FROZEN_GRASSLAND;
    if (b == BIOME_STEPPE) return BIOME_FROZEN_STEPPE;
    if (b == BIOME_SAVANNA) return BIOME_FROZEN_SAVANNA;
    if (b == BIOME_HILLS) return BIOME_FROZEN_HILLS;
    if (b == BIOME_FOOTHILLS) return BIOME_FROZEN_FOOTHILLS;
    return b;
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width;
    int i = int(x) + int(y) * W;

    int b = InB.in_biome[i];
    bool is_land = Land.is_land[i] != 0u;
    float t_norm = clamp01(Temp.temp_norm[i]);
    float m = clamp01(Moist.moist_norm[i]);
    float elev = Height.height_data[i];
    float wig = Ice.ice_wiggle[i]; // expected ~[-1,1]
    float lat01 = float(y) / max(1.0, float(PC.height - 1));
    float lat_abs = abs(lat01 * 2.0 - 1.0);
    float t_c0 = PC.temp_min_c + t_norm * (PC.temp_max_c - PC.temp_min_c);
    float elev_m = elev * PC.height_scale_m;
    float t_c_adj = t_c0 - PC.lapse_c_per_km * (elev_m / 1000.0);
    vec2 wp = vec2(float(x), float(y));
    float continental_hint = is_land ? clamp01(1.0 - m) : 0.0;
    float region0 = fbm3(wp * vec2(0.018, 0.032) + vec2(37.1, 11.7));
    float region1 = fbm3((wp + vec2(91.0, 53.0)) * vec2(0.052, 0.021));
    float local_variation = (region0 - 0.5) * 0.22 + (region1 - 0.5) * 0.10;
    float topo_bias = clamp((elev_m - 1400.0) / 4200.0, -0.35, 0.45) * 0.09;
    float humidity_bias = (0.5 - m) * 0.08;
    float lat_abs_warped = clamp(lat_abs + local_variation + topo_bias + humidity_bias, 0.0, 1.0);
    float equator = 1.0 - smoothstep(0.10, 0.30, lat_abs_warped);
    float temperate = smoothstep(0.20, 0.47, lat_abs_warped) * (1.0 - smoothstep(0.68, 0.92, lat_abs_warped));
    float polar = smoothstep(0.72, 0.96, lat_abs_warped);
    float temperate_cont = temperate * (0.60 + 0.40 * continental_hint);
    float wig_local = wig;
    if (abs(wig_local) < 0.0001) {
        wig_local = (value_noise(wp * 0.037 + vec2(11.3, 7.9)) - 0.5) * 2.0;
    }

    if (!is_land){
        // Ocean: strong seasonal edge motion in temperate belts, persistent ice near poles.
        float freeze_threshold_c = PC.ocean_ice_base_thresh_c + wig_local * PC.ocean_ice_wiggle_amp_c;
        freeze_threshold_c += temperate * 0.8;
        freeze_threshold_c += polar * 1.2;
        freeze_threshold_c -= equator * 3.0;
        float ocean_hysteresis_c = mix(2.0, 3.6, polar);
        ocean_hysteresis_c = mix(ocean_hysteresis_c, 2.0, temperate);
        float thaw_threshold_c = freeze_threshold_c + ocean_hysteresis_c;
        if (b == BIOME_ICE_SHEET) {
            if (t_c0 <= thaw_threshold_c) {
                OutB.out_biome[i] = BIOME_ICE_SHEET;
                return;
            }
            OutB.out_biome[i] = BIOME_OCEAN;
            return;
        }
        if (t_c0 <= freeze_threshold_c) {
            OutB.out_biome[i] = BIOME_ICE_SHEET;
            return;
        }
        OutB.out_biome[i] = BIOME_OCEAN;
        return;
    }

    // Land: strongest seasonal glacier movement in temperate-continental regions.
    float elev_form_c = GLACIER_ELEV_FORM_C + temperate_cont * 0.9 + polar * 1.3 - equator * 2.2;
    float elev_hold_c = GLACIER_ELEV_HOLD_C - temperate_cont * 1.0 + polar * 0.7 - equator * 2.8;
    float deep_form_c = GLACIER_DEEP_FORM_C + temperate * 1.0 + polar * 1.2 - equator * 2.0;
    float deep_hold_c = GLACIER_DEEP_HOLD_C - temperate * 0.9 + polar * 0.6 - equator * 1.6;
    float elev_form_m = GLACIER_ELEV_FORM_MOIST + equator * 0.06;
    float elev_hold_m = GLACIER_ELEV_HOLD_MOIST + equator * 0.08 + temperate_cont * 0.02;
    float deep_form_m = GLACIER_DEEP_FORM_MOIST + equator * 0.05;
    float deep_hold_m = GLACIER_DEEP_HOLD_MOIST + equator * 0.06 + temperate_cont * 0.02;

    bool glacier_form = false;
    if (elev_m >= 1800.0 && t_c_adj <= elev_form_c && m >= elev_form_m) {
        glacier_form = true;
    } else if (t_c0 <= deep_form_c && m >= deep_form_m) {
        glacier_form = true;
    }
    bool glacier_hold = false;
    if (b == BIOME_GLACIER) {
        if (elev_m >= 1800.0 && t_c_adj <= elev_hold_c && m >= elev_hold_m) {
            glacier_hold = true;
        } else if (t_c0 <= deep_hold_c && m >= deep_hold_m) {
            glacier_hold = true;
        }
    }
    bool glacier = glacier_form || glacier_hold;
    if (glacier) {
        OutB.out_biome[i] = BIOME_GLACIER;
        return;
    }

    // Thaw stale glacier cells when cryosphere is evaluated without full biome reclassification.
    if (b == BIOME_GLACIER) {
        if (elev_m >= 2200.0) {
            OutB.out_biome[i] = BIOME_ALPINE;
        } else if (elev_m >= 1200.0) {
            OutB.out_biome[i] = BIOME_MOUNTAINS;
        } else if (t_c_adj <= 2.0 && m >= 0.30) {
            OutB.out_biome[i] = BIOME_TUNDRA;
        } else if (m >= 0.30) {
            OutB.out_biome[i] = BIOME_GRASSLAND;
        } else {
            OutB.out_biome[i] = BIOME_STEPPE;
        }
        return;
    }

    // Frozen-family coupling: cryosphere drives freeze/thaw variants with hysteresis.
    // This runs both in full-biome and cryosphere-only passes, keeping frozen ecology
    // coherent with cryosphere climate smoothing.
    int base_b = normalize_hot_variants(thaw_to_base(b));
    float frozen_form_c = -5.0 + temperate * 0.6 + polar * 1.0 - equator * 1.4;
    float frozen_hold_c = frozen_form_c + 2.0;
    int frozen_b = freeze_target(base_b);
    bool can_freeze_family = (frozen_b != base_b);
    if (can_freeze_family) {
        if (is_frozen_family(b)) {
            if (t_c_adj <= frozen_hold_c) {
                OutB.out_biome[i] = freeze_target(base_b);
            } else {
                OutB.out_biome[i] = base_b;
            }
            return;
        }
        if (t_c_adj <= frozen_form_c) {
            OutB.out_biome[i] = frozen_b;
            return;
        }
    }

    OutB.out_biome[i] = b;
}
