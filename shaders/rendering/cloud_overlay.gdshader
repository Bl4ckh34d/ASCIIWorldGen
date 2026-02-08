shader_type canvas_item;

// Cloud tile overlay shader
// Draws white tiles with varying opacity based on cloud coverage.

uniform sampler2D world_data_1; // height, temp, moisture, light
uniform sampler2D world_data_3; // turquoise_strength, shelf_noise, clouds, boundary
uniform sampler2D cloud_texture;
uniform int use_cloud_texture = 0;
uniform sampler2D light_texture;
uniform int use_light_texture = 0;
uniform vec2 map_dimensions;
uniform float day_of_year = 0.0;
uniform float time_of_day = 0.0;

uniform float cloud_opacity = 0.90;
uniform float cloud_min = 0.18;
uniform float cloud_levels = 10.0;
uniform float cloud_power = 0.95;
uniform float cloud_brightness = 1.0;
uniform float cloud_night_alpha = 0.28;

const float CLOUD_PI = 3.14159265359;
const float CLOUD_TAU = 6.28318530718;
const float SOLAR_TILT = 0.5235987756; // 30 deg

vec3 _dir_from_lon_lat(float lon, float lat) {
    float cl = cos(lat);
    return vec3(cl * cos(lon), cl * sin(lon), sin(lat));
}

void fragment() {
    vec2 world_pos = UV * map_dimensions;
    vec2 world_cell = floor(world_pos);
    world_cell = clamp(world_cell, vec2(0.0), map_dimensions - vec2(1.0));
    vec2 world_uv = (world_cell + vec2(0.5)) / map_dimensions;

    float cloud_cov = (use_cloud_texture != 0) ? texture(cloud_texture, world_uv).r : texture(world_data_3, world_uv).b;

    float c = clamp((cloud_cov - cloud_min) / max(0.0001, 1.0 - cloud_min), 0.0, 1.0);
    c = pow(c, cloud_power);
    float levels = max(1.0, cloud_levels);
    float denom = max(1.0, levels - 1.0);
    float q_hard = floor(c * levels + 0.0001) / denom;
    float q = mix(c, q_hard, 0.08);
    float alpha = clamp(q, 0.0, 1.0) * cloud_opacity;

    // Drive cloud visibility from pure sun geometry (season/day-night), not
    // relief-shaded ground lighting, so terrain shadows don't show through.
    float lon = CLOUD_TAU * (world_cell.x / max(1.0, map_dimensions.x));
    float lat_norm = 0.5 - (world_cell.y / max(1.0, map_dimensions.y - 1.0));
    float phi = lat_norm * CLOUD_PI;
    float decl = SOLAR_TILT * cos(CLOUD_TAU * day_of_year);
    float sun_lon = -CLOUD_TAU * time_of_day;
    float s = dot(_dir_from_lon_lat(lon, phi), _dir_from_lon_lat(sun_lon, decl));
    float day_visibility = smoothstep(-0.16, 0.58, s);
    alpha *= mix(cloud_night_alpha, 1.0, day_visibility);
    // Suppress blotchy cloud fragments in deep night.
    alpha *= smoothstep(-0.30, 0.12, day_visibility);

    if (alpha <= 0.001) {
        COLOR = vec4(0.0);
    } else {
    float brightness = mix(0.46, 1.0, day_visibility) * cloud_brightness;
    COLOR = vec4(vec3(brightness), alpha);
    }
}
