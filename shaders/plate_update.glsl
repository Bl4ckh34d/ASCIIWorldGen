#[compute]
#version 450
// File: res://shaders/plate_update.glsl
// Plate boundary update. For each boundary cell, compute relative plate motion
// and apply uplift/ridge/transform roughness. Writes updated height to out buffer.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer HeightIn { float height_in[]; } HIn;
layout(std430, set = 0, binding = 1) buffer PlateIdBuf { int plate_id[]; } PID;
layout(std430, set = 0, binding = 2) buffer BoundaryBuf { int boundary_mask[]; } Bnd;
layout(std430, set = 0, binding = 3) buffer PlateVelU { float plate_vel_u[]; } PvU;
layout(std430, set = 0, binding = 4) buffer PlateVelV { float plate_vel_v[]; } PvV;
layout(std430, set = 0, binding = 5) buffer HeightOut { float height_out[]; } HOut;

layout(push_constant) uniform Params {
    int width;
    int height;
    int num_plates;
    int band_cells;
    float dt_days;
    float uplift_rate_per_day;
    float ridge_rate_per_day;
    float transform_roughness_per_day;
    float seed_phase;
} PC;

uint idx(int x, int y) { return uint(x + y * PC.width); }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int i = int(idx(int(x), int(y)));
    float h = HIn.height_in[i];
    if (Bnd.boundary_mask[i] == 0) {
        HOut.height_out[i] = h;
        return;
    }
    int pid = PID.plate_id[i];
    // Find a neighbor of a different plate to approximate boundary normal
    int nx_sel = int(x);
    int ny_sel = int(y);
    bool found = false;
    int W = PC.width;
    int H = PC.height;
    for (int dy = -1; dy <= 1 && !found; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (abs(dx) + abs(dy) != 1) continue;
            int nx = int(x) + dx;
            int ny = int(y) + dy;
            // wrap-x, clamp-y
            if (nx < 0) nx = W - 1; else if (nx >= W) nx = 0;
            if (ny < 0 || ny >= H) continue;
            int j = nx + ny * W;
            if (PID.plate_id[j] != pid) {
                nx_sel = nx; ny_sel = ny; found = true; break;
            }
        }
    }
    float dirx = float(nx_sel - int(x));
    if (dirx > float(W) * 0.5) dirx -= float(W);
    else if (dirx < -float(W) * 0.5) dirx += float(W);
    float diry = float(ny_sel - int(y));
    float len = max(0.0001, sqrt(dirx * dirx + diry * diry));
    dirx /= len; diry /= len;
    int p_other = PID.plate_id[nx_sel + ny_sel * W];
    float u1 = (pid >= 0 && pid < PC.num_plates) ? PvU.plate_vel_u[pid] : 0.0;
    float v1 = (pid >= 0 && pid < PC.num_plates) ? PvV.plate_vel_v[pid] : 0.0;
    float u2 = (p_other >= 0 && p_other < PC.num_plates) ? PvU.plate_vel_u[p_other] : 0.0;
    float v2 = (p_other >= 0 && p_other < PC.num_plates) ? PvV.plate_vel_v[p_other] : 0.0;
    float rel_u = u2 - u1;
    float rel_v = v2 - v1;
    float approach = -(rel_u * dirx + rel_v * diry);
    float uplift = 0.0;
    if (approach > 0.1) {
        uplift = PC.uplift_rate_per_day * PC.dt_days * approach;
    } else if (approach < -0.1) {
        uplift = PC.ridge_rate_per_day * PC.dt_days * (-approach);
    } else {
        // cheap hash noise based on coordinates
        float n = fract(sin(dot(vec2(x,y) + PC.seed_phase, vec2(12.9898,78.233))) * 43758.5453);
        uplift = PC.transform_roughness_per_day * PC.dt_days * (n - 0.5);
    }
    // Apply to band around boundary cell (simple square of PC.band_cells)
    float hnew = h;
    for (int by = -PC.band_cells; by <= PC.band_cells; ++by) {
        for (int bx = -PC.band_cells; bx <= PC.band_cells; ++bx) {
            if (abs(bx) + abs(by) > PC.band_cells) continue;
            int xx = int(x) + bx;
            int yy = int(y) + by;
            if (xx < 0) xx = W - 1; else if (xx >= W) xx = 0;
            if (yy < 0 || yy >= H) continue;
            int ii = xx + yy * W;
            float hv = HIn.height_in[ii];
            hv = clamp(hv + uplift, -1.0, 2.0);
            // Write to output neighbor index if same invocation covers it, otherwise local sum used when ii==i
            if (ii == i) hnew = hv;
        }
    }
    HOut.height_out[i] = hnew;
}


