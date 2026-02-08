#[compute]
#version 450
// File: res://shaders/day_night_light.glsl
// Compute per-tile daylight factor in [0..1] from latitude, day-of-year (season), and time-of-day.
// No inputs other than dimensions; writes to a light buffer.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer LightBuf { float light[]; } Light;
layout(std430, set = 0, binding = 1) readonly buffer HeightBuf { float height[]; } Height;

layout(push_constant) uniform Params {
    int width;
    int height;
    float day_of_year;  // 0..1
    float time_of_day;  // 0..1
    float base;         // base brightness (e.g., 0.25)
    float contrast;     // scale of daylight term (e.g., 0.75)
    float moon_count;   // 0..3
    float moon_seed;    // deterministic seed from intro scene
    float moon_shadow_strength; // 0..1
    float sim_days;     // continuous simulation time in days
} PC;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;
// Temporary test mode: force a daily eclipse pass so shadow behavior can be validated quickly.
const bool DEBUG_FORCE_DAILY_ECLIPSE = false;

float clamp01(float v){ return clamp(v, 0.0, 1.0); }

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 dir_from_lon_lat(float lon, float lat) {
    float cl = cos(lat);
    return vec3(cl * cos(lon), cl * sin(lon), sin(lat));
}

float angular_distance(vec3 a, vec3 b) {
    return acos(clamp(dot(a, b), -1.0, 1.0));
}

mat3 rot_x(float a) {
    float c = cos(a);
    float s = sin(a);
    return mat3(
        vec3(1.0, 0.0, 0.0),
        vec3(0.0, c, -s),
        vec3(0.0, s, c)
    );
}

mat3 rot_z(float a) {
    float c = cos(a);
    float s = sin(a);
    return mat3(
        vec3(c, -s, 0.0),
        vec3(s, c, 0.0),
        vec3(0.0, 0.0, 1.0)
    );
}

float moon_shadow_factor(vec3 n, vec3 sun_dir, float sun_dot) {
    if (DEBUG_FORCE_DAILY_ECLIPSE) {
        float day_phase = fract(max(0.0, PC.sim_days)); // one full sweep per in-game day
        float shadow_lon = -TAU * day_phase + 0.45 * sin(PC.sim_days * 0.41);
        float shadow_lat = 0.18 * sin(PC.sim_days * 0.83);
        vec3 shadow_axis = dir_from_lon_lat(shadow_lon, shadow_lat);
        float dist = angular_distance(n, shadow_axis);
        float radius = 0.030;
        float penumbra = 0.085;
        float umbra = 1.0 - smoothstep(radius, radius + penumbra, dist);
        umbra *= smoothstep(0.02, 0.30, sun_dot);
        float strength = clamp01(PC.moon_shadow_strength + 0.35);
        return clamp01(umbra * 0.70 * strength);
    }

    int moon_count = clamp(int(floor(PC.moon_count + 0.5)), 0, 3);
    if (moon_count <= 0 || sun_dot <= 0.0) {
        return 0.0;
    }

    float moon_seed = max(0.0001, PC.moon_seed);
    float t_days = max(0.0, PC.sim_days);
    float strongest = 0.0;

    for (int mi = 0; mi < 3; mi++) {
        if (mi >= moon_count) {
            continue;
        }

        float fi = float(mi);
        float h0 = hash12(vec2(moon_seed * 0.071 + fi * 11.13, moon_seed * 0.037 + fi * 3.97));
        float h1 = hash12(vec2(moon_seed * 0.113 + fi * 7.21, moon_seed * 0.053 + fi * 5.61));
        float h2 = hash12(vec2(moon_seed * 0.167 + fi * 2.83, moon_seed * 0.029 + fi * 13.17));
        float h3 = hash12(vec2(moon_seed * 0.197 + fi * 17.11, moon_seed * 0.089 + fi * 19.73));
        float h4 = hash12(vec2(moon_seed * 0.251 + fi * 23.03, moon_seed * 0.131 + fi * 29.31));
        float h5 = hash12(vec2(moon_seed * 0.307 + fi * 31.39, moon_seed * 0.149 + fi * 37.71));

        // Reuse scene-2 style orbit scaffolding and convert to days for scene-3 cadence.
        float orbit_mul = 2.80 + fi * 1.45 + h0 * 0.40;
        float orbit_period_days = 5.5 + pow(max(1.0, orbit_mul), 1.5) * 4.6;
        float omega = TAU / max(1.0, orbit_period_days);
        float phase = h2 * TAU;
        float incl = radians(2.0 + h1 * 11.0);
        float node = h3 * TAU;
        float precess = t_days * (0.003 + h5 * 0.004);
        float ang = t_days * omega + phase;
        float ecc = mix(0.03, 0.22, h5);
        float orbital_dist = orbit_mul * (1.0 + ecc * sin(ang + h1 * TAU));
        float dist_norm = clamp((orbital_dist - 2.2) / 4.8, 0.0, 1.0);

        vec3 moon_dir = vec3(cos(ang), sin(ang), 0.0);
        moon_dir = rot_x(incl) * moon_dir;
        moon_dir = rot_z(node + precess) * moon_dir;
        moon_dir = normalize(moon_dir);

        // New-moon conjunction + node proximity gate makes eclipses occasional.
        float align = dot(moon_dir, sun_dir);
        // Farther moons need tighter conjunction to produce visible eclipses.
        float align_lo = mix(0.992, 0.997, dist_norm);
        float align_hi = mix(0.9994, 0.99992, dist_norm);
        float align_gate = smoothstep(align_lo, align_hi, align);
        float node_gate = 1.0 - smoothstep(0.12, 0.68, abs(moon_dir.z));
        float event_gate = align_gate * node_gate;
        if (event_gate <= 0.0001) {
            continue;
        }

        vec3 shadow_axis = normalize(mix(sun_dir, moon_dir, 0.82));
        float dist = angular_distance(n, shadow_axis);
        // Apparent angular size falls with distance; penumbra widens with distance.
        float radius = mix(0.060, 0.018, dist_norm) * mix(0.78, 1.20, h4);
        float penumbra = radius * mix(1.4, 6.4, dist_norm) * mix(0.9, 1.25, h0);
        float umbra = 1.0 - smoothstep(radius, radius + penumbra, dist);
        umbra *= smoothstep(0.03, 0.35, sun_dot);

        float moon_strength = mix(0.24, 0.55, h4) * mix(1.20, 0.58, dist_norm) * event_gate;
        strongest = max(strongest, umbra * moon_strength);
    }

    return clamp01(strongest * clamp01(PC.moon_shadow_strength));
}

