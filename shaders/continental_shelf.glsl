// File: res://shaders/continental_shelf.glsl
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Inputs set=0
layout(set = 0, binding = 0, std430) readonly buffer HeightBuf { float height_data[]; } Height;
layout(set = 0, binding = 1, std430) readonly buffer IsLandBuf { uint is_land_data[]; } IsLand;
layout(set = 0, binding = 2, std430) readonly buffer DistBuf { float dist_to_land[]; } Dist;
layout(set = 0, binding = 3, std430) readonly buffer ShoreNoiseBuf { float shore_noise[]; } ShoreNoise;

// Outputs set=0
layout(set = 0, binding = 4, std430) writeonly buffer OutTurqBuf { uint out_turquoise[]; } OutTurq;
layout(set = 0, binding = 5, std430) writeonly buffer OutBeachBuf { uint out_beach[]; } OutBeach;
layout(set = 0, binding = 6, std430) writeonly buffer OutTurqStrengthBuf { float out_turq_strength[]; } OutStrength;

layout(push_constant) uniform Params {
    int width;
    int height;
    float sea_level;
    float shallow_threshold;
    float shore_band;
    int wrap_x; // 1 or 0
    float noise_x_scale;
} PC;

int idx(int x, int y) { return x + y * PC.width; }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    // Init outputs default
    OutTurq.out_turquoise[i] = 0u;
    OutStrength.out_turq_strength[i] = 0.0;
    if (IsLand.is_land_data[i] != 0u) {
        OutBeach.out_beach[i] = 0u;
        return;
    }

    float depth = PC.sea_level - Height.height_data[i];
    if (depth < 0.0 || depth > PC.shallow_threshold) {
        OutBeach.out_beach[i] = 0u;
        return;
    }

    // Near-land test using distance field
    bool near_land = (Dist.dist_to_land[i] <= 1.5);
    if (!near_land) {
        OutBeach.out_beach[i] = 0u;
        return;
    }

    float nval = ShoreNoise.shore_noise[i];
    if (nval > 0.55) {
        OutTurq.out_turquoise[i] = 1u;
        // Mark beaches on neighboring land cells (unordered writes are ok)
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dy == 0) continue;
                int nx = int(x) + dx;
                if (PC.wrap_x == 1) {
                    nx = (nx % W + W) % W;
                }
                int ny = int(y) + dy;
                if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
                int ni = idx(nx, ny);
                if (IsLand.is_land_data[ni] != 0u) {
                    OutBeach.out_beach[ni] = 1u;
                }
            }
        }
    }

    // Continuous turquoise strength
    float depth2 = depth;
    if (depth2 < 0.0) depth2 = 0.0;
    float s_depth = clamp(1.0 - depth2 / PC.shallow_threshold, 0.0, 1.0);
    float s_dist = 1.0 - clamp(Dist.dist_to_land[i] / PC.shore_band, 0.0, 1.0);
    float t = clamp((nval - 0.45) / 0.15, 0.0, 1.0);
    float s_noise = t * t * (3.0 - 2.0 * t);
    float strength = clamp(s_depth * s_dist * s_noise, 0.0, 1.0);
    OutStrength.out_turq_strength[i] = strength;
    if (strength > 0.5) {
        OutTurq.out_turquoise[i] = 1u;
    }
}


