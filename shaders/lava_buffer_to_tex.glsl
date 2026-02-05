#[compute]
#version 450
// File: res://shaders/lava_buffer_to_tex.glsl
// Pack lava mask buffer (float) into a GPU texture (R32F) for rendering.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer LavaBuf { float lava[]; } Lava;
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
    float v = clamp(Lava.lava[i], 0.0, 1.0);
    imageStore(out_tex, ivec2(int(x), int(y)), vec4(v, 0.0, 0.0, 1.0));
}
