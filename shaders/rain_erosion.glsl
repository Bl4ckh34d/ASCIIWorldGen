#[compute]
#version 450
// File: res://shaders/rain_erosion.glsl
// GPU terrain erosion pass.
// Rainfall erosion on normal land + glacial erosion on cryosphere land.
// Skips non-erodible cells: water, lakes, lava.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer HeightInBuf { float height_in[]; } HeightIn;
layout(std430, set = 0, binding = 1) readonly buffer MoistureBuf { float moisture[]; } Moisture;
layout(std430, set = 0, binding = 2) readonly buffer FlowAccumBuf { float flow_accum[]; } Flow;
layout(std430, set = 0, binding = 3) readonly buffer LandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 4) readonly buffer LakeBuf { uint lake_mask[]; } Lake;
layout(std430, set = 0, binding = 5) readonly buffer LavaBuf { float lava[]; } Lava;
layout(std430, set = 0, binding = 6) readonly buffer BiomeBuf { int biome_id[]; } Biome;
layout(std430, set = 0, binding = 7) writeonly buffer HeightOutBuf { float height_out[]; } HeightOut;

layout(push_constant) uniform Params {
	int width;
	int height;
	int biome_ice_sheet_id;
	int biome_glacier_id;
	int biome_desert_ice_id;
	int _pad_i0;
	int _pad_i1;
	int _pad_i2;
	float dt_days;
	float sea_level;
	float base_rate_per_day;
	float max_rate_per_day;
	float noise_phase;
	float _pad0;
	float _pad1;
	float _pad2;
} PC;

int index_of(int x, int y) {
	return x + y * PC.width;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void main() {
	uint gx = gl_GlobalInvocationID.x;
	uint gy = gl_GlobalInvocationID.y;
	if (gx >= uint(PC.width) || gy >= uint(PC.height)) {
		return;
	}

	int x = int(gx);
	int y = int(gy);
	int i = index_of(x, y);

	float h0 = HeightIn.height_in[i];

	// Fast hard masks: no erosion outside active rocky land.
	if (Land.is_land[i] == 0u) {
		HeightOut.height_out[i] = h0;
		return;
	}
	if (Lake.lake_mask[i] != 0u) {
		HeightOut.height_out[i] = h0;
		return;
	}
	if (Lava.lava[i] > 0.5) {
		HeightOut.height_out[i] = h0;
		return;
	}
	int bid = Biome.biome_id[i];
	bool is_cryo = (bid == PC.biome_ice_sheet_id || bid == PC.biome_glacier_id || bid == PC.biome_desert_ice_id);

	float above_sea = h0 - PC.sea_level;
	if (above_sea <= -0.005) {
		HeightOut.height_out[i] = h0;
		return;
	}

	float best_drop = 0.0;
	float slope_sum = 0.0;
	int slope_count = 0;
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			int ny = y + oy;
			if (ny < 0 || ny >= PC.height) {
				continue;
			}
			int nx = (x + ox + PC.width) % PC.width;
			float hn = HeightIn.height_in[index_of(nx, ny)];
			float dh = h0 - hn;
			if (dh > best_drop) {
				best_drop = dh;
			}
			slope_sum += abs(dh);
			slope_count++;
		}
	}

	if (best_drop <= 0.0 || slope_count <= 0) {
		HeightOut.height_out[i] = h0;
		return;
	}

	float avg_slope = slope_sum / float(slope_count);
	float slope_drive = clamp((best_drop * 0.74 + avg_slope * 0.26 - 0.0007) / 0.06, 0.0, 1.0);
	if (slope_drive <= 0.0) {
		HeightOut.height_out[i] = h0;
		return;
	}

	float shape_noise = 0.82 + 0.36 * hash12(vec2(float(x), float(y)) + vec2(PC.noise_phase, PC.noise_phase * 0.37));
	float erode = 0.0;
	float erode_cap = 0.0;

	if (is_cryo) {
		// Glacial abrasion/plucking:
		// - driven primarily by slope and relief
		// - weakly coupled to moisture as a proxy for ice throughput
		// - stronger at higher elevations where persistent ice survives
		float moist = clamp(Moisture.moisture[i], 0.0, 1.0);
		float ice_flux = 0.45 + 0.55 * moist;
		float cryo_relief = clamp((best_drop * 0.70 + avg_slope * 0.30 - 0.0004) / 0.045, 0.0, 1.0);
		float cryo_altitude = 0.65 + 0.85 * clamp((above_sea - 0.02) / 0.65, 0.0, 1.0);
		float cryo_rate = PC.base_rate_per_day * 2.1;
		float cryo_rate_max = PC.max_rate_per_day * 2.4;
		erode = PC.dt_days * cryo_rate * cryo_relief * cryo_altitude * ice_flux * (0.88 + 0.24 * shape_noise);
		erode_cap = min(cryo_rate_max * PC.dt_days, best_drop * 0.52);
	} else {
		float moist = clamp(Moisture.moisture[i], 0.0, 1.0);
		float flow = max(0.0, Flow.flow_accum[i]);
		float flow_drive = flow / (flow + 64.0);
		float rain_drive = clamp(moist * 0.78 + flow_drive * 0.22, 0.0, 1.0);
		if (rain_drive <= 0.02) {
			HeightOut.height_out[i] = h0;
			return;
		}

		float mountain_drive = 0.6 + 1.4 * clamp((above_sea - 0.04) / 0.55, 0.0, 1.0);
		erode = PC.dt_days * PC.base_rate_per_day * rain_drive * slope_drive * mountain_drive * shape_noise;
		erode_cap = min(PC.max_rate_per_day * PC.dt_days, best_drop * 0.42);
	}

	erode = min(erode, erode_cap);

	float h_out = clamp(h0 - erode, -1.0, 2.0);
	HeightOut.height_out[i] = h_out;
}
