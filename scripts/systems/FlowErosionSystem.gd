# File: res://scripts/systems/FlowErosionSystem.gd
extends RefCounted

## Rivers, flow accumulation, and light erosion.
## Fast linear-time pipeline: basin pooling above sea level, D4 flow, accumulation,
## percentile seeding + non-maximum suppression, thin downstream tracing.

var _height_ref: PackedFloat32Array = PackedFloat32Array()

func _compare_height(a, b) -> bool:
	var ia: int = int(a)
	var ib: int = int(b)
	if ia < 0 or ib < 0:
		return false
	if ia >= _height_ref.size() or ib >= _height_ref.size():
		return false
	return _height_ref[ia] < _height_ref[ib]

func compute_full(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, settings: Dictionary = {}) -> Dictionary:
	var size: int = max(0, w * h)
	var flow_dir := PackedInt32Array()
	var flow_accum := PackedFloat32Array()
	var river := PackedByteArray()
	var lake_mask := PackedByteArray()
	flow_dir.resize(size)
	flow_accum.resize(size)
	river.resize(size)
	lake_mask.resize(size)
	for i0 in range(size):
		flow_dir[i0] = -1
		flow_accum[i0] = 0.0
		river[i0] = 0
		lake_mask[i0] = 0

	# 0) Prepare inputs and existing lakes (optional)
	var sea_level: float = float(settings.get("sea_level", 0.0))
	var lake_mask_in: PackedByteArray = settings.get("lake_mask", PackedByteArray())
	if lake_mask_in.size() == size:
		lake_mask = lake_mask_in.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(settings.get("rng_seed", 1337))

	# Precompute land index list to avoid scanning oceans repeatedly
	var land_list: Array = []
	land_list.resize(0)
	for i_land in range(size):
		if is_land.size() == size and is_land[i_land] != 0:
			land_list.append(i_land)

	# 1) D8 (8-neighbor) steepest descent on original heights for better connectivity (land only)
	for idx in land_list:
		var i: int = int(idx)
		var x: int = i % w
		var y: int = floori(float(i) / float(w))
		var h0: float = height[i]
		var best_h: float = h0
		var best_i: int = -1
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx: int = x + dx
				var ny: int = y + dy
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var j: int = nx + ny * w
				var hj: float = height[j]
				if hj < best_h:
					best_h = hj
					best_i = j
		# assign
		flow_dir[i] = best_i
		flow_accum[i] = 1.0

	# 2) Accumulation in ascending height order
	_height_ref = height
	var order: Array = []
	order.resize(land_list.size())
	for ii in range(land_list.size()):
		order[ii] = land_list[ii]
	order.sort_custom(Callable(self, "_compare_height"))
	for k in range(order.size()):
		var idx: int = int(order[k])
		var to_idx: int = flow_dir[idx]
		if to_idx >= 0 and to_idx < size:
			flow_accum[to_idx] += flow_accum[idx]

	# 2b) Basin assignment by following flow to sinks (flow_dir == -1) or ocean
	var sink_id := PackedInt32Array(); sink_id.resize(size)
	for si in range(size):
		sink_id[si] = -2
	var next_sink_id: int = 0
	var sink_members := {}
	# Mark ocean cells as non-basin upfront to avoid traversing
	for start0 in range(size):
		if is_land[start0] == 0:
			sink_id[start0] = -1
			continue
	for start in land_list:
		if sink_id[start] != -2:
			continue
		var path := []
		var cur: int = int(start)
		var resolved: int = -2
		while true:
			if is_land[cur] == 0:
				resolved = -1
				break
			if sink_id[cur] != -2:
				resolved = sink_id[cur]
				break
			path.append(cur)
			var to := flow_dir[cur]
			if to < 0:
				resolved = next_sink_id
				next_sink_id += 1
				break
			cur = to
		for p in path:
			sink_id[p] = resolved
			if resolved >= 0:
				if not sink_members.has(resolved):
					sink_members[resolved] = []
				(sink_members[resolved] as Array).append(p)

	# 2c) Compute spill levels and partially fill basins above sea level
	var fill_min: float = float(settings.get("lake_fill_fraction_min", 0.85))
	var fill_max: float = float(settings.get("lake_fill_fraction_max", 1.0))
	var max_lakes: int = int(settings.get("max_lakes", max(4, floori(float(size) / 4096.0))))
	var basin_scores: Array = []
	var basin_info := {}
	for sid in sink_members.keys():
		var members: Array = sink_members[sid]
		if members.size() == 0:
			continue
		var min_h: float = 1e9
		var spill: float = 1e9
		for m in members:
			var mi: int = int(m)
			var hx: float = height[mi]
			if hx < min_h:
				min_h = hx
			var mx: int = mi % w
			var my: int = floori(float(mi) / float(w))
			var dirs2 := [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]
			for d2 in dirs2:
				var nx: int = mx + d2.x
				var ny: int = my + d2.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var ni: int = nx + ny * w
				if sink_id[ni] == sid:
					continue
				var c: float = max(height[mi], height[ni])
				if c < spill:
					spill = c
		if spill <= sea_level:
			continue
		var depth: float = spill - min_h
		if depth <= 0.0001:
			continue
		basin_info[sid] = {"members": members, "min_h": min_h, "spill": spill, "depth": depth}
		basin_scores.append([sid, depth])
	basin_scores.sort_custom(Callable(self, "_score_desc"))
	var filled_count: int = 0
	for entry in basin_scores:
		if filled_count >= max_lakes:
			break
		var sid2: int = int(entry[0])
		var info: Dictionary = basin_info[sid2]
		var min_h2: float = float(info["min_h"])
		var spill2: float = float(info["spill"])
		var frac: float = rng.randf_range(fill_min, fill_max)
		var fill_level: float = min_h2 + frac * max(0.0, spill2 - min_h2)
		if fill_level <= sea_level:
			continue
		var members2: Array = info["members"]
		for m2 in members2:
			var i2 := int(m2)
			if height[i2] < fill_level:
				lake_mask[i2] = 1
		filled_count += 1

	# 3) River seeds by percentile + non-maximum suppression (thin centerlines)
	var acc_vals: Array = []
	acc_vals.resize(0)
	var _land_count: int = 0
	for i2 in range(size):
		if is_land[i2] != 0:
			_land_count += 1
			acc_vals.append(flow_accum[i2])
	var threshold: float = 4.0
	if acc_vals.size() > 0:
		acc_vals.sort()
		var frac: float = float(settings.get("river_percentile", 0.99))
		var idx_thr: int = clamp(int(floor(float(acc_vals.size() - 1) * frac)), 0, acc_vals.size() - 1)
		threshold = max(threshold, float(acc_vals[idx_thr]))
	var seeds: Array = []
	for i3 in range(size):
		if is_land[i3] == 0:
			continue
		if flow_accum[i3] < threshold:
			continue
		# Skip local sinks with no outgoing flow to avoid 1-tile rivers
		if flow_dir[i3] < 0:
			continue
		var x3: int = i3 % w
		var y3: int = floori(float(i3) / float(w))
		var is_max: bool = true
		var val: float = flow_accum[i3]
		for dy2 in range(-1, 2):
			for dx2 in range(-1, 2):
				if dx2 == 0 and dy2 == 0:
					continue
				var nx2: int = x3 + dx2
				var ny2: int = y3 + dy2
				if nx2 < 0 or ny2 < 0 or nx2 >= w or ny2 >= h:
					continue
				var j2: int = nx2 + ny2 * w
				if is_land[j2] == 0:
					continue
				if flow_accum[j2] > val:
					is_max = false
					break
			if not is_max:
				break
		if is_max:
			seeds.append(i3)

	# 4) Trace thin downstream paths from seeds to outlets/lakes
	var visited_path := PackedByteArray(); visited_path.resize(size)
	for s in seeds:
		var start: int = int(s)
		var cur: int = start
		var guard: int = 0
		while guard < size:
			guard += 1
			if cur < 0 or cur >= size:
				break
			if visited_path[cur] != 0:
				break
			visited_path[cur] = 1
			river[cur] = 1
			var to_idx_p: int = flow_dir[cur]
			if to_idx_p < 0 or to_idx_p >= size:
				break
			# stop at ocean or hydro lake
			if is_land[to_idx_p] == 0 or lake_mask[to_idx_p] != 0:
				break
			if to_idx_p == cur:
				break
			cur = to_idx_p

	# 4b) Remove short river segments below a minimum length
	var min_len: int = int(settings.get("min_river_length", 5))
	if min_len > 1:
		_prune_short_rivers(river, w, h, min_len)

	# 5) Optionally ensure connectivity by one more downstream pass (already handled above)

	return {
		"flow_dir": flow_dir,
		"flow_accum": flow_accum,
		"river": river,
		"lake": lake_mask,
	}

