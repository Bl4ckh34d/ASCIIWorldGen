#[compute]
#version 450
// File: res://shaders/river_buffer_to_tex.glsl
// Pack river mask buffer (u32) into a GPU texture (R32F) for rendering without CPU readback.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer RiverBuf { uint river[]; } River;
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
    float c = (River.river[i] != 0u) ? 1.0 : 0.0;
    imageStore(out_tex, ivec2(int(x), int(y)), vec4(c, 0.0, 0.0, 1.0));
}
