#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Outputs (set = 0)
layout(std430, set = 0, binding = 0) buffer DesertBuf { float desert[]; } Desert;
layout(std430, set = 0, binding = 1) buffer IceBuf { float ice_wiggle[]; } Ice;
layout(std430, set = 0, binding = 2) buffer ShoreBuf { float shore_noise[]; } Shore;
layout(std430, set = 0, binding = 3) buffer ShelfBuf { float shelf_value[]; } Shelf;

layout(push_constant) uniform Params {
    int width;
    int height;
    int seed;
    float noise_x_scale;
    float base_freq;
    float shore_freq;
} PC;

// Hash utilities (tileable along X by modulo width, stable for negative coords)
float hash_f(vec2 p){
    float xf = floor(p.x);
    float yf = floor(p.y);
    float w = max(1.0, float(PC.width));
    xf = mod(mod(xf, w) + w, w);
    vec2 q = vec2(xf, yf) + float(PC.seed) * vec2(0.06711056, 0.00583715);
    return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453123);
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
    return mix(nx0, nx1, u.y);
}

// Simple FBM
float fbm2(vec2 p, float freq, int octaves){
    float amp = 0.5;
    float sum = 0.0;
    float f = freq;
    for (int o = 0; o < 8; o++){
        if (o >= octaves) break;
        sum += amp * perlin2(p * f);
        f *= 2.0;
        amp *= 0.5;
    }
    return sum;
}

// Coarse value-like noise (0..1)
float value2(vec2 p){
    vec2 pf = floor(p);
    vec2 f = fract(p);
    float h00 = hash_f(pf + vec2(0.0, 0.0));
    float h10 = hash_f(pf + vec2(1.0, 0.0));
    float h01 = hash_f(pf + vec2(0.0, 1.0));
    float h11 = hash_f(pf + vec2(1.0, 1.0));
    float nx0 = mix(h00, h10, f.x);
    float nx1 = mix(h01, h11, f.x);
    return mix(nx0, nx1, f.y);
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width;
    int i = int(x) + int(y) * W;

    float nx = float(x) * PC.noise_x_scale;
    float ny = float(y);
    float t = float(x) / float(max(1, W));
    float period = float(W) * PC.noise_x_scale;

    // Desert split (0..1)
    float d0 = fbm2(vec2(nx, ny), max(0.001, PC.base_freq), 5);
    float d1 = fbm2(vec2(nx + period, ny), max(0.001, PC.base_freq), 5);
    float d = mix(d0, d1, t) * 0.5 + 0.5;
    Desert.desert[i] = clamp(d, 0.0, 1.0);

    // Ice wiggle (-1..1)
    float ice_x = nx * 1.1 + 37.0;
    float ice_period = period * 1.1;
    float ice0 = perlin2(vec2(ice_x, ny * 1.1 - 13.0));
    float ice1 = perlin2(vec2(ice_x + ice_period, ny * 1.1 - 13.0));
    float ice = mix(ice0, ice1, t);
    Ice.ice_wiggle[i] = clamp(ice, -1.0, 1.0);

    // Shore value noise (0..1), higher frequency
    float s0 = fbm2(vec2(nx, ny), max(0.002, PC.shore_freq), 3);
    float s1 = fbm2(vec2(nx + period, ny), max(0.002, PC.shore_freq), 3);
    float s = mix(s0, s1, t) * 0.5 + 0.5;
    Shore.shore_noise[i] = clamp(s, 0.0, 1.0);

    // Shelf coarse value noise (0..1)
    float sv0 = value2(vec2(float(x), float(y)) / 20.0);
    float sv1 = value2(vec2(float(x + uint(W)), float(y)) / 20.0);
    float sv = mix(sv0, sv1, t);
    Shelf.shelf_value[i] = clamp(sv, 0.0, 1.0);
}
