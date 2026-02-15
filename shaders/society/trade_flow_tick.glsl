#[compute]
#version 450
// File: res://shaders/society/trade_flow_tick.glsl

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer NeighborIdxBuf { int neighbor_idx[]; } BNeighborIdx;
layout(std430, set = 0, binding = 1) readonly buffer NeighborCapBuf { float neighbor_cap[]; } BNeighborCap;
layout(std430, set = 0, binding = 2) readonly buffer StockInBuf { float stock_in[]; } BStockIn;
layout(std430, set = 0, binding = 3) buffer StockOutBuf { float stock_out[]; } BStockOut;

layout(push_constant) uniform Params {
	int settlement_count;
	int commodity_count;
	int max_neighbors;
	int abs_day;
	float dt_days;
	float _pad1;
	float _pad2;
	float _pad3;
} PC;

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint total = uint(max(0, PC.settlement_count * PC.commodity_count));
	if (gid >= total) {
		return;
	}
	int commodity = int(gid) % max(1, PC.commodity_count);
	int settlement = int(gid) / max(1, PC.commodity_count);
	int base_idx = settlement * PC.commodity_count + commodity;

	float self_stock = BStockIn.stock_in[base_idx];
	float delta = 0.0;

	// Symmetric pairwise transfer approximation.
	// Each settlement thread only writes its own stock cell; no cross-thread writes.
	for (int k = 0; k < PC.max_neighbors; k++) {
		int slot = settlement * PC.max_neighbors + k;
		int nb = BNeighborIdx.neighbor_idx[slot];
		if (nb < 0 || nb >= PC.settlement_count) {
			continue;
		}
		float cap = max(0.0, BNeighborCap.neighbor_cap[slot]);
		if (cap <= 0.0) {
			continue;
		}
		int nb_idx = nb * PC.commodity_count + commodity;
		float nb_stock = BStockIn.stock_in[nb_idx];
		// Transfer rate kept small for stability in batched dt updates.
		delta += (nb_stock - self_stock) * cap * 0.025 * PC.dt_days;
	}

	BStockOut.stock_out[base_idx] = max(0.0, self_stock + delta);
}

