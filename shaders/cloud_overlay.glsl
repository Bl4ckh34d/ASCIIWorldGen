#[compute]
#version 450
// File: res://shaders/cloud_overlay.glsl
// Simple cloud intensity overlay from temperature and moisture

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer TempBuf { float temp_norm[]; } Temp;
layout(std430, set = 0, binding = 1) buffer MoistBuf { float moist_norm[]; } Moist;
layout(std430, set = 0, binding = 2) buffer IsLandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 3) buffer OutCloud { float cloud[]; } Cloud;

layout(push_constant) uniform Params {
    int width;
    int height;
    float phase; // animation phase (0..1), can be 0 if static
} PC;

float clamp01(float v){ return clamp(v, 0.0, 1.0); }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    float t = clamp01(Temp.temp_norm[i]);
    float m = clamp01(Moist.moist_norm[i]);
    float lat = abs(float(y) / max(1.0, float(H) - 1.0) - 0.5) * 2.0; // 0 at equator, 1 at poles

    // Base zonal banding: more clouds near equator and at mid-latitudes
    float band_eq = 0.7 * (1.0 - lat);
    float band_mid = 0.3 * max(0.0, 1.0 - abs(lat - 0.6) * 3.0);
    float base = clamp01(band_eq + band_mid);

    // Temperature-moisture modulation
    float cool = clamp01((0.55 - t) * 2.0);
    float humid = m;
    float mod = clamp01(0.4 + 0.6 * (0.6 * humid + 0.4 * cool));

    // Gentle phase shift to suggest advection
    float adv = 0.15 * sin(6.28318 * (float(x) / float(max(1, W)) + PC.phase));

    Cloud.cloud[i] = clamp01(base * mod + adv);
}


