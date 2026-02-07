#[compute]
#version 450
// File: res://shaders/tectonic_pinhole_cleanup.glsl
// Convert isolated boundary-adjacent ocean pinholes into volcanic land.
// Intentionally avoids cells that are themselves tectonic boundary cells so
// active trench/rift relief is preserved.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer HeightBuf { float height_data[]; } Height;
layout(std430, set = 0, binding = 1) buffer LandBuf { int is_land[]; } Land;
layout(std430, set = 0, binding = 2) readonly buffer BoundaryBuf { int boundary_mask[]; } Boundary;
layout(std430, set = 0, binding = 3) buffer LavaBuf { float lava_mask[]; } Lava;

layout(push_constant) uniform Params {
	int width;
	int height;
	int min_land_neighbors;
	int min_boundary_neighbors;
	float sea_level;
	float uplift_amount;
	float max_pit_depth;
	int seed;
} PC;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33 + float(PC.seed % 101));
	return fract((p3.x + p3.y) * p3.z);
}

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

	if (Land.is_land[i] != 0) {
		return;
	}
	if (Boundary.boundary_mask[i] != 0) {
		return;
	}

	float h0 = Height.height_data[i];
	float depth = PC.sea_level - h0;
	if (depth <= 0.0 || depth > PC.max_pit_depth) {
		return;
	}

	int land_neighbors = 0;
	int boundary_neighbors = 0;
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
			if (Land.is_land[j] != 0) {
				land_neighbors++;
			}
			if (Boundary.boundary_mask[j] != 0) {
				boundary_neighbors++;
			}
		}
	}

	if (land_neighbors < PC.min_land_neighbors || boundary_neighbors < PC.min_boundary_neighbors) {
		return;
	}

	float n = hash12(vec2(float(x), float(y)));
	float uplift = PC.uplift_amount * (0.85 + 0.45 * n);
	float target_h = PC.sea_level + uplift;
	Height.height_data[i] = max(h0, target_h);
	Land.is_land[i] = 1;
}
