#[compute]
#version 450
// File: res://shaders/land_mask_update.glsl
// Update land mask buffer from height buffer and sea level.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer HeightBuf { float height[]; } Height;
layout(std430, set = 0, binding = 1) buffer LandBuf { uint land[]; } Land;

layout(push_constant) uniform Params {
    int width;
    int height;
    float sea_level;
} PC;

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(x) + int(y) * PC.width;
    float h = Height.height[i];
    Land.land[i] = (h > PC.sea_level) ? 1u : 0u;
}
