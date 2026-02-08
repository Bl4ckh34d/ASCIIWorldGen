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

// Hash utility robust for negative lattice coordinates.
// Keep X wrapping periodic when wrap_x is enabled.
float hash_f(vec2 p){
    float xf = floor(p.x);
    float yf = floor(p.y);
    if (PC.wrap_x == 1) {
        float w = max(1.0, float(PC.width));
        xf = mod(mod(xf, w) + w, w);
    }
    vec2 q = vec2(xf, yf) + float(PC.seed) * vec2(0.06711056, 0.00583715);
    return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453123);
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

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    float xf = float(x);
    float yf = float(y);
    float t = xf / float(max(1, W));

    // CPU-parity domain warp (warp_noise: simplex-ish FBM, fixed settings).
    float wx0 = fbm2(vec2(xf * 0.8 * PC.noise_x_scale, yf * 0.8), PC.base_freq * 1.5, 3, 2.0, 0.5);
    float wy0 = fbm2(vec2((xf + 1000.0) * 0.8 * PC.noise_x_scale, (yf - 777.0) * 0.8), PC.base_freq * 1.5, 3, 2.0, 0.5);
    float wx = wx0;
    float wy = wy0;
    if (PC.wrap_x == 1) {
        float wx1 = fbm2(vec2((xf + float(W)) * 0.8 * PC.noise_x_scale, yf * 0.8), PC.base_freq * 1.5, 3, 2.0, 0.5);
        float wy1 = fbm2(vec2((xf + 1000.0 + float(W)) * 0.8 * PC.noise_x_scale, (yf - 777.0) * 0.8), PC.base_freq * 1.5, 3, 2.0, 0.5);
        wx = mix(wx0, wx1, t);
        wy = mix(wy0, wy1, t);
    }
    OutWarpX.out_warp_x[i] = wx * PC.warp_amount;
    OutWarpY.out_warp_y[i] = wy * PC.warp_amount;

    // Base terrain field (unwarped) and continental scaffold (unwarped),
    // sampled later in terrain_gen with warp-aware bilinear lookup.
    float n0 = fbm2(vec2(xf * PC.noise_x_scale, yf), PC.base_freq, PC.octaves, PC.lacunarity, PC.gain);
    float n = n0;
    if (PC.wrap_x == 1) {
        float n1 = fbm2(vec2((xf + float(W)) * PC.noise_x_scale, yf), PC.base_freq, PC.octaves, PC.lacunarity, PC.gain);
        n = mix(n0, n1, t);
    }

    float cont_freq = max(0.002, PC.cont_freq);
    float c0 = fbm2(vec2(xf * 0.5 * PC.noise_x_scale, yf * 0.5), cont_freq, 4, 2.0, 0.5);
    float c = c0;
    if (PC.wrap_x == 1) {
        float c1 = fbm2(vec2((xf + float(W)) * 0.5 * PC.noise_x_scale, yf * 0.5), cont_freq, 4, 2.0, 0.5);
        c = mix(c0, c1, t);
    }

    OutFBM.out_fbm[i] = clamp(n, -1.0, 1.0);
    OutCont.out_cont[i] = clamp(c, -1.0, 1.0);
}
