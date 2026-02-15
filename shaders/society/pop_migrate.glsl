#[compute]
#version 450
// File: res://shaders/society/pop_migrate.glsl
//
// v0 migration pass (ping-pong):
// Reads pop_in and wildlife and writes pop_out.
//
// Note: No atomics. This implements a conservative, deterministic local smoothing that
// biases staying put unless local wildlife is low. It's intentionally "symbolic".

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer PopInBuf  { float pop_in[]; } BIn;
layout(std430, set = 0, binding = 1) buffer WildBuf   { float wild[]; } BWild;
layout(std430, set = 0, binding = 2) buffer PopOutBuf { float pop_out[]; } BOut;

layout(push_constant) uniform Params {
	int width;
	int height;
	int abs_day;
	int _pad0;
	float dt_days;
	float move_rate;
	float wildlife_low;
	float _pad3;
} PC;

int wrap_x(int x, int w) {
	int r = x % w;
	return (r < 0) ? (r + w) : r;
}

int clamp_y(int y, int h) {
	return clamp(y, 0, h - 1);
}

int idx_xy(int x, int y, int w) {
	return x + y * w;
}

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint total = uint(max(0, PC.width * PC.height));
	if (gid >= total) return;

	int i = int(gid);
	float pC = max(0.0, BIn.pop_in[i]);

	int x = i % PC.width;
	int y = i / PC.width;
	int xL = wrap_x(x - 1, PC.width);
	int xR = wrap_x(x + 1, PC.width);
	int yU = clamp_y(y - 1, PC.height);
	int yD = clamp_y(y + 1, PC.height);
	int iL = idx_xy(xL, y, PC.width);
	int iR = idx_xy(xR, y, PC.width);
	int iU = idx_xy(x, yU, PC.width);
	int iD = idx_xy(x, yD, PC.width);

	float wC = clamp(BWild.wild[i], 0.0, 1.0);
	float wL = clamp(BWild.wild[iL], 0.0, 1.0);
	float wR = clamp(BWild.wild[iR], 0.0, 1.0);
	float wU = clamp(BWild.wild[iU], 0.0, 1.0);
	float wD = clamp(BWild.wild[iD], 0.0, 1.0);

	float pL = max(0.0, BIn.pop_in[iL]);
	float pR = max(0.0, BIn.pop_in[iR]);
	float pU = max(0.0, BIn.pop_in[iU]);
	float pD = max(0.0, BIn.pop_in[iD]);

	// Migration is always possible (exploration/spread), but becomes much stronger when wildlife is low.
	float low = smoothstep(PC.wildlife_low, 0.0, wC); // 0 when high wildlife, 1 when very low
	float k_base = 0.18;
	float k = clamp(PC.move_rate * PC.dt_days, 0.0, 0.25) * mix(k_base, 1.0, low);

	// Prefer neighbors with higher wildlife.
	float aL = max(0.0, wL - wC);
	float aR = max(0.0, wR - wC);
	float aU = max(0.0, wU - wC);
	float aD = max(0.0, wD - wC);
	float sumA = aL + aR + aU + aD;

	// Local smoothing component.
	float neigh_mean = 0.25 * (pL + pR + pU + pD);
	float smoothed = mix(pC, neigh_mean, k);

	// Bias towards the best neighbor direction a bit.
	float best_w = max(max(wL, wR), max(wU, wD));
	float dir_bias = smoothstep(0.02, 0.25, best_w - wC);
	float dir_k = k * dir_bias;
	float outp = smoothed;
	if (sumA > 1e-6 && dir_k > 0.0) {
		float target = (pC * 0.85 + neigh_mean * 0.15);
		outp = mix(outp, target, dir_k * 0.25);
	}

	BOut.pop_out[i] = max(0.0, outp);
}
