#[compute]
#version 450
// File: res://shaders/cycle_apply.glsl
// Lightweight temperature update applying seasonal + diurnal cycles ONLY.
// Inputs: current temperature, land mask, distance to coast
// Output: updated temperature (additive clamp)

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Buffers (set=0)
layout(std430, set = 0, binding = 0) buffer TempBuf { float temp_in[]; } Temp;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land_data[]; } IsLand;
layout(std430, set = 0, binding = 2) buffer DistBuf { float dist_data[]; } Dist;
layout(std430, set = 0, binding = 3) buffer TempOutBuf { float temp_out[]; } OutT;

layout(push_constant) uniform Params {
    int width;
    int height;
    // Seasonal controls
    float season_phase;           // 0..1
    float season_amp_equator;     // normalized units (0..1)
    float season_amp_pole;
    float season_ocean_damp;      // 0..1
    // Diurnal controls
    float diurnal_amp_equator;
    float diurnal_amp_pole;
    float diurnal_ocean_damp;
    float time_of_day;            // 0..1
    // Misc
    float continentality_scale;   // scales coast distance -> 0..1
    float temp_base_offset_delta; // delta vs temperature_base reference offset
    float temp_scale_ratio;       // current temp_scale / temperature_base reference scale
} PC;

float clamp01(float v){ return clamp(v, 0.0, 1.0); }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) { return; }
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    // Signed latitude in [-0.5, +0.5]
    float lat_norm_signed = 0.5 - (float(y) / max(1.0, float(H) - 1.0));
    float lat_abs = abs(lat_norm_signed) * 2.0; // 0..1

    bool land = (IsLand.is_land_data[i] != 0u);
    float dc_norm = clamp(Dist.dist_data[i] / float(max(1, W)), 0.0, 1.0) * PC.continentality_scale;
    float cont_amp = land ? (0.2 + 0.8 * dc_norm) : 0.0;

    // Amplitudes by latitude and continentality / ocean damp
    float amp_lat = mix(PC.season_amp_equator, PC.season_amp_pole, pow(lat_abs, 1.2));
    float amp_cont = mix(PC.season_ocean_damp, 1.0, cont_amp);

    // Smooth hemispheric opposition (no hard equator seam).
    float hemi = clamp(lat_norm_signed * 2.0, -1.0, 1.0);
    float equator_fade = smoothstep(0.03, 0.20, lat_abs);
    float season_driver = cos(6.2831853 * PC.season_phase);
    float dT_season = amp_lat * amp_cont * season_driver * hemi * equator_fade;

    float amp_lat_d = mix(PC.diurnal_amp_equator, PC.diurnal_amp_pole, pow(lat_abs, 1.2));
    // Continental interiors (farther from coast) get stronger day/night swing.
    float coast_dist01 = clamp(dc_norm, 0.0, 1.0);
    float land_diurnal_gain = mix(0.55, 1.35, coast_dist01);
    float amp_cont_d = land ? land_diurnal_gain : PC.diurnal_ocean_damp;
    float local_time = fract(PC.time_of_day + float(x) / float(max(1, W)));
    float dT_diurnal = amp_lat_d * amp_cont_d * cos(6.2831853 * local_time);

    float t = Temp.temp_in[i];
    float t_out = clamp01(t + dT_season + dT_diurnal);

    // Insolation-driven relaxation (energy-density proxy from solar zenith angle).
    const float PI = 3.14159265359;
    const float TAU = 6.28318530718;
    float phi = lat_norm_signed * PI;
    float decl = radians(23.44) * cos(TAU * PC.season_phase);
    float hour_angle = TAU * local_time;
    float sun_dot = sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(hour_angle);
    float insol = clamp01(max(0.0, sun_dot));

    // Simple albedo proxy: brighter surfaces (snow/ice) hold lower equilibrium temps.
    float cryo_hint = smoothstep(0.36, 0.14, t_out);
    float albedo = mix(0.20, 0.58, cryo_hint);
    float eq_temp = clamp01(pow(insol, 0.72) * (1.0 - 0.42 * albedo) + 0.06);

    // Thermal inertia: oceans react slower than continental interiors.
    float ocean_inertia = mix(0.012, 0.030, clamp(dc_norm, 0.0, 1.0));
    float land_inertia = mix(0.022, 0.060, clamp(dc_norm, 0.0, 1.0));
    float inertia = land ? land_inertia : ocean_inertia;
    t_out = clamp01(mix(t_out, eq_temp, inertia));

    // Re-anchor fast-path output against the baseline temperature buffer.
    // This lets long-term paleoclimate drift (warm/ice ages) show up without
    // accumulating additive error each tick.
    float offset_delta = clamp(PC.temp_base_offset_delta, -0.35, 0.35);
    float scale_ratio = clamp(PC.temp_scale_ratio, 0.6, 1.6);
    t_out = clamp01((t_out + offset_delta - 0.5) * scale_ratio + 0.5);
    OutT.temp_out[i] = t_out;
}
