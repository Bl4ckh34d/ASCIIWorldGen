#[compute]
#version 450
// File: res://shaders/plate_boundary_mask.glsl
// Build boundary mask (4-neighborhood) from plate_id with wrap-X neighbors.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer PlateId { int plate_id[]; } PID;
layout(std430, set = 0, binding = 1) buffer OutBoundary { int boundary_mask[]; } Bnd;

layout(push_constant) uniform Params {
    int width;
    int height;
} PC;

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;
    int pid = PID.plate_id[i];
    bool is_boundary = false;
    int nx, ny;
    // left
    nx = int(x) - 1; ny = int(y);
    if (nx < 0) nx = W - 1;
    if (PID.plate_id[nx + ny * W] != pid) is_boundary = true;
    // right
    nx = int(x) + 1; ny = int(y);
    if (nx >= W) nx = 0;
    if (PID.plate_id[nx + ny * W] != pid) is_boundary = true;
    // up (clamp y)
    nx = int(x); ny = max(0, int(y) - 1);
    if (PID.plate_id[nx + ny * W] != pid) is_boundary = true;
    // down (clamp y)
    nx = int(x); ny = min(H - 1, int(y) + 1);
    if (PID.plate_id[nx + ny * W] != pid) is_boundary = true;
    Bnd.boundary_mask[i] = is_boundary ? 1 : 0;
}


