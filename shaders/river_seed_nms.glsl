#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer AccumBuf { float accum[]; } Acc;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) buffer FlowDirBuf { int flow_dir[]; } Flow;
layout(std430, set = 0, binding = 3) buffer SeedsBuf { uint seeds[]; } Seeds;

layout(push_constant) uniform Params { int width; int height; float threshold; int rx0; int ry0; int rx1; int ry1; } PC;

int idx(int x, int y) { return x + y * PC.width; }
const int NMS_RADIUS = 2;
const float NMS_EPS = 1.0e-6;

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;
    Seeds.seeds[i] = 0u;
    if (Land.is_land[i] == 0u) return;
    if (Flow.flow_dir[i] < 0) return;
    // Check ROI bounds - only seed within the specified region
    if (int(x) < PC.rx0 || int(x) >= PC.rx1 || int(y) < PC.ry0 || int(y) >= PC.ry1) return;
    float a = Acc.accum[i];
    if (a < PC.threshold) return;
    // Wider non-maximum suppression (5x5): keeps only dominant channel seeds.
    bool is_max = true;
    for (int dy = -NMS_RADIUS; dy <= NMS_RADIUS && is_max; dy++){
        for (int dx = -NMS_RADIUS; dx <= NMS_RADIUS; dx++){
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx; int ny = int(y) + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int j = idx(nx, ny);
            if (Land.is_land[j] == 0u) continue;
            float aj = Acc.accum[j];
            if (aj > a + NMS_EPS) { is_max = false; break; }
            // Deterministic tie-break so flat maxima produce one seed, not clusters.
            if (abs(aj - a) <= NMS_EPS && j < i) { is_max = false; break; }
        }
    }
    if (is_max) Seeds.seeds[i] = 1u;
}


