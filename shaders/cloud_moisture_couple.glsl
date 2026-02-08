#[compute]
#version 450
// File: res://shaders/cloud_moisture_couple.glsl
// Physically-inspired moisture evolution driven by clouds, temperature, surface type, and day/night.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer CloudBuf { float cloud[]; } Cloud;
layout(std430, set = 0, binding = 1) buffer MoistBuf { float moist[]; } Moist;
layout(std430, set = 0, binding = 2) buffer LandBuf { int land[]; } Land;
layout(std430, set = 0, binding = 3) buffer TempBuf { float temp[]; } Temp;
layout(std430, set = 0, binding = 4) buffer LightBuf { float light[]; } Light;
layout(std430, set = 0, binding = 5) buffer BiomeBuf { int biome_id[]; } Biome;

layout(push_constant) uniform Params {
    int width;
    int height;
    float dt_days;
    float rain_land;
    float rain_ocean;
    float evap_land;
    float evap_ocean;
    float mix_rate;
    float relax_rate;
    float condense_rate;
    float precip_rate;
    float vegetation_boost;
    float cloud_dissip_rate;
} PC;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

float biome_veg_factor(int b){
    switch (b) {
        case 10:
            return 0.95;
        case 11:
        case 12:
        case 13:
        case 14:
        case 15:
            return 1.0;
        case 22:
            return 0.28;
        case 23:
            return 0.22;
        case 27:
            return 0.08;
        case 6:
        case 7:
        case 21:
            return 0.48;
        case 29:
        case 30:
        case 33:
            return 0.16;
        case 36:
        case 37:
        case 40:
            return 0.12;
        case 16:
        case 18:
        case 19:
            return 0.20;
        case 34:
            return 0.10;
        case 41:
            return 0.08;
        case 20:
            return 0.18;
        case 2:
            return 0.12;
        case 3:
        case 4:
        case 5:
        case 25:
        case 26:
        case 28:
            return 0.04;
        default:
            return 0.16;
    }
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(x) + int(y) * PC.width;

    float c = clamp01(Cloud.cloud[i]);
    float m = clamp01(Moist.moist[i]);
    float t = clamp01(Temp.temp[i]);
    float light_v = clamp01(Light.light[i]);
    bool is_land = Land.land[i] != 0;

    float day = smoothstep(0.18, 0.90, light_v);
    float night = 1.0 - day;
    float warm = smoothstep(0.30, 0.90, t);
    float veg = is_land ? biome_veg_factor(Biome.biome_id[i]) : 0.0;

    float evap_base = is_land ? PC.evap_land : PC.evap_ocean;
    float rain_base = is_land ? PC.rain_land : PC.rain_ocean;
    float land_evap_supply = is_land ? mix(0.25, 1.18, veg) : 1.0;
    float veg_dense = smoothstep(0.20, 0.95, veg);
    float thermal_evap = is_land ? (0.28 + 1.00 * warm) : (0.45 + 0.95 * warm);

    float evap_surface = evap_base
                       * thermal_evap
                       * (is_land ? (0.30 + 0.90 * day) : (0.55 + 0.60 * day))
                       * (1.0 - 0.30 * c)
                       * land_evap_supply;
    float transp = is_land
        ? evap_base * PC.vegetation_boost * mix(0.08, 1.30, veg_dense) * (0.15 + 0.85 * warm) * (0.25 + 0.75 * day) * (1.0 - 0.25 * c)
        : 0.0;

    float target = is_land
        ? clamp01(0.20 + 0.20 * warm + 0.40 * veg + 0.12 * night - 0.10 * (1.0 - veg))
        : clamp01(0.60 + 0.28 * warm + 0.08 * night);
    float relax = (PC.relax_rate + PC.mix_rate) * (target - m);

    float condense = PC.condense_rate
                   * c
                   * (0.35 + 0.65 * night + max(0.0, m - target) * 0.5);
    float precip = rain_base
                 * PC.precip_rate
                 * c * c
                 * (0.40 + 0.60 * night);

    float delta = PC.dt_days * (evap_surface + transp + relax - condense - precip);
    m = clamp01(m + delta);
    float subsat = clamp01(target - m + 0.20);
    float rainout_loss = PC.cloud_dissip_rate * precip * (0.40 + 0.60 * night);
    float dry_loss = PC.cloud_dissip_rate * subsat * (0.25 + 0.75 * day);
    float loss = clamp01(PC.dt_days * (rainout_loss + dry_loss));
    c = clamp01(c * (1.0 - loss));
    Moist.moist[i] = m;
    Cloud.cloud[i] = c;
}
