shader_type canvas_item;

// ASCII Quad Rendering Shader
// High-performance GPU-based ASCII map rendering

// Texture uniforms
uniform sampler2D font_atlas;
uniform sampler2D world_data_1; // height, temp, moisture, light
uniform sampler2D world_data_2; // biome, land, char_idx, flags
uniform sampler2D world_data_3; // turquoise_strength, shelf_noise, clouds, boundary
uniform sampler2D cloud_texture;
uniform sampler2D light_texture;
uniform int use_cloud_texture = 0;
uniform int use_light_texture = 0;
uniform sampler2D river_texture;
uniform int use_river_texture = 0;
uniform sampler2D biome_texture;
uniform int use_biome_texture = 0;
uniform sampler2D lava_texture;
uniform int use_lava_texture = 0;
uniform sampler2D society_overlay;
uniform int use_society_overlay = 0;
uniform sampler2D world_data_4; // lake, river, lava, lake_level_norm
uniform sampler2D color_palette;
uniform int debug_mode = 0;
uniform float sea_level = 0.0;
uniform float cloud_shadow_strength = 0.14;
uniform float cloud_light_strength = 0.25;
uniform vec2 cloud_shadow_offset = vec2(1.5, 1.0);
uniform float water_wave_strength = 0.0;
uniform float day_of_year = 0.0;
uniform float time_of_day = 0.0;
// When enabled, override lon/lat for solar geometry (regional/local map views).
uniform int use_fixed_lonlat = 0;
uniform float fixed_lon = 0.0; // radians
uniform float fixed_phi = 0.0; // radians, [-PI/2..PI/2]
uniform int use_glyphs = 0;
uniform int bedrock_only_mode = 0;

// Map parameters
uniform vec2 map_dimensions;
uniform vec2 cell_size;
uniform vec2 atlas_uv_size; // 1/16, 1/6

// View window parameters (optional).
// When display_dimensions is (0,0), the shader uses map_dimensions (legacy behavior).
// Otherwise, it renders only the sub-rectangle of the data textures starting at
// display_origin (in cells) with size display_dimensions (in cells), optionally
// shifted by scroll_offset (fractional cells) for smooth scrolling.
uniform vec2 display_dimensions = vec2(0.0, 0.0);
uniform vec2 display_origin = vec2(0.0, 0.0);
uniform vec2 scroll_offset = vec2(0.0, 0.0);
uniform vec2 noise_world_origin = vec2(0.0, 0.0);

// Hover overlay parameters (tile coordinates; negative disables)
uniform vec2 hover_cell = vec2(-1.0, -1.0);

// Character atlas layout (16x6 grid)
const float CHARS_PER_ROW = 16.0;
const float CHARS_PER_COL = 6.0;
const float TOTAL_CHARS = 95.0;
const float CHAR_IDX_TILDE = 94.0; // '~'
const float CHAR_IDX_HASH = 3.0;   // '#'
const float BIOME_OCEAN = 0.0;
const float BIOME_ICE_SHEET = 1.0;
const float MARKER_TREE = 224.0;
const float MARKER_SHRUB = 225.0;
const float MARKER_BOULDER = 226.0;
const float MARKER_REED = 227.0;
const float MARKER_PLAYER_UNDER_CANOPY = 228.0;

const vec3 BEACH_COLOR = vec3(1.0, 0.98, 0.90);
const vec3 ICE_COLOR = vec3(0.85, 0.90, 0.95);
// Dark basalt-like lava field appearance (cool crust), not bright red.
const vec3 LAVA_COLOR = vec3(0.14, 0.13, 0.12);
const float SOLAR_TILT = 0.5235987756; // 30 deg
const float NIGHT_BRIGHTNESS_FLOOR = 0.02;

vec2 get_atlas_uv(float char_index, vec2 char_uv) {
    // Calculate grid position from character index
    float grid_x = mod(char_index, CHARS_PER_ROW);
    float grid_y = floor(char_index / CHARS_PER_ROW);
    
    // Calculate base UV coordinates for this character
    vec2 base_uv = vec2(grid_x / CHARS_PER_ROW, grid_y / CHARS_PER_COL);
    
    // Add character-local UV offset
    vec2 char_uv_offset = char_uv * atlas_uv_size;
    
    return base_uv + char_uv_offset;
}

vec3 sample_biome_color(float biome_id) {
    // Sample color from palette texture
    float palette_u = clamp((biome_id + 0.5) / 256.0, 0.0, 1.0);
    return texture(color_palette, vec2(palette_u, 0.5)).rgb;
}

