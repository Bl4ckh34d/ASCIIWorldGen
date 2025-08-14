#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer HeightBuf { float height_data[]; } Height;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land_data[]; } Land;
layout(std430, set = 0, binding = 2) buffer FlowDirBuf { int flow_dir[]; } Flow;

layout(push_constant) uniform Params {
    int width;
    int height;
    int wrap_x;
    int roi_x0;
    int roi_y0;
    int roi_x1;
    int roi_y1;
} PC;

int idx(int x, int y) { return x + y * PC.width; }

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    // ROI early-out: skip work outside tile
    if (int(x) < PC.roi_x0 || int(x) >= PC.roi_x1 || int(y) < PC.roi_y0 || int(y) >= PC.roi_y1) {
        return;
    }
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


