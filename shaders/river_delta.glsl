#[compute]
#version 450
// File: res://shaders/river_delta.glsl
// Morphological dilation of river mask near coastline to form deltas

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer InRiver { uint in_river[]; } InR;
layout(std430, set = 0, binding = 1) buffer IsLand { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) buffer DistBuf { float water_dist[]; } DistB;
layout(std430, set = 0, binding = 3) buffer OutRiver { uint out_river[]; } OutR;

layout(push_constant) uniform Params {
    int width;
    int height;
    float max_shore_dist;
} PC;

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    uint rv = InR.in_river[i];
    if (rv != 0u) { OutR.out_river[i] = 1u; return; }
    // Only allow growth on land within the near-shore band
    if (Land.is_land[i] == 0u) { OutR.out_river[i] = 0u; return; }
    if (DistB.water_dist[i] > PC.max_shore_dist) { OutR.out_river[i] = 0u; return; }

    // Check 3x3 neighborhood for river
    bool grow = false;
    for (int dy = -1; dy <= 1 && !grow; ++dy){
        for (int dx = -1; dx <= 1 && !grow; ++dx){
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx; int ny = int(y) + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int j = nx + ny * W;
            if (InR.in_river[j] != 0u) grow = true;
        }
    }
    OutR.out_river[i] = grow ? 1u : 0u;
}


