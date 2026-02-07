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
layout(std430, set = 0, binding = 8) readonly buffer RockBuf { int rock_type[]; } Rock;
layout(std430, set = 0, binding = 9) readonly buffer FlowDirBuf { int flow_dir[]; } FlowDir;

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
	float glacier_smoothing_bias;
	float cryo_rate_scale;
	float cryo_cap_scale;
} PC;

int index_of(int x, int y) {
	return x + y * PC.width;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

const int ROCK_BASALTIC = 0;
const int ROCK_GRANITIC = 1;
const int ROCK_SEDIMENTARY_CLASTIC = 2;
const int ROCK_LIMESTONE = 3;
const int ROCK_METAMORPHIC = 4;
const int ROCK_VOLCANIC_ASH = 5;

float rock_erodibility(int r) {
	if (r == ROCK_GRANITIC) return 0.62;
	if (r == ROCK_SEDIMENTARY_CLASTIC) return 1.40;
	if (r == ROCK_LIMESTONE) return 1.08;
	if (r == ROCK_METAMORPHIC) return 0.78;
	if (r == ROCK_VOLCANIC_ASH) return 1.62;
	return 0.72; // basaltic default
}

float rock_transportability(int r) {
	if (r == ROCK_GRANITIC) return 0.72;
	if (r == ROCK_SEDIMENTARY_CLASTIC) return 1.45;
	if (r == ROCK_LIMESTONE) return 1.12;
	if (r == ROCK_METAMORPHIC) return 0.82;
	if (r == ROCK_VOLCANIC_ASH) return 1.68;
	return 0.76; // basaltic default
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
	bool is_land_px = (Land.is_land[i] != 0u);
	bool is_lake_px = (Lake.lake_mask[i] != 0u);

	// Keep lakes/lava stable in this pass.
	if (is_lake_px || Lava.lava[i] > 0.5) {
		HeightOut.height_out[i] = h0;
		return;
	}

	int bid = Biome.biome_id[i];
	bool is_cryo = (bid == PC.biome_ice_sheet_id || bid == PC.biome_glacier_id || bid == PC.biome_desert_ice_id);

	float best_drop = 0.0;
	float slope_sum = 0.0;
	float neighbor_sum = 0.0;
	int slope_count = 0;
	int ocean_neighbors = 0;
	int land_neighbors = 0;
	float sediment_src = 0.0;
	float mouth_src = 0.0;
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
			int j = index_of(nx, ny);
			float hn = HeightIn.height_in[j];
			float dh = h0 - hn;
			if (dh > best_drop) {
				best_drop = dh;
			}
			slope_sum += abs(dh);
			neighbor_sum += hn;
			slope_count++;

			bool n_land = (Land.is_land[j] != 0u);
			bool n_lake = (Lake.lake_mask[j] != 0u);
			if (!n_land && !n_lake) {
				ocean_neighbors++;
			}
			if (n_land) {
				land_neighbors++;
			}

			// Ocean-cell sediment intake proxy from adjacent land.
				if (!is_land_px && !n_lake && n_land) {
					float moist_n = clamp(Moisture.moisture[j], 0.0, 1.0);
					float flow_n = max(0.0, Flow.flow_accum[j]);
					float flow_drive_n = flow_n / (flow_n + 64.0);
					float src_elev = max(0.0, hn - PC.sea_level);
					float shore_drop = max(0.0, hn - h0);
					float transport_n = rock_transportability(Rock.rock_type[j]);
					bool drains_here = (FlowDir.flow_dir[j] == i);
					float src = moist_n * 0.55 + flow_drive_n * 0.25 + clamp(shore_drop / 0.16, 0.0, 1.0) * 0.20;
					src *= clamp(src_elev / 0.6, 0.0, 1.0);
					src *= transport_n;
					sediment_src += src;
					if (drains_here) {
						// Emphasize true river mouths so deltas nucleate at outlet cells.
						mouth_src += src * (0.65 + 1.65 * flow_drive_n);
					}
				}
			}
		}

	float shape_noise = 0.82 + 0.36 * hash12(vec2(float(x), float(y)) + vec2(PC.noise_phase, PC.noise_phase * 0.37));
	float neighbor_mean = h0;
	if (slope_count > 0) {
		neighbor_mean = neighbor_sum / float(slope_count);
	}

	// Nearshore deposition: any ocean cell next to land can slowly receive sediment.
	if (!is_land_px) {
		if (land_neighbors <= 0 || sediment_src <= 0.0) {
			HeightOut.height_out[i] = h0;
			return;
		}
		float depth = max(0.0, PC.sea_level - h0);
		float nearshore = 1.0 - smoothstep(0.03, 0.30, depth);
		if (nearshore <= 0.0) {
			HeightOut.height_out[i] = h0;
			return;
		}
		float sediment_drive = sediment_src / float(max(1, land_neighbors));
		float mouth_drive = mouth_src / float(max(1, land_neighbors));
		float channel_focus = clamp(mouth_drive / (mouth_drive + 0.08), 0.0, 1.0);
		float deposit = PC.dt_days * PC.base_rate_per_day * sediment_drive * nearshore * (0.50 + 0.50 * shape_noise);
		deposit += PC.dt_days * PC.base_rate_per_day * mouth_drive * nearshore * (0.45 + 0.55 * shape_noise);
		float deposit_cap = min(PC.max_rate_per_day * PC.dt_days * (0.26 + 0.20 * channel_focus), depth * (0.20 + 0.10 * channel_focus) + 0.0008);
		deposit = min(deposit, deposit_cap);
		float h_after_deposit = min(h0 + deposit, PC.sea_level - 0.006);
		// Subaqueous slope relaxation: spread fresh mouth deposits downslope to form
		// gently descending delta fronts instead of vertical stacking.
		float local_drop = max(0.0, h_after_deposit - neighbor_mean);
		float relax_drive = clamp(local_drop / 0.08, 0.0, 1.0);
		float relax = PC.dt_days * PC.base_rate_per_day * relax_drive * (0.22 + 0.68 * nearshore) * (0.70 + 0.60 * channel_focus);
		relax = min(relax, local_drop * 0.55);
		float h_out_water = h_after_deposit - relax;
		HeightOut.height_out[i] = clamp(h_out_water, -1.0, 2.0);
		return;
	}

	float above_sea = h0 - PC.sea_level;
	if (above_sea <= -0.005) {
		HeightOut.height_out[i] = h0;
		return;
	}
	if (best_drop <= 0.0 || slope_count <= 0) {
		HeightOut.height_out[i] = h0;
		return;
	}

	float avg_slope = slope_sum / float(slope_count);
	float slope_drive = clamp((best_drop * 0.74 + avg_slope * 0.26 - 0.0007) / 0.06, 0.0, 1.0);
	float coastal_exposure = float(ocean_neighbors) / float(max(1, slope_count));
	if (slope_drive <= 0.0 && coastal_exposure <= 0.0) {
		HeightOut.height_out[i] = h0;
		return;
	}

	float erode = 0.0;
	float erode_cap = PC.max_rate_per_day * PC.dt_days;
	int rock = Rock.rock_type[i];
	float rock_erode_mult = rock_erodibility(rock);

	if (is_cryo) {
		// Glacial abrasion/plucking:
		// - driven primarily by slope and relief
		// - weakly coupled to moisture as a proxy for ice throughput
		// - stronger at higher elevations where persistent ice survives
		float moist = clamp(Moisture.moisture[i], 0.0, 1.0);
		float ice_flux = 0.45 + 0.55 * moist;
		float smooth_bias = clamp(PC.glacier_smoothing_bias, 0.0, 1.0);
		float cryo_relief_raw = clamp((best_drop * 0.70 + avg_slope * 0.30 - 0.0004) / 0.045, 0.0, 1.0);
		float cryo_relief_smooth = clamp((best_drop * 0.52 + avg_slope * 0.48 - 0.0003) / 0.055, 0.0, 1.0);
		float cryo_relief = mix(cryo_relief_raw, cryo_relief_smooth, smooth_bias * 0.55);
		float cryo_altitude = 0.65 + 0.85 * clamp((above_sea - 0.02) / 0.65, 0.0, 1.0);
		float cryo_rate = PC.base_rate_per_day * max(0.1, PC.cryo_rate_scale);
		float cryo_rate_max = PC.max_rate_per_day * max(0.1, PC.cryo_cap_scale);
		erode = PC.dt_days * cryo_rate * cryo_relief * cryo_altitude * ice_flux * (0.88 + 0.24 * shape_noise);
		float laplacian = neighbor_mean - h0;
		float peak_drive = clamp((-laplacian - 0.0008) / 0.055, 0.0, 1.0);
		float valley_drive = clamp((laplacian - 0.0008) / 0.055, 0.0, 1.0);
		float smooth_factor = 1.0 + smooth_bias * (peak_drive * 0.65 - valley_drive * 0.50);
		erode *= clamp(smooth_factor, 0.45, 1.55);
		erode *= (0.85 + 0.35 * rock_erode_mult);
		erode_cap = min(cryo_rate_max * PC.dt_days, best_drop * 0.52);
	} else {
		float moist = clamp(Moisture.moisture[i], 0.0, 1.0);
		float flow = max(0.0, Flow.flow_accum[i]);
		float flow_drive = flow / (flow + 64.0);
		float rain_drive = clamp(moist * 0.78 + flow_drive * 0.22, 0.0, 1.0);
		if (rain_drive > 0.02) {
			float mountain_drive = 0.6 + 1.4 * clamp((above_sea - 0.04) / 0.55, 0.0, 1.0);
			erode = PC.dt_days * PC.base_rate_per_day * rain_drive * slope_drive * mountain_drive * shape_noise;
			erode *= rock_erode_mult;
			erode_cap = min(PC.max_rate_per_day * PC.dt_days, best_drop * 0.42);
		}
	}

	// Extra coast wear: land bordering ocean always has some erosion chance.
	if (coastal_exposure > 0.0) {
		float coast_drive = coastal_exposure * (0.55 + 0.45 * clamp(best_drop / 0.10, 0.0, 1.0));
		float coast_rate = PC.base_rate_per_day * (is_cryo ? 0.30 : 0.42);
		coast_rate *= (0.78 + 0.42 * rock_erode_mult);
		float coast_erode = PC.dt_days * coast_rate * coast_drive * (0.88 + 0.28 * shape_noise);
		float coast_cap = min(PC.max_rate_per_day * PC.dt_days * 0.30, best_drop * 0.25 + 0.0007);
		erode += min(coast_erode, coast_cap);
	}

	erode = min(erode, erode_cap);
	float total_cap_mult = (is_cryo ? max(1.05, PC.cryo_cap_scale * 1.05) : 1.2);
	float total_cap = min(PC.max_rate_per_day * PC.dt_days * total_cap_mult, best_drop * 0.65 + 0.0008);
	erode = min(erode, total_cap);
	if (erode <= 0.0) {
		HeightOut.height_out[i] = h0;
		return;
	}

	float h_out = clamp(h0 - erode, -1.0, 2.0);
	HeightOut.height_out[i] = h_out;
}
