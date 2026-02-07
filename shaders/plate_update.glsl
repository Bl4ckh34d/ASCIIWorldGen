#[compute]
#version 450
// File: res://shaders/plate_update.glsl
// Plate update with stylized but more realistic tectonic behavior:
// - Slow plate drift (advection-like lateral transport)
// - Convergent boundaries: overriding-plate uplift + subducting-plate trench carving
// - Divergent boundaries: rifts are net extensional lowering where appropriate
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
} PC;

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
        HOut.height_out[i] = clamp(h_base, -1.0, 2.0);
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
        HOut.height_out[i] = clamp(h_base, -1.0, 2.0);
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
    const float conv_thresh = 0.08;
    const float div_thresh = -0.08;
    if (approach > conv_thresh) {
        float conv = approach - conv_thresh;
        bool self_subducts = (b_self + 0.03 < b_other);
        bool other_subducts = (b_other + 0.03 < b_self);
        float buoy_contrast = abs(b_self - b_other);
        float uplift_gain = (0.50 + 0.75 * buoy_contrast);
        float trench_gain = (0.72 + 1.05 * buoy_contrast);
        if (self_subducts) {
            delta_h += PC.uplift_rate_per_day * PC.dt_days * conv * uplift_gain * 0.18;
            delta_h -= PC.subduction_rate_per_day * PC.dt_days * conv * trench_gain;
            delta_h -= PC.trench_rate_per_day * PC.dt_days * conv * trench_gain * 0.58;
        } else if (other_subducts) {
            delta_h += PC.uplift_rate_per_day * PC.dt_days * conv * uplift_gain * 0.88;
            delta_h -= PC.trench_rate_per_day * PC.dt_days * conv * trench_gain * 0.16;
        } else {
            delta_h += PC.uplift_rate_per_day * PC.dt_days * conv * 0.58;
            delta_h -= PC.trench_rate_per_day * PC.dt_days * conv * 0.08;
        }
    } else if (approach < div_thresh) {
        divergent = true;
        float div = (-approach) - (-div_thresh);
        // Keep divergent deformation narrow so rifts do not widen into giant basins.
        boundary_w = pow(belt_w, 2.25);
        float land_factor = smoothstep(PC.sea_level - 0.02, PC.sea_level + 0.35, h_base);
        // Mid-ocean divergence should trend toward elevated young crust, not endlessly deepen.
        float rift_target = mix(PC.sea_level - 0.16, PC.sea_level - 0.08, land_factor);
        float to_target = rift_target - h_base;
        float settle_rate = PC.subduction_rate_per_day * PC.dt_days * div * mix(0.40, 0.26, land_factor);
        delta_h += clamp(to_target, -settle_rate, settle_rate);
        // Add subtle upwelling so active ridge axes stay visible.
        float ridge_gain = mix(0.44, 0.16, land_factor);
        delta_h += PC.ridge_rate_per_day * PC.dt_days * div * ridge_gain;
        // Hard floor to prevent runaway abyssal deepening on persistent divergent seams.
        divergence_floor = mix(PC.sea_level - 0.24, PC.sea_level - 0.12, land_factor);
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

    delta_h *= boundary_w * organic;
    float h_out = clamp(h_base + delta_h, -1.0, 2.0);
    if (divergent) {
        h_out = max(h_out, divergence_floor);
    }
    HOut.height_out[i] = h_out;
}
