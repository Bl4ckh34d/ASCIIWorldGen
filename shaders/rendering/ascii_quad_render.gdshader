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

// Hover overlay parameters (tile coordinates; negative disables)
uniform vec2 hover_cell = vec2(-1.0, -1.0);

// Character atlas layout (16x6 grid)
const float CHARS_PER_ROW = 16.0;
const float CHARS_PER_COL = 6.0;
const float TOTAL_CHARS = 95.0;
const float CHAR_IDX_TILDE = 94.0; // '~'
const float CHAR_IDX_HASH = 3.0;   // '#'
const float BIOME_ICE_SHEET = 1.0;

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
    vec3 shallow = vec3(0.05, 0.65, 0.80);
    vec3 c = mix(deep, shallow, shade);
    if (turq_strength > 0.0) {
        float overlay = clamp((1.0 - depth_norm) * turq_strength, 0.0, 0.85);
        c = mix(c, vec3(0.10, 0.85, 0.95), overlay);
    }
    return c;
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
    bool is_unknown_marker = abs(biome_id - 254.0) < 0.5;
    
    // Robustness: in GPU-only mode, if packed land-mask texture is missing/stale,
    // infer land from relief so terrain does not disappear into full-ocean rendering.
    bool is_land_tile = (is_land >= 0.5) || (height_raw > sea_level);
    bool bedrock_mode = (bedrock_only_mode != 0);
    bool hide_ocean_in_bedrock = (bedrock_mode && !is_land_tile);
    bool lake_here = (lake_flag > 0.5);
    bool river_here = (river_flag > 0.5);
    bool lava_here = (lava_flag > 0.5);
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

    // Cloud shadows: sun-angle aware projection.
    // Near low sun angles (sunrise/sunset), shadows lengthen.
    float light_mod = light;
    if (cloud_shadow_strength > 0.0) {
        // Keep cloud shadows visible across twilight and avoid washing out
        // near the bright edge of the terminator.
        float shadow_vis = smoothstep(-0.30, 0.04, sun_dot);
        float shadow_geom_blend = smoothstep(-0.08, 0.28, sun_dot);

        vec3 east = vec3(-sin(lon), cos(lon), 0.0);
        vec3 north = vec3(-sin(phi) * cos(lon), -sin(phi) * sin(lon), cos(phi));
        vec2 sun_tan = vec2(dot(sun_dir, east), dot(sun_dir, north));
        vec2 shadow_dir = vec2(-sun_tan.x, sun_tan.y); // map coords: +x east, +y south
        float dir_len = length(shadow_dir);
        if (dir_len < 0.001) {
            shadow_dir = normalize(cloud_shadow_offset + vec2(0.0001, 0.0001));
        } else {
            shadow_dir /= dir_len;
        }
        float low_sun = 1.0 - smoothstep(0.10, 0.75, max(0.0, sun_dot));
        float base_len = max(0.75, length(cloud_shadow_offset));
        float shadow_len = clamp(base_len * mix(0.7, 4.5, low_sun), 0.5, 10.0);
        vec2 dynamic_offset = shadow_dir * shadow_len;
        vec2 offset_cells = mix(cloud_shadow_offset, dynamic_offset, shadow_geom_blend);
        // Sample cloud from the up-sun side of this ground cell so cast shadows
        // project away from the sun (toward the day/night boundary at low sun).
        vec2 shadow_cell = _wrap_cell_x(world_cell - offset_cells);
        vec2 shadow_uv = (shadow_cell + vec2(0.5)) / map_dimensions;
        float cloud_shadow = (use_cloud_texture != 0) ? texture(cloud_texture, shadow_uv).r : texture(world_data_3, shadow_uv).b;
        float cloud_shadow_effect = cloud_shadow * cloud_shadow_strength * shadow_vis;
        // Add cloud shadow in darkness space and clamp at night-floor darkness.
        float dark_base = clamp(1.0 - light_mod, 0.0, 1.0);
        float dark_cap = 1.0 - NIGHT_BRIGHTNESS_FLOOR;
        float dark_out = min(dark_cap, dark_base + cloud_shadow_effect);
        light_mod = 1.0 - dark_out;
    }

    // Water glint around subsolar region with sparkle breakup.
    bool water_surface = (!hide_ocean_in_bedrock) && (!is_land_tile || lake_here);
    float glint_add = 0.0;
    if (water_surface) {
        float sun_vis = max(0.0, sun_dot);
        float abs_lat = abs(lat_norm_signed) * 2.0;
        float polar_tighten = smoothstep(0.60, 0.98, abs_lat);
        // Smaller central blob, but sparkles can spread farther from center.
        float core = pow(sun_vis, mix(220.0, 304.0, polar_tighten));
        float halo = pow(sun_vis, mix(30.0, 50.0, polar_tighten));
        float outer = pow(sun_vis, mix(14.0, 24.0, polar_tighten));
        float sparkle_noise = _hash12(world_cell * vec2(1.73, 1.19) + vec2(time_of_day * 920.0, day_of_year * 410.0));
        float sparkle_density = mix(0.885, 0.935, polar_tighten);
        float sparkle = smoothstep(sparkle_density, 0.998, sparkle_noise) * halo;
        float micro_noise = _hash12(world_cell * vec2(2.41, 0.93) + vec2(time_of_day * 1280.0 + 13.0, day_of_year * 560.0 - 5.0));
        float micro_spark = smoothstep(mix(0.978, 0.989, polar_tighten), 1.0, micro_noise) * core;
        float far_noise = _hash12(world_cell * vec2(0.89, 2.17) + vec2(time_of_day * 740.0 - 11.0, day_of_year * 300.0 + 9.0));
        float far_spark = smoothstep(mix(0.955, 0.978, polar_tighten), 1.0, far_noise) * outer;
        float day_gate = smoothstep(0.05, 0.34, sun_vis);
        float glint = core * 0.90 + halo * 0.005 + sparkle * 0.24 + micro_spark * 0.16 + far_spark * 0.18;
        glint *= day_gate;
        glint *= smoothstep(0.07, 0.95, light_mod);
        glint *= (1.0 - cloud_cov * 0.62);
        glint *= 0.56;
        glint_add = clamp(glint, 0.0, 0.62);
    }

    if (cloud_cov > 0.0 && !is_unknown_marker) {
        // Suppress relief-scale ground contrast under cloud cover so terrain
        // shadows don't visually leak through semi-transparent clouds.
        float sky_day = smoothstep(-0.16, 0.58, sun_dot);
        float sky_light = mix(NIGHT_BRIGHTNESS_FLOOR, 1.0, sky_day);
        float cloud_relief_suppress = smoothstep(0.15, 0.85, cloud_cov);
        light_mod = mix(light_mod, sky_light, cloud_relief_suppress * 0.82);
        base_color = mix(base_color, vec3(1.0), cloud_cov * cloud_light_strength);
    }

    vec3 lit_color = base_color * light_mod;
    if (glint_add > 0.0) {
        lit_color += vec3(1.0, 0.98, 0.90) * glint_add;
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
