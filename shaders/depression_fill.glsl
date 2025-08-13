#[compute]
#version 450
// File: res://shaders/depression_fill.glsl
// Minimax relaxation step for drainage elevation E

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer HeightBuf { float height[]; } H;
layout(std430, set = 0, binding = 1) buffer LandBuf { uint is_land[]; } L;
layout(std430, set = 0, binding = 2) buffer EInBuf { float e_in[]; } Ein;
layout(std430, set = 0, binding = 3) buffer EOutBuf { float e_out[]; } Eout;

layout(push_constant) uniform Params { int width; int height_px; int wrap_x; int total_cells; } PC;

void main(){
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(PC.total_cells)) return;
    // Keep oceans as their own height
    if (L.is_land[i] == 0u) { Eout.e_out[i] = H.height[i]; return; }
    int W = PC.width; int Hh = PC.height_px;
    int x = int(i) % W; int y = int(i) / W;
    // Minimax relaxation: E[i] = min( E[i], min_j max( H[i], E[j] ) ) over neighbors j
    float best = Ein.e_in[i];
    // 8-neighborhood
    for (int dy = -1; dy <= 1; dy++){
        for (int dx = -1; dx <= 1; dx++){
            if (dx == 0 && dy == 0) continue;
            int nx = x + dx; int ny = y + dy;
            if (PC.wrap_x != 0) nx = (nx % W + W) % W;
            if (nx < 0 || ny < 0 || nx >= W || ny >= Hh) continue;
            int j = nx + ny * W;
            float candidate = max(H.height[i], Ein.e_in[j]);
            if (candidate < best) best = candidate;
        }
    }
    // Ensure we never go below the local terrain height
    if (best < H.height[i]) best = H.height[i];
    Eout.e_out[i] = best;
}


