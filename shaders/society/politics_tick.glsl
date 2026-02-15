#[compute]
#version 450
// File: res://shaders/society/politics_tick.glsl

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer UnrestBuf { float unrest[]; } BUnrest;

layout(push_constant) uniform Params {
	int province_count;
	int abs_day;
	int _pad0;
	int _pad1;
	float dt_days;
	float unrest_decay_scale;
	float unrest_drift;
	float _pad4;
} PC;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(max(0, PC.province_count))) {
		return;
	}
	// v0 placeholder: unrest decays slowly.
	float u = BUnrest.unrest[i];
	float dt = max(0.0, PC.dt_days);
	float decay = 0.002 * clamp(PC.unrest_decay_scale, 0.1, 4.0);
	float drift = clamp(PC.unrest_drift, -0.01, 0.01);
	u = clamp(u + (drift - decay) * dt, 0.0, 1.0);
	BUnrest.unrest[i] = u;
}
