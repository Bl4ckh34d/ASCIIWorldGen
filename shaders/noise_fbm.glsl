#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Outputs: four fields built on GPU
layout(std430, set = 0, binding = 0) buffer OutFBMBuf { float out_fbm[]; } OutFBM;
layout(std430, set = 0, binding = 1) buffer OutContBuf { float out_cont[]; } OutCont;
layout(std430, set = 0, binding = 2) buffer OutWarpXBuf { float out_warp_x[]; } OutWarpX;
layout(std430, set = 0, binding = 3) buffer OutWarpYBuf { float out_warp_y[]; } OutWarpY;

layout(push_constant) uniform Params {
    int width;
    int height;
    int wrap_x; // 1 or 0
    int seed;
    float base_freq;
    float cont_freq;
    float noise_x_scale;
    float warp_amount;
    float lacunarity;
    float gain;
    int octaves;
} PC;

// Hash utilities (tileable along X by using modulo with width)
uint hash_u32(uvec2 p){
    // From https://www.shadertoy.com/view/4djSRW style hash
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

float perlin2_tiled(vec2 p){
    // Lattice corners
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
    // Normalize to approx [-1,1]
    return n;
}

float fbm2(vec2 p, float freq, int octaves, float lacunarity, float gain){
    float amp = 0.5;
    float sum = 0.0;
    float f = freq;
    for (int o = 0; o < 12; o++){
        if (o >= octaves) break;
        sum += amp * perlin2_tiled(p * f);
        f *= lacunarity;
        amp *= gain;
    }
    // Map to [-1,1] approximately
    return sum;
}

mat2 rot2(float a){
    float c = cos(a);
    float s = sin(a);
    return mat2(c, -s, s, c);
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    vec2 p = vec2(float(x), float(y));
    vec2 p0 = p * vec2(PC.noise_x_scale, 1.0);
    vec2 p1 = rot2(0.71) * p0;
    vec2 p2 = rot2(-1.13) * p0;

    // Multi-domain warp suppresses directional "wavy" artifacts.
    float wx = (
        fbm2(p1 * 0.70, PC.base_freq, PC.octaves, PC.lacunarity, PC.gain) * 0.62 +
        fbm2(p2 * 1.25 + vec2(113.0, -71.0), PC.base_freq * 1.75, min(PC.octaves, 4), PC.lacunarity * 1.12, PC.gain * 0.84) * 0.38
    ) * PC.warp_amount;
    float wy = (
        fbm2(p2 * 0.70 + vec2(53.0, 139.0), PC.base_freq, PC.octaves, PC.lacunarity, PC.gain) * 0.62 +
        fbm2(p1 * 1.35 + vec2(-97.0, 211.0), PC.base_freq * 1.65, min(PC.octaves, 4), PC.lacunarity * 1.10, PC.gain * 0.86) * 0.38
    ) * PC.warp_amount;
    OutWarpX.out_warp_x[i] = wx;
    OutWarpY.out_warp_y[i] = wy;

    // Base FBM (warped coords)
    float sx = float(x) + wx;
    float sy = float(y) + wy;
    vec2 sp0 = vec2(sx * PC.noise_x_scale, sy);
    vec2 sp1 = rot2(0.57) * sp0;
    vec2 sp2 = rot2(-0.93) * sp0;
    float fbm_val = 0.58 * fbm2(sp1, PC.base_freq, PC.octaves, PC.lacunarity, PC.gain)
        + 0.42 * fbm2(sp2, PC.base_freq * 1.17, PC.octaves, PC.lacunarity * 1.03, PC.gain * 0.97);
    // Higher-frequency detail + ridged component for natural rugged structure.
    int det_oct = min(PC.octaves, 3);
    float detail_val = fbm2(sp0 * 2.9, PC.base_freq * 2.3, det_oct, PC.lacunarity * 1.30, PC.gain * 0.82);
    float ridge_val = 1.0 - abs(fbm2(sp0 * 1.9 + vec2(37.0, -59.0), PC.base_freq * 1.8, det_oct + 1, PC.lacunarity * 1.22, PC.gain * 0.80));
    ridge_val = ridge_val * 2.0 - 1.0;
    float fbm_combined = fbm_val * 0.60 + detail_val * 0.24 + ridge_val * 0.16;

    // Continental scaffold: two low-frequency fields and a broad ridge mask.
    vec2 cp0 = p0 * 0.5;
    vec2 cp1 = rot2(0.41) * cp0;
    vec2 cp2 = rot2(-0.67) * cp0;
    float cont_a = fbm2(cp1, PC.cont_freq, PC.octaves, PC.lacunarity, PC.gain);
    float cont_b = fbm2(cp2 + vec2(221.0, -133.0), PC.cont_freq * 0.82, max(2, PC.octaves - 1), PC.lacunarity * 1.02, PC.gain * 0.95);
    float cont_ridge = 1.0 - abs(fbm2(cp0 + vec2(-301.0, 87.0), PC.cont_freq * 0.92, max(2, PC.octaves - 1), PC.lacunarity * 1.08, PC.gain * 0.90));
    cont_ridge = cont_ridge * 2.0 - 1.0;
    float cont_val = cont_a * 0.52 + cont_b * 0.33 + cont_ridge * 0.15;

    // Clamp to [-1,1] for safety
    OutFBM.out_fbm[i] = clamp(fbm_combined, -1.0, 1.0);
    OutCont.out_cont[i] = clamp(cont_val, -1.0, 1.0);
}

