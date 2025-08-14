#[compute]
#version 450
// File: res://shaders/river_meander.glsl
// River meander: small lateral adjustments guided by curvature and noise.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer FlowDir { int flow_dir[]; } FD;
layout(std430, set = 0, binding = 1) buffer FlowAccum { float flow_accum[]; } FA;
layout(std430, set = 0, binding = 2) buffer RiverIn { int river_in[]; } RIn;
layout(std430, set = 0, binding = 3) buffer RiverOut { int river_out[]; } ROut;

layout(push_constant) uniform Params {
    int width;
    int height;
    float dt_days;
    float lateral_rate;
    float noise_amp;
    float phase;
} PC;

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width;
    int i = int(x) + int(y) * W;
    int r = RIn.river_in[i];
    if (r == 0) { ROut.river_out[i] = 0; return; }
    // Estimate curvature by looking at flow direction differences in a 3x3 neighborhood
    int dirs[8] = int[8]( -1,-1,-1,-1,-1,-1,-1,-1 );
    int idx = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) continue;
            int nx = int(x) + dx; int ny = int(y) + dy;
            if (nx < 0 || ny < 0 || nx >= W || ny >= PC.height) continue;
            dirs[idx++] = FD.flow_dir[nx + ny * W];
        }
    }
    float curv = 0.0; int ccount = 0;
    for (int k = 0; k < 8; ++k) { if (dirs[k] >= 0) { curv += float(dirs[k]); ccount++; } }
    if (ccount > 0) curv = curv / float(ccount);
    // Noise-driven lateral bias
    float n = hash21(vec2(float(i) * 0.002 + PC.phase, float(i) * 0.001));
    float lateral = (curv - 3.5) * 0.02 + (n - 0.5) * PC.noise_amp;
    lateral *= PC.dt_days * PC.lateral_rate;
    // Move the river bit laterally by one cell probabilistically
    int nx = int(x + (lateral > 0.0 ? 1 : (lateral < 0.0 ? -1 : 0)));
    if (nx < 0) nx = 0; else if (nx >= W) nx = W - 1;
    int j = nx + int(y) * W;
    ROut.river_out[j] = 1;
}


