#[compute]
#version 450
// File: res://shaders/biome_buffer_to_tex.glsl
// Pack biome id buffer (int) into a GPU texture (R32F) for rendering.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer BiomeBuf { int biome[]; } Biome;
layout(r32f, set = 0, binding = 1) uniform image2D out_tex;

layout(push_constant) uniform Params {
    int width;
    int height;
} PC;

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(x) + int(y) * PC.width;
    float v = clamp(float(Biome.biome[i]) / 255.0, 0.0, 1.0);
    imageStore(out_tex, ivec2(int(x), int(y)), vec4(v, 0.0, 0.0, 1.0));
}
