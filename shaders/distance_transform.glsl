// File: res://shaders/distance_transform.glsl
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer LandBuf { uint is_land[]; } Land;
layout(set = 0, binding = 1, std430) readonly buffer DistInBuf { float dist_in[]; } DistIn;
layout(set = 0, binding = 2, std430) writeonly buffer DistOutBuf { float dist_out[]; } DistOut;

layout(push_constant) uniform Params { int width; int height; int wrap_x; int mode; } PC; // mode: 0 fwd, 1 bwd

int idx(int x, int y) { return x + y * PC.width; }

float min3(float a, float b, float c) { return min(min(a,b), c); }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;

    // Always keep land at 0
    if (Land.is_land[i] != 0u) {
        DistOut.dist_out[i] = 0.0;
        return;
    }

    float cur = DistIn.dist_in[i];
    float best = cur;

    // Costs: orthogonal = 1.0, diagonal = 1.4142135
    const float C1 = 1.0;
    const float C2 = 1.4142135;

    if (PC.mode == 0) {
        // forward: neighbors above and left
        int xl = int(x) - 1; if (PC.wrap_x == 1) xl = (xl % W + W) % W;
        int xr = int(x) + 1; if (PC.wrap_x == 1) xr = (xr % W + W) % W;
        int yt = int(y) - 1;
        // left
        if (xl >= 0 && xl < W) best = min(best, DistIn.dist_in[idx(xl, int(y))] + C1);
        // top
        if (yt >= 0) best = min(best, DistIn.dist_in[idx(int(x), yt)] + C1);
        // top-left
        if (yt >= 0 && xl >= 0 && xl < W) best = min(best, DistIn.dist_in[idx(xl, yt)] + C2);
        // top-right
        if (yt >= 0) best = min(best, DistIn.dist_in[idx(xr < W ? xr : (PC.wrap_x == 1 ? (xr % W) : W - 1), yt)] + C2);
    } else {
        // backward: neighbors below and right
        int xl = int(x) - 1; if (PC.wrap_x == 1) xl = (xl % W + W) % W;
        int xr = int(x) + 1; if (PC.wrap_x == 1) xr = (xr % W + W) % W;
        int yb = int(y) + 1;
        // right
        if (xr < W || PC.wrap_x == 1) best = min(best, DistIn.dist_in[idx(xr < W ? xr : (xr % W), int(y))] + C1);
        // bottom
        if (yb < H) best = min(best, DistIn.dist_in[idx(int(x), yb)] + C1);
        // bottom-left
        if (yb < H) best = min(best, DistIn.dist_in[idx(xl, yb)] + C2);
        // bottom-right
        if (yb < H) best = min(best, DistIn.dist_in[idx(xr < W ? xr : (xr % W), yb)] + C2);
    }

    DistOut.dist_out[i] = best;
}


