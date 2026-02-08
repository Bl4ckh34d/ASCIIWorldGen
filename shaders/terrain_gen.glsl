#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Inputs (set=0)
layout(std430, set = 0, binding = 0) buffer WarpXBuf { float warp_x[]; } WarpX;
layout(std430, set = 0, binding = 1) buffer WarpYBuf { float warp_y[]; } WarpY;
layout(std430, set = 0, binding = 2) buffer FbmBuf   { float fbm_base[]; } Fbm;
layout(std430, set = 0, binding = 3) buffer ContBuf  { float cont_base[]; } Cont;

// Outputs (set=0)
layout(std430, set = 0, binding = 4) buffer OutHeightBuf { float out_height[]; } OutH;
layout(std430, set = 0, binding = 5) buffer OutLandBuf   { uint  out_land[]; } OutLand;

layout(push_constant) uniform Params {
    int width;
    int height;
    int wrap_x;
    float sea_level;
    float noise_x_scale;
    float warp_amount;
} PC;

int idx(int x, int y) { return x + y * PC.width; }

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

// Specialized bilinear samplers for SSBO-backed arrays (cannot pass unsized arrays as params)
float sample_bilinear_fbm(int W, int H, float fx, float fy){
    float x = clamp(fx, 0.0, float(W - 1));
    float y = clamp(fy, 0.0, float(H - 1));
    int x0 = int(floor(x));
    int y0 = int(floor(y));
    int x1 = min(x0 + 1, W - 1);
    int y1 = min(y0 + 1, H - 1);
    float tx = x - float(x0);
    float ty = y - float(y0);
    int i00 = x0 + y0 * W;
    int i10 = x1 + y0 * W;
    int i01 = x0 + y1 * W;
    int i11 = x1 + y1 * W;
    float v00 = Fbm.fbm_base[i00];
    float v10 = Fbm.fbm_base[i10];
    float v01 = Fbm.fbm_base[i01];
    float v11 = Fbm.fbm_base[i11];
    float vx0 = mix(v00, v10, tx);
    float vx1 = mix(v01, v11, tx);
    return mix(vx0, vx1, ty);
}

float sample_bilinear_cont(int W, int H, float fx, float fy){
    float x = clamp(fx, 0.0, float(W - 1));
    float y = clamp(fy, 0.0, float(H - 1));
    int x0 = int(floor(x));
    int y0 = int(floor(y));
    int x1 = min(x0 + 1, W - 1);
    int y1 = min(y0 + 1, H - 1);
    float tx = x - float(x0);
    float ty = y - float(y0);
    int i00 = x0 + y0 * W;
    int i10 = x1 + y0 * W;
    int i01 = x0 + y1 * W;
    int i11 = x1 + y1 * W;
    float v00 = Cont.cont_base[i00];
    float v10 = Cont.cont_base[i10];
    float v01 = Cont.cont_base[i01];
    float v11 = Cont.cont_base[i11];
    float vx0 = mix(v00, v10, tx);
    float vx1 = mix(v01, v11, tx);
    return mix(vx0, vx1, ty);
}

float sample_bilinear_wrapx_fbm(int W, int H, float fx, float fy){
    float x = fx; // wrap in X
    float y = clamp(fy, 0.0, float(H - 1));
    // wrap x into [0, W)
    float xw = x - floor(x / float(W)) * float(W);
    int x0 = int(floor(xw));
    int y0 = int(floor(y));
    int x1 = (x0 + 1) % W;
    int y1 = min(y0 + 1, H - 1);
    float tx = xw - float(x0);
    float ty = y - float(y0);
    int i00 = x0 + y0 * W;
    int i10 = x1 + y0 * W;
    int i01 = x0 + y1 * W;
    int i11 = x1 + y1 * W;
    float v00 = Fbm.fbm_base[i00];
    float v10 = Fbm.fbm_base[i10];
    float v01 = Fbm.fbm_base[i01];
    float v11 = Fbm.fbm_base[i11];
    float vx0 = mix(v00, v10, tx);
    float vx1 = mix(v01, v11, tx);
    return mix(vx0, vx1, ty);
}

float sample_bilinear_wrapx_cont(int W, int H, float fx, float fy){
    float x = fx; // wrap in X
    float y = clamp(fy, 0.0, float(H - 1));
    float xw = x - floor(x / float(W)) * float(W);
    int x0 = int(floor(xw));
    int y0 = int(floor(y));
    int x1 = (x0 + 1) % W;
    int y1 = min(y0 + 1, H - 1);
    float tx = xw - float(x0);
    float ty = y - float(y0);
    int i00 = x0 + y0 * W;
    int i10 = x1 + y0 * W;
    int i01 = x0 + y1 * W;
    int i11 = x1 + y1 * W;
    float v00 = Cont.cont_base[i00];
    float v10 = Cont.cont_base[i10];
    float v01 = Cont.cont_base[i01];
    float v11 = Cont.cont_base[i11];
    float vx0 = mix(v00, v10, tx);
    float vx1 = mix(v01, v11, tx);
    return mix(vx0, vx1, ty);
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width;
    int H = PC.height;
    int i = int(x) + int(y) * W;

    float wx = WarpX.warp_x[i];
    float wy = WarpY.warp_y[i];
    float sx = float(x) + wx;
    float sy = float(y) + wy;

    // Sample base FBM and continental fields with optional wrap-X
    float fbm;
    float cont;
    if (PC.wrap_x == 1) {
        fbm = sample_bilinear_wrapx_fbm(W, H, sx, sy);
        cont = sample_bilinear_wrapx_cont(W, H, float(x), float(y));
    } else {
        fbm = sample_bilinear_fbm(W, H, sx, sy);
        cont = sample_bilinear_cont(W, H, float(x), float(y));
    }

    // CPU-parity height shaping.
    float hval = 0.65 * fbm + 0.45 * cont;
    // Basic circular falloff when not wrapping X
    if (PC.wrap_x == 0) {
        float cx = float(W) * 0.5;
        float cy = float(H) * 0.5;
        float dx = float(x) - cx;
        float dy = float(y) - cy;
        float max_r = sqrt(cx * cx + cy * cy);
        float r = sqrt(dx * dx + dy * dy) / max_r;
        float falloff = clamp(1.0 - r * 0.85, 0.0, 1.0);
        hval = hval * 0.85 + falloff * 0.15;
    }
    // Signed-power shaping and contrast boost (matches TerrainNoise CPU path).
    float gamma = 0.65;
    float a = abs(hval);
    hval = (hval >= 0.0 ? 1.0 : -1.0) * pow(a, gamma);
    hval *= 1.10;
    hval = clamp(hval, -1.0, 1.0);

    OutH.out_height[i] = hval;
    OutLand.out_land[i] = (hval > PC.sea_level) ? 1u : 0u;
}
