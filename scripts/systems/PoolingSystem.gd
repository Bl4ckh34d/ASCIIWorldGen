# File: res://scripts/systems/PoolingSystem.gd
extends RefCounted

## Detect inland lakes as water components not connected to map boundary water.
## Uses the existing water mask implied by is_land == 0. Labels each inland
## water component with a positive lake_id; boundary-connected water has id 0.

func compute(w: int, h: int, _height: PackedFloat32Array, is_land: PackedByteArray, wrap_x: bool = true) -> Dictionary:
	var size: int = max(0, w * h)
	var water := PackedByteArray()
	water.resize(size)
	for i in range(size):
		water[i] = 1 if (i < is_land.size() and is_land[i] == 0) else 0

	# Step 1: mark boundary-connected water via BFS
	var boundary_conn := PackedByteArray()
	boundary_conn.resize(size)
	for i2 in range(size):
		boundary_conn[i2] = 0
	var q: Array = []
	# Enqueue water on all edges
	for x in range(w):
		var top_i: int = x + 0 * w
		var bot_i: int = x + (h - 1) * w
		if water[top_i] != 0:
			boundary_conn[top_i] = 1
			q.append(top_i)
		if water[bot_i] != 0:
			boundary_conn[bot_i] = 1
			q.append(bot_i)
	for y in range(h):
		var left_i: int = 0 + y * w
		var right_i: int = (w - 1) + y * w
		if water[left_i] != 0:
			boundary_conn[left_i] = 1
			q.append(left_i)
		if water[right_i] != 0:
			boundary_conn[right_i] = 1
			q.append(right_i)
	var head0: int = 0
	while head0 < q.size():
		var cur: int = int(q[head0])
		head0 += 1
		var cx: int = cur % w
		var cy: int = int(float(cur) / float(w))
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx: int = cx + dx
				var ny: int = cy + dy
				if wrap_x:
					nx = (nx + w) % w
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var ni: int = nx + ny * w
				if water[ni] == 0:
					continue
				if boundary_conn[ni] != 0:
					continue
				boundary_conn[ni] = 1
				q.append(ni)

	# Step 2: label remaining water (not boundary-connected) as lakes with IDs
	var lake := PackedByteArray()
	lake.resize(size)
	for i3 in range(size):
		lake[i3] = 0
	var lake_id := PackedInt32Array()
	lake_id.resize(size)
	for i4 in range(size):
		lake_id[i4] = 0
	var visited := PackedByteArray()
	visited.resize(size)
	for i5 in range(size):
		visited[i5] = 0
	var next_lake_id: int = 1
	for y2 in range(h):
		for x2 in range(w):
			var idx: int = x2 + y2 * w
			if water[idx] == 0 or boundary_conn[idx] != 0 or visited[idx] != 0:
				continue
			# New inland water component -> lake
			var comp := []
			q.clear()
			q.append(idx)
			var head1: int = 0
			visited[idx] = 1
			while head1 < q.size():
				var cur2: int = int(q[head1])
				head1 += 1
				comp.append(cur2)
				var cx2: int = cur2 % w
				var cy2: int = int(float(cur2) / float(w))
				for dy2 in range(-1, 2):
					for dx2 in range(-1, 2):
						if dx2 == 0 and dy2 == 0:
							continue
						var nx2: int = cx2 + dx2
						var ny2: int = cy2 + dy2
						if wrap_x:
							nx2 = (nx2 + w) % w
						if nx2 < 0 or ny2 < 0 or nx2 >= w or ny2 >= h:
							continue
						var ni2: int = nx2 + ny2 * w
						if visited[ni2] != 0:
							continue
						if water[ni2] == 0 or boundary_conn[ni2] != 0:
							continue
						visited[ni2] = 1
						q.append(ni2)
			# Assign labels
			for p in comp:
				lake[p] = 1
				lake_id[p] = next_lake_id
			next_lake_id += 1

	return {
		"lake": lake,
		"lake_id": lake_id,
	}


