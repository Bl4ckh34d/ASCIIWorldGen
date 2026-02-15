#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer LandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 1) buffer DistInBuf { float dist_in[]; } DistIn;
layout(std430, set = 0, binding = 2) buffer DistOutBuf { float dist_out[]; } DistOut;

layout(push_constant) uniform Params { int width; int height; int wrap_x; int mode; } PC; // mode: 0 fwd, 1 bwd, 2 seed

int idx(int x, int y) { return x + y * PC.width; }
int wrap_x_idx(int x, int w) { int r = x % w; return (r < 0) ? (r + w) : r; }
bool valid_x(int x, int w) { return x >= 0 && x < w; }

// Avoid built-in min precision overload issues by using explicit helpers
float minf(float a, float b) { return a < b ? a : b; }

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height; int i = int(x) + int(y) * W;

    if (PC.mode == 2) {
        DistOut.dist_out[i] = (Land.is_land[i] != 0u) ? 0.0 : 1e9;
        return;
    }

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
        int xl = int(x) - 1;
        int xr = int(x) + 1;
        if (PC.wrap_x == 1) {
            xl = wrap_x_idx(xl, W);
            xr = wrap_x_idx(xr, W);
        }
        int yt = int(y) - 1;
        // left
        if (valid_x(xl, W)) best = minf(best, DistIn.dist_in[idx(xl, int(y))] + C1);
        // top
        if (yt >= 0) best = minf(best, DistIn.dist_in[idx(int(x), yt)] + C1);
        // top-left
        if (yt >= 0 && valid_x(xl, W)) best = minf(best, DistIn.dist_in[idx(xl, yt)] + C2);
        // top-right
        if (yt >= 0 && valid_x(xr, W)) best = minf(best, DistIn.dist_in[idx(xr, yt)] + C2);
    } else {
        // backward: neighbors below and right
        int xl = int(x) - 1;
        int xr = int(x) + 1;
        if (PC.wrap_x == 1) {
            xl = wrap_x_idx(xl, W);
            xr = wrap_x_idx(xr, W);
        }
        int yb = int(y) + 1;
        // right
        if (valid_x(xr, W)) best = minf(best, DistIn.dist_in[idx(xr, int(y))] + C1);
        // bottom
        if (yb < H) best = minf(best, DistIn.dist_in[idx(int(x), yb)] + C1);
        // bottom-left
        if (yb < H && valid_x(xl, W)) best = minf(best, DistIn.dist_in[idx(xl, yb)] + C2);
        // bottom-right
        if (yb < H && valid_x(xr, W)) best = minf(best, DistIn.dist_in[idx(xr, yb)] + C2);
    }

    DistOut.dist_out[i] = best;
}
