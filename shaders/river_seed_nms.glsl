// File: res://shaders/river_seed_nms.glsl
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer AccumBuf { float accum[]; } Acc;
layout(set = 0, binding = 1, std430) readonly buffer IsLandBuf { uint is_land[]; } Land;
layout(set = 0, binding = 2, std430) readonly buffer FlowDirBuf { int flow_dir[]; } Flow;
layout(set = 0, binding = 3, std430) writeonly buffer SeedsBuf { uint seeds[]; } Seeds;

layout(push_constant) uniform Params { int width; int height; float threshold; } PC;

int idx(int x, int y) { return x + y * PC.width; }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;
    Seeds.seeds[i] = 0u;
    if (Land.is_land[i] == 0u) return;
    if (Flow.flow_dir[i] < 0) return;
    float a = Acc.accum[i];
    if (a < PC.threshold) return;
    // Non-maximum suppression in 8-neighborhood
    bool is_max = true;
    for (int dy = -1; dy <= 1 && is_max; dy++){
        for (int dx = -1; dx <= 1; dx++){
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx; int ny = int(y) + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int j = idx(nx, ny);
            if (Land.is_land[j] == 0u) continue;
            if (Acc.accum[j] > a) { is_max = false; break; }
        }
    }
    if (is_max) Seeds.seeds[i] = 1u;
}


