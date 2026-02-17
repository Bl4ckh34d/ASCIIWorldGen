#[compute]
#version 450
// File: res://shaders/climate_adjust.glsl
// Raw GLSL compute shader for ClimateAdjust (Godot RenderingDevice)
// Inputs: height, is_land (u32 0/1), distance_to_coast, temp_noise, moist_noise_base, flow_u, flow_v
// Outputs: temperature, moisture, precip
// Layout summary (set=0):
//   b0 height_data, b1 is_land_data, b2 distance_to_coast, b3 temp_noise, b4 moist_noise_base
//   b5 flow_u, b6 flow_v, b7 out_temp, b8 out_moist, b9 out_precip, b10 light_data
// Push constants:
//   ivec2(width,height) + 20 floats (sea/temp/moist/season/diurnal/orbit terms), padded to 96 bytes.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Storage buffers (set=0)
layout(std430, set = 0, binding = 0) buffer HeightBuf { float height_data[]; } Height;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land_data[]; } IsLand;
layout(std430, set = 0, binding = 2) buffer DistBuf { float dist_data[]; } Dist;
layout(std430, set = 0, binding = 3) buffer TempNoiseBuf { float temp_noise_data[]; } TempNoise;
layout(std430, set = 0, binding = 4) buffer MoistNoiseBaseBuf { float moist_noise_base_data[]; } MoistBase;
layout(std430, set = 0, binding = 5) buffer FlowUBuf { float flow_u_data[]; } FlowU;
layout(std430, set = 0, binding = 6) buffer FlowVBuf { float flow_v_data[]; } FlowV;
layout(std430, set = 0, binding = 7) buffer OutTempBuf { float out_temp[]; } OutTemp;
layout(std430, set = 0, binding = 8) buffer OutMoistBuf { float out_moist[]; } OutMoist;
layout(std430, set = 0, binding = 9) buffer OutPrecipBuf { float out_precip[]; } OutPrecip;
layout(std430, set = 0, binding = 10) buffer LightBuf { float light_data[]; } Light;

layout(push_constant) uniform Params {
    int width;
    int height;
    float sea_level;
    float temp_base_offset;
    float temp_scale;
    float moist_base_offset;
    float moist_scale;
    float continentality_scale;
    float ocean_frac;
    float noise_x_scale;
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
    float stellar_flux;           // relative incoming stellar power (1.0 = baseline)
    float lat_energy_density_strength; // 0..1, boosts equator-vs-pole energy density contrast
    float humidity_heat_capacity; // 0..1, humidity thermal buffering strength
    float _pad0;
} PC;

// Helpers
float clamp01(float v) { return clamp(v, 0.0, 1.0); }

// Bilinear sample helpers specialized for MoistBase buffer (Vulkan GLSL does not allow passing SSBO arrays as function params)
float sample_bilinear_moist(int W, int H, float fx, float fy) {
    float x = clamp(fx, 0.0, float(W - 1));
    float y = clamp(fy, 0.0, float(H - 1));
    int x0 = int(floor(x));
    int y0 = int(floor(y));
    int x1 = min(x0 + 1, W - 1);
    int y1 = min(y0 + 1, H - 1);
    float tx = x - float(x0);
    float ty = y - float(y0);
    int i00 = x0 + y0 * W;
    int i10 = x1 + y0 * W;
    int i01 = x0 + y1 * W;
    int i11 = x1 + y1 * W;
    float v00 = MoistBase.moist_noise_base_data[i00];
    float v10 = MoistBase.moist_noise_base_data[i10];
    float v01 = MoistBase.moist_noise_base_data[i01];
    float v11 = MoistBase.moist_noise_base_data[i11];
    float vx0 = mix(v00, v10, tx);
    float vx1 = mix(v01, v11, tx);
    return mix(vx0, vx1, ty);
}

