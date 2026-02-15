#[compute]
#version 450
// File: res://shaders/society/npc_tick.glsl

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// needs packed as float4 per npc: (hunger, thirst, safety, wealth)
layout(std430, set = 0, binding = 0) buffer NeedsBuf { vec4 needs[]; } BNeeds;
layout(std430, set = 0, binding = 1) readonly buffer LocalMaskBuf { uint local_mask[]; } BLocal;

layout(push_constant) uniform Params {
	int npc_count;
	int abs_day;
	int _pad0;
	int _pad1;
	float dt_days;
	float need_gain_scale;
	float local_relief_scale;
	float remote_stress_scale;
} PC;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(max(0, PC.npc_count))) {
		return;
	}
	vec4 n = BNeeds.needs[i];
	// v0: drift hunger/thirst each day.
	float dt = max(0.0, PC.dt_days);
	float need_gain = clamp(PC.need_gain_scale, 0.1, 4.0);
	n.x = clamp(n.x + 0.05 * need_gain * dt, 0.0, 1.0);
	n.y = clamp(n.y + 0.06 * need_gain * dt, 0.0, 1.0);
	uint is_local = BLocal.local_mask[i];
	if (is_local != 0u) {
		// "Detailed" local region placeholder: slightly better safety recovery when not starving.
		float relief = (1.0 - n.x) * 0.010 * clamp(PC.local_relief_scale, 0.1, 4.0) * dt;
		n.z = clamp(n.z - relief, 0.0, 1.0);
	} else {
		// Simplified outside-region placeholder: slower changes.
		n.z = clamp(n.z + 0.001 * clamp(PC.remote_stress_scale, 0.1, 4.0) * dt, 0.0, 1.0);
	}
	// Wealth pressure drifts from needs; local scope can stabilize it a bit.
	float wealth_delta = ((n.x + n.y) * 0.5 - 0.45) * 0.004 * need_gain * dt;
	if (is_local != 0u) {
		wealth_delta *= 0.7;
	}
	n.w = clamp(n.w + wealth_delta, 0.0, 1.0);
	BNeeds.needs[i] = n;
}
