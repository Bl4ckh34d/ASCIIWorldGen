#[compute]
#version 450
// File: res://shaders/u32_to_f32.glsl
// Convert u32 buffer to float buffer.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer InBuf { uint in_u[]; } InU;
layout(std430, set = 0, binding = 1) buffer OutBuf { float out_f[]; } OutF;

layout(push_constant) uniform Params {
    int count;
} PC;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(PC.count)) return;
    OutF.out_f[i] = float(InU.in_u[i]);
}
