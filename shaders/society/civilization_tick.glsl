#[compute]
#version 450
// File: res://shaders/society/civilization_tick.glsl
//
// v0 civilization tick:
// - per-world-tile human population (arbitrary units)
// - deterministic emergence event after a configured day
// - crude growth based on local wildlife density
// Note: v0 intentionally avoids same-dispatch neighbor reads to keep determinism
// and avoid race conditions. Migration comes later via ping-pong buffers.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer PopBuf  { float pop[]; } BPop;
layout(std430, set = 0, binding = 1) buffer WildBuf { float wild[]; } BWild;
// meta[0]=humans_emerged (0/1), meta[1]=tech_level (0..1)
// meta[2]=war_pressure (0..1), meta[3]=global_devastation (0..1)
layout(std430, set = 0, binding = 2) buffer MetaBuf { float meta[]; } BMeta;

layout(push_constant) uniform Params {
	int width;
	int height;
	int abs_day;
	int emergence_day;
	int start_x;
	int start_y;
	int _pad0;
	int _pad1;
	float dt_days;
	float _pad2;
	float _pad3;
	float _pad4;
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
	float p = max(0.0, BPop.pop[i]);
	float w = clamp(BWild.wild[i], 0.0, 1.0);
	float war_pressure = clamp(BMeta.meta[2], 0.0, 1.0);
	float global_dev = clamp(BMeta.meta[3], 0.0, 1.0);

	// One-time deterministic emergence.
	if (gid == 0u) {
		float emerged = BMeta.meta[0];
		if (emerged < 0.5 && PC.abs_day >= PC.emergence_day) {
			int sx = wrap_x(PC.start_x, PC.width);
			int sy = clamp_y(PC.start_y, PC.height);
			int si = idx_xy(sx, sy, PC.width);
			BPop.pop[si] = max(BPop.pop[si], 6.0);
			BMeta.meta[0] = 1.0;
		}
	}

	// Crude growth/decay driven by wildlife "carrying capacity".
	float carry = 80.0 * w * (1.0 - 0.30 * global_dev); // arbitrary
	float growth = 0.0;
	if (carry > 1.0) {
		// Logistic-ish growth.
		growth = 0.08 * p * (1.0 - (p / max(1.0, carry)));
	}
	growth *= max(0.0, 1.0 - 0.45 * war_pressure - 0.35 * global_dev);
	// Starvation when wildlife is low.
	float starvation = (w < 0.15) ? (0.06 * p) : 0.0;
	// Warfare/devastation pressure hook (symbolic).
	starvation += p * (0.02 * war_pressure + 0.03 * global_dev);

	// Early survival bonus: for a short window after emergence, reduce die-off to help the first band spread.
	int since_emerge = PC.abs_day - PC.emergence_day;
	if (since_emerge >= 0 && since_emerge < 365) {
		starvation *= 0.25;
		// Also add a tiny baseline growth so small pops don't instantly collapse.
		growth += 0.02 * max(0.0, 1.0 - (p / max(1.0, carry)));
	}

	p = max(0.0, p + (growth - starvation) * PC.dt_days);
	BPop.pop[i] = p;

	// Tech-level is updated in a separate step later (requires reductions).
}
