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

uniform float cloud_opacity = 1.0;
uniform float cloud_min = 0.2;
uniform float cloud_levels = 8.0;
uniform float cloud_power = 0.7;
uniform float cloud_brightness = 1.1;
uniform float cloud_night_alpha = 0.35;

void fragment() {
    vec2 world_pos = UV * map_dimensions;
    vec2 world_cell = floor(world_pos);
    world_cell = clamp(world_cell, vec2(0.0), map_dimensions - vec2(1.0));
    vec2 world_uv = (world_cell + vec2(0.5)) / map_dimensions;

    float cloud_cov = (use_cloud_texture != 0) ? texture(cloud_texture, world_uv).r : texture(world_data_3, world_uv).b;
    float light = (use_light_texture != 0) ? texture(light_texture, world_uv).r : texture(world_data_1, world_uv).a;

    float c = clamp((cloud_cov - cloud_min) / max(0.0001, 1.0 - cloud_min), 0.0, 1.0);
    c = pow(c, cloud_power);
    float levels = max(1.0, cloud_levels);
    float denom = max(1.0, levels - 1.0);
    float q_hard = floor(c * levels + 0.0001) / denom;
    float q = mix(c, q_hard, 0.20);
    float alpha = clamp(q, 0.0, 1.0) * cloud_opacity;

    // Dim clouds at night similarly to the map tiles.
    float light_clamped = clamp(light, 0.0, 1.0);
    alpha *= mix(cloud_night_alpha, 1.0, light_clamped);

    if (alpha <= 0.001) {
        COLOR = vec4(0.0);
    } else {
    float brightness = mix(0.35, 1.0, light_clamped) * cloud_brightness;
    COLOR = vec4(vec3(brightness), alpha);
    }
}
