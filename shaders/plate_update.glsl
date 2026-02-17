#[compute]
#version 450
// File: res://shaders/plate_update.glsl
// Plate update with stylized but more realistic tectonic behavior:
// - Slow plate drift (advection-like lateral transport)
// - Convergent boundaries: uplift-dominant mountain building (no deep trench carving)
// - Divergent boundaries: extensional rifts, with polar ice-sheet guarding
// - Transform boundaries: shear roughness
// All done in a single GPU pass.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer HeightIn { float height_in[]; } HIn;
layout(std430, set = 0, binding = 1) buffer PlateIdBuf { int plate_id[]; } PID;
layout(std430, set = 0, binding = 2) buffer BoundaryBuf { int boundary_mask[]; } Bnd;
layout(std430, set = 0, binding = 3) buffer PlateVelU { float plate_vel_u[]; } PvU;
layout(std430, set = 0, binding = 4) buffer PlateVelV { float plate_vel_v[]; } PvV;
layout(std430, set = 0, binding = 5) buffer PlateBuoyancy { float plate_buoyancy[]; } Pb;
layout(std430, set = 0, binding = 6) buffer HeightOut { float height_out[]; } HOut;

layout(push_constant) uniform Params {
    int width;
    int height;
    int num_plates;
    int band_cells;
    float dt_days;
    float uplift_rate_per_day;
    float ridge_rate_per_day;
    float transform_roughness_per_day;
    float subduction_rate_per_day;
    float trench_rate_per_day;
    float drift_cells_per_day;
    float seed_phase;
    float sea_level;
    float max_boundary_delta_per_day;
    float divergence_response;
} PC;

const float HEIGHT_MIN = -1.0;
const float HEIGHT_MAX = 1.25;

uint idx(int x, int y) { return uint(x + y * PC.width); }

