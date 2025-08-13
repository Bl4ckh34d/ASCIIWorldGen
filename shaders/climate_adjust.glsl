#[compute]
#version 450
// File: res://shaders/climate_adjust.glsl
// Raw GLSL compute shader for ClimateAdjust (Godot RenderingDevice)
// Inputs: height, is_land (u32 0/1), distance_to_coast, temp_noise, moist_noise_base, flow_u, flow_v
// Outputs: temperature, moisture, precip

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
    // Apply elevation cooling only above sea level (temperature-neutral below sea level)
    float rel_elev = max(0.0, Height.height_data[i] - PC.sea_level);
    float elev_cool = clamp(rel_elev * 1.2, 0.0, 1.0);
    float zonal = 0.5 + 0.5 * sin(6.28318 * float(y) / float(H) * 3.0);
    float u = 1.0 - lat;
    float t_lat = 0.65 * pow(u, 0.8) + 0.35 * pow(u, 1.6);
    bool land_px = (IsLand.is_land_data[i] != 0u);
    float lat_amp = land_px ? 1.0 : 0.82; // damp lat gradient over ocean
    float t = t_lat * 0.82 * lat_amp + zonal * 0.15 - elev_cool * 0.9 + 0.18 * TempNoise.temp_noise_data[i];

    float dc_norm = clamp(Dist.dist_data[i] / float(max(1, W)), 0.0, 1.0) * PC.continentality_scale;
    float cont_gain = land_px ? 0.8 : 0.2; // much smaller anomalies over open ocean
    float t_anom = (t - 0.5) * (1.0 + cont_gain * dc_norm);
    t = clamp01(0.5 + t_anom);
    t = clamp01((t + PC.temp_base_offset - 0.5) * PC.temp_scale + 0.5);

    // Shore temperature anchoring: for first ~2 cells into the ocean,
    // blend ocean temperature toward adjacent land temperature so polar
    // coastlines don't have an unfrozen water rim
    if (!land_px) {
        float d = Dist.dist_data[i];
        if (d <= 2.0) {
            float t_land_sum = 0.0;
            int cnt = 0;
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    if (dx == 0 && dy == 0) { continue; }
                    int nx = int(x) + dx;
                    int ny = int(y) + dy;
                    if (nx < 0 || ny < 0 || nx >= W || ny >= H) { continue; }
                    int j = nx + ny * W;
                    if (IsLand.is_land_data[j] != 0u) {
                        float lat2 = abs(float(ny) / max(1.0, float(H) - 1.0) - 0.5) * 2.0;
                        float u2 = 1.0 - lat2;
                        float t_lat2 = 0.65 * pow(u2, 0.8) + 0.35 * pow(u2, 1.6);
                        float rel_elev2 = max(0.0, Height.height_data[j] - PC.sea_level);
                        float elev_cool2 = clamp(rel_elev2 * 1.2, 0.0, 1.0);
                        float zonal2 = 0.5 + 0.5 * sin(6.28318 * float(ny) / float(H) * 3.0);
                        float t2 = t_lat2 * 0.82 + zonal2 * 0.15 - elev_cool2 * 0.9 + 0.18 * TempNoise.temp_noise_data[j];
                        float dc2 = clamp(Dist.dist_data[j] / float(max(1, W)), 0.0, 1.0) * PC.continentality_scale;
                        float t_anom2 = (t2 - 0.5) * (1.0 + 0.8 * dc2);
                        t2 = clamp01(0.5 + t_anom2);
                        t2 = clamp01((t2 + PC.temp_base_offset - 0.5) * PC.temp_scale + 0.5);
                        t_land_sum += t2;
                        cnt++;
                    }
                }
            }
            if (cnt > 0) {
                float t_land_avg = t_land_sum / float(cnt);
                float wblend = smoothstep(0.0, 2.0, d);
                t = mix(t_land_avg, t, wblend);
            }
        }
    }

    float m_base = 0.5 + 0.3 * sin(6.28318 * float(y) / float(H) * 3.0);
    // Moisture base noise sampled with offset (x+100, y-50)
    float m_noise = 0.3 * sample_bilinear_moist(W, H, float(x) * PC.noise_x_scale + 100.0, float(y) - 50.0);
    // Flow advection fields (already evaluated at scaled coords on CPU when built)
    float adv_u = FlowU.flow_u_data[i];
    float adv_v = FlowV.flow_v_data[i];
    float sx = clamp(float(x) + adv_u * 6.0, 0.0, float(W - 1));
    float sy = clamp(float(y) + adv_v * 6.0, 0.0, float(H - 1));
    float m_adv = 0.2 * sample_bilinear_moist(W, H, sx * PC.noise_x_scale, sy);
    float polar_dry = 0.20 * lat;
    float m = m_base + m_noise + m_adv - polar_dry;

    float humid_amp = mix(0.40, 1.60, PC.ocean_frac);
    float humid_bias = mix(-0.30, 0.30, PC.ocean_frac);
    m = (m - 0.5) * humid_amp + 0.5 + humid_bias;
    float s_norm = clamp(PC.sea_level, -1.0, 1.0);
    float dryness_strength = max(0.0, -s_norm);
    float wet_strength = max(0.0, s_norm);
    float amp2 = 1.0 + 0.5 * wet_strength - 0.5 * dryness_strength;
    float bias2 = 0.25 * wet_strength - 0.25 * dryness_strength;
    m = (m - 0.5) * amp2 + 0.5 + bias2;
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