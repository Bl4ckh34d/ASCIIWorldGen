#[compute]
#version 450
// File: res://shaders/terrain_relax.glsl
// Slope-limited relaxation pass for heightfield stability.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer HeightInBuf { float height_in[]; } HeightIn;
layout(std430, set = 0, binding = 1) readonly buffer BoundaryBuf { int boundary_mask[]; } Boundary;
layout(std430, set = 0, binding = 2) readonly buffer LavaBuf { float lava[]; } Lava;
layout(std430, set = 0, binding = 3) writeonly buffer HeightOutBuf { float height_out[]; } HeightOut;

layout(push_constant) uniform Params {
	int width;
	int height;
	int has_lava;
	int _pad_i0;
	float sea_level;
	float max_delta_interior;
	float max_delta_boundary;
	float relax_rate;
	float max_step_per_iter;
} PC;

int idx_wrap_x(int x, int y) {
	int xx = (x + PC.width) % PC.width;
	return xx + y * PC.width;
}

void main() {
	uint gx = gl_GlobalInvocationID.x;
	uint gy = gl_GlobalInvocationID.y;
	if (gx >= uint(PC.width) || gy >= uint(PC.height)) {
		return;
	}

	int x = int(gx);
	int y = int(gy);
	int i = x + y * PC.width;

	float h0 = HeightIn.height_in[i];
	float delta = 0.0;
	float w_sum = 0.0;
	float self_b = (Boundary.boundary_mask[i] != 0) ? 1.0 : 0.0;
	float lava_boost = (PC.has_lava == 1) ? clamp(Lava.lava[i], 0.0, 1.0) : 0.0;

	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			int ny = y + oy;
			if (ny < 0 || ny >= PC.height) {
				continue;
			}
			int j = idx_wrap_x(x + ox, ny);
			float hn = HeightIn.height_in[j];
			float nb_b = (Boundary.boundary_mask[j] != 0) ? 1.0 : 0.0;
			float bmix = max(self_b, nb_b);
			float allowed = mix(PC.max_delta_interior, PC.max_delta_boundary, bmix);
			// Preserve steeper vents and lava ramps where active volcanism exists.
			allowed *= mix(1.0, 1.75, lava_boost);

			float dh = h0 - hn;
			float excess = abs(dh) - allowed;
			if (excess <= 0.0) {
				continue;
			}
			float flux = PC.relax_rate * excess;
			// Diagonals relax slightly less to avoid checkerboard artifacts.
			float n_w = (abs(ox) + abs(oy) == 2) ? 0.70710678 : 1.0;
			if (dh > 0.0) {
				delta -= flux * n_w;
			} else {
				delta += flux * n_w;
			}
			w_sum += n_w;
		}
	}

	float d = (w_sum > 0.0) ? (delta / w_sum) : 0.0;
	d = clamp(d, -PC.max_step_per_iter, PC.max_step_per_iter);

	float h_out = clamp(h0 + d, -1.0, 2.0);
	HeightOut.height_out[i] = h_out;
}
