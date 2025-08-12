#[compute]
#version 450
// File: res://shaders/biome_smooth.glsl
// 3x3 majority filter for biome IDs

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer InBiome { int in_biome[]; } InB;
layout(std430, set = 0, binding = 1) buffer OutBiome { int out_biome[]; } OutB;

layout(push_constant) uniform Params {
    int width;
    int height;
} PC;

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int cx = int(x); int cy = int(y);
    int best_id = InB.in_biome[cx + cy * W];
    int best_count = -1;
    // Brute-force majority without histogram: for each neighbor, count matches in window
    for (int dy = -1; dy <= 1; ++dy){
        for (int dx = -1; dx <= 1; ++dx){
            int nx = cx + dx; int ny = cy + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int candidate = InB.in_biome[nx + ny * W];
            int cnt = 0;
            for (int dy2 = -1; dy2 <= 1; ++dy2){
                for (int dx2 = -1; dx2 <= 1; ++dx2){
                    int nx2 = cx + dx2; int ny2 = cy + dy2;
                    if (nx2 < 0 || ny2 < 0 || nx2 >= W || ny2 >= H) continue;
                    int v = InB.in_biome[nx2 + ny2 * W];
                    if (v == candidate) cnt++;
                }
            }
            if (cnt > best_count){
                best_count = cnt;
                best_id = candidate;
            }
        }
    }
    OutB.out_biome[cx + cy * W] = best_id;
}


