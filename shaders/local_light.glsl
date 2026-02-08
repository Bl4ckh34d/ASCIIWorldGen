#[compute]
#version 450
// File: res://shaders/local_light.glsl
// Compute per-tile light factor for regional/local map views.
// Uses fixed lon/lat (tile-scale approximation) + local hillshade from the provided height buffer.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer LightBuf { float light[]; } Light;
layout(std430, set = 0, binding = 1) readonly buffer HeightBuf { float height[]; } Height;

layout(push_constant) uniform Params {
    int width;
    int height;
    float day_of_year;   // 0..1
    float time_of_day;   // 0..1
    float base;          // base brightness floor
    float contrast;      // daylight contrast
    float fixed_lon;     // radians
    float fixed_phi;     // radians
    float sim_days;      // for future use
    float relief_strength; // 0..1-ish
} PC;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;
const float SOLAR_TILT = 0.5235987756; // 30 deg

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

vec3 dir_from_lon_lat(float lon, float lat) {
    float cl = cos(lat);
    return vec3(cl * cos(lon), cl * sin(lon), sin(lat));
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    float decl = SOLAR_TILT * cos(TAU * PC.day_of_year);
    float sun_lon = -TAU * PC.time_of_day;
    vec3 sun_dir = dir_from_lon_lat(sun_lon, decl);
    vec3 n = dir_from_lon_lat(PC.fixed_lon, PC.fixed_phi);
    float s = dot(n, sun_dir);

    // Daylight model: direct + diffuse + twilight (same intent as world light shader, simplified).
    float lat_norm = PC.fixed_phi / PI; // [-0.5..0.5]
    float lat_abs = abs(lat_norm) * 2.0;
    float night_floor = 0.010;
    float hemi_dot = lat_norm * decl;
    float opposite_hemi = 1.0 - smoothstep(-0.02, 0.02, hemi_dot);
    float polar_weight = smoothstep(0.45, 0.95, lat_abs);
    float season_weight = smoothstep(radians(10.0), radians(28.0), abs(decl));
    float winter_darkening = opposite_hemi * polar_weight * season_weight * clamp(lat_abs * abs(decl) * 1.35, 0.0, 1.0);
    night_floor = mix(0.010, 0.002, winter_darkening);

    float mu = clamp01(s);
    float air_mass = 1.0 / max(0.08, mu + 0.08);
    float transmittance = exp(-0.18 * air_mass);
    float direct_light = mu * transmittance;
    float diffuse_light = (0.22 + 0.55 * mu) * (1.0 - transmittance);
    float twilight_light = 0.24 * smoothstep(-0.12, 0.03, s);
    float solar_lighting = clamp01(direct_light + diffuse_light + twilight_light);

    float summer_polar = smoothstep(0.55, 0.98, lat_abs)
        * smoothstep(0.00, 0.28, hemi_dot)
        * smoothstep(radians(8.0), radians(30.0), abs(decl));
    solar_lighting = clamp01(solar_lighting + 0.08 * summer_polar);

    float daylight_base = night_floor + (1.0 - night_floor) * solar_lighting;
    float base_darkness = clamp01(1.0 - daylight_base);

    // Local hillshade (terrain relief) from height buffer.
    int xi = int(x);
    int yi = int(y);
    int xm = max(xi - 1, 0);
    int xp = min(xi + 1, W - 1);
    int ym = max(yi - 1, 0);
    int yp = min(yi + 1, H - 1);
    float h_l = Height.height[xm + yi * W];
    float h_r = Height.height[xp + yi * W];
    float h_d = Height.height[xi + ym * W];
    float h_u = Height.height[xi + yp * W];
    float dzdx = 0.5 * (h_r - h_l);
    float dzdy = 0.5 * (h_u - h_d);
    float slope_mag = clamp(length(vec2(dzdx, dzdy)) * 12.0, 0.0, 1.0);

    // Convert global sun direction into local tangent basis at this lon/lat.
    float lon = PC.fixed_lon;
    float phi = PC.fixed_phi;
    vec3 east = vec3(-sin(lon), cos(lon), 0.0);
    vec3 north = vec3(-sin(phi) * cos(lon), -sin(phi) * sin(lon), cos(phi));
    vec3 sun_local = normalize(vec3(dot(sun_dir, east), dot(sun_dir, north), max(0.02, s)));
    vec3 terrain_n = normalize(vec3(-dzdx * 11.0, -dzdy * 11.0, 1.0));
    float relief_lambert = max(dot(terrain_n, sun_local), 0.0);
    float relief_shadow = (1.0 - relief_lambert) * smoothstep(0.03, 0.50, slope_mag);
    float low_sun_boost = 1.0 - smoothstep(0.10, 0.75, max(0.0, s));
    float rel_str = max(0.0, PC.relief_strength) * (0.55 + 0.45 * low_sun_boost);
    float relief_blend = clamp(rel_str * relief_shadow, 0.0, 0.55);

    float darkness = min(1.0 - night_floor, base_darkness + relief_blend);
    float daylight = 1.0 - darkness;
    float out_light = clamp01(PC.base + PC.contrast * daylight);
    Light.light[i] = out_light;
}

