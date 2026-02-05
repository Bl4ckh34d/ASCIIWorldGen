#[compute]
#version 450
// File: res://shaders/cloud_overlay.glsl
// Cloud intensity overlay generated from procedural noise (independent of humidity)

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer TempBuf { float temp_norm[]; } Temp;
layout(std430, set = 0, binding = 1) buffer MoistBuf { float moist_norm[]; } Moist;
layout(std430, set = 0, binding = 2) buffer IsLandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 3) buffer OutCloud { float cloud[]; } Cloud;

layout(push_constant) uniform Params {
    int width;
    int height;
    int seed;
    float phase; // animation phase (0..1), can be 0 if static
} PC;

float clamp01(float v){ return clamp(v, 0.0, 1.0); }

// --- Noise helpers (value noise + fbm) ---
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
    uvec2 qi = uvec2(q);
    qi.x = qi.x % uint(max(1, PC.width));
    return float(hash_u32(qi)) * (1.0 / 4294967296.0);
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
float fbm2(vec2 q, int oct){
    float amp = 0.55;
    float sum = 0.0;
    float f = 1.0;
    for (int o = 0; o < 6; o++){
        if (o >= oct) break;
        sum += amp * (value2(q * f) * 2.0 - 1.0);
        f *= 2.0;
        amp *= 0.5;
    }
    return sum;
}

float worley2(vec2 p){
    vec2 cell = floor(p);
    float minDist = 1e9;
    for (int j = -1; j <= 1; j++){
        for (int i = -1; i <= 1; i++){
            vec2 c = cell + vec2(float(i), float(j));
            float rx = hash_f(c + vec2(1.7, 9.2));
            float ry = hash_f(c + vec2(8.3, 2.8));
            vec2 diff = (c + vec2(rx, ry)) - p;
            float d = dot(diff, diff);
            if (d < minDist) minDist = d;
        }
    }
    return sqrt(minDist);
}

vec2 curl2(vec2 p){
    float e = 0.5;
    float n1 = fbm2(p + vec2(0.0, e), 4);
    float n2 = fbm2(p - vec2(0.0, e), 4);
    float n3 = fbm2(p + vec2(e, 0.0), 4);
    float n4 = fbm2(p - vec2(e, 0.0), 4);
    vec2 grad = vec2(n1 - n2, n3 - n4) / (2.0 * e);
    return vec2(grad.y, -grad.x);
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    float lat_signed = (float(y) / max(1.0, float(H) - 1.0) - 0.5) * 2.0;
    float lat = abs(lat_signed); // 0 at equator, 1 at poles
    float base = clamp01(1.0 - 0.15 * lat); // slight polar bias only
    float mid = clamp(1.0 - abs(lat - 0.45) / 0.35, 0.0, 1.0);
    float wind_strength = pow(mid, 1.3);
    float eq = clamp(1.0 - lat / 0.25, 0.0, 1.0);
    eq = pow(eq, 1.15);
    float polar = clamp((lat - 0.65) / 0.35, 0.0, 1.0);
    polar = pow(polar, 1.1);
    float hem = (lat_signed >= 0.0) ? 1.0 : -1.0;
    float eq_dir = -1.0;
    float polar_dir = -1.0;
    float drift_dir = hem * (1.0 - eq) * (1.0 - polar) + eq_dir * eq + polar_dir * polar;
    float drift = drift_dir * (wind_strength + 0.5 * eq + 0.4 * polar) * PC.phase * 12.0;
    vec2 drift_vec = vec2(drift, 0.0);

    vec2 p = vec2(float(x), float(y)) * 0.035 + drift_vec;
    float seed_f = float(PC.seed % 997);
    vec2 curl = curl2(p * 0.7 + vec2(seed_f * 0.03, seed_f * 0.07));
    vec2 pp = p + curl * 2.6 + vec2(PC.phase * 3.0, PC.phase * 1.4);
    float w = worley2(pp * 1.0);
    float worley_val = exp(-w * 2.3);
    float fbm_val = fbm2(pp * 0.85 + vec2(seed_f * 0.01, seed_f * 0.02), 4) * 0.5 + 0.5;
    float noise = clamp01(worley_val * 0.75 + fbm_val * 0.25);
    // Large-scale coverage mask to create big clear areas + dense clusters
    vec2 lp = vec2(float(x), float(y)) * 0.004 + vec2(seed_f * 0.02, seed_f * 0.031) + vec2(PC.phase * 2.0, -PC.phase * 1.2) + drift_vec * 0.35;
    float large = fbm2(lp, 3) * 0.5 + 0.5;
    large = smoothstep(0.3, 0.7, large);
    large = pow(large, 1.8);
    float large_mult = mix(0.05, 1.7, large);

    // Gentle phase shift to suggest advection
    float adv = 0.08 * sin(6.28318 * (float(x) / float(max(1, W)) + PC.phase));

    float humidity = clamp01(Moist.moist_norm[i]);
    float humid_boost = smoothstep(0.2, 0.85, humidity);

    float core = smoothstep(0.35, 0.7, noise);
    float cov = base * (0.25 + 0.75 * core);
    cov = (cov + adv * (0.2 + 0.8 * core)) * large_mult;
    cov = cov * (0.45 + 0.95 * humid_boost) + humid_boost * 0.08;
    cov = clamp01(cov);
    Cloud.cloud[i] = cov;
}
