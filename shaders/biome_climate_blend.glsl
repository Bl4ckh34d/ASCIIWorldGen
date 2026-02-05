#[compute]
#version 450
// File: res://shaders/biome_climate_blend.glsl
// Low-pass filter for climate used by biomes (GPU).
// Inputs: current temp/moist, previous slow temp/moist (in-place update).

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer TempInBuf { float temp_in[]; } TempIn;
layout(std430, set = 0, binding = 1) buffer MoistInBuf { float moist_in[]; } MoistIn;
layout(std430, set = 0, binding = 2) buffer TempSlowBuf { float temp_slow[]; } TempSlow;
layout(std430, set = 0, binding = 3) buffer MoistSlowBuf { float moist_slow[]; } MoistSlow;

layout(push_constant) uniform Params {
    int width;
    int height;
    float alpha;
} PC;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int i = int(x) + int(y) * PC.width;
    float t = TempIn.temp_in[i];
    float m = MoistIn.moist_in[i];
    float ts = TempSlow.temp_slow[i];
    float ms = MoistSlow.moist_slow[i];
    float a = clamp(PC.alpha, 0.0, 1.0);
    TempSlow.temp_slow[i] = clamp01(mix(ts, t, a));
    MoistSlow.moist_slow[i] = clamp01(mix(ms, m, a));
}
