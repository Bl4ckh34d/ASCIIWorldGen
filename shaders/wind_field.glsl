#[compute]
#version 450
// File: res://shaders/wind_field.glsl
// Generate wind vector field (u, v) from latitudinal bands and simple eddies.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer OutUBuf { float out_u[]; } OutU;
layout(std430, set = 0, binding = 1) buffer OutVBuf { float out_v[]; } OutV;

layout(push_constant) uniform Params {
    int width;
    int height;
    float phase; // 0..1
} PC;

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    // Latitudinal coordinate 0..1: 0 at equator, 1 at pole
    float lat = abs(float(y) / max(1.0, float(H) - 1.0) - 0.5) * 2.0;

    // Zonal band component: easterlies near equator, westerlies at mid-lats, easterlies near poles
    float band_u = 0.0;
    if (lat < 0.3) {
        band_u = -1.0;
    } else if (lat < 0.7) {
        band_u = 0.8;
    } else {
        band_u = -0.6;
    }
    // Small meridional component that changes sign with latitude
    float v_band = 0.25 * sin(6.28318 * lat * 1.5);

    // Simple eddies via trigonometric noise; evolves with phase
    float fx = float(x) / max(1.0, float(W));
    float fy = float(y) / max(1.0, float(H));
    float t = PC.phase;
    float n1 = 0.5 * (sin(6.28318 * (fx * 3.1 + t * 0.8)) + cos(6.28318 * (fy * 2.7 - t * 0.6)));
    float n2 = 0.5 * (sin(6.28318 * (fx * 5.3 - t * 1.2)) + cos(6.28318 * (fy * 4.1 + t * 1.4)));
    float nu = 0.35 * (n1 + 0.5 * n2);
    float nv = 0.35 * (sin(6.28318 * (fx * 2.1 - t * 1.1)) + cos(6.28318 * (fy * 3.7 + t * 0.9))) * 0.5;

    OutU.out_u[i] = band_u + nu;
    OutV.out_v[i] = v_band + nv * 0.6;
}


