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
const int BIOME_GLACIER = 24;

float clamp01(float v){ return clamp(v, 0.0, 1.0); }

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

    float t_c0 = PC.temp_min_c + t_norm * (PC.temp_max_c - PC.temp_min_c);
    float elev_m = elev * PC.height_scale_m;
    float t_c_adj = t_c0 - PC.lapse_c_per_km * (elev_m / 1000.0);

    if (!is_land){
        // Ocean: re-apply ice sheets in very cold seas
        float threshold_c = PC.ocean_ice_base_thresh_c + wig * PC.ocean_ice_wiggle_amp_c;
        if (t_c0 <= threshold_c) {
            OutB.out_biome[i] = BIOME_ICE_SHEET;
            return;
        }
        // keep as is (could be ICE_SHEET or OCEAN already)
        OutB.out_biome[i] = (b == BIOME_ICE_SHEET) ? BIOME_ICE_SHEET : BIOME_OCEAN;
        return;
    }

    // Land: re-apply glacier mask when high altitude and cold, or very cold overall
    bool glacier = false;
    if (elev_m >= 1800.0 && t_c_adj <= -2.0 && m >= 0.25) {
        glacier = true;
    } else if (t_c0 <= -18.0 && m >= 0.20) {
        glacier = true;
    }
    OutB.out_biome[i] = glacier ? BIOME_GLACIER : b;
}


