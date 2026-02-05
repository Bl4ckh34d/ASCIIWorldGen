#[compute]
#version 450
// File: res://shaders/wind_field.glsl
// Generate wind vector field (u, v) from latitudinal bands and simple eddies.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer OutUBuf { float out_u[]; } OutU;
layout(std430, set = 0, binding = 1) buffer OutVBuf { float out_v[]; } OutV;

layout(push_constant) uniform Params {
    int width;
    int height;
    float phase; // 0..1
} PC;

uint hash_u32(uvec2 q){
    q = q * uvec2(1664525u, 1013904223u);
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
vec2 curl_from_worley(vec2 p){
    float e = 0.75;
    float n1 = worley2(p + vec2(e, 0.0));
    float n2 = worley2(p - vec2(e, 0.0));
    float n3 = worley2(p + vec2(0.0, e));
    float n4 = worley2(p - vec2(0.0, e));
    vec2 grad = vec2(n1 - n2, n3 - n4) / (2.0 * e);
    return vec2(grad.y, -grad.x);
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    float lat01 = float(y) / max(1.0, float(H) - 1.0);
    float lat_signed = (lat01 - 0.5) * 2.0;
    // Meandering jet latitude shift (low-frequency noise)
    float low1 = sin(6.28318 * (lat01 * 0.35 + PC.phase * 0.7));
    float low2 = cos(6.28318 * (lat01 * 0.18 - PC.phase * 0.4));
    float lat_jitter = 0.18 * (low1 + low2) * 0.5;
    lat_signed = clamp(lat_signed + lat_jitter, -1.0, 1.0);
    float abs_lat = abs(lat_signed);
    float hem_sign = (lat_signed >= 0.0) ? 1.0 : -1.0;
    float mid = clamp(1.0 - abs(abs_lat - 0.45) / 0.35, 0.0, 1.0);
    mid = pow(mid, 1.2);
    float eq = clamp(1.0 - abs_lat / 0.25, 0.0, 1.0);
    eq = pow(eq, 1.15);
    float polar = clamp((abs_lat - 0.65) / 0.35, 0.0, 1.0);
    polar = pow(polar, 1.1);
    float band_strength = mix(0.45, 1.2, mid) + 0.55 * eq + 0.45 * polar;
    float eq_dir = -1.0;
    float polar_dir = -1.0;
    float band_u = hem_sign * band_strength * (1.0 - eq) * (1.0 - polar)
                 + eq_dir * band_strength * eq
                 + polar_dir * band_strength * polar;
    float lat_mult = mix(0.75, 1.4, mid) + polar * 0.3;
    float v_band = -0.22 * lat_signed * lat_mult;

    // Simple eddies via trigonometric noise; evolves with phase
    float fx = float(x) / max(1.0, float(W));
    float fy = float(y) / max(1.0, float(H));
    float t = PC.phase;
    float n1 = 0.5 * (sin(6.28318 * (fx * 3.1 + t * 0.8)) + cos(6.28318 * (fy * 2.7 - t * 0.6)));
    float n2 = 0.5 * (sin(6.28318 * (fx * 5.3 - t * 1.2)) + cos(6.28318 * (fy * 4.1 + t * 1.4)));
    float nu = 0.35 * (n1 + 0.5 * n2);
    float nv = 0.35 * (sin(6.28318 * (fx * 2.1 - t * 1.1)) + cos(6.28318 * (fy * 3.7 + t * 0.9))) * 0.5;
    float meander = 0.25 * sin(6.28318 * (fx * 0.9 + fy * 0.6 + t * 0.4));
    float bg_u = 0.12 * sin(6.28318 * (lat01 * 0.8 + t * 0.5));
    float bg_v = 0.08 * cos(6.28318 * (fx * 0.7 + t * 0.4));
    // Worley-based curl for swirling winds
    vec2 p = vec2(float(x), float(y)) * 0.035 + vec2(t * 3.0, -t * 2.0);
    vec2 curl = curl_from_worley(p);
    vec2 p2 = vec2(float(x), float(y)) * 0.085 + vec2(t * 6.0, -t * 4.0);
    vec2 curl2 = curl_from_worley(p2);
    float curl_mult = mix(0.15, 0.45, mid) + polar * 0.25;
    float turb_scale = 0.7;

    float base_u = band_u * lat_mult + (nu + meander + bg_u + curl.x * curl_mult + curl2.x * 0.22) * turb_scale;
    float base_v = v_band + (nv * 0.6 + bg_v + curl.y * curl_mult + curl2.y * 0.22) * turb_scale;
    // Rotate local wind to encourage vortices and break long streaks
    float angle = (sin(6.28318 * (fx * 1.7 + t * 0.9)) + cos(6.28318 * (fy * 1.3 - t * 0.7))) * 0.35;
    float ca = cos(angle);
    float sa = sin(angle);
    float rot_u = base_u * ca - base_v * sa;
    float rot_v = base_u * sa + base_v * ca;
    float mix_t = 0.6;
    OutU.out_u[i] = mix(base_u, rot_u, mix_t);
    OutV.out_v[i] = mix(base_v, rot_v, mix_t);
}