vec3 water_color_from_height(float height_raw, float sea_level_val, float turq_strength, float shelf_val) {
    float depth = max(0.0, sea_level_val - height_raw);
    float depth_norm = clamp(depth / 0.5, 0.0, 1.0);
    if (shelf_val > 0.0) {
        float shelf_influence = (1.0 - depth_norm) * 0.08;
        depth_norm = clamp(depth_norm - shelf_val * shelf_influence, 0.0, 1.0);
    }
    float shade = pow(1.0 - depth_norm, 2.0);
    vec3 deep = vec3(0.02, 0.10, 0.25);
    vec3 shallow = vec3(0.08, 0.72, 0.92);
    vec3 c = mix(deep, shallow, shade);
    if (turq_strength > 0.0) {
        float overlay = clamp((1.0 - depth_norm) * turq_strength, 0.0, 0.85);
        c = mix(c, vec3(0.10, 0.85, 0.95), overlay);
    }
    return c;
}

float water_wave_signal(vec2 world_cell, vec2 char_uv) {
    vec2 p = world_cell + char_uv;
    float t = TIME * 0.85;
    float w0 = sin((p.x * 0.067 + p.y * 0.123 + t * 0.95) * TAU);
    float w1 = sin((p.x * -0.109 + p.y * 0.081 - t * 1.21) * TAU);
    float w2 = sin((p.x * 0.043 + p.y * 0.157 + t * 0.63) * TAU);
    return clamp(w0 * 0.50 + w1 * 0.32 + w2 * 0.18, -1.0, 1.0);
}

vec2 _wrap_cell_x(vec2 cell) {
    float x = mod(cell.x, map_dimensions.x);
    if (x < 0.0) {
        x += map_dimensions.x;
    }
    float y = clamp(cell.y, 0.0, map_dimensions.y - 1.0);
    return vec2(x, y);
}

float _lake_mask_at(vec2 cell) {
    vec2 wrapped = _wrap_cell_x(cell);
    vec2 uv = (wrapped + vec2(0.5)) / map_dimensions;
    return texture(world_data_4, uv).r;
}

float _river_mask_at(vec2 cell) {
    vec2 wrapped = _wrap_cell_x(cell);
    vec2 uv = (wrapped + vec2(0.5)) / map_dimensions;
    return (use_river_texture != 0) ? texture(river_texture, uv).r : texture(world_data_4, uv).g;
}

float _river_line_mask(vec2 cell, vec2 char_uv) {
    float rL = step(0.5, _river_mask_at(cell + vec2(-1.0, 0.0)));
    float rR = step(0.5, _river_mask_at(cell + vec2(1.0, 0.0)));
    float rU = step(0.5, _river_mask_at(cell + vec2(0.0, -1.0)));
    float rD = step(0.5, _river_mask_at(cell + vec2(0.0, 1.0)));
    float rUL = step(0.5, _river_mask_at(cell + vec2(-1.0, -1.0)));
    float rUR = step(0.5, _river_mask_at(cell + vec2(1.0, -1.0)));
    float rDL = step(0.5, _river_mask_at(cell + vec2(-1.0, 1.0)));
    float rDR = step(0.5, _river_mask_at(cell + vec2(1.0, 1.0)));

    float horiz = max(rL, rR);
    float vert = max(rU, rD);
    float diag1 = max(rUL, rDR); // "\"
    float diag2 = max(rUR, rDL); // "/"

    float thickness = 0.09;
    float soft = 0.04;
    float line_h = 1.0 - smoothstep(thickness, thickness + soft, abs(char_uv.y - 0.5));
    float line_v = 1.0 - smoothstep(thickness, thickness + soft, abs(char_uv.x - 0.5));
    float line_d1 = 1.0 - smoothstep(thickness, thickness + soft, abs(char_uv.x - char_uv.y));
    float line_d2 = 1.0 - smoothstep(thickness, thickness + soft, abs((char_uv.x + char_uv.y) - 1.0));

    float line = 0.0;
    if (horiz > 0.5 && vert < 0.5 && diag1 < 0.5 && diag2 < 0.5) {
        line = line_h;
    } else if (vert > 0.5 && horiz < 0.5 && diag1 < 0.5 && diag2 < 0.5) {
        line = line_v;
    } else if (diag1 > 0.5 && diag2 < 0.5 && horiz < 0.5 && vert < 0.5) {
        line = line_d1;
    } else if (diag2 > 0.5 && diag1 < 0.5 && horiz < 0.5 && vert < 0.5) {
        line = line_d2;
    } else {
        // At junctions/mixed neighborhoods, only draw segments backed by neighbors.
        float seg_h = line_h * horiz;
        float seg_v = line_v * vert;
        float seg_d1 = line_d1 * diag1;
        float seg_d2 = line_d2 * diag2;
        line = max(max(seg_h, seg_v), max(seg_d1, seg_d2));
    }

    if (line <= 0.0) {
        float dist = distance(char_uv, vec2(0.5));
        line = 1.0 - smoothstep(0.2, 0.26, dist);
    }
    return clamp(line, 0.0, 1.0);
}

