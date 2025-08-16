shader_type canvas_item;

// ASCII Quad Rendering Shader
// High-performance GPU-based ASCII map rendering

// Texture uniforms
uniform sampler2D font_atlas;
uniform sampler2D world_data_1; // height, temp, moisture, light
uniform sampler2D world_data_2; // biome, land, char_idx, flags
uniform sampler2D color_palette;

// Map parameters
uniform vec2 map_dimensions;
uniform vec2 cell_size;
uniform vec2 atlas_uv_size; // 1/16, 1/6

// Character atlas layout (16x6 grid)
const float CHARS_PER_ROW = 16.0;
const float CHARS_PER_COL = 6.0;
const float TOTAL_CHARS = 95.0;

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
    float palette_u = biome_id / 255.0;
    return texture(color_palette, vec2(palette_u, 0.0)).rgb;
}

void fragment() {
    // Calculate world position from screen UV
    vec2 world_pos = UV * map_dimensions;
    vec2 world_cell = floor(world_pos);
    
    // Calculate UV for sampling world data
    vec2 world_uv = world_cell / map_dimensions;
    
    // Calculate character-local UV (0-1 within each character cell)
    vec2 char_uv = fract(world_pos);
    
    // Sample world data
    vec4 data1 = texture(world_data_1, world_uv);
    vec4 data2 = texture(world_data_2, world_uv);
    
    // Unpack data
    float height = data1.r;
    float temperature = data1.g;
    float moisture = data1.b;
    float light = data1.a;
    
    float biome_id_norm = data2.r;
    float is_land = data2.g;
    float char_index_norm = data2.b;
    float flags = data2.a;
    
    // Convert normalized values back to indices
    float biome_id = biome_id_norm * 255.0;
    float char_index = char_index_norm * 255.0;
    
    // Calculate atlas UV coordinates
    vec2 atlas_uv = get_atlas_uv(char_index, char_uv);
    
    // Sample character from atlas
    vec4 char_sample = texture(font_atlas, atlas_uv);
    float char_alpha = char_sample.r; // Use red channel as alpha
    
    // Sample base color from palette
    vec3 base_color = sample_biome_color(biome_id_norm * 255.0);
    
    // Apply lighting modulation
    vec3 lit_color = base_color * light;
    
    // Apply temperature tinting (subtle)
    if (temperature > 0.7) {
        // Hot areas get red tint
        lit_color = mix(lit_color, lit_color * vec3(1.2, 0.9, 0.7), 0.15);
    } else if (temperature < 0.3) {
        // Cold areas get blue tint
        lit_color = mix(lit_color, lit_color * vec3(0.8, 0.9, 1.2), 0.15);
    }
    
    // Handle water vs land
    if (is_land < 0.5) {
        // Water - use ocean blue with light modulation
        lit_color = mix(vec3(0.2, 0.4, 0.8), vec3(0.4, 0.6, 1.0), light);
    }
    
    // Final output
    COLOR = vec4(lit_color, char_alpha);
}