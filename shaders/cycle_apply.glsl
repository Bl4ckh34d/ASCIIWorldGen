#[compute]
#version 450
// File: res://shaders/cycle_apply.glsl
// Lightweight cycles-only temperature update shader
// Applies only seasonal and diurnal temperature deltas to existing temperature

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Storage buffers (set=0)
layout(std430, set = 0, binding = 0) buffer InOutTempBuf { float temperature[]; } OutTemp;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land_data[]; } IsLand;
layout(std430, set = 0, binding = 2) buffer DistBuf { float dist_data[]; } Dist;

layout(push_constant) uniform Params {
    int width;
    int height;
    float continentality_scale;
    // Seasonal controls
    float season_phase;           // 0..1 (day_of_year)
    float season_amp_equator;     // amplitude at equator (0..1 normalized temp units)
    float season_amp_pole;        // amplitude at poles
    float season_ocean_damp;      // 0..1 multiplier for ocean seasonal amplitude
    // Diurnal controls
    float diurnal_amp_equator;
    float diurnal_amp_pole;
    float diurnal_ocean_damp;
    float time_of_day;            // 0..1
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

    float lat = abs(float(y) / max(1.0, float(H) - 1.0) - 0.5) * 2.0;
    bool land_px = (IsLand.is_land_data[i] != 0u);
    
    // Get current temperature
    float t = OutTemp.temperature[i];
    
    // Seasonal term with hemispheric inversion
    float lat_norm = float(y) / max(1.0, float(H) - 1.0) - 0.5; // -0.5 to +0.5
    float phase_h = (lat_norm < 0.0) ? PC.season_phase + 0.5 : PC.season_phase;
    float amp_lat = mix(PC.season_amp_equator, PC.season_amp_pole, pow(lat, 1.2));
    
    // Continentality scaling for seasonal amplitude
    float dc_norm = clamp(Dist.dist_data[i] / float(max(1, W)), 0.0, 1.0) * PC.continentality_scale;
    float cont_amp = land_px ? (0.2 + 0.8 * dc_norm) : 0.0;
    float amp_cont = mix(PC.season_ocean_damp, 1.0, cont_amp);
    float season = amp_lat * amp_cont * cos(6.28318 * phase_h);
    
    // Diurnal term: latitude and ocean damped
    float amp_lat_d = mix(PC.diurnal_amp_equator, PC.diurnal_amp_pole, pow(lat, 1.2));
    float amp_cont_d = land_px ? 1.0 : PC.diurnal_ocean_damp;
    float diurnal = amp_lat_d * amp_cont_d * cos(6.28318 * PC.time_of_day);
    
    // Apply cycles additively and clamp
    t = clamp01(t + season + diurnal);
    
    OutTemp.temperature[i] = t;
}