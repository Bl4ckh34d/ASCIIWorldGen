#[compute]
#version 450
// File: res://shaders/volcanism.glsl
// Volcanism spawn/decay: boost along plate boundaries and random hotspots.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer BoundaryBuf { int boundary_mask[]; } Bnd;
layout(std430, set = 0, binding = 1) buffer LavaBuf { float lava[]; } Lava;

layout(push_constant) uniform Params {
    int width;
    int height;
    float dt_days;
    float decay_rate_per_day;
    float spawn_boundary_rate_per_day;
    float hotspot_rate_per_day;
    float hotspot_threshold;
    float boundary_spawn_threshold;
    float phase;   // 0..1 time phase for RNG
    int seed;
} PC;

// Hash-based RNG in 0..1
float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(x) + int(y) * PC.width;
    float prev = Lava.lava[i];
    float dt = max(0.0, PC.dt_days);
    // Decay
    float decay = clamp(1.0 - PC.decay_rate_per_day * dt, 0.0, 1.0);
    float val = prev * decay;
    // Boundary spawn (probabilistic)
    if (Bnd.boundary_mask[i] != 0) {
        float r2 = hash21(vec2(float(i) * 0.002 + PC.phase * 3.17, float(PC.seed) * 0.00013));
        if (r2 > PC.boundary_spawn_threshold) {
            val += PC.spawn_boundary_rate_per_day * dt;
        }
    }
    // Hotspots
    float r = hash21(vec2(float(i) * 0.001 + PC.phase * 13.37, float(PC.seed) * 0.00001));
    if (r > PC.hotspot_threshold) {
        val += PC.hotspot_rate_per_day * dt;
    }
    // Clamp
    val = clamp(val, 0.0, 1.0);
    Lava.lava[i] = val;
}