float sample_point_moist(int W, int H, float fx, float fy) {
    int xi = int(clamp(round(fx), 0.0, float(W - 1)));
    int yi = int(clamp(round(fy), 0.0, float(H - 1)));
    return MoistBase.moist_noise_base_data[xi + yi * W];
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    float lat_norm_signed = 0.5 - (float(y) / max(1.0, float(H) - 1.0)); // -0.5..+0.5 (north positive)
    float lat = abs(lat_norm_signed) * 2.0;
    bool land_px = (IsLand.is_land_data[i] != 0u);
    float local_time_solar = fract(PC.time_of_day + float(x) / float(max(1, W)));

    // Base climatology (latitude + elevation + seed noise) used as a stabilizing background.
    float rel_elev = max(0.0, Height.height_data[i] - 0.0);
    float elev_cool = clamp(rel_elev * 0.6, 0.0, 1.0);
    float zonal = 0.5 + 0.5 * sin(6.28318 * (float(y) / float(H) + 0.11));
    float u = 1.0 - lat;
    float t_lat = 0.65 * pow(u, 0.8) + 0.35 * pow(u, 1.6);
    float lat_amp = land_px ? 1.0 : 0.82;
    float t_base = t_lat * 0.82 * lat_amp + zonal * 0.06 - elev_cool * 0.9;
    float t_noise = 0.18 * TempNoise.temp_noise_data[i];
    float t_climatology = clamp01(t_base + t_noise);

    // Sun-driven forcing model (same geometry intent as cycle_apply/day_night_light).
    const float PI = 3.14159265359;
    const float TAU = 6.28318530718;
    const float SOLAR_TILT = radians(30.0);
    float phi = lat_norm_signed * PI;
    float decl = SOLAR_TILT * cos(TAU * PC.season_phase);
    float hour_angle = TAU * local_time_solar;
    float sun_dot = sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(hour_angle);
    float insol_inst = clamp01(max(0.0, sun_dot));
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

    float dc_norm = clamp(Dist.dist_data[i] / float(max(1, W)), 0.0, 1.0) * PC.continentality_scale;
    float amp_lat = mix(PC.season_amp_equator, PC.season_amp_pole, pow(lat, 1.2));
    float cont_amp = land_px ? (0.2 + 0.8 * dc_norm) : 0.0;
    float amp_cont = mix(PC.season_ocean_damp, 1.0, cont_amp);
    float season_driver = clamp((day_fraction - 0.5) * 2.0, -1.0, 1.0);
    float season = amp_lat * amp_cont * season_driver * 0.75;
    float amp_lat_d = mix(PC.diurnal_amp_equator, PC.diurnal_amp_pole, pow(lat, 1.2));
    float coast_dist01 = clamp(dc_norm, 0.0, 1.0);
    float coast_wet = 1.0 - smoothstep(0.02, 0.45, dc_norm);
    float land_diurnal_gain = mix(0.55, 1.35, coast_dist01);
    float amp_cont_d = land_px ? land_diurnal_gain : PC.diurnal_ocean_damp;
    float diurnal = amp_lat_d * amp_cont_d * diurnal_driver;

    // Precompute a humidity proxy from large-scale moisture drivers so humidity can
    // buffer temperature swings (high humidity reduces day/night thermal amplitude).
    float m_base = 0.5 + 0.16 * sin(6.28318 * (float(y) / float(H) * 1.4 + 0.17));
    float m_noise = 0.3 * sample_bilinear_moist(W, H, float(x) * PC.noise_x_scale + 100.0, float(y) * PC.noise_x_scale - 50.0);
    float adv_u = FlowU.flow_u_data[i];
    float adv_v = FlowV.flow_v_data[i];
    float sx = clamp(float(x) + adv_u * 6.0, 0.0, float(W - 1));
    float sy = clamp(float(y) + adv_v * 6.0, 0.0, float(H - 1));
    // Keep one bilinear path for baseline moisture and use point sample for advection to cut fetches.
    float m_adv = 0.2 * sample_point_moist(W, H, sx * PC.noise_x_scale, sy * PC.noise_x_scale);
    float sea_mod = clamp(PC.sea_level, -1.0, 1.0) * 0.08;
    float m_seed = 0.48 + 0.18 * m_noise + 0.12 * m_adv + 0.10 * m_base;
    float humidity_proxy = clamp01(m_seed + sea_mod + coast_wet * 0.12 + (land_px ? 0.0 : 0.12));
    float humidity_heat = smoothstep(0.24, 0.92, humidity_proxy) * clamp(PC.humidity_heat_capacity, 0.0, 1.0);
    diurnal *= mix(1.0, 0.58, humidity_heat);

    float cryo_hint = smoothstep(0.36, 0.14, t_climatology);
    float albedo = mix(0.20, 0.58, cryo_hint);
    float noon_incidence = clamp01(max(0.0, cos(phi - decl)));
    float mean_energy = day_fraction * noon_incidence;
    float equator_bias = 1.0 - lat;
    float density_lat = mix(
        1.0,
        mix(0.20, 1.0, pow(clamp(equator_bias, 0.0, 1.0), 0.85)),
        clamp(PC.lat_energy_density_strength, 0.0, 1.0)
    );
    float flux_scale = clamp(PC.stellar_flux, 0.35, 2.0);
    float solar_energy = clamp01(mix(mean_energy, insol_inst, 0.72) * density_lat * flux_scale);
    float light_local = clamp01(Light.light_data[i]);
    float relief_shadow_hint = max(0.0, insol_inst - light_local);
    float relief_temp_cool = 0.035 * relief_shadow_hint * smoothstep(0.06, 0.40, insol_inst) * (land_px ? 1.0 : 0.45);
    float night_retention = humidity_heat * (1.0 - daylight) * (land_px ? mix(0.010, 0.026, coast_wet) : 0.032);
    float evap_cooling = humidity_heat * daylight * (land_px ? 0.012 : 0.008);
    float t_solar = clamp01(pow(solar_energy, 0.72) * (1.0 - 0.42 * albedo) + 0.06 + season + diurnal + night_retention - relief_temp_cool - evap_cooling);
    float cont_blend = land_px ? mix(0.58, 0.88, coast_dist01) : 0.42;
    float t = clamp01(mix(t_climatology, t_solar, cont_blend));
    // FIXED: Reduce extreme temperature scaling to prevent lava everywhere
    // Apply gentler temperature transformation to avoid extreme artifacts
    float temp_offset = clamp(PC.temp_base_offset, -0.3, 0.3);  // Limit offset
    float temp_scale = clamp(PC.temp_scale, 0.6, 1.4);          // Limit scaling
    t = clamp01((t + temp_offset - 0.5) * temp_scale + 0.5);

    // Shore temperature anchoring:
    // distance-only attenuation to avoid expensive 8-neighbor shoreline scans.
    if (!land_px) {
        float d = max(0.0, Dist.dist_data[i]);
        float shore_strength = 1.0 - smoothstep(0.0, 4.0, d);
        float polar_pull = smoothstep(0.55, 1.0, lat);
        float shore_target = clamp01(t_climatology - polar_pull * 0.08);
        t = mix(t, shore_target, 0.75 * shore_strength);
    }

    float local_day = 0.5 - 0.5 * cos(6.28318 * (PC.time_of_day + float(x) / float(max(1, W))));
    float night = 1.0 - local_day;
    float warm = smoothstep(0.30, 0.90, t);
    float interior = smoothstep(0.18, 0.90, dc_norm);
    float polar_dry = smoothstep(0.65, 1.0, lat) * 0.22;

    float evap_ocean = land_px ? 0.0 : (0.34 + 0.48 * warm) * (0.45 + 0.55 * local_day);
    float evap_land = land_px ? (0.08 + 0.20 * warm) * (0.25 + 0.75 * local_day) : 0.0;
    float veg_potential = land_px
        ? (0.55 * smoothstep(0.30, 0.82, t) * (0.30 + 0.70 * coast_wet) * (1.0 - smoothstep(0.72, 1.0, dc_norm)))
        : 0.0;
    float transp = evap_land * veg_potential;
    float trade_dry = interior * (0.04 + 0.11 * warm);
    float nocturnal_condense = (0.03 + 0.10 * night) * (0.35 + 0.65 * warm);
    float m_source = evap_ocean + transp + coast_wet * 0.12;
    float m_sink = polar_dry + trade_dry + nocturnal_condense;
    float target = land_px
        ? clamp(0.32 + 0.30 * veg_potential + 0.24 * coast_wet + 0.10 * night, 0.0, 1.0)
        : clamp(0.62 + 0.26 * warm + 0.08 * night, 0.0, 1.0);

    float m = m_seed + m_source - m_sink + sea_mod + (PC.ocean_frac - 0.5) * 0.06;
    m = mix(m, target, 0.26);
    m = clamp01((m + PC.moist_base_offset - 0.5) * PC.moist_scale + 0.5);

    // Precip proxy using simple orographic factor (slope_y)
    float slope_y = 0.0;
    if (y > 0 && y < uint(H - 1)) {
        slope_y = Height.height_data[i] - Height.height_data[i - W];
    }
    float rain_orography = clamp(0.5 + slope_y * 3.0, 0.0, 1.0);
    float p = clamp01(m * rain_orography);

    OutTemp.out_temp[i] = t;
    OutMoist.out_moist[i] = m;
    OutPrecip.out_precip[i] = p;
}
