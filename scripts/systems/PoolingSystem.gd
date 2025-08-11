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
	while q.size() > 0:
		var cur: int = q.pop_front()
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
			# New inland water component → lake
			var comp := []
			q.clear()
			q.append(idx)
			visited[idx] = 1
			while q.size() > 0:
				var cur2: int = q.pop_front()
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


