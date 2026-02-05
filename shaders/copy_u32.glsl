#[compute]
#version 450
// File: res://shaders/copy_u32.glsl
// Copy u32 buffer to another.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer SrcBuf { uint src[]; } Src;
layout(std430, set = 0, binding = 1) buffer DstBuf { uint dst[]; } Dst;

layout(push_constant) uniform Params {
    int count;
} PC;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(PC.count)) return;
    Dst.dst[i] = Src.src[i];
}
