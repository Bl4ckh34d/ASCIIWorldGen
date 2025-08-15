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
    // ENHANCED: Make seasonal changes more dramatic and faster
    float tilt = radians(30.0); // Increased from 23.44° to 30° for more dramatic effect
    float delta = -tilt * cos(6.2831853 * PC.day_of_year);
    
    // Debug: you can see seasonal effect by checking delta value
    // delta varies from -30° to +30° throughout the year

    // Hour angle H (radians); wrap across width; time_of_day 0..1
    float H_ang = 6.2831853 * (PC.time_of_day + float(x) / float(max(1, W)));
    // Sun elevation calculation (this creates the terminator curve)
    float s = sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(H_ang);
    
    // Enhanced terminator for dramatic seasonal visibility
    float daylight = 0.0;
    
    // Create extremely sharp terminator boundary
    float terminator_threshold = 0.02; // Very thin twilight zone
    
    if (s > terminator_threshold) {
        // Day side - bright
        daylight = 1.0;
        
        // Add seasonal summer brightness boost at high latitudes  
        float lat_abs = abs(lat_norm) * 2.0;
        bool same_hemisphere_as_sun = (lat_norm * delta) > 0.0;
        if (same_hemisphere_as_sun && lat_abs > 0.6) {
            // Summer hemisphere high latitudes get extra brightness
            daylight = min(1.0, 1.0 + lat_abs * abs(delta) * 2.0);
        }
        
    } else if (s > -terminator_threshold) {
        // Twilight zone - creates the visible terminator line
        float twilight = (s + terminator_threshold) / (2.0 * terminator_threshold);
        daylight = twilight * 0.6; // Dim twilight
        
    } else {
        // Night side - dark (but not completely black)
        daylight = 0.1;
        
        // Add polar night effect
        float lat_abs = abs(lat_norm) * 2.0;
        bool opposite_hemisphere = (lat_norm * delta) < 0.0;
        if (opposite_hemisphere && lat_abs > 0.6 && abs(delta) > radians(15.0)) {
            // Winter hemisphere high latitudes get extra darkness
            daylight = max(0.05, daylight * (1.0 - lat_abs * abs(delta) * 1.5));
        }
    }
    
    // Apply base lighting and contrast
    float b = clamp01(PC.base + PC.contrast * daylight);
    Light.light[i] = b;
}
