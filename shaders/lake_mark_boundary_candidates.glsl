#[compute]
#version 450
// File: res://shaders/lake_mark_boundary_candidates.glsl
// Marks inside lake cells that border non-lake land as pour-point candidates.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer MaskBuf { uint lake_mask[]; } M;
layout(std430, set = 0, binding = 1) buffer LandBuf { uint is_land[]; } Ld;
layout(std430, set = 0, binding = 2) buffer OutBuf { uint candidates[]; } Out;

layout(push_constant) uniform Params { int width; int height; int wrap_x; } PC;

int idx(int x, int y) { return x + y * PC.width; }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;
    Out.candidates[i] = 0u;
    if (M.lake_mask[i] == 0u) return;
    // Check 8-neighborhood for any non-lake land neighbor
    for (int dy = -1; dy <= 1; dy++){
        for (int dx = -1; dx <= 1; dx++){
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx; int ny = int(y) + dy;
            if (PC.wrap_x != 0) nx = (nx % W + W) % W;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int j = idx(nx, ny);
            if (Ld.is_land[j] != 0u && M.lake_mask[j] == 0u) { Out.candidates[i] = 1u; return; }
        }
    }
}