float _lake_neighbor_count(vec2 cell) {
    float c = 0.0;
    c += step(0.5, _lake_mask_at(cell + vec2(1.0, 0.0)));
    c += step(0.5, _lake_mask_at(cell + vec2(-1.0, 0.0)));
    c += step(0.5, _lake_mask_at(cell + vec2(0.0, 1.0)));
    c += step(0.5, _lake_mask_at(cell + vec2(0.0, -1.0)));
    c += step(0.5, _lake_mask_at(cell + vec2(1.0, 1.0)));
    c += step(0.5, _lake_mask_at(cell + vec2(1.0, -1.0)));
    c += step(0.5, _lake_mask_at(cell + vec2(-1.0, 1.0)));
    c += step(0.5, _lake_mask_at(cell + vec2(-1.0, -1.0)));
    return c;
}

vec3 _dir_from_lon_lat(float lon, float lat) {
    float cl = cos(lat);
    return vec3(cl * cos(lon), cl * sin(lon), sin(lat));
}

float _hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec4 _society_at(vec2 cell) {
    vec2 wrapped = _wrap_cell_x(cell);
    vec2 uv = (wrapped + vec2(0.5)) / map_dimensions;
    return (use_society_overlay != 0) ? texture(society_overlay, uv) : vec4(0.0);
}

float _biome_id_at(vec2 cell) {
    vec2 wrapped = _wrap_cell_x(cell);
    vec2 uv = (wrapped + vec2(0.5)) / map_dimensions;
    float biome_norm = (use_biome_texture != 0) ? texture(biome_texture, uv).r : texture(world_data_2, uv).r;
    return biome_norm * 255.0;
}

bool _is_tree_marker_id(float biome_id) {
    return abs(biome_id - MARKER_TREE) < 0.5 || abs(biome_id - MARKER_PLAYER_UNDER_CANOPY) < 0.5;
}

float _tree_marker_at(vec2 cell) {
    float id = _biome_id_at(cell);
    return _is_tree_marker_id(id) ? 1.0 : 0.0;
}

float _soft_circle_mask(vec2 uv, vec2 center, float radius, float softness) {
    float d = distance(uv, center);
    return 1.0 - smoothstep(radius, radius + softness, d);
}

float _tree_crown_mask(vec2 cell, vec2 uv) {
    float h0 = _hash12(cell * vec2(1.71, 0.93) + vec2(13.0, -7.0));
    float h1 = _hash12(cell * vec2(0.77, 1.37) + vec2(-19.0, 5.0));
    vec2 center = vec2(0.5) + (vec2(h0, h1) - 0.5) * 0.16;
    vec2 d = uv - center;
    float angle = atan(d.y, d.x);
    float lobe = sin(angle * 3.0 + h0 * TAU) * 0.08 + sin(angle * 5.0 - h1 * TAU) * 0.05;
    float radius = 0.39 + (h0 - 0.5) * 0.09 + lobe;
    return clamp(1.0 - smoothstep(radius, radius + 0.12, length(d)), 0.0, 1.0);
}

float _shrub_mask(vec2 cell, vec2 uv) {
    float h = _hash12(cell * vec2(1.13, 2.11) + vec2(2.7, -9.1));
    vec2 c0 = vec2(0.42, 0.46) + (vec2(fract(h * 13.0), fract(h * 29.0)) - 0.5) * 0.10;
    vec2 c1 = vec2(0.58, 0.55) + (vec2(fract(h * 17.0), fract(h * 31.0)) - 0.5) * 0.10;
    float m0 = _soft_circle_mask(uv, c0, 0.18, 0.08);
    float m1 = _soft_circle_mask(uv, c1, 0.16, 0.07);
    return clamp(max(m0, m1), 0.0, 1.0);
}

float _boulder_mask(vec2 cell, vec2 uv) {
    float h = _hash12(cell * vec2(0.89, 1.57) + vec2(-12.3, 4.5));
    vec2 center = vec2(0.5) + (vec2(fract(h * 19.0), fract(h * 37.0)) - 0.5) * 0.12;
    float rx = 0.30 + (h - 0.5) * 0.07;
    float ry = 0.24 + (0.5 - h) * 0.05;
    vec2 d = abs(uv - center);
    float k = sqrt(pow(d.x / max(rx, 0.001), 2.2) + pow(d.y / max(ry, 0.001), 2.2));
    return clamp(1.0 - smoothstep(1.0, 1.18, k), 0.0, 1.0);
}