float sample_height_wrap_x(float fx, float fy, int W, int H) {
    float xw = mod(fx, float(W));
    if (xw < 0.0) {
        xw += float(W);
    }
    float yc = clamp(fy, 0.0, float(H - 1));
    int x0 = int(floor(xw));
    int y0 = int(floor(yc));
    int x1 = (x0 + 1) % max(1, W);
    int y1 = min(y0 + 1, H - 1);
    float tx = xw - float(x0);
    float ty = yc - float(y0);
    float h00 = Height.height[x0 + y0 * W];
    float h10 = Height.height[x1 + y0 * W];
    float h01 = Height.height[x0 + y1 * W];
    float h11 = Height.height[x1 + y1 * W];
    float hx0 = mix(h00, h10, tx);
    float hx1 = mix(h01, h11, tx);
    return mix(hx0, hx1, ty);
}

float terrain_horizon_occlusion(
        int xi,
        int yi,
        float sun_dot,
        vec3 sun_dir,
        vec3 east,
        vec3 north,
        int W,
        int H
    ) {
    if (sun_dot <= 0.0) {
        return 0.0;
    }
    vec2 sun_h = vec2(dot(sun_dir, east), dot(sun_dir, north));
    float hlen = length(sun_h);
    if (hlen <= 0.0001) {
        return 0.0;
    }
    vec2 dir = sun_h / hlen;
    // Map coordinates: +x east, +y south.
    float dx = dir.x;
    float dy = -dir.y;
    float h0 = max(0.0, Height.height[xi + yi * W]);
    float max_horizon_slope = -1e6;
    const int RAY_STEPS = 7;
    const float HEIGHT_EXAG = 0.34;
    for (int sidx = 1; sidx <= RAY_STEPS; sidx++) {
        float dist = float(sidx);
        float sx = float(xi) + dx * dist;
        float sy = float(yi) + dy * dist;
        float hs = max(0.0, sample_height_wrap_x(sx, sy, W, H));
        float slope = ((hs - h0) * HEIGHT_EXAG) / max(1.0, dist);
        max_horizon_slope = max(max_horizon_slope, slope);
    }
    float sun_slope = tan(max(0.0, asin(clamp(sun_dot, -1.0, 1.0))));
    float excess = max_horizon_slope - sun_slope;
    float occ = smoothstep(0.01, 0.08, excess);
    return clamp01(occ);
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) { return; }
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    // Latitude phi in radians
    float lat_norm = 0.5 - (float(y) / max(1.0, float(H) - 1.0)); // -0.5..+0.5 (north positive)
    float phi = lat_norm * PI; // -pi/2..+pi/2

    // Solar declination delta (in radians); Earth tilt 23.44 deg
    // ENHANCED: Make seasonal changes more dramatic and faster
    float tilt = radians(30.0); // Increased from 23.44 deg to 30 deg for more dramatic effect
    float delta = tilt * cos(TAU * PC.day_of_year);
    
    // Debug: you can see seasonal effect by checking delta value
    // delta varies from -30 deg to +30 deg throughout the year

    float lon = TAU * (float(x) / float(max(1, W)));
    vec3 n = dir_from_lon_lat(lon, phi);
    float sun_lon = -TAU * PC.time_of_day;
    vec3 sun_dir = dir_from_lon_lat(sun_lon, delta);
    vec3 east = vec3(-sin(lon), cos(lon), 0.0);
    vec3 north = vec3(-sin(phi) * cos(lon), -sin(phi) * sin(lon), cos(phi));

    // Sun elevation (dot with surface normal) drives the terminator geometry.
    float s = dot(n, sun_dir);

    float daylight = 0.0;
    float lat_abs = abs(lat_norm) * 2.0;
    // Night floor is the darkest baseline; eclipse shading cannot go below this.
    float night_floor = 0.010;
    // Smooth high-latitude winter darkening (avoids hard latitude "scissor" lines).
    float hemi_dot = lat_norm * delta;
    float opposite_hemi = 1.0 - smoothstep(-0.02, 0.02, hemi_dot);
    float polar_weight = smoothstep(0.45, 0.95, lat_abs);
    float season_weight = smoothstep(radians(10.0), radians(28.0), abs(delta));
    float winter_darkening = opposite_hemi * polar_weight * season_weight * clamp(lat_abs * abs(delta) * 1.35, 0.0, 1.0);
    night_floor = mix(0.010, 0.002, winter_darkening);
    
    // Physically driven light model:
    // - direct beam from solar incidence
    // - diffuse sky contribution
    // - twilight scattering near/just below horizon
    // This keeps the same overall silhouette while removing hard branch thresholds.
    float mu = clamp01(s);
    float air_mass = 1.0 / max(0.08, mu + 0.08);
    float transmittance = exp(-0.18 * air_mass);
    float direct_light = mu * transmittance;
    float diffuse_light = (0.22 + 0.55 * mu) * (1.0 - transmittance);
    float twilight_light = 0.24 * smoothstep(-0.12, 0.03, s);
    float solar_lighting = clamp01(direct_light + diffuse_light + twilight_light);

    // Mild summer polar brightening from atmosphere/long-day effect.
    float summer_polar = smoothstep(0.55, 0.98, lat_abs)
        * smoothstep(0.00, 0.28, hemi_dot)
        * smoothstep(radians(8.0), radians(30.0), abs(delta));
    solar_lighting = clamp01(solar_lighting + 0.08 * summer_polar);
    // Terrain-driven horizon occlusion: subtly irregularize the terminator at
    // local scales while preserving global day/night/season geometry.
    float term_band = 1.0 - smoothstep(0.14, 0.50, max(0.0, s));
    float h_occ = terrain_horizon_occlusion(int(x), int(y), s, sun_dir, east, north, W, H) * term_band;

    float daylight_base = night_floor + (1.0 - night_floor) * solar_lighting;
    float night_darkness_max = 1.0 - night_floor;
    float base_darkness = clamp01(1.0 - daylight_base);
    // Add horizon shadow directly in darkness space so twilight does not wash it out.
    float horizon_darkness = 0.26 * h_occ;

    // Eclipse darkening only affects daylight above the night baseline.
    // This makes moon shadows melt into the terminator without stacking past night darkness.
    float moon_shadow = moon_shadow_factor(n, sun_dir, s);
    float day_excess = max(0.0, daylight_base - night_floor);
    float moon_darkness = day_excess * moon_shadow;

    // Terrain relief shading (hillshade): gentle, strongest near low sun.
    // Keep this much weaker than the day/night baseline darkness.
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
    float dzdx = 0.5 * (h_r - h_l);
    float dzdy = 0.5 * (h_u - h_d);
    float slope_mag = clamp(length(vec2(dzdx, dzdy)) * 12.0, 0.0, 1.0);
    vec3 sun_local = normalize(vec3(dot(sun_dir, east), dot(sun_dir, north), max(0.02, s)));
    vec3 terrain_n = normalize(vec3(-dzdx * 11.0, -dzdy * 11.0, 1.0));
    float relief_lambert = max(dot(terrain_n, sun_local), 0.0);
    // Keep relief active well into twilight so the bright terminator edge does not erase it.
    float twilight_relief = smoothstep(-0.30, 0.02, s);
    float relief_shadow = (1.0 - relief_lambert)
        * twilight_relief
        * smoothstep(0.03, 0.50, slope_mag);
    float low_sun_boost = 1.0 - smoothstep(0.10, 0.75, max(0.0, s));
    float relief_strength = 0.04 + 0.09 * low_sun_boost;
    float relief_blend = clamp(relief_strength * relief_shadow, 0.0, 0.55);
    // Final additive composition in darkness space.
    float darkness = min(night_darkness_max, base_darkness + horizon_darkness + moon_darkness + relief_blend);
    daylight = 1.0 - darkness;
    
    // Apply base lighting and contrast
    float b = clamp01(PC.base + PC.contrast * daylight);
    Light.light[i] = b;
}