func compute_fast(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray) -> Dictionary:
	# Quick path: same as full (no droplets)
	return compute_full(w, h, height, is_land, {})

func _score_desc(a, b) -> bool:
	# a and b are [sid, depth]
	return float(a[1]) > float(b[1])

func _prune_short_rivers(river: PackedByteArray, w: int, h: int, min_len: int) -> void:
	var size: int = w * h
	if river.size() != size:
		return
	var visited := PackedByteArray(); visited.resize(size)
	for i in range(size):
		visited[i] = 0
	var dirs := [
		Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0),
		Vector2i(-1,-1), Vector2i(1,-1), Vector2i(-1,1), Vector2i(1,1)
	]
	for start in range(size):
		if river[start] == 0 or visited[start] != 0:
			continue
		var comp: Array = []
		var q: Array = []
		q.append(start)
		visited[start] = 1
		while q.size() > 0:
			var cur: int = q.pop_front()
			comp.append(cur)
			var cx: int = cur % w
			var cy: int = floori(float(cur) / float(w))
			for d in dirs:
				var nx: int = cx + d.x
				var ny: int = cy + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var ni: int = nx + ny * w
				if visited[ni] != 0 or river[ni] == 0:
					continue
				visited[ni] = 1
				q.append(ni)
		# Prune tiny river segments
		if comp.size() < min_len:
			for p in comp:
				river[int(p)] = 0

