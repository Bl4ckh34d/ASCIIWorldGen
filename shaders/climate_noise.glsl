#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Outputs (set=0)
layout(std430, set = 0, binding = 0) buffer OutTempNoise { float temp_noise[]; } OutT;
layout(std430, set = 0, binding = 1) buffer OutMoistBase { float moist_noise_base[]; } OutMB;
layout(std430, set = 0, binding = 2) buffer OutMoistRaw { float moist_noise_raw[]; } OutMR;
layout(std430, set = 0, binding = 3) buffer OutFlowU { float flow_u[]; } OutU;
layout(std430, set = 0, binding = 4) buffer OutFlowV { float flow_v[]; } OutV;

layout(push_constant) uniform Params {
    int width;
    int height;
    int wrap_x; // currently unused; fields tile in X via coords
    int seed;
    float noise_x_scale;
} PC;

// Hash-based Perlin utilities
uint hash_u32(uvec2 p){
    p = p * uvec2(1664525u, 1013904223u) + uvec2(uint(PC.seed), 374761393u);
    p ^= (p.yx >> 16);
    p *= uvec2(2246822519u, 3266489917u);
    p ^= (p.yx >> 13);
    p *= uvec2(668265263u, 2246822519u);
    p ^= (p.yx >> 16);
    return p.x ^ p.y;
}

float hash_f(vec2 p){
    uvec2 pi = uvec2(p);
    if (PC.wrap_x == 1) {
        pi.x = pi.x % uint(PC.width);
    }
    return float(hash_u32(pi)) * (1.0 / 4294967296.0);
}

vec2 grad2(vec2 p){
    float h = hash_f(p) * 6.28318530718; // [0, 2pi)
    return vec2(cos(h), sin(h));
}

float fade(float t){ return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

float perlin2(vec2 p){
    vec2 p0 = floor(p);
    vec2 f = fract(p);
    vec2 p1 = p0 + vec2(1.0, 0.0);
    vec2 p2 = p0 + vec2(0.0, 1.0);
    vec2 p3 = p0 + vec2(1.0, 1.0);

    vec2 g0 = grad2(p0);
    vec2 g1 = grad2(p1);
    vec2 g2 = grad2(p2);
    vec2 g3 = grad2(p3);

    float n0 = dot(g0, f - vec2(0.0, 0.0));
    float n1 = dot(g1, f - vec2(1.0, 0.0));
    float n2 = dot(g2, f - vec2(0.0, 1.0));
    float n3 = dot(g3, f - vec2(1.0, 1.0));

    vec2 u = vec2(fade(f.x), fade(f.y));
    float nx0 = mix(n0, n1, u.x);
    float nx1 = mix(n2, n3, u.x);
    float n = mix(nx0, nx1, u.y);
    return n;
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;

    float nx = float(x) * PC.noise_x_scale;
    float ny = float(y) * PC.noise_x_scale;

    // Base noises
    float t_noise = perlin2(vec2(nx, ny));
    float m_base = perlin2(vec2(nx + 100.0, ny - 50.0));
    float m_raw = perlin2(vec2(nx, ny));

    // Flow advect fields at lower frequency
    float u = perlin2(vec2(nx * 0.5, ny * 0.5));
    float v = perlin2(vec2((nx + 1000.0) * 0.5, (ny - 777.0) * 0.5));

    OutT.temp_noise[i] = clamp(t_noise, -1.0, 1.0);
    OutMB.moist_noise_base[i] = clamp(m_base, -1.0, 1.0);
    OutMR.moist_noise_raw[i] = clamp(m_raw, -1.0, 1.0);
    OutU.flow_u[i] = clamp(u, -1.0, 1.0);
    OutV.flow_v[i] = clamp(v, -1.0, 1.0);
}