float sample_height_wrap_x(float fx, float fy) {
    int W = PC.width;
    int H = PC.height;
    float x = fx;
    float y = clamp(fy, 0.0, float(H - 1));
    int x0i = int(floor(x));
    int y0 = int(floor(y));
    float tx = x - float(x0i);
    float ty = y - float(y0);
    int x0 = ((x0i % W) + W) % W;
    int x1 = (x0 + 1) % W;
    int y1 = min(y0 + 1, H - 1);
    float v00 = HIn.height_in[x0 + y0 * W];
    float v10 = HIn.height_in[x1 + y0 * W];
    float v01 = HIn.height_in[x0 + y1 * W];
    float v11 = HIn.height_in[x1 + y1 * W];
    float vx0 = mix(v00, v10, tx);
    float vx1 = mix(v01, v11, tx);
    return mix(vx0, vx1, ty);
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(idx(int(x), int(y)));
    int pid = PID.plate_id[i];
    float h = HIn.height_in[i];
    float u_self = (pid >= 0 && pid < PC.num_plates) ? PvU.plate_vel_u[pid] : 0.0;
    float v_self = (pid >= 0 && pid < PC.num_plates) ? PvV.plate_vel_v[pid] : 0.0;
    float b_self = (pid >= 0 && pid < PC.num_plates) ? clamp(Pb.plate_buoyancy[pid], 0.0, 1.0) : 0.5;

    // Slow drift for all cells: advect from upwind position.
    float drift_shift = clamp(PC.drift_cells_per_day * PC.dt_days, 0.0, 0.45);
    float hx = float(x) - u_self * drift_shift;
    float hy = float(y) - v_self * drift_shift;
    float h_drift = sample_height_wrap_x(hx, hy);
    float h_base = mix(h, h_drift, clamp(drift_shift * 1.6, 0.0, 0.7));

    if (Bnd.boundary_mask[i] == 0) {
        HOut.height_out[i] = clamp(h_base, HEIGHT_MIN, HEIGHT_MAX);
        return;
    }

    // Find nearest different-plate cell in a configurable band.
    int nx_sel = int(x);
    int ny_sel = int(y);
    float nearest_d = 1e9;
    bool found = false;
    int W = PC.width;
    int H = PC.height;
    int band = max(1, PC.band_cells);
    for (int dy = -band; dy <= band; ++dy) {
        for (int dx = -band; dx <= band; ++dx) {
            if (dx == 0 && dy == 0) continue;
            float dd = length(vec2(float(dx), float(dy)));
            if (dd > float(band) + 0.001) continue;
            int nx = int(x) + dx;
            int ny = int(y) + dy;
            // wrap-x, clamp-y
            if (nx < 0) nx = W - 1; else if (nx >= W) nx = 0;
            if (ny < 0 || ny >= H) continue;
            int j = nx + ny * W;
            int pj = PID.plate_id[j];
            if (pj != pid && dd < nearest_d) {
                nearest_d = dd;
                nx_sel = nx;
                ny_sel = ny;
                found = true;
            }
        }
    }
    if (!found) {
        HOut.height_out[i] = clamp(h_base, HEIGHT_MIN, HEIGHT_MAX);
        return;
    }

    float dirx = float(nx_sel - int(x));
    if (dirx > float(W) * 0.5) dirx -= float(W);
    else if (dirx < -float(W) * 0.5) dirx += float(W);
    float diry = float(ny_sel - int(y));
    float len = max(0.0001, sqrt(dirx * dirx + diry * diry));
    dirx /= len; diry /= len;
    int p_other = PID.plate_id[nx_sel + ny_sel * W];
    float u1 = u_self;
    float v1 = v_self;
    float u2 = (p_other >= 0 && p_other < PC.num_plates) ? PvU.plate_vel_u[p_other] : 0.0;
    float v2 = (p_other >= 0 && p_other < PC.num_plates) ? PvV.plate_vel_v[p_other] : 0.0;
    float b_other = (p_other >= 0 && p_other < PC.num_plates) ? clamp(Pb.plate_buoyancy[p_other], 0.0, 1.0) : 0.5;

    float rel_u = u2 - u1;
    float rel_v = v2 - v1;
    float shear = abs(rel_u * (-diry) + rel_v * dirx);
    float approach = -(rel_u * dirx + rel_v * diry);
    float belt_w = 1.0 - smoothstep(1.0, float(band) + 0.6, nearest_d);
    belt_w = clamp(belt_w, 0.0, 1.0);
    float boundary_w = belt_w;
    float organic = 0.72 + 0.56 * fract(sin(dot(vec2(float(x), float(y)) + vec2(float(pid), float(p_other)) * 0.37 + vec2(PC.seed_phase), vec2(27.19, 91.07))) * 13758.5453);

    float delta_h = 0.0;
    bool divergent = false;
    float divergence_floor = -1.0;
    float ocean_neighbors = 0.0;
    float neigh_count = 0.0;
    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            if (ox == 0 && oy == 0) continue;
            int ny = int(y) + oy;
            if (ny < 0 || ny >= H) continue;
            int nx = int(x) + ox;
            if (nx < 0) nx = W - 1; else if (nx >= W) nx = 0;
            float hn_ctx = HIn.height_in[nx + ny * W];
            if (hn_ctx <= PC.sea_level) ocean_neighbors += 1.0;
            neigh_count += 1.0;
        }
    }
    float ocean_ratio = (neigh_count > 0.0) ? (ocean_neighbors / neigh_count) : 0.0;
    float marine_context = smoothstep(0.12, 0.55, ocean_ratio);
    if (h_base <= PC.sea_level) {
        marine_context = max(marine_context, 0.7);
    }
    float lat_abs = abs((float(y) / max(1.0, float(H - 1))) * 2.0 - 1.0); // 0 equator .. 1 poles
    float polar_ice_guard = smoothstep(0.62, 0.90, lat_abs);
    const float conv_thresh = 0.08;
    const float div_thresh = -0.08;
    if (approach > conv_thresh) {
        float conv = approach - conv_thresh;
        // Convergent belts should be narrower than generic boundary bands.
        boundary_w = mix(pow(belt_w, 1.45), pow(belt_w, 1.18), marine_context);
        bool self_subducts = (b_self + 0.03 < b_other);
        bool other_subducts = (b_other + 0.03 < b_self);
        float buoy_contrast = abs(b_self - b_other);
        float uplift_gain = (0.50 + 0.75 * buoy_contrast);
        // Convergent boundaries should build relief, not open deep chasms.
        float marine_arc = mix(1.0, 1.16, marine_context);
        float buoy_split = 0.35 + 0.65 * buoy_contrast;
        if (self_subducts) {
            delta_h += PC.uplift_rate_per_day * PC.dt_days * conv * uplift_gain * (0.42 + 0.38 * buoy_split) * marine_arc;
        } else if (other_subducts) {
            delta_h += PC.uplift_rate_per_day * PC.dt_days * conv * uplift_gain * (0.92 + 0.26 * buoy_split) * marine_arc;
        } else {
            delta_h += PC.uplift_rate_per_day * PC.dt_days * conv * (0.68 + 0.20 * buoy_split) * marine_arc;
        }

        // Break up long linear fold-lines:
        // segment uplift along strike and carve noisy incision bands.
        float strike_u = -diry;
        float strike_v = dirx;
        float strike_coord = float(x) * strike_u + float(y) * strike_v;
        float cross_coord = float(x) * dirx + float(y) * diry;
        float n_seg0 = fract(sin(strike_coord * 0.179 + float(pid * 13 + p_other * 7) + PC.seed_phase * 57.0) * 43758.5453);
        float n_seg1 = fract(sin(strike_coord * 0.613 - cross_coord * 0.231 + float(pid * 5 - p_other * 11) + PC.seed_phase * 31.0) * 24634.6345);
        float n_seg2 = fract(sin(strike_coord * 1.337 + cross_coord * 0.417 + PC.seed_phase * 13.0) * 32768.5453);
        float ridge_segment_gain = mix(0.55, 1.25, n_seg0);
        delta_h *= ridge_segment_gain;

        float relief = max(0.0, h_base - PC.sea_level);
        float relief_w = smoothstep(0.04, 0.70, relief);
        float crest_break = smoothstep(0.72, 0.96, n_seg1) * smoothstep(0.05, 0.85, belt_w);
        float incision = PC.subduction_rate_per_day * PC.dt_days * conv * (0.10 + 0.26 * buoy_contrast);
        incision *= crest_break * relief_w * (0.65 + 0.35 * n_seg2);
        delta_h -= incision;

        // Add small strike-slip roughness so ridges read as broken ranges, not skin wrinkles.
        float shear_rough = PC.transform_roughness_per_day * PC.dt_days * (0.25 + 0.60 * shear);
        shear_rough *= (n_seg2 - 0.5) * 1.2 * belt_w;
        delta_h += shear_rough;
    } else if (approach < div_thresh) {
        divergent = true;
        float div = max(0.0, ((-approach) - (-div_thresh)) * PC.divergence_response);
        float continental_guard = 1.0 - marine_context;
        // Keep divergent deformation narrow so rifts do not widen into giant basins.
        boundary_w = mix(pow(belt_w, 2.35), pow(belt_w, 1.75), marine_context);
        float land_factor = smoothstep(PC.sea_level - 0.02, PC.sea_level + 0.35, h_base);
        // Preserve surrounding bathymetry instead of converging to a fixed sea-level offset.
        // Use local two-plate neighborhood as the divergent baseline.
        float h_other = HIn.height_in[nx_sel + ny_sel * W];
        float local_ref = mix(min(h_base, h_other), 0.5 * (h_base + h_other), 0.72);
        float n_div = fract(sin(dot(vec2(float(x), float(y)) + vec2(float(pid), float(p_other)) * 0.73 + vec2(PC.seed_phase * 2.0), vec2(41.73, 19.91))) * 24634.6345);
        float jitter = (n_div - 0.5) * mix(0.016, 0.009, land_factor);
        float land_raise = smoothstep(0.55, 1.0, land_factor) * 0.022;
        float rift_target = local_ref + jitter + land_raise;
        // In marine divergent settings, bias target toward a deeper spreading-floor state.
        float marine_target = PC.sea_level + mix(-0.22, -0.08, polar_ice_guard);
        float marine_mix = clamp(marine_context * (1.0 - 0.45 * polar_ice_guard), 0.0, 1.0);
        rift_target = mix(rift_target, min(rift_target, marine_target), marine_mix);
        float to_target = rift_target - h_base;
        float settle_rate = PC.subduction_rate_per_day * PC.dt_days * div * mix(0.34, 0.16, land_factor);
        settle_rate *= mix(1.0, 0.55, polar_ice_guard);
        delta_h += clamp(to_target, -settle_rate, settle_rate);
        // Keep a narrow deep axis only at the seam itself.
        float seam_w = smoothstep(1.60, 0.60, nearest_d);
        float deep_axis = PC.trench_rate_per_day * PC.dt_days * div * mix(1.10, 0.14, land_factor);
        deep_axis *= mix(0.12, 0.90, marine_context);
        deep_axis *= mix(1.0, 0.18, polar_ice_guard);
        delta_h -= deep_axis * seam_w * seam_w;
        // Gentle upwelling so ridge line still reads, without flattening the whole divergent zone.
        float ridge_gain = mix(0.08, 0.10, land_factor);
        ridge_gain = mix(ridge_gain, max(ridge_gain, 0.24), polar_ice_guard * 0.80);
        delta_h += PC.ridge_rate_per_day * PC.dt_days * div * ridge_gain;
        // Dynamic floor: near seam can be deeper, outside seam stays near local ocean floor.
        float seam_floor = local_ref - mix(0.30, 0.02, land_factor);
        float flank_floor = local_ref - mix(0.14, -0.005, land_factor);
        // Land divergence should not auto-create submerged trenches.
        float seam_sea_floor = PC.sea_level + mix(-0.24, 0.05, land_factor);
        float flank_sea_floor = PC.sea_level + mix(-0.12, 0.08, land_factor);
        seam_floor = max(seam_floor, seam_sea_floor);
        flank_floor = max(flank_floor, flank_sea_floor);
        divergence_floor = mix(flank_floor, seam_floor, seam_w);
        // Continental interiors should produce rift valleys first, not instant oceanic trenches.
        float continental_floor = PC.sea_level + mix(0.012, -0.04, marine_context);
        divergence_floor = max(divergence_floor, continental_floor);
        // Polar ice-sheet guard: avoid opening dark ocean rifts through ice-covered caps.
        float ice_floor = PC.sea_level + mix(-0.03, 0.09, polar_ice_guard);
        divergence_floor = max(divergence_floor, ice_floor);
        // Reduce net lowering when marine context is weak.
        delta_h *= mix(0.40, 1.0, marine_context);
        delta_h *= mix(1.0, 0.52, polar_ice_guard);
        // Preserve some rough extensional signal even under strong guard.
        if (continental_guard > 0.2) {
            float n_rift = fract(sin(dot(vec2(float(x) + 19.0, float(y) + 7.0) + vec2(PC.seed_phase * 1.7), vec2(18.9898, 67.233))) * 32768.5453);
            delta_h += PC.transform_roughness_per_day * PC.dt_days * div * (n_rift - 0.5) * 0.35 * continental_guard;
        }
    } else {
        // cheap hash noise based on coordinates
        float n = fract(sin(dot(vec2(float(x), float(y)) + vec2(PC.seed_phase), vec2(12.9898,78.233))) * 43758.5453);
        delta_h += PC.transform_roughness_per_day * PC.dt_days * (n - 0.5);
    }

    // Transform zones add rough strike-slip textures rather than major elevation jumps.
    if (approach >= div_thresh && approach <= conv_thresh) {
        float n2 = fract(sin(dot(vec2(float(x) + 31.0, float(y) + 17.0) + vec2(PC.seed_phase), vec2(21.9898,43.233))) * 24634.6345);
        delta_h += PC.transform_roughness_per_day * PC.dt_days * shear * ((n2 - 0.5) * 1.8);
    }

    float max_abs_delta = max(0.0, PC.max_boundary_delta_per_day * PC.dt_days);
    if (delta_h > 0.0) {
        // Taper uplift near the global terrain ceiling to avoid runaway needle peaks.
        float uplift_guard = 1.0 - smoothstep(HEIGHT_MAX - 0.30, HEIGHT_MAX, h_base);
        delta_h *= max(0.05, uplift_guard);
    }
    if (max_abs_delta > 0.0) {
        delta_h = clamp(delta_h, -max_abs_delta, max_abs_delta);
    }
    delta_h *= boundary_w * organic;
    float h_out = clamp(h_base + delta_h, HEIGHT_MIN, HEIGHT_MAX);
    if (divergent) {
        h_out = max(h_out, divergence_floor);
        if (polar_ice_guard > 0.001) {
            float polar_min = PC.sea_level + mix(-0.01, 0.07, polar_ice_guard);
            h_out = max(h_out, polar_min);
        }
    }
    HOut.height_out[i] = h_out;
}