vec2 _foliage_sway(vec2 cell, float amplitude, float speed, vec2 wind_dir) {
    float h0 = _hash12(cell * vec2(0.73, 1.29) + vec2(11.7, -5.3));
    float h1 = _hash12(cell * vec2(1.31, 0.79) + vec2(-3.2, 8.4));
    float t = TIME * speed + h0 * TAU;
    vec2 dir = normalize(wind_dir + vec2(0.0001, -0.0001));
    float lateral = sin(t) * (0.65 + h1 * 0.35);
    float bob = cos(t * 1.27 + h1 * TAU) * 0.45;
    return vec2(dir.x * lateral - dir.y * bob, dir.y * lateral + dir.x * bob) * amplitude;
}

void fragment() {
    if (debug_mode == 1) {
        // Debug gradient to verify shader execution (use SCREEN_UV to avoid UV=0 issues)
        COLOR = vec4(SCREEN_UV.x, SCREEN_UV.y, 0.0, 1.0);
    } else {
    vec2 disp = display_dimensions;
    if (disp.x <= 0.0 || disp.y <= 0.0) {
        disp = map_dimensions;
    }
    // Calculate world position from screen UV.
    vec2 world_pos = UV * disp + display_origin + scroll_offset;
    vec2 world_cell = floor(world_pos);
    world_cell = clamp(world_cell, vec2(0.0), map_dimensions - vec2(1.0));
    vec2 noise_cell = world_cell + noise_world_origin;
    
    // Calculate UV for sampling world data
    vec2 world_uv = (world_cell + vec2(0.5)) / map_dimensions;
    
    // Calculate character-local UV (0-1 within each character cell)
    vec2 char_uv = fract(world_pos);
    
    // Sample world data
    vec4 data1 = texture(world_data_1, world_uv);
    vec4 data2 = texture(world_data_2, world_uv);
    vec4 data3 = texture(world_data_3, world_uv);
    vec4 data4 = texture(world_data_4, world_uv);
    
    // Unpack data
    float height_norm = data1.r;
    float temperature = data1.g;
    float light = (use_light_texture != 0) ? texture(light_texture, world_uv).r : data1.a;

    float height_raw = height_norm * 2.0 - 1.0;
    
    float biome_id_norm = (use_biome_texture != 0) ? texture(biome_texture, world_uv).r : data2.r;
    float is_land = data2.g;
    float char_index_norm = data2.b;
    float beach_flag = data2.a;

    float turq_strength = data3.r;
    float shelf_val = data3.g;
    float cloud_raw = (use_cloud_texture != 0) ? texture(cloud_texture, world_uv).r : data3.b;
    float cloud_gain = (use_cloud_texture != 0) ? 1.0 : 1.25;
    float cloud_cov = clamp(cloud_raw * cloud_gain, 0.0, 1.0);
    float plate_boundary = data3.a;

    float lake_flag = data4.r;
    float river_flag = _river_mask_at(world_cell);
    float lava_flag = (use_lava_texture != 0) ? texture(lava_texture, world_uv).r : data4.b;
    float lake_level_raw = data4.a * 2.0 - 1.0;
    
    // Convert normalized values back to indices
    float biome_id = biome_id_norm * 255.0;
    float char_index = char_index_norm * 255.0;
    bool is_tree_marker = _is_tree_marker_id(biome_id);
    bool is_shrub_marker = abs(biome_id - MARKER_SHRUB) < 0.5;
    bool is_boulder_marker = abs(biome_id - MARKER_BOULDER) < 0.5;
    bool is_reed_marker = abs(biome_id - MARKER_REED) < 0.5;
    bool is_player_under_canopy = abs(biome_id - MARKER_PLAYER_UNDER_CANOPY) < 0.5;
    // Treat fog + solid-void markers as hard-black.
    bool is_unknown_marker = biome_id >= 253.5;
    
    // Robustness: in GPU-only mode, if packed land-mask texture is missing/stale,
    // infer land from relief so terrain does not disappear into full-ocean rendering.
    bool relief_water = (height_raw <= sea_level + 0.004);
    bool relief_land = (height_raw > sea_level + 0.02);
    bool is_ocean_biome = (abs(biome_id - BIOME_OCEAN) < 0.5) || (abs(biome_id - BIOME_ICE_SHEET) < 0.5);
    bool force_foreground_marker = (!is_unknown_marker) && ((abs(biome_id - 220.0) < 0.5) || (abs(biome_id - MARKER_PLAYER_UNDER_CANOPY) < 0.5));
    bool is_land_tile = force_foreground_marker || (((is_land >= 0.5) && !relief_water) || relief_land);
    bool submerged_surface = (!is_unknown_marker) && (biome_id < 200.0) && relief_water;
    if (submerged_surface || (!is_unknown_marker && is_ocean_biome)) {
        is_land_tile = false;
    }
    bool bedrock_mode = (bedrock_only_mode != 0);
    bool hide_ocean_in_bedrock = (bedrock_mode && !is_land_tile);
    bool lake_here = (lake_flag > 0.5);
    bool river_here = (river_flag > 0.5);
    bool lava_here = (lava_flag > 0.5);
    bool water_surface = (!hide_ocean_in_bedrock) && (!is_land_tile || lake_here);
    vec3 base_color;
    float out_char_index = char_index;
    float lake_circle_mask = 0.0;

    if (hide_ocean_in_bedrock) {
        base_color = vec3(0.0);
        out_char_index = 0.0;
    } else if (!is_land_tile) {
        base_color = water_color_from_height(height_raw, sea_level, turq_strength, shelf_val);
        out_char_index = CHAR_IDX_TILDE;
        if (!is_land_tile && abs(biome_id - BIOME_ICE_SHEET) < 0.5) {
            base_color = ICE_COLOR;
            out_char_index = CHAR_IDX_HASH;
        }
    } else {
        if (is_unknown_marker) {
            base_color = vec3(0.0);
            out_char_index = 0.0;
        } else if (!bedrock_mode && beach_flag > 0.5) {
            base_color = BEACH_COLOR;
        } else {
            base_color = sample_biome_color(biome_id);
        }
    }

    if (!bedrock_mode && is_land_tile && lake_here) {
        float lake_neighbors = _lake_neighbor_count(world_cell);
        float lake_depth_bias = (lake_neighbors / 8.0) * 0.08;
        float lake_height = height_raw - lake_depth_bias;
        base_color = water_color_from_height(lake_height, lake_level_raw, 0.0, shelf_val);
        out_char_index = CHAR_IDX_TILDE;
        float edge_factor = clamp((8.0 - lake_neighbors) / 8.0, 0.0, 1.0);
        if (edge_factor > 0.0) {
            base_color = mix(base_color, BEACH_COLOR, edge_factor * 0.12);
        }
        if (lake_neighbors <= 2.0) {
            float dist = distance(char_uv, vec2(0.5));
            float radius = 0.32;
            float softness = 0.08;
            lake_circle_mask = smoothstep(radius, radius - softness, dist);
        }
    }
    if (!bedrock_mode && is_land_tile && river_here) {
        float river_line = _river_line_mask(world_cell, char_uv);
        vec3 river_col = vec3(0.12, 0.62, 0.92);
        base_color = mix(base_color, river_col, river_line * 0.85);
    }

    if (!bedrock_mode && lava_here) {
        base_color = LAVA_COLOR;
        out_char_index = CHAR_IDX_HASH;
    }

    if (is_land_tile && !bedrock_mode && !is_unknown_marker) {
        if (temperature > 0.7) {
            base_color = mix(base_color, base_color * vec3(1.2, 0.9, 0.7), 0.15);
        } else if (temperature < 0.3) {
            base_color = mix(base_color, base_color * vec3(0.8, 0.9, 1.2), 0.15);
        }
        if (plate_boundary > 0.5) {
            base_color = mix(base_color, vec3(0.9, 0.9, 0.2), 0.2);
        }
    }

    // Shared solar geometry for cloud shadows and water glint.
    float lon = (use_fixed_lonlat != 0)
        ? fixed_lon
        : (TAU * (world_cell.x / max(1.0, map_dimensions.x)));
    float lat_norm_signed = (use_fixed_lonlat != 0)
        ? (fixed_phi / PI)
        : (0.5 - (world_cell.y / max(1.0, map_dimensions.y - 1.0)));
    float phi = (use_fixed_lonlat != 0) ? fixed_phi : (lat_norm_signed * PI);
    float decl = SOLAR_TILT * cos(TAU * day_of_year);
    float sun_lon = -TAU * time_of_day;
    vec3 n = _dir_from_lon_lat(lon, phi);
    vec3 sun_dir = _dir_from_lon_lat(sun_lon, decl);
    float sun_dot = dot(n, sun_dir);
    vec3 east = vec3(-sin(lon), cos(lon), 0.0);
    vec3 north = vec3(-sin(phi) * cos(lon), -sin(phi) * sin(lon), cos(phi));
    vec2 sun_tan = vec2(dot(sun_dir, east), dot(sun_dir, north));
    vec2 sun_dir_map = vec2(sun_tan.x, -sun_tan.y);
    float sun_dir_len = length(sun_dir_map);
    if (sun_dir_len < 0.0001) {
        sun_dir_map = normalize(vec2(0.83, -0.56));
    } else {
        sun_dir_map /= sun_dir_len;
    }
    float shadow_geom_blend = smoothstep(-0.08, 0.28, sun_dot);
    float low_sun = 1.0 - smoothstep(0.10, 0.75, max(0.0, sun_dot));
    vec2 shadow_dir = vec2(-sun_tan.x, sun_tan.y); // map coords: +x east, +y south
    float shadow_dir_len = length(shadow_dir);
    if (shadow_dir_len < 0.001) {
        shadow_dir = normalize(cloud_shadow_offset + vec2(0.0001, 0.0001));
    } else {
        shadow_dir /= shadow_dir_len;
    }
    float base_shadow_len = max(0.75, length(cloud_shadow_offset));
    float shadow_len = clamp(base_shadow_len * mix(0.7, 4.5, low_sun), 0.5, 10.0);
    vec2 dynamic_offset = shadow_dir * shadow_len;
    vec2 offset_cells = mix(cloud_shadow_offset, dynamic_offset, shadow_geom_blend);

    if (!bedrock_mode && !is_unknown_marker) {
        if (is_tree_marker) {
            vec2 tree_uv = clamp(char_uv + _foliage_sway(noise_cell, 0.055, 1.05, shadow_dir), vec2(0.0), vec2(1.0));
            float crown_mask = _tree_crown_mask(noise_cell, tree_uv);
            float crown_side = clamp(0.5 + dot(tree_uv - vec2(0.5), sun_dir_map) * 1.6, 0.0, 1.0);
            vec3 crown_dark = base_color * vec3(0.52, 0.60, 0.52);
            vec3 crown_lit = base_color * vec3(1.12, 1.16, 1.02);
            vec3 crown_color = mix(crown_dark, crown_lit, crown_side);
            base_color = mix(base_color * 0.74, crown_color, crown_mask);
            float trunk_mask = _soft_circle_mask(tree_uv, vec2(0.50, 0.52), 0.08, 0.05) * crown_mask;
            base_color = mix(base_color, vec3(0.24, 0.16, 0.08), trunk_mask * 0.52);
            if (is_player_under_canopy) {
                float player_dot = _soft_circle_mask(tree_uv, vec2(0.57, 0.60), 0.05, 0.03);
                base_color = mix(base_color, vec3(0.98, 0.90, 0.30), player_dot);
            }
        } else if (is_shrub_marker || is_reed_marker) {
            vec2 shrub_uv = clamp(char_uv + _foliage_sway(noise_cell + vec2(7.0, -3.0), 0.032, 1.35, shadow_dir), vec2(0.0), vec2(1.0));
            float shrub_mask = _shrub_mask(noise_cell, shrub_uv);
            if (is_reed_marker) {
                float reed_cols = (1.0 - smoothstep(0.08, 0.16, abs(shrub_uv.x - 0.40))) * smoothstep(0.16, 0.96, shrub_uv.y);
                reed_cols = max(reed_cols, (1.0 - smoothstep(0.08, 0.16, abs(shrub_uv.x - 0.62))) * smoothstep(0.10, 0.94, shrub_uv.y));
                shrub_mask = max(shrub_mask, reed_cols * 0.90);
            }
            float shrub_side = clamp(0.5 + dot(shrub_uv - vec2(0.5), sun_dir_map) * 1.2, 0.0, 1.0);
            vec3 shrub_dark = base_color * vec3(0.62, 0.70, 0.60);
            vec3 shrub_lit = base_color * vec3(1.08, 1.12, 0.95);
            base_color = mix(base_color * 0.88, mix(shrub_dark, shrub_lit, shrub_side), shrub_mask);
        } else if (is_boulder_marker) {
            float rock_mask = _boulder_mask(noise_cell, char_uv);
            float rock_side = clamp(0.5 + dot(char_uv - vec2(0.46, 0.46), sun_dir_map) * 1.9, 0.0, 1.0);
            vec3 rock_dark = base_color * vec3(0.52, 0.52, 0.56);
            vec3 rock_lit = base_color * vec3(1.12, 1.10, 1.08);
            base_color = mix(base_color * 0.82, mix(rock_dark, rock_lit, rock_side), rock_mask);
        }
    }

    // Cloud shadows: sun-angle aware projection.
    // Near low sun angles (sunrise/sunset), shadows lengthen.
    float light_mod = light;
    if (cloud_shadow_strength > 0.0) {
        // Keep cloud shadows visible across twilight and avoid washing out
        // near the bright edge of the terminator.
        float shadow_vis = smoothstep(-0.30, 0.04, sun_dot);
        // Sample cloud from the up-sun side of this ground cell so cast shadows
        // project away from the sun (toward the day/night boundary at low sun).
        vec2 shadow_cell = _wrap_cell_x(world_cell - offset_cells);
        vec2 shadow_uv = (shadow_cell + vec2(0.5)) / map_dimensions;
        vec2 shadow_uv_w = (_wrap_cell_x(shadow_cell + vec2(-1.0, 0.0)) + vec2(0.5)) / map_dimensions;
        vec2 shadow_uv_e = (_wrap_cell_x(shadow_cell + vec2(1.0, 0.0)) + vec2(0.5)) / map_dimensions;
        vec2 shadow_uv_n = (_wrap_cell_x(shadow_cell + vec2(0.0, -1.0)) + vec2(0.5)) / map_dimensions;
        vec2 shadow_uv_s = (_wrap_cell_x(shadow_cell + vec2(0.0, 1.0)) + vec2(0.5)) / map_dimensions;
        float cloud_shadow_c = (use_cloud_texture != 0) ? texture(cloud_texture, shadow_uv).r : texture(world_data_3, shadow_uv).b;
        float cloud_shadow_w = (use_cloud_texture != 0) ? texture(cloud_texture, shadow_uv_w).r : texture(world_data_3, shadow_uv_w).b;
        float cloud_shadow_e = (use_cloud_texture != 0) ? texture(cloud_texture, shadow_uv_e).r : texture(world_data_3, shadow_uv_e).b;
        float cloud_shadow_n = (use_cloud_texture != 0) ? texture(cloud_texture, shadow_uv_n).r : texture(world_data_3, shadow_uv_n).b;
        float cloud_shadow_s = (use_cloud_texture != 0) ? texture(cloud_texture, shadow_uv_s).r : texture(world_data_3, shadow_uv_s).b;
        float cloud_shadow = cloud_shadow_c * 0.55 + (cloud_shadow_w + cloud_shadow_e + cloud_shadow_n + cloud_shadow_s) * 0.1125;
        float cloud_shadow_effect = cloud_shadow * cloud_shadow_strength * shadow_vis;
        if (water_surface) {
            cloud_shadow_effect = 0.0;
        }
        // Add cloud shadow in darkness space and clamp at night-floor darkness.
        float dark_base = clamp(1.0 - light_mod, 0.0, 1.0);
        float dark_cap = 1.0 - NIGHT_BRIGHTNESS_FLOOR;
        float dark_out = min(dark_cap, dark_base + cloud_shadow_effect);
        light_mod = 1.0 - dark_out;
    }
    if (!bedrock_mode && is_land_tile && !is_unknown_marker && !is_tree_marker) {
        vec2 canopy_probe_a = _wrap_cell_x(world_cell - offset_cells * 0.55);
        vec2 canopy_probe_b = _wrap_cell_x(world_cell - offset_cells * 0.95);
        float canopy_occ = max(_tree_marker_at(canopy_probe_a), _tree_marker_at(canopy_probe_b) * 0.82);
        if (canopy_occ > 0.0) {
            float canopy_vis = smoothstep(-0.24, 0.22, sun_dot);
            float canopy_dark = canopy_occ * mix(0.10, 0.24, low_sun) * canopy_vis;
            float dark_base_canopy = clamp(1.0 - light_mod, 0.0, 1.0);
            float dark_cap_canopy = 1.0 - NIGHT_BRIGHTNESS_FLOOR;
            light_mod = 1.0 - min(dark_cap_canopy, dark_base_canopy + canopy_dark);
        }
    }

    // Keep world water stable and readable; avoid per-tile wave crest styling.
    float glint_add = 0.0;

    if (cloud_cov > 0.0 && !is_unknown_marker) {
        // Suppress relief-scale ground contrast under cloud cover so terrain
        // shadows don't visually leak through semi-transparent clouds.
        float sky_day = smoothstep(-0.16, 0.58, sun_dot);
        float sky_light = mix(NIGHT_BRIGHTNESS_FLOOR, 1.0, sky_day);
        float cloud_relief_suppress = smoothstep(0.15, 0.85, cloud_cov);
        light_mod = mix(light_mod, sky_light, cloud_relief_suppress * 0.82);
        float cloud_tint = cloud_cov * cloud_light_strength;
        if (water_surface) {
            cloud_tint = 0.0;
        }
        base_color = mix(base_color, vec3(1.0), cloud_tint);
    }

    vec3 lit_color = base_color * light_mod;
    if (is_land_tile && !is_unknown_marker && biome_id < 200.0) {
        float tone_noise = _hash12(noise_cell * vec2(0.93, 1.71) + vec2(13.0, -7.0)) - 0.5;
        lit_color *= (1.0 + tone_noise * 0.08);
    }
    if (glint_add > 0.0) {
        lit_color += vec3(0.88, 0.95, 1.0) * glint_add;
        lit_color = clamp(lit_color, vec3(0.0), vec3(1.0));
    }
    
    // Apply hover overlay as a 7-tile crosshair (center + 3 tiles each side),
    // inverting the underlying tile color for high contrast without fixed tint.
    bool hover_active = (hover_cell.x >= 0.0 && hover_cell.y >= 0.0);
    if (hover_active) {
        float dx_raw = abs(world_cell.x - hover_cell.x);
        float dx_wrap = min(dx_raw, map_dimensions.x - dx_raw); // horizontal world wrap
        float dy = abs(world_cell.y - hover_cell.y);
        bool on_vertical = (dx_wrap < 0.5) && (dy <= 3.0);
        bool on_horizontal = (dy < 0.5) && (dx_wrap <= 3.0);
        if (on_vertical || on_horizontal) {
            lit_color = vec3(1.0) - lit_color;
        }
    }

    // Civilization overlay (worldgen debug): subtle tint + boundary outline around human presence.
    if (use_society_overlay != 0 && !is_unknown_marker) {
        vec4 soc = _society_at(world_cell);
        float human = clamp(soc.r, 0.0, 1.0);
        float wild = clamp(soc.g, 0.0, 1.0);
        float lvl = clamp(soc.b, 0.0, 1.0);
        float state_norm = clamp(soc.a, 0.0, 1.0);

        // Subtle tint that doesn't erase geography: warm for humans, cool for high wildlife.
        vec3 human_tint = vec3(1.0, 0.92, 0.78);
        vec3 wild_tint = vec3(0.78, 0.92, 1.0);
        lit_color = mix(lit_color, human_tint, human * 0.18);
        lit_color = mix(lit_color, wild_tint, wild * 0.06);

        // Settlement "glow": slightly boost value for higher settlement levels.
        float glow = smoothstep(0.20, 1.0, lvl) * 0.10;
        lit_color = clamp(lit_color + vec3(glow), 0.0, 1.0);

        // Outline humans-held area by drawing edges where presence changes.
        float t = 0.08;
        float here = step(t, human);
        float left = step(t, _society_at(world_cell + vec2(-1.0, 0.0)).r);
        float right = step(t, _society_at(world_cell + vec2(1.0, 0.0)).r);
        float up = step(t, _society_at(world_cell + vec2(0.0, -1.0)).r);
        float down = step(t, _society_at(world_cell + vec2(0.0, 1.0)).r);

        float bw = 0.10;
        float edge_l = here * (1.0 - left) * (1.0 - smoothstep(0.0, bw, char_uv.x));
        float edge_r = here * (1.0 - right) * smoothstep(1.0 - bw, 1.0, char_uv.x);
        float edge_u = here * (1.0 - up) * (1.0 - smoothstep(0.0, bw, char_uv.y));
        float edge_d = here * (1.0 - down) * smoothstep(1.0 - bw, 1.0, char_uv.y);
        float edge = clamp(edge_l + edge_r + edge_u + edge_d, 0.0, 1.0);
        if (edge > 0.0) {
            vec3 border_col = vec3(0.08, 0.08, 0.08);
            lit_color = mix(lit_color, border_col, edge * 0.85);
        }

        // Political borders: compare hashed state id between neighbors, draw a slightly thicker outline.
        float state_here = step(0.002, state_norm);
        if (state_here > 0.5) {
            float sL = _society_at(world_cell + vec2(-1.0, 0.0)).a;
            float sR = _society_at(world_cell + vec2(1.0, 0.0)).a;
            float sU = _society_at(world_cell + vec2(0.0, -1.0)).a;
            float sD = _society_at(world_cell + vec2(0.0, 1.0)).a;
            float diffL = step(0.004, abs(state_norm - sL));
            float diffR = step(0.004, abs(state_norm - sR));
            float diffU = step(0.004, abs(state_norm - sU));
            float diffD = step(0.004, abs(state_norm - sD));
            float bw2 = 0.14;
            float edge2_l = diffL * (1.0 - smoothstep(0.0, bw2, char_uv.x));
            float edge2_r = diffR * smoothstep(1.0 - bw2, 1.0, char_uv.x);
            float edge2_u = diffU * (1.0 - smoothstep(0.0, bw2, char_uv.y));
            float edge2_d = diffD * smoothstep(1.0 - bw2, 1.0, char_uv.y);
            float edge2 = clamp(edge2_l + edge2_r + edge2_u + edge2_d, 0.0, 1.0);
            if (edge2 > 0.0) {
                vec3 pol_col = vec3(0.02, 0.02, 0.02);
                lit_color = mix(lit_color, pol_col, edge2 * 0.70);
            }
        }
    }

    // Calculate atlas UV coordinates
    float char_alpha = 1.0;
    if (use_glyphs != 0) {
        vec2 atlas_uv = get_atlas_uv(out_char_index, char_uv);
        // Sample character from atlas
        vec4 char_sample = texture(font_atlas, atlas_uv);
        // Use alpha channel when available; fall back to red channel.
        char_alpha = max(char_sample.a, char_sample.r);
        // If atlas is missing/blank, force solid tiles so the map is still visible.
        if (char_alpha < 0.01) {
            char_alpha = 1.0;
        }
    }
    if (lake_circle_mask > 0.0) {
        char_alpha = max(char_alpha, lake_circle_mask);
    }

    // Final output
    COLOR = vec4(lit_color, char_alpha);
    }
}
