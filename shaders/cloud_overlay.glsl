#[compute]
#version 450
// File: res://shaders/cloud_overlay.glsl
// Multi-scale humidity-driven cloud source field.
// Humidity is the primary driver; temperature/day-night and vegetation modulate formation.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer TempBuf { float temp_norm[]; } Temp;
layout(std430, set = 0, binding = 1) buffer MoistBuf { float moist_norm[]; } Moist;
layout(std430, set = 0, binding = 2) buffer IsLandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 3) buffer LightBuf { float light[]; } Light;
layout(std430, set = 0, binding = 4) buffer BiomeBuf { int biome_id[]; } Biome;
layout(std430, set = 0, binding = 5) buffer HeightBuf { float height[]; } Height;
layout(std430, set = 0, binding = 6) buffer WindUBuf { float wind_u[]; } WindU;
layout(std430, set = 0, binding = 7) buffer WindVBuf { float wind_v[]; } WindV;
layout(std430, set = 0, binding = 8) buffer OutCloud { float cloud[]; } Cloud;

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
    ivec2 qi = ivec2(floor(q));
    int wx = max(1, PC.width);
    int wy = 8192; // Keep hashing coordinates bounded for numerical stability.
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

float biome_veg_factor(int b){
    switch (b) {
        case 10: // SWAMP
            return 0.95;
        case 11: // TROPICAL_FOREST
        case 12: // BOREAL_FOREST
        case 13: // CONIFER_FOREST
        case 14: // TEMPERATE_FOREST
        case 15: // RAINFOREST
            return 1.0;
        case 22: // FROZEN_FOREST
            return 0.28;
        case 23: // FROZEN_MARSH
            return 0.22;
        case 27: // SCORCHED_FOREST
            return 0.08;
        case 7:  // GRASSLAND
        case 6:  // STEPPE
        case 21: // SAVANNA
            return 0.48;
        case 29: // FROZEN_GRASSLAND
        case 30: // FROZEN_STEPPE
        case 33: // FROZEN_SAVANNA
            return 0.16;
        case 36: // SCORCHED_GRASSLAND
        case 37: // SCORCHED_STEPPE
        case 40: // SCORCHED_SAVANNA
            return 0.12;
        case 16: // HILLS
        case 18: // MOUNTAINS
        case 19: // ALPINE
            return 0.20;
        case 34: // FROZEN_HILLS
            return 0.10;
        case 41: // SCORCHED_HILLS
            return 0.08;
        case 20: // TUNDRA
            return 0.18;
        case 2: // BEACH
            return 0.12;
        case 3:  // DESERT_SAND
        case 4:  // WASTELAND
        case 5:  // DESERT_ICE
        case 25: // LAVA_FIELD
        case 26: // VOLCANIC_BADLANDS
        case 28: // SALT_DESERT
            return 0.04;
        default:
            return 0.16;
    }
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    float temp = clamp01(Temp.temp_norm[i]);
    float humidity = clamp01(Moist.moist_norm[i]);
    bool land = Land.is_land[i] != 0u;
    float light_val = clamp01(Light.light[i]);
    float daylight = smoothstep(0.18, 0.90, light_val);
    float night = 1.0 - daylight;
    float warm = smoothstep(0.30, 0.88, temp);
    float humid = smoothstep(0.26, 0.96, humidity);
    float veg = land ? biome_veg_factor(Biome.biome_id[i]) : 0.0;

    float lat_signed = (float(y) / max(1.0, float(H) - 1.0) - 0.5) * 2.0;
    float abs_lat = abs(lat_signed);
    int xi = int(x);
    int yi = int(y);
    int xm = (xi - 1 + W) % W;
    int xp = (xi + 1) % W;
    int ym = max(yi - 1, 0);
    int yp = min(yi + 1, H - 1);
    float h_l = Height.height[xm + yi * W];
    float h_r = Height.height[xp + yi * W];
    float h_d = Height.height[xi + ym * W];
    float h_u = Height.height[xi + yp * W];
    vec2 slope = vec2((h_r - h_l) * 0.5, (h_u - h_d) * 0.5);
    float slope_mag = clamp(length(slope) * 14.0, 0.0, 1.0);
    vec2 wind = vec2(WindU.wind_u[i], WindV.wind_v[i]);
    float wind_mag = length(wind);
    vec2 wind_dir = (wind_mag > 0.0001) ? (wind / wind_mag) : vec2(0.0, 0.0);
    float upslope = clamp(dot(wind_dir, slope) * 20.0, 0.0, 1.0);
    float relief_lift = smoothstep(0.08, 0.78, slope_mag + upslope * 0.65);

    float seed_f = float(PC.seed % 4096);
    vec2 p = vec2(float(x), float(y));
    vec2 p_seeded = p + vec2(seed_f * 0.137, seed_f * 0.071);

    // Planet-scale weather regimes.
    vec2 regime_p = p_seeded * 0.004 + vec2(PC.phase * 0.14, -PC.phase * 0.10);
    regime_p.x += sin(6.28318 * (float(y) / max(1.0, float(H) - 1.0) * 0.8 + PC.phase * 0.11)) * 5.0;
    float regime = fbm2(regime_p, 4) * 0.5 + 0.5;
    float regime_mask = smoothstep(0.30, 0.72, regime);

    // Domain-warped mid/high frequencies prevent latitude striping.
    vec2 warp_a = curl2(p_seeded * 0.020 + vec2(PC.phase * 0.22, -PC.phase * 0.18));
    vec2 warp_b = curl2(p_seeded * 0.045 + vec2(-PC.phase * 0.31, PC.phase * 0.27));

    vec2 mid_p = p_seeded * 0.016 + warp_a * 2.6 + vec2(PC.phase * 0.55, -PC.phase * 0.41);
    float mid = fbm2(mid_p, 5) * 0.5 + 0.5;
    float mid_core = smoothstep(0.44, 0.80, mid);

    float cell = worley2(mid_p * 1.05 + warp_b * 1.2);
    float billow = exp(-cell * 2.25);
    billow = smoothstep(0.22, 0.90, billow);

    vec2 high_p = p_seeded * 0.046 + warp_b * 3.4 + vec2(PC.phase * 0.95, -PC.phase * 0.73);
    float wisps = fbm2(high_p, 3) * 0.5 + 0.5;
    wisps = smoothstep(0.48, 0.84, wisps);

    float structure = mid_core * 0.54 + billow * 0.34 + wisps * 0.12;
    structure *= mix(0.70, 1.25, regime_mask);

    // Physical drivers for cloud formation.
    // Forested land recycles moisture (evapotranspiration), arid land suppresses cloud seed potential.
    float ocean_boost = land ? 0.0 : (0.20 + 0.22 * warm + 0.12 * night);
    float land_evap_supply = land ? mix(0.35, 1.30, veg) : 1.0;
    float veg_boost = land ? (0.32 * smoothstep(0.25, 0.95, veg) * (0.35 + 0.65 * warm) * (0.35 + 0.65 * daylight)) : 0.0;
    float arid_penalty = land ? (0.30 * (1.0 - veg) * (0.55 + 0.45 * daylight) * (0.45 + 0.55 * warm)) : 0.0;
    float orographic_lift = land ? (0.22 * humid * relief_lift * (0.45 + 0.55 * daylight) * (0.40 + 0.60 * clamp01(wind_mag * 1.5))) : 0.0;
    float polar_stratus = smoothstep(0.56, 0.98, abs_lat) * humidity * (0.08 + 0.18 * night + 0.10 * (1.0 - warm));
    float convective = land ? (0.18 * daylight * warm) : (0.10 * daylight * warm);
    float night_stratus = land ? (0.06 * night * humidity) : (0.16 * night * humidity);
    float lat_dry = smoothstep(0.72, 1.0, abs_lat) * 0.08 * (1.0 - 0.45 * humidity);

    float potential = humid * (0.54 + 0.46 * warm) * land_evap_supply
                    + ocean_boost
                    + veg_boost
                    + orographic_lift
                    + polar_stratus
                    + convective
                    + night_stratus
                    - lat_dry
                    - arid_penalty;
    potential = clamp01(potential);

    float threshold = mix(0.66, 0.36, potential);
    float density = smoothstep(threshold - 0.11, threshold + 0.12, structure);
    float anvil = smoothstep(0.62, 0.92, wisps + mid * 0.35) * (0.35 + 0.65 * daylight * warm);

    float cov = density * (0.44 + 0.56 * potential) + anvil * 0.16 * potential;
    cov *= mix(0.82, 1.15, regime_mask);
    cov += humidity * 0.08 * regime_mask;
    cov = clamp01(cov);
    Cloud.cloud[i] = cov;
}
