extends RefCounted
class_name SettlementExtractor

# Deterministic settlement extraction from per-tile human population fields.
# v0: local maxima + minimum distance pruning.

static func _level_for_pop(pop: float) -> String:
	if pop >= 80.0:
		return "city"
	if pop >= 30.0:
		return "village"
	if pop >= 10.0:
		return "camp"
	return ""

static func _score_for_level(level: String) -> int:
	if level == "city":
		return 3
	if level == "village":
		return 2
	if level == "camp":
		return 1
	return 0

static func _is_local_max(pop: PackedFloat32Array, w: int, h: int, x: int, y: int, r: int) -> bool:
	var i0: int = x + y * w
	var p0: float = float(pop[i0])
	for dy in range(-r, r + 1):
		var yy: int = clamp(y + dy, 0, h - 1)
		for dx in range(-r, r + 1):
			if dx == 0 and dy == 0:
				continue
			var xx: int = posmod(x + dx, w)
			var i: int = xx + yy * w
			if float(pop[i]) > p0:
				return false
	return true

static func extract_settlements(
	world_seed_hash: int,
	world_w: int,
	world_h: int,
	pop: PackedFloat32Array,
	min_pop_camp: float = 10.0
) -> Array[Dictionary]:
	var w: int = max(0, int(world_w))
	var h: int = max(0, int(world_h))
	var size: int = w * h
	if size <= 0 or pop.size() != size:
		return []
	var seed_value: int = int(world_seed_hash)
	if seed_value == 0:
		seed_value = 1

	# Gather local maxima above threshold.
	var candidates: Array[Dictionary] = []
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var p: float = float(pop[i])
			if p < min_pop_camp:
				continue
			if not _is_local_max(pop, w, h, x, y, 2):
				continue
			var level: String = _level_for_pop(p)
			if level.is_empty():
				continue
			var noise: float = float(abs(int(("%d|%d|%d" % [seed_value, x, y]).hash())) % 10000) / 10000.0
			candidates.append({
				"x": x,
				"y": y,
				"pop": p,
				"level": level,
				"rank": _score_for_level(level),
				"noise": noise,
			})

	# Sort: higher level first, then pop, then deterministic noise.
	candidates.sort_custom(func(a, b):
		var ra: int = int(a.get("rank", 0))
		var rb: int = int(b.get("rank", 0))
		if ra != rb:
			return ra > rb
		var pa: float = float(a.get("pop", 0.0))
		var pb: float = float(b.get("pop", 0.0))
		if abs(pa - pb) > 0.0001:
			return pa > pb
		return float(a.get("noise", 0.0)) > float(b.get("noise", 0.0))
	)

	# Min-distance prune.
	var out: Array[Dictionary] = []
	for c in candidates:
		var x: int = int(c.get("x", 0))
		var y: int = int(c.get("y", 0))
		var level: String = String(c.get("level", "camp"))
		var min_dist: int = 8
		if level == "city":
			min_dist = 16
		elif level == "village":
			min_dist = 12
		var ok: bool = true
		for s in out:
			var sx: int = int(s.get("x", 0))
			var sy: int = int(s.get("y", 0))
			# Horizontal wrap.
			var dx_raw: int = abs(x - sx)
			var dx: int = min(dx_raw, w - dx_raw) if w > 0 else dx_raw
			var dy: int = abs(y - sy)
			if dx + dy < min_dist:
				ok = false
				break
		if not ok:
			continue
		out.append({
			"x": x,
			"y": y,
			"pop": float(c.get("pop", 0.0)),
			"level": level,
		})
	return out


