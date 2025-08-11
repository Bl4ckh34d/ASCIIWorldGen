// File: res://shaders/flow_dir.glsl
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer HeightBuf { float height_data[]; } Height;
layout(set = 0, binding = 1, std430) readonly buffer IsLandBuf { uint is_land_data[]; } Land;
layout(set = 0, binding = 2, std430) writeonly buffer FlowDirBuf { int flow_dir[]; } Flow;

layout(push_constant) uniform Params { int width; int height; int wrap_x; } PC;

int idx(int x, int y) { return x + y * PC.width; }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;
    if (Land.is_land_data[i] == 0u) { Flow.flow_dir[i] = -1; return; }
    float h0 = Height.height_data[i];
    float best_h = h0;
    int best_i = -1;
    for (int dy = -1; dy <= 1; dy++){
        for (int dx = -1; dx <= 1; dx++){
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx;
            if (PC.wrap_x == 1) nx = (nx % W + W) % W;
            int ny = int(y) + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int j = idx(nx, ny);
            float hj = Height.height_data[j];
            if (hj < best_h) { best_h = hj; best_i = j; }
        }
    }
    Flow.flow_dir[i] = best_i;
}


