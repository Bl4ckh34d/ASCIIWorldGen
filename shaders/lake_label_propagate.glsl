#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer LandBuf { uint land[]; } Land; // 1=land,0=water
layout(std430, set = 0, binding = 1) buffer LabelBuf { int labels[]; } Lbl;

layout(push_constant) uniform Params { int width; int height; int wrap_x; } PC;

int idx(int x, int y) { return x + y * PC.width; }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;
    if (Land.land[i] != 0u) { Lbl.labels[i] = 0; return; }
    int best = Lbl.labels[i];
    for (int dy = -1; dy <= 1; dy++){
        for (int dx = -1; dx <= 1; dx++){
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx;
            if (PC.wrap_x == 1) nx = (nx % W + W) % W;
            int ny = int(y) + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int j = idx(nx, ny);
            if (Land.land[j] != 0u) continue;
            int v = Lbl.labels[j];
            if (v > best) best = v;
        }
    }
    Lbl.labels[i] = best;
}


