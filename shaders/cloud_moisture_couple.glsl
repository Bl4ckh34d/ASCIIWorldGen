#[compute]
#version 450
// File: res://shaders/cloud_moisture_couple.glsl
// Couple cloud coverage to moisture field on GPU.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer CloudBuf { float cloud[]; } Cloud;
layout(std430, set = 0, binding = 1) buffer MoistBuf { float moist[]; } Moist;
layout(std430, set = 0, binding = 2) buffer LandBuf { int land[]; } Land;

layout(push_constant) uniform Params {
    int width;
    int height;
    float dt_days;
    float rain_land;
    float rain_ocean;
    float evap_land;
    float evap_ocean;
} PC;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(x) + int(y) * PC.width;
    float cloud = clamp01(Cloud.cloud[i]);
    bool is_land = Land.land[i] != 0;
    float rain = is_land ? PC.rain_land : PC.rain_ocean;
    float evap = is_land ? PC.evap_land : PC.evap_ocean;
    float delta = PC.dt_days * (rain * cloud - evap * (1.0 - cloud));
    float m = clamp01(Moist.moist[i] + delta);
    Moist.moist[i] = m;
}
