#[compute]
#version 450
// File: res://shaders/cloud_noise.glsl
// Generate a lightweight, deterministic cloud coverage field for a local view.
// Output is a float cloud coverage in [0..1] per cell.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer CloudBuf { float cloud[]; } Cloud;

layout(push_constant) uniform Params {
    int width;
    int height;
    int origin_x;
    int origin_y;
    int world_period_x;
    int world_height;
    int seed;
    int _pad0;
    float sim_days;
    float scale;
    float wind_x;
    float wind_y;
    float coverage;
    float contrast;
    float overcast_floor;
    float morph_strength;
} PC;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    // Quintic-ish smooth curve
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i + vec2(0.0, 0.0));
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    vec2 pp = p;
    for (int o = 0; o < 4; o++) {
        v += a * value_noise(pp);
        pp = pp * 2.03 + vec2(17.1, -9.7);
        a *= 0.5;
    }
    return v;
}

int wrap_x(int x, int period) {
    if (period <= 0) { return x; }
    int m = x % period;
    if (m < 0) { m += period; }
    return m;
}

int clamp_y(int y, int max_y) {
    if (max_y <= 0) { return y; }
    return clamp(y, 0, max_y);
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int W = PC.width;
    int i = int(x) + int(y) * W;

    int gx = PC.origin_x + int(x);
    int gy = PC.origin_y + int(y);
    gx = wrap_x(gx, PC.world_period_x);
    gy = clamp_y(gy, max(0, PC.world_height - 1));

    vec2 seed_off = vec2(float(PC.seed) * 0.0013, float(PC.seed) * 0.0021);
    vec2 wind = vec2(PC.wind_x, PC.wind_y) * PC.sim_days;
    vec2 p = (vec2(float(gx), float(gy)) * max(0.0001, PC.scale)) + seed_off + wind;

    float n = fbm(p);
    float morph = clamp01(PC.morph_strength);
    if (morph > 0.0) {
        vec2 morph_shift = vec2(0.37, -0.29) * (PC.sim_days * (0.25 + 0.55 * morph));
        float n2 = fbm(p * (1.35 + 0.25 * morph) + morph_shift + vec2(23.7, -41.9));
        float phase = 0.5 + 0.5 * sin(PC.sim_days * (0.85 + 0.35 * morph) + float(gx + gy) * 0.0025 + float(PC.seed) * 0.00013);
        n = mix(n, n2, morph * mix(0.20, 0.45, phase));
    }
    n = clamp01(n);
    // Shape into cloud cover: coverage is a threshold, contrast sharpens edges.
    float c = smoothstep(clamp01(PC.coverage), 1.0, n);
    float k = max(0.001, PC.contrast);
    c = pow(clamp01(c), k);
    c = max(c, clamp01(PC.overcast_floor));
    Cloud.cloud[i] = clamp01(c);
}
