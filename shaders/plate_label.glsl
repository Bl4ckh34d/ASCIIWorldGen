#[compute]
#version 450
// File: res://shaders/plate_label.glsl
// Assign nearest plate site id to each cell with wrap-X distance.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer SiteX { int site_x[]; } SX;
layout(std430, set = 0, binding = 1) buffer SiteY { int site_y[]; } SY;
layout(std430, set = 0, binding = 2) buffer OutPlateId { int out_plate_id[]; } Out;

layout(push_constant) uniform Params {
    int width;
    int height;
    int num_sites;
} PC;

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;
    float best_d2 = 3.4e38;
    int best_idx = 0;
    for (int p = 0; p < PC.num_sites; ++p) {
        int sx = SX.site_x[p];
        int sy = SY.site_y[p];
        int dx = int(x) - sx;
        // wrap-x shortest distance
        if (dx > W / 2) dx -= W; else if (dx < -W / 2) dx += W;
        int dy = int(y) - sy;
        float d2 = float(dx * dx + dy * dy);
        if (d2 < best_d2) { best_d2 = d2; best_idx = p; }
    }
    Out.out_plate_id[i] = best_idx;
}


