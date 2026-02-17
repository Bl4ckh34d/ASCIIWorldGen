#[compute]
#version 450
// File: res://shaders/cycle_apply.glsl
// Lightweight temperature update applying seasonal + diurnal cycles ONLY.
// Inputs: current temperature, moisture, land mask, distance to coast
// Output: updated temperature (additive clamp)

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Buffers (set=0)
layout(std430, set = 0, binding = 0) buffer TempBuf { float temp_in[]; } Temp;
layout(std430, set = 0, binding = 1) buffer MoistBuf { float moist_in[]; } Moist;
layout(std430, set = 0, binding = 2) buffer IsLandBuf { uint is_land_data[]; } IsLand;
layout(std430, set = 0, binding = 3) buffer DistBuf { float dist_data[]; } Dist;
layout(std430, set = 0, binding = 4) buffer TempOutBuf { float temp_out[]; } OutT;
layout(std430, set = 0, binding = 5) buffer LightBuf { float light_data[]; } Light;

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
    float stellar_flux;           // relative incoming stellar power (1.0 = baseline)
    float lat_energy_density_strength; // 0..1, boosts equator-vs-pole energy density contrast
    float humidity_heat_capacity; // 0..1, humidity thermal buffering strength
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
    float moist = clamp01(Moist.moist_in[i]);
    float dc_norm = clamp(Dist.dist_data[i] / float(max(1, W)), 0.0, 1.0) * PC.continentality_scale;
    float cont_amp = land ? (0.2 + 0.8 * dc_norm) : 0.0;

    // Sun-driven forcing model:
    // temperature follows incoming solar energy (latitude + season + actual daylight)
    // and is stabilized by atmospheric/ocean thermal inertia.
    const float PI = 3.14159265359;
    const float TAU = 6.28318530718;
    const float SOLAR_TILT = radians(30.0); // Keep in sync with day_night_light.glsl

    float local_time = fract(PC.time_of_day + float(x) / float(max(1, W)));
    float phi = lat_norm_signed * PI;
    float decl = SOLAR_TILT * cos(TAU * PC.season_phase);
    float hour_angle = TAU * local_time;
    float sun_dot = sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(hour_angle);
    float insol_inst = clamp01(max(0.0, sun_dot));

    // Day-length fraction controls seasonal energy and disables diurnal cycle during
    // continuous polar day/night.
    float phi_safe = clamp(phi, -1.55334, 1.55334);
    float cos_h0 = -tan(phi_safe) * tan(decl);
    float day_fraction = 0.5;
    if (cos_h0 >= 1.0) {
        day_fraction = 0.0;
    } else if (cos_h0 <= -1.0) {
        day_fraction = 1.0;
    } else {
        day_fraction = acos(cos_h0) / PI;
    }
    float daylight = smoothstep(-0.05, 0.05, sun_dot);
    float transition_strength = 1.0 - smoothstep(0.90, 1.10, abs(cos_h0));
    float day_norm = max(0.08, max(day_fraction, 1.0 - day_fraction));
    float diurnal_driver = clamp((daylight - day_fraction) / day_norm, -1.0, 1.0) * transition_strength;

    // Seasonal and diurnal amplitudes retain continentality behavior, but are now
    // driven by real sunlight geometry.
    float amp_lat = mix(PC.season_amp_equator, PC.season_amp_pole, pow(lat_abs, 1.2));
    float amp_cont = mix(PC.season_ocean_damp, 1.0, cont_amp);
    float season_driver = clamp((day_fraction - 0.5) * 2.0, -1.0, 1.0);
    float dT_season = amp_lat * amp_cont * season_driver * 0.75;

    float amp_lat_d = mix(PC.diurnal_amp_equator, PC.diurnal_amp_pole, pow(lat_abs, 1.2));
    float coast_dist01 = clamp(dc_norm, 0.0, 1.0);
    float coast_wet = 1.0 - smoothstep(0.02, 0.45, dc_norm);
    float land_diurnal_gain = mix(0.55, 1.35, coast_dist01);
    float ocean_diurnal_damp = PC.diurnal_ocean_damp * mix(0.42, 0.22, coast_dist01);
    float amp_cont_d = land ? land_diurnal_gain : ocean_diurnal_damp;
    float dT_diurnal = amp_lat_d * amp_cont_d * diurnal_driver;
    float humidity_heat = smoothstep(0.24, 0.92, moist) * clamp(PC.humidity_heat_capacity, 0.0, 1.0);
    dT_diurnal *= mix(1.0, 0.58, humidity_heat);

    float t_prev = Temp.temp_in[i];
    float cryo_hint = smoothstep(0.36, 0.14, t_prev);
    float albedo = mix(0.20, 0.58, cryo_hint);

    // Blend instantaneous insolation (day/night shadow) with day-length energy budget.
    float noon_incidence = clamp01(max(0.0, cos(phi - decl)));
    float mean_energy = day_fraction * noon_incidence;
    float equator_bias = 1.0 - lat_abs;
    // Keep runtime cycle pass aligned with initial climate pass:
    // stronger latitude energy-density attenuation for clearer pole/equator contrast.
    float lat_strength = clamp(PC.lat_energy_density_strength, 0.0, 1.0);
    float lat_strength_boosted = 1.0 - pow(1.0 - lat_strength, 2.6);
    float density_lat = mix(
        1.0,
        mix(0.16, 1.0, pow(clamp(equator_bias, 0.0, 1.0), 0.85)),
        lat_strength_boosted
    );
    float flux_scale = clamp(PC.stellar_flux, 0.35, 2.0);
    float solar_inst_weight = land ? 0.72 : mix(0.38, 0.16, coast_dist01);
    float solar_energy = clamp01(mix(mean_energy, insol_inst, solar_inst_weight) * density_lat * flux_scale);
    float light_local = clamp01(Light.light_data[i]);
    float relief_shadow_hint = max(0.0, insol_inst - light_local);
    float relief_temp_cool = 0.035 * relief_shadow_hint * smoothstep(0.06, 0.40, insol_inst) * (land ? 1.0 : 0.45);
    float eq_temp = clamp01(pow(solar_energy, 0.72) * (1.0 - 0.42 * albedo) + 0.06);
    float night_retention = humidity_heat * (1.0 - daylight) * (land ? mix(0.010, 0.026, coast_wet) : mix(0.040, 0.060, coast_dist01));
    float evap_cooling = humidity_heat * daylight * (land ? 0.012 : mix(0.006, 0.004, coast_dist01));
    eq_temp = clamp01(eq_temp + dT_season + dT_diurnal + night_retention - relief_temp_cool - evap_cooling);

    // Thermal response per climate tick (ocean slower, interior land faster).
    float ocean_response = mix(0.0016, 0.00025, coast_dist01);
    float land_response = mix(0.0030, 0.0120, coast_dist01);
    float response = land ? land_response : ocean_response;
    float t_out = clamp01(mix(t_prev, eq_temp, response));

    // Re-anchor fast-path output against the baseline temperature buffer.
    // This lets long-term paleoclimate drift (warm/ice ages) show up without
    // accumulating additive error each tick.
    float offset_delta = clamp(PC.temp_base_offset_delta, -0.35, 0.35);
    float scale_ratio = clamp(PC.temp_scale_ratio, 0.6, 1.6);
    t_out = clamp01((t_out + offset_delta - 0.5) * scale_ratio + 0.5);
    OutT.temp_out[i] = t_out;
}
