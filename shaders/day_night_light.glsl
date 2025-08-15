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
} PC;

float clamp01(float v){ return clamp(v, 0.0, 1.0); }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) { return; }
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    // Latitude phi in radians
    float lat_norm = (float(y) / max(1.0, float(H) - 1.0)) - 0.5; // -0.5..+0.5
    float phi = lat_norm * 3.14159265; // -pi/2..+pi/2

    // Solar declination delta (in radians); Earth tilt 23.44°
    float tilt = radians(23.44);
    float delta = -tilt * cos(6.2831853 * PC.day_of_year);

    // Hour angle H (radians); wrap across width; time_of_day 0..1
    float H_ang = 6.2831853 * (PC.time_of_day + float(x) / float(max(1, W)));
    // Sun elevation proxy s
    float s = sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(H_ang);
    float daylight = max(0.0, s);
    
    // Sharper terminator transition using power function
    float sharpness = 3.0; // Higher values = sharper transition
    daylight = pow(daylight, 1.0 / sharpness);
    
    // Polar summer boost: enhance daylight at high latitudes during summer
    float lat_factor = abs(lat_norm) * 2.0; // 0..1 based on distance from equator
    float seasonal_boost = 1.0;
    
    // Check if it's summer at this latitude (sun elevation is generally higher)
    float summer_indicator = sin(phi) * sin(delta);
    if (summer_indicator > 0.0 && lat_factor > 0.5) {
        // Polar summer: significantly boost light intensity
        seasonal_boost = 1.0 + (lat_factor - 0.5) * 2.0 * summer_indicator * 2.5;
    }
    
    // Enhanced contrast and stronger base light
    float enhanced_contrast = PC.contrast * 1.4; // Stronger contrast
    float enhanced_base = max(PC.base * 0.8, 0.1); // Dimmer nights but not completely black
    
    float b = clamp01(enhanced_base + enhanced_contrast * daylight * seasonal_boost);
    Light.light[i] = b;
}