# Depression-filling lakes (priority-flood). Fills closed basins above sea level
# and labels them as lakes starting from global edges as drainage boundaries.
func compute_fill_from_depressions(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, _sea_level: float, wrap_x: bool = true, river_mask: PackedByteArray = PackedByteArray()) -> Dictionary:
	var size: int = max(0, w * h)
	var filled := PackedFloat32Array(); filled.resize(size)
	var visited := PackedByteArray(); visited.resize(size)
	for i in range(size):
		filled[i] = height[i] if i < height.size() else 0.0
		visited[i] = 0
	# Min-heap using parallel arrays (value, index). For small maps, linear pop is fine.
	var heap_vals: Array = []
	var heap_idx: Array = []
	# Binary heap helpers
	var _heap_swap = func(i: int, j: int) -> void:
		var tv: float = heap_vals[i]
		heap_vals[i] = heap_vals[j]
		heap_vals[j] = tv
		var ti: int = heap_idx[i]
		heap_idx[i] = heap_idx[j]
		heap_idx[j] = ti
	var _heap_sift_up = func(pos: int) -> void:
		var i := pos
		while i > 0:
			var parent: int = (i - 1) >> 1
			if heap_vals[i] >= heap_vals[parent]:
				break
			_heap_swap.call(i, parent)
			i = parent
	var _heap_sift_down = func(pos: int) -> void:
		var i := pos
		while true:
			var left := i * 2 + 1
			var right := left + 1
			if left >= heap_vals.size():
				break
			var smallest := left
			if right < heap_vals.size() and heap_vals[right] < heap_vals[left]:
				smallest = right
			if heap_vals[i] <= heap_vals[smallest]:
				break
			_heap_swap.call(i, smallest)
			i = smallest
	var _heap_push = func(val: float, idx: int) -> void:
		heap_vals.append(val)
		heap_idx.append(idx)
		_heap_sift_up.call(heap_vals.size() - 1)
	var _heap_pop = func() -> Array:
		# Caller must ensure size > 0
		var out_val: float = heap_vals[0]
		var out_idx: int = heap_idx[0]
		var last_val: float = heap_vals.pop_back()
		var last_idx: int = heap_idx.pop_back()
		if heap_vals.size() > 0:
			heap_vals[0] = last_val
			heap_idx[0] = last_idx
			_heap_sift_down.call(0)
		return [out_val, out_idx]
	# Seed boundaries: always top/bottom. Left/right only when not wrapping in X.

	for x in range(w):
		var it: int = x + 0 * w
		var ib: int = x + (h - 1) * w
		if visited[it] == 0:
			visited[it] = 1
			filled[it] = height[it]
			_heap_push.call(filled[it], it)
		if visited[ib] == 0:
			visited[ib] = 1
			filled[ib] = height[ib]
			_heap_push.call(filled[ib], ib)
	if not wrap_x:
		for y in range(h):
			var il: int = 0 + y * w
			var ir: int = (w - 1) + y * w
			if visited[il] == 0:
				visited[il] = 1
				filled[il] = height[il]
				_heap_push.call(filled[il], il)
			if visited[ir] == 0:
				visited[ir] = 1
				filled[ir] = height[ir]
				_heap_push.call(filled[ir], ir)

	# Process
	var processed: int = 0
	while heap_vals.size() > 0:
		var top: Array = _heap_pop.call()
		var f: float = float(top[0])
		var i0: int = int(top[1])
		processed += 1
		if processed > size:
			break
		var cx: int = i0 % w
		var cy: int = int(float(i0) / float(w))
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx: int = cx + dx
				var ny: int = cy + dy
				if wrap_x:
					nx = (nx + w) % w
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var ni: int = nx + ny * w
				if visited[ni] != 0:
					continue
				visited[ni] = 1
				var hni: float = height[ni]
				var fi: float = f
				if hni > fi:
					fi = hni
				filled[ni] = fi
				_heap_push.call(fi, ni)

	# Lake mask: land cells elevated by fill (filled > height)
	var lake := PackedByteArray(); lake.resize(size)
	for k in range(size):
		lake[k] = 1 if (k < is_land.size() and is_land[k] != 0 and filled[k] > height[k]) else 0
	# Label connected lakes
	var lake_id := PackedInt32Array(); lake_id.resize(size)
	for k2 in range(size): lake_id[k2] = 0
	var visited2 := PackedByteArray(); visited2.resize(size)
	for k3 in range(size): visited2[k3] = 0
	var qlabel: Array = []
	var next_id: int = 1
	for yy in range(h):
		for xx in range(w):
			var si: int = xx + yy * w
			if lake[si] == 0 or visited2[si] != 0:
				continue
			visited2[si] = 1
			qlabel.clear()
			qlabel.append(si)
			lake_id[si] = next_id
			while qlabel.size() > 0:
				var ci: int = qlabel.pop_front()
				var cx2: int = ci % w
				var cy2: int = int(float(ci) / float(w))
				for dy2 in range(-1, 2):
					for dx2 in range(-1, 2):
						if dx2 == 0 and dy2 == 0:
							continue
						var nx2: int = cx2 + dx2
						var ny2: int = cy2 + dy2
						if wrap_x:
							nx2 = (nx2 + w) % w
						if nx2 < 0 or ny2 < 0 or nx2 >= w or ny2 >= h:
							continue
						var ni2: int = nx2 + ny2 * w
						if visited2[ni2] != 0 or lake[ni2] == 0:
							continue
						visited2[ni2] = 1
						lake_id[ni2] = next_id
						qlabel.append(ni2)
			next_id += 1

	# Optional: keep only lakes that are fed by rivers (adjacent to any river cell)
	if river_mask.size() == size:
		var lake_has_river := {}
		# Mark which lake_id touches a river
		for y in range(h):
			for x in range(w):
				var i := x + y * w
				if lake[i] == 0:
					continue
				var id := lake_id[i]
				if id <= 0:
					continue
				var touches := false
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var nx := x + dx
						var ny := y + dy
						if wrap_x:
							nx = (nx + w) % w
						if nx < 0 or ny < 0 or nx >= w or ny >= h:
							continue
						var ni := nx + ny * w
						if river_mask[ni] != 0:
							touches = true
							break
					if touches:
						break
				if touches:
					lake_has_river[id] = true
		# Filter lakes that do not touch any river
		for k in range(size):
			if lake[k] == 0:
				continue
			var id2 := lake_id[k]
			if id2 <= 0:
				continue
			if not lake_has_river.has(id2):
				lake[k] = 0
				lake_id[k] = 0

	return {"lake": lake, "lake_id": lake_id}
