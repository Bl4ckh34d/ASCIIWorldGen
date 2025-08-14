#[compute]
#version 450
// File: res://shaders/day_night_light.glsl
// Day-night lighting compute shader
// Calculates sun elevation and brightness for each pixel

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Storage buffers (set=0)
layout(std430, set = 0, binding = 0) buffer LightBuf { float light[]; } Light;

layout(push_constant) uniform Params {
    int width;
    int height;
    float day_of_year;       // 0..1 (for solar declination)
    float time_of_day;       // 0..1 (for hour angle)
    float base;              // base brightness (0..1)
    float contrast;          // contrast multiplier (0..1)
} PC;

// Helpers
float clamp01(float v) { return clamp(v, 0.0, 1.0); }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    // Latitude phi (radians) per row y: phi = PI*(y/(H-1) - 0.5)
    float lat_norm = float(y) / max(1.0, float(H) - 1.0) - 0.5; // -0.5 to +0.5
    float phi = 3.14159 * lat_norm; // latitude in radians
    
    // Solar declination delta (Earth tilt 23.44 deg): delta = -23.44 deg * cos(2*PI*day_of_year)
    float delta = -23.44 * 3.14159 / 180.0 * cos(6.28318 * PC.day_of_year);
    
    // Hour angle at x: H = 2*PI * (time_of_day + x/W). Wrap horizontally.
    // Use fract to ensure proper wrapping and continuous movement
    float normalized_x = fract(PC.time_of_day + float(x) / float(W));
    float hour_angle = 6.28318 * normalized_x;
    
    // Sun elevation proxy s = sin(phi)*sin(delta) + cos(phi)*cos(delta)*cos(H)
    float s = sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(hour_angle);
    
    // Enhanced polar lighting: boost brightness at high latitudes during summer
    // Hemispheric inversion: northern summer = southern winter
    float abs_lat = abs(lat_norm); // 0 to 0.5
    float polar_factor = abs_lat * abs_lat; // 0 to 0.25, stronger at poles
    float hemisphere_sign = (lat_norm >= 0.0) ? 1.0 : -1.0; // North: +1, South: -1
    float seasonal_boost = polar_factor * hemisphere_sign * sin(delta) * 0.6; // Oscillates between hemispheres
    
    // Brighter overall lighting with improved contrast
    float enhanced_base = max(PC.base, 0.4); // Minimum brightness of 0.4
    float enhanced_contrast = PC.contrast * 1.2; // 20% more contrast
    float sun_brightness = enhanced_contrast * max(0.0, s * 0.8 + 0.2); // Softer sun cutoff
    
    // Brightness b = clamp(base + contrast * sun + seasonal_boost, 0, 1)
    float b = clamp01(enhanced_base + sun_brightness + seasonal_boost);
    
    Light.light[i] = b;
}