func _heap_push(pqi: Array, pqk: Array, idx: int, key: float) -> void:
	# binary min-heap push
	pqi.append(idx)
	pqk.append(key)
	var i: int = pqi.size() - 1
	while i > 0:
		var parent: int = floori(float(i - 1) / 2.0)
		if pqk[parent] <= pqk[i]:
			break
		# swap
		var ti = pqi[parent]
		var tk = pqk[parent]
		pqi[parent] = pqi[i]
		pqk[parent] = pqk[i]
		pqi[i] = ti
		pqk[i] = tk
		i = parent

func _heap_pop(pqi: Array, pqk: Array) -> Array:
	# returns [idx, key]
	var last_i: int = pqi.size() - 1
	var out_i = pqi[0]
	var out_k = pqk[0]
	# move last to root
	pqi[0] = pqi[last_i]
	pqk[0] = pqk[last_i]
	pqi.remove_at(last_i)
	pqk.remove_at(last_i)
	# heapify down
	var i: int = 0
	while true:
		var left: int = i * 2 + 1
		var right: int = left + 1
		var smallest: int = i
		if left < pqi.size() and pqk[left] < pqk[smallest]:
			smallest = left
		if right < pqi.size() and pqk[right] < pqk[smallest]:
			smallest = right
		if smallest == i:
			break
		# swap i and smallest
		var ti = pqi[smallest]
		var tk = pqk[smallest]
		pqi[smallest] = pqi[i]
		pqk[smallest] = pqk[i]
		pqi[i] = ti
		pqk[i] = tk
		i = smallest
	return [out_i, out_k]

func _simulate_droplets(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, flow_accum: PackedFloat32Array, settings: Dictionary) -> void:
	var size: int = w * h
	var walkers_per_tile: int = int(settings.get("walkers_per_tile", 10))
	var step_limit: int = int(settings.get("walker_step_limit", max(w, h)))
	var min_slope: float = float(settings.get("min_slope", 0.0001))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(settings.get("rng_seed", 1337))
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			if is_land[i] == 0:
				continue
			var walkers: int = walkers_per_tile
			while walkers > 0:
				walkers -= 1
				var cx: int = x
				var cy: int = y
				var steps: int = 0
				while steps < step_limit:
					steps += 1
					var ci: int = cx + cy * w
					if is_land[ci] == 0:
						break
					flow_accum[ci] += 1.0
					# Choose neighbor by slope-weighted probability
					var h0: float = height[ci]
					var probs: Array = []
					var choices: Array = []
					var total_p: float = 0.0
					var stopped: bool = true
					for dy in range(-1, 2):
						for dx in range(-1, 2):
							if dx == 0 and dy == 0:
								continue
							var nx: int = cx + dx
							var ny: int = cy + dy
							if nx < 0 or ny < 0 or nx >= w or ny >= h:
								continue
							var ni: int = nx + ny * w
							# stop if adjacent to lake/ocean/river in future; for now only ocean/lake via is_land
							var dh: float = h0 - height[ni]
							if dh <= min_slope:
								continue
							stopped = false
							var p: float = max(0.0, dh)
							total_p += p
							probs.append(p)
							choices.append(ni)
					if stopped or choices.size() == 0:
						break
					var pick: float = rng.randf() * max(0.000001, total_p)
					var acc: float = 0.0
					var next_i: int = int(choices[0])
					for idx in range(choices.size()):
						acc += float(probs[idx])
						if pick <= acc:
							next_i = int(choices[idx])
							break
					cx = int(next_i % w)
					cy = floori(float(next_i) / float(w))
