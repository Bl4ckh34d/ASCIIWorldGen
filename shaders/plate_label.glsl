#[compute]
#version 450
// File: res://shaders/plate_label.glsl
// Assign plate ids using a strongly warped weighted Voronoi field (wrap-X).
// The warp is multi-scale and flow-like to avoid straight Voronoi seams.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer SiteX { int site_x[]; } SX;
layout(std430, set = 0, binding = 1) buffer SiteY { int site_y[]; } SY;
layout(std430, set = 0, binding = 2) buffer SiteWeight { float site_weight[]; } SW;
layout(std430, set = 0, binding = 3) buffer OutPlateId { int out_plate_id[]; } Out;

layout(push_constant) uniform Params {
    int width;
    int height;
    int num_sites;
    int seed;
    float warp_strength_cells;
    float warp_frequency;
    float lat_anisotropy;
    float _pad0;
} PC;

uint hash_u32(uvec2 q){
    q = q * uvec2(1664525u, 1013904223u) + uvec2(uint(PC.seed), 374761393u);
    q ^= (q.yx >> 16);
    q *= uvec2(2246822519u, 3266489917u);
    q ^= (q.yx >> 13);
    q *= uvec2(668265263u, 2246822519u);
    q ^= (q.yx >> 16);
    return q.x ^ q.y;
}

float hash_f(vec2 q){
    ivec2 qi = ivec2(floor(q));
    int wx = max(1, PC.width);
    int wy = max(1, PC.height);
    qi.x = ((qi.x % wx) + wx) % wx;
    qi.y = ((qi.y % wy) + wy) % wy;
    return float(hash_u32(uvec2(uint(qi.x), uint(qi.y)))) * (1.0 / 4294967296.0);
}

float value2(vec2 q){
    vec2 pf = floor(q);
    vec2 f = fract(q);
    float h00 = hash_f(pf + vec2(0.0, 0.0));
    float h10 = hash_f(pf + vec2(1.0, 0.0));
    float h01 = hash_f(pf + vec2(0.0, 1.0));
    float h11 = hash_f(pf + vec2(1.0, 1.0));
    float nx0 = mix(h00, h10, f.x);
    float nx1 = mix(h01, h11, f.x);
    return mix(nx0, nx1, f.y);
}

float fbm2(vec2 q){
    float amp = 0.55;
    float sum = 0.0;
    float f = 1.0;
    for (int o = 0; o < 4; ++o){
        sum += amp * (value2(q * f) * 2.0 - 1.0);
        f *= 2.0;
        amp *= 0.5;
    }
    return sum;
}

vec2 warp_field(vec2 p){
    float wf = max(0.00001, PC.warp_frequency);
    vec2 q = p * wf;
    float a = fbm2(q + vec2(17.1, 5.3));
    float b = fbm2(q + vec2(-11.7, 23.9));
    float c = fbm2(q * 1.7 + vec2(41.2, -7.8));
    float d = fbm2(q * 1.3 + vec2(-23.1, 29.4));
    return vec2(a + 0.55 * c, b + 0.45 * d);
}

vec2 flow_warp(vec2 p){
    float wf = max(0.00001, PC.warp_frequency);
    // Low frequency steering
    vec2 drift = vec2(
        fbm2(p * (wf * 0.43) + vec2(101.0, -37.0)),
        fbm2(p * (wf * 0.41) + vec2(-83.0, 59.0))
    );
    // Mid/high frequency deformation
    vec2 adv = vec2(
        fbm2(p * (wf * 1.35) + vec2(13.0, 27.0)),
        fbm2(p * (wf * 1.58) + vec2(-29.0, 11.0))
    );
    return drift * 0.78 + adv * 0.46;
}

float site_hash(int s, float salt){
    return fract(sin(float(s) * 12.9898 + float(PC.seed) * 0.017 + salt) * 43758.5453);
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;
    float lat01 = float(y) / max(1.0, float(H - 1));
    float lat_abs = abs(lat01 - 0.5) * 2.0;
    float lat_scale = mix(1.0, clamp(PC.lat_anisotropy, 0.2, 2.5), smoothstep(0.15, 0.95, lat_abs));
    vec2 p = vec2(float(x), float(y));
    float ws = max(0.0, PC.warp_strength_cells);
    vec2 warped = p;
    // Layered advection-style warping for organic, plate-like outlines.
    vec2 w0 = warp_field(warped) + flow_warp(warped + vec2(17.0, -11.0)) * 0.65;
    warped += w0 * (ws * 0.70);
    vec2 w1 = warp_field(warped * 1.17 + vec2(43.0, -29.0)) + flow_warp(warped * 1.09 + vec2(-61.0, 37.0)) * 0.60;
    warped += w1 * (ws * 0.42);
    vec2 w2 = warp_field(warped * 1.71 + vec2(-97.0, 53.0));
    warped += w2 * (ws * 0.22);

    float best_d2 = 3.4e38;
    int best_idx = 0;
    for (int s = 0; s < PC.num_sites; ++s) {
        float sx = float(SX.site_x[s]);
        float sy = float(SY.site_y[s]);
        float dx = warped.x - sx;
        // wrap-x shortest distance
        if (dx > float(W) * 0.5) dx -= float(W);
        else if (dx < -float(W) * 0.5) dx += float(W);
        float dy = warped.y - sy;
        float h0 = site_hash(s, 3.7);
        float h1 = site_hash(s, 9.1);
        float site_ax = mix(0.82, 1.26, h0);
        float site_ay = mix(0.82, 1.26, h1);
        dx *= site_ax;
        dy *= lat_scale * site_ay;
        float d2 = dx * dx + dy * dy;
        float weight = clamp(SW.site_weight[s], 0.20, 3.40);
        // Site-specific exponent adds shape diversity beyond pure Euclidean Voronoi.
        float pwr = mix(0.88, 1.22, site_hash(s, 17.3));
        d2 = pow(max(1e-6, d2), pwr);
        d2 *= weight;
        if (d2 < best_d2) { best_d2 = d2; best_idx = s; }
    }
    Out.out_plate_id[i] = best_idx;
}
