#[compute]
#version 450
// File: res://shaders/lake_label_from_mask.glsl
// Propagate labels only where lake_mask==1

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer MaskBuf { uint lake_mask[]; } M;
layout(std430, set = 0, binding = 1) buffer LabelsBuf { int labels[]; } L;
layout(std430, set = 0, binding = 2) buffer ChangedBuf { uint flag[]; } Changed;

layout(push_constant) uniform Params { int width; int height; int wrap_x; } PC;

int idx(int x, int y) { return x + y * PC.width; }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;
    if (M.lake_mask[i] == 0u) return;
    int best = L.labels[i];
    for (int dy = -1; dy <= 1; dy++){
        for (int dx = -1; dx <= 1; dx++){
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx; int ny = int(y) + dy;
            if (PC.wrap_x != 0) nx = (nx % W + W) % W;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int j = idx(nx, ny);
            if (M.lake_mask[j] == 0u) continue;
            int lbl = L.labels[j];
            if (lbl > 0 && (best == 0 || lbl < best)) best = lbl;
        }
    }
    if (best > 0 && best != L.labels[i]) {
        L.labels[i] = best;
        Changed.flag[0] = 1u;
    }
}


