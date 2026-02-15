#[compute]
#version 450
// File: res://shaders/society/economy_tick.glsl

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer ProdBuf { float prod[]; } BProd;
layout(std430, set = 0, binding = 1) buffer ConsBuf { float cons[]; } BCons;
layout(std430, set = 0, binding = 2) buffer StockBuf { float stock[]; } BStock;
layout(std430, set = 0, binding = 3) buffer PricesBuf { float prices[]; } BPrices;
layout(std430, set = 0, binding = 4) buffer ScarcityBuf { float scarcity[]; } BScarcity;

layout(push_constant) uniform Params {
	int settlement_count;
	int commodity_count;
	int abs_day;
	int _pad0;
	float dt_days;
	float war_pressure;
	float devastation;
	float shock_scalar;
	float prod_scale;
	float cons_scale;
	float scarcity_scale;
	float price_speed;
} PC;

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint total = uint(max(0, PC.settlement_count * PC.commodity_count));
	if (gid >= total) {
		return;
	}
	// v0: stock += prod - cons, then immediate symbolic stockpile shocks from war/devastation.
	// We keep this lightweight and deterministic for batched worldgen ticks.
	float p = BProd.prod[gid] * clamp(PC.prod_scale, 0.1, 4.0);
	float c = BCons.cons[gid] * clamp(PC.cons_scale, 0.1, 4.0);
	float v = BStock.stock[gid];
	float dt = max(0.0, PC.dt_days);
	v = max(0.0, v + (p - c) * dt);

	float war = clamp(PC.war_pressure, 0.0, 1.0);
	float dev = clamp(PC.devastation, 0.0, 1.0);
	float shock_scale = clamp(PC.shock_scalar, 0.0, 2.0);
	int commodity = int(gid) % max(1, PC.commodity_count);
	float commodity_sensitivity = 1.0;
	// 0..5 commodity ordering is currently: water, food, fuel, medicine, materials, arms.
	if (commodity == 0 || commodity == 1) {
		commodity_sensitivity = 1.10;
	} else if (commodity == 2 || commodity == 3) {
		commodity_sensitivity = 1.05;
	} else if (commodity == 5) {
		commodity_sensitivity = 0.85;
	}
	float scarcity_scale = clamp(PC.scarcity_scale, 0.1, 4.0);
	float daily_shock = clamp(shock_scale * scarcity_scale * (0.10 * war + 0.22 * dev) * commodity_sensitivity, 0.0, 0.95);
	float retention = exp(-daily_shock * dt);
	v = max(0.0, v * retention);
	BStock.stock[gid] = v;

	// Scarcity proxy: if stock is small compared to daily consumption, scarcity rises.
	float denom = max(0.001, c);
	float days_cover = v / denom;
	float target_cover_days = max(1.0, 7.0 / scarcity_scale);
	float sc = clamp(1.0 - (days_cover / target_cover_days), 0.0, 1.0);
	BScarcity.scarcity[gid] = sc;

	// Price proxy: base 1.0, inflated by scarcity.
	float base_price = BPrices.prices[gid];
	float shock_now = clamp(1.0 - retention, 0.0, 1.0);
	float target = 1.0 + sc * 1.25 + shock_now * 0.75;
	// Blend 20%/day towards target for batched dt.
	float price_speed = clamp(PC.price_speed, 0.1, 4.0);
	float out_price = mix(base_price, target, clamp(0.20 * price_speed * dt, 0.0, 1.0));
	BPrices.prices[gid] = clamp(out_price, 0.05, 50.0);
}
