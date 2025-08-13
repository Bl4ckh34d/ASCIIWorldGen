#[compute]
#version 450
// File: res://shaders/mountain_radiance.glsl

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Inputs (set = 0)
layout(std430, set = 0, binding = 0) buffer InTemp { float in_temp[]; } InT;
layout(std430, set = 0, binding = 1) buffer InMoist { float in_moist[]; } InM;
layout(std430, set = 0, binding = 2) buffer BiomeBuf { int biomes[]; } Bio;

// Outputs
layout(std430, set = 0, binding = 3) buffer OutTemp { float out_temp[]; } OutT;
layout(std430, set = 0, binding = 4) buffer OutMoist { float out_moist[]; } OutM;

layout(push_constant) uniform Params {
    int width;
    int height;
    float cool_amp_per_pass;
    float wet_amp_per_pass;
} PC;

const int BIOME_MOUNTAINS = 18;
const int BIOME_ALPINE = 19;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

bool is_mountain_like(int b) {
    return (b == BIOME_MOUNTAINS) || (b == BIOME_ALPINE);
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) {
        return;
    }
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    float t = clamp01(InT.in_temp[i]);
    float m = clamp01(InM.in_moist[i]);

    // Sum influence of nearby mountain/alpine cells within radius 2
    float dt = 0.0;
    float dm = 0.0;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx;
            int ny = int(y) + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
            int j = nx + ny * W;
            int b = Bio.biomes[j];
            if (!is_mountain_like(b)) continue;
            float dist = sqrt(float(dx*dx + dy*dy));
            float fall = clamp(1.0 - dist / 3.0, 0.0, 1.0);
            dt -= PC.cool_amp_per_pass * fall;
            dm += PC.wet_amp_per_pass * fall;
        }
    }

    float t_out = clamp01(t + dt);
    float m_out = clamp01(m + dm);
    OutT.out_temp[i] = t_out;
    OutM.out_moist[i] = m_out;
}



