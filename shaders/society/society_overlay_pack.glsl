#[compute]
#version 450
// File: res://shaders/society/society_overlay_pack.glsl
//
// Packs society buffers into a GPU texture for visualization:
//   R: human density (normalized 0..1)
//   G: wildlife density (0..1)
//   B: settlement level (0 none, ~0.33 camp, ~0.66 village, 1.0 city) derived from pop thresholds
//   A: political state id (hashed to 0..255, normalized)

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer WildBuf { float wild[]; } BWild;
layout(std430, set = 0, binding = 1) buffer PopBuf  { float pop[]; } BPop;
layout(std430, set = 0, binding = 2) buffer StateBuf { int state_id[]; } BState;
layout(rgba32f, set = 0, binding = 3) uniform image2D out_tex;

layout(push_constant) uniform Params {
	int width;
	int height;
	int _pad0;
	int _pad1;
	float pop_ref;
	float _pad2;
	float _pad3;
	float _pad4;
} PC;

float pop_to_norm(float p) {
	float ref = max(1.0, PC.pop_ref);
	// log curve to keep early growth visible and avoid saturating too early
	return clamp(log(1.0 + p) / log(1.0 + ref), 0.0, 1.0);
}

float settlement_level(float p) {
	// v0 thresholds (arbitrary units)
	if (p >= 80.0) return 1.0;   // city
	if (p >= 30.0) return 0.66;  // village/town
	if (p >= 10.0) return 0.33;  // camp
	return 0.0;
}

void main() {
	uint x = gl_GlobalInvocationID.x;
	uint y = gl_GlobalInvocationID.y;
	if (x >= uint(PC.width) || y >= uint(PC.height)) return;
	int i = int(x) + int(y) * PC.width;
	float w = clamp(BWild.wild[i], 0.0, 1.0);
	float p = max(0.0, BPop.pop[i]);
	float hn = pop_to_norm(p);
	float lvl = settlement_level(p);
	int sid = BState.state_id[i];
	float s_norm = clamp(float(sid) / 255.0, 0.0, 1.0);
	imageStore(out_tex, ivec2(int(x), int(y)), vec4(hn, w, lvl, s_norm));
}
