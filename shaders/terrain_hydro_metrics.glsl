#[compute]
#version 450
// File: res://shaders/terrain_hydro_metrics.glsl
// GPU instrumentation pass for terrain + hydro regression metrics.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer HeightBuf { float height[]; } Height;
layout(std430, set = 0, binding = 1) readonly buffer LandBuf { uint land[]; } Land;
layout(std430, set = 0, binding = 2) readonly buffer LakeBuf { uint lake[]; } Lake;
layout(std430, set = 0, binding = 3) buffer StatsBuf { uint stats[]; } Stats;

layout(push_constant) uniform Params {
	int width;
	int height;
	float sea_level;
	float slope_mean_threshold;
	float slope_peak_threshold;
	float height_sum_scale;
} PC;

const uint STAT_TOTAL_CELLS = 0u;
const uint STAT_OCEAN_CELLS = 1u;
const uint STAT_LAKE_CELLS = 2u;
const uint STAT_SLOPE_OUTLIERS = 3u;
const uint STAT_INLAND_BELOW_SEA = 4u;
const uint STAT_HEIGHT_SUM_Q = 5u;

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
	float h0 = Height.height[i];
	uint is_land = Land.land[i];
	uint is_lake = Lake.lake[i];

	atomicAdd(Stats.stats[STAT_TOTAL_CELLS], 1u);
	if (is_land == 0u) {
		atomicAdd(Stats.stats[STAT_OCEAN_CELLS], 1u);
	}
	if (is_lake != 0u) {
		atomicAdd(Stats.stats[STAT_LAKE_CELLS], 1u);
	}
	if (is_land != 0u && h0 <= PC.sea_level) {
		atomicAdd(Stats.stats[STAT_INLAND_BELOW_SEA], 1u);
	}

	float diff_sum = 0.0;
	float diff_peak = 0.0;
	int diff_count = 0;
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
			float d = abs(h0 - Height.height[j]);
			diff_sum += d;
			diff_peak = max(diff_peak, d);
			diff_count += 1;
		}
	}
	if (diff_count > 0) {
		float diff_mean = diff_sum / float(diff_count);
		if (diff_mean >= PC.slope_mean_threshold && diff_peak >= PC.slope_peak_threshold) {
			atomicAdd(Stats.stats[STAT_SLOPE_OUTLIERS], 1u);
		}
	}

	float h_norm = clamp(h0 + 1.5, 0.0, 3.5);
	uint h_q = uint(round(h_norm * max(1.0, PC.height_sum_scale)));
	atomicAdd(Stats.stats[STAT_HEIGHT_SUM_Q], h_q);
}
