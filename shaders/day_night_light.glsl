#[compute]
#version 450
// File: res://shaders/day_night_light.glsl
// Compute per-tile daylight factor in [0..1] from latitude, day-of-year (season), and time-of-day.
// No inputs other than dimensions; writes to a light buffer.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer LightBuf { float light[]; } Light;

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

    // Sun elevation (dot with surface normal) creates the terminator curve.
    float s = dot(n, sun_dir);
    
    // Enhanced terminator for dramatic seasonal visibility
    float daylight = 0.0;
    float lat_abs = abs(lat_norm) * 2.0;
    // Night floor is the darkest baseline; eclipse shading cannot go below this.
    float night_floor = 0.1;
    bool opposite_hemisphere = (lat_norm * delta) < 0.0;
    if (opposite_hemisphere && lat_abs > 0.6 && abs(delta) > radians(15.0)) {
        night_floor = max(0.05, night_floor * (1.0 - lat_abs * abs(delta) * 1.5));
    }
    
    // Create extremely sharp terminator boundary
    float terminator_threshold = 0.02; // Very thin twilight zone
    
    if (s > terminator_threshold) {
        // Day side - bright
        daylight = 1.0;
        
        // Add seasonal summer brightness boost at high latitudes  
        bool same_hemisphere_as_sun = (lat_norm * delta) > 0.0;
        if (same_hemisphere_as_sun && lat_abs > 0.6) {
            // Summer hemisphere high latitudes get extra brightness
            daylight = min(1.0, 1.0 + lat_abs * abs(delta) * 2.0);
        }
        
    } else if (s > -terminator_threshold) {
        // Twilight zone - creates the visible terminator line
        float twilight = (s + terminator_threshold) / (2.0 * terminator_threshold);
        daylight = mix(night_floor, 0.6, twilight); // Blend from night floor into dim twilight
        
    } else {
        // Night side
        daylight = night_floor;
    }

    // Eclipse darkening only affects daylight above the night baseline.
    // This makes moon shadows melt into the terminator without stacking past night darkness.
    float moon_shadow = moon_shadow_factor(n, sun_dir, s);
    float day_excess = max(0.0, daylight - night_floor);
    daylight = night_floor + day_excess * (1.0 - moon_shadow);
    
    // Apply base lighting and contrast
    float b = clamp01(PC.base + PC.contrast * daylight);
    Light.light[i] = b;
}
