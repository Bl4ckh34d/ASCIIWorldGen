#[compute]
#version 450
// File: res://shaders/cloud_advection.glsl
// Cloud advection + diffusion + injection

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer InCloudBuf { float in_cloud[]; } InC;
layout(std430, set = 0, binding = 1) buffer WindUBuf { float wind_u[]; } WindU;
layout(std430, set = 0, binding = 2) buffer WindVBuf { float wind_v[]; } WindV;
layout(std430, set = 0, binding = 3) buffer SourceBuf { float source[]; } Source;
layout(std430, set = 0, binding = 4) buffer OutCloudBuf { float out_cloud[]; } OutC;

layout(push_constant) uniform Params {
    int width;
    int height;
    float adv_scale;    // cells per tick (adv_cells_per_day * dt_days)
    float diff_alpha;   // 0..1
    float inj_alpha;    // 0..1
    float structure_sharpen;
    float source_pin;
    float cloud_floor;
    float cloud_contrast;
    float cloud_global_floor;
    float detail_preserve;
    float decay_alpha;
} PC;

float clamp01(float v) { return clamp(v, 0.0, 1.0); }

// Bilinear sampling with wrap-X and clamp-Y from the InC buffer
float sample_bilinear_wrap_x(int W, int H, float fx, float fy) {
    float x = fx;
    float y = clamp(fy, 0.0, float(H - 1));
    int x0i = int(floor(x));
    int y0 = int(floor(y));
    float tx = x - float(x0i);
    float ty = y - float(y0);
    int x0 = ((x0i % W) + W) % W;
    int x1 = (x0 + 1) % W;
    int y1 = min(y0 + 1, H - 1);
    int i00 = x0 + y0 * W;
    int i10 = x1 + y0 * W;
    int i01 = x0 + y1 * W;
    int i11 = x1 + y1 * W;
    float v00 = InC.in_cloud[i00];
    float v10 = InC.in_cloud[i10];
    float v01 = InC.in_cloud[i01];
    float v11 = InC.in_cloud[i11];
    float vx0 = mix(v00, v10, tx);
    float vx1 = mix(v01, v11, tx);
    return mix(vx0, vx1, ty);
}

void main(){
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(PC.width) || y >= uint(PC.height)) return;
    int W = PC.width; int H = PC.height;
    int i = int(x) + int(y) * W;

    float u = WindU.wind_u[i];
    float v = WindV.wind_v[i];
    float sx = float(x) - PC.adv_scale * u;
    float sy = float(y) - PC.adv_scale * v;
    float adv_val = sample_bilinear_wrap_x(W, H, sx, sy);

    // Diffusion: mix with 4-neighbor mean from input field (approximate, stable)
    int l = (int(x) - 1 + W) % W + int(y) * W;
    int r = (int(x) + 1) % W + int(y) * W;
    int t = int(x) + max(0, int(y) - 1) * W;
    int b = int(x) + min(H - 1, int(y) + 1) * W;
    float nbr = (InC.in_cloud[l] + InC.in_cloud[r] + InC.in_cloud[t] + InC.in_cloud[b]) * 0.25;
    float detail = abs(adv_val - nbr);
    float keep = smoothstep(0.02, 0.18, detail) * clamp01(PC.detail_preserve);
    float local_diff = clamp01(PC.diff_alpha * (1.0 - keep));
    float diffused = mix(adv_val, nbr, local_diff);

    // Injection from humidity proxy (source)
    float src_raw = clamp01(Source.source[i]);
    float src_nbr = clamp01((Source.source[l] + Source.source[r] + Source.source[t] + Source.source[b]) * 0.25);
    float src = mix(src_raw, src_nbr, 0.35);
    float src_weight = smoothstep(0.20, 0.90, src);
    float inj = clamp01(PC.inj_alpha * mix(0.35, 1.0, src_weight));
    float injected = mix(diffused, src, inj);
    float pinned = max(injected, src * clamp01(PC.source_pin));
    // Preserve soft edges: emphasize contrast/sharpening mostly in dense cloud cores.
    float core_emphasis = smoothstep(0.30, 0.78, pinned) * smoothstep(0.20, 0.80, src_weight);
    float contrasted = clamp01((pinned - PC.cloud_floor) * max(0.01, PC.cloud_contrast));
    float tonal = mix(pinned, contrasted, core_emphasis);
    float sharpened = tonal;
    if (PC.structure_sharpen > 0.0001) {
        float sharp_k = PC.structure_sharpen * core_emphasis;
        sharpened = clamp01(tonal + (tonal - nbr) * sharp_k);
    }
    float decay = clamp01(PC.decay_alpha * (0.35 + 0.65 * (1.0 - src_weight)));
    float c = sharpened * (1.0 - decay);
    c = max(c, clamp01(PC.cloud_global_floor));
    OutC.out_cloud[i] = c;
}
