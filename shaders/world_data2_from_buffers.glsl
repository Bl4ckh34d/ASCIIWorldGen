#[compute]
#version 450
// File: res://shaders/world_data2_from_buffers.glsl
// Pack base world data (surface_id, is_land, char_index=0, beach_flag) from buffers into RGBA32F texture.
// surface_id is biome_id by default, or rock_type in bedrock mode.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer BiomeBuf { int biome[]; } Biome;
layout(std430, set = 0, binding = 1) buffer LandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) buffer BeachBuf { uint beach[]; } Beach;
layout(rgba32f, set = 0, binding = 3) uniform image2D out_tex;
layout(std430, set = 0, binding = 4) buffer RockBuf { int rock[]; } Rock;

layout(push_constant) uniform Params {
    int width;
    int height;
    int use_rock;
    int _pad0;
} PC;

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(x) + int(y) * PC.width;
    int surface_id = (PC.use_rock != 0) ? Rock.rock[i] : Biome.biome[i];
    float surface_norm = clamp(float(surface_id) / 255.0, 0.0, 1.0);
    float land = (Land.is_land[i] != 0u) ? 1.0 : 0.0;
    float beach = (Beach.beach[i] != 0u) ? 1.0 : 0.0;
    float char_idx = 0.0;
    imageStore(out_tex, ivec2(int(x), int(y)), vec4(surface_norm, land, char_idx, beach));
}
