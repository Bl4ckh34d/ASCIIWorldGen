#[compute]
#version 450
// File: res://shaders/plate_field_advection_i32.glsl
// Advect an i32 field (e.g. biome_id, rock_type) by local plate velocity.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer FieldInBuf { int field_in[]; } InField;
layout(std430, set = 0, binding = 1) readonly buffer PlateIdBuf { int plate_id[]; } PID;
layout(std430, set = 0, binding = 2) readonly buffer PlateVelUBuf { float plate_vel_u[]; } PvU;
layout(std430, set = 0, binding = 3) readonly buffer PlateVelVBuf { float plate_vel_v[]; } PvV;
layout(std430, set = 0, binding = 4) writeonly buffer FieldOutBuf { int field_out[]; } OutField;

layout(push_constant) uniform Params {
    int width;
    int height;
    int num_plates;
    int _pad_i0;
    float dt_days;
    float drift_cells_per_day;
    float _pad_f0;
    float _pad_f1;
} PC;

uint idx(int x, int y) { return uint(x + y * PC.width); }

void main() {
    uint gx = gl_GlobalInvocationID.x;
    uint gy = gl_GlobalInvocationID.y;
    if (gx >= uint(PC.width) || gy >= uint(PC.height)) return;

    int x = int(gx);
    int y = int(gy);
    int i = int(idx(x, y));
    int pid = PID.plate_id[i];

    float u = (pid >= 0 && pid < PC.num_plates) ? PvU.plate_vel_u[pid] : 0.0;
    float v = (pid >= 0 && pid < PC.num_plates) ? PvV.plate_vel_v[pid] : 0.0;

    // Match terrain drift stability behavior in plate_update.glsl.
    float drift_shift = clamp(PC.drift_cells_per_day * PC.dt_days, 0.0, 0.45);
    int sx = int(round(float(x) - u * drift_shift));
    int sy = int(round(float(y) - v * drift_shift));

    // wrap-x / clamp-y
    int W = PC.width;
    int H = PC.height;
    sx = ((sx % W) + W) % W;
    sy = clamp(sy, 0, H - 1);

    int si = sx + sy * W;
    OutField.field_out[i] = InField.field_in[si];
}

