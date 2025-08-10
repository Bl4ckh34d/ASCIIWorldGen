# File: res://scripts/Utils.gd
extends RefCounted
class_name Utils

static func idx(x: int, y: int, w: int) -> int:
	return x + y * w

static func clampf(v: float, lo: float, hi: float) -> float:
	return min(max(v, lo), hi)

static func sample_noise_wrap_x(noise: FastNoiseLite, sample_x: float, sample_y: float, pixel_x: float, period_x: float) -> float:
	var t: float = 0.0
	if period_x != 0.0:
		t = (pixel_x / period_x)
	t = clampf(t, 0.0, 1.0)
	var v0: float = noise.get_noise_2d(sample_x, sample_y)
	var v1: float = noise.get_noise_2d(sample_x - period_x, sample_y)
	return lerp(v0, v1, t)
