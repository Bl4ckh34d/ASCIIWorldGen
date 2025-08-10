# File: res://scripts/Utils.gd
extends RefCounted
class_name Utils

static func idx(x: int, y: int, w: int) -> int:
	return x + y * w

static func clampf(v: float, lo: float, hi: float) -> float:
	return min(max(v, lo), hi)


