#[compute]
#version 450
// File: res://shaders/world_data2_from_buffers.glsl
// Pack base world data (biome, is_land, char_index=0, beach_flag) from buffers into RGBA32F texture.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer BiomeBuf { int biome[]; } Biome;
layout(std430, set = 0, binding = 1) buffer LandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) buffer BeachBuf { uint beach[]; } Beach;
layout(rgba32f, set = 0, binding = 3) uniform image2D out_tex;

layout(push_constant) uniform Params {
    int width;
    int height;
} PC;

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(x) + int(y) * PC.width;
    int b = Biome.biome[i];
    float biome_norm = clamp(float(b) / 255.0, 0.0, 1.0);
    float land = (Land.is_land[i] != 0u) ? 1.0 : 0.0;
    float beach = (Beach.beach[i] != 0u) ? 1.0 : 0.0;
    float char_idx = 0.0;
    imageStore(out_tex, ivec2(int(x), int(y)), vec4(biome_norm, land, char_idx, beach));
}
