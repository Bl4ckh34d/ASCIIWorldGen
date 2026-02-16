# File: res://scripts/systems/FlowErosionSystem.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

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

func compute_pour_from_labels(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, lake_mask: PackedByteArray, lake_id: PackedInt32Array, settings: Dictionary = {}) -> Dictionary:
	var size: int = max(0, w * h)
	var wrap_x: bool = VariantCastsUtil.to_bool(settings.get("wrap_x", true))
	# Collect boundary candidates per lake_id
	var per_lake: Dictionary = {}
	for i in range(size):
		if i >= lake_mask.size() or lake_mask[i] == 0:
			continue
		var lid: int = (lake_id[i] if i < lake_id.size() else 0)
		if lid <= 0:
			continue
		var x: int = i % w
		var y: int = floori(float(i) / float(w))
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx: int = x + dx
				var ny: int = y + dy
				if wrap_x:
					nx = (nx + w) % w
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var j: int = nx + ny * w
				if is_land[j] == 0:
					continue
				if j < lake_mask.size() and lake_mask[j] != 0:
					continue
				# edge from inside i to outside j
				var c: float = max(height[i], height[j])
				if not per_lake.has(lid): per_lake[lid] = []
				(per_lake[lid] as Array).append([i, j, c])
	# Sort and select seeds with ocean bias
	var pour_points := {}
	var forced_seeds := PackedInt32Array()
	var forced_tmp: Array = []
	var max_forced_outflows: int = clamp(int(settings.get("max_forced_outflows", 3)), 0, 8)
	var p0: float = float(settings.get("prob_outflow_0", 0.50))
	var p1: float = float(settings.get("prob_outflow_1", 0.35))
	var p2: float = float(settings.get("prob_outflow_2", 0.10))
	var p3: float = float(settings.get("prob_outflow_3", 0.05))
	var probs: Array = []
	probs.resize(max_forced_outflows + 1)
	for ii in range(probs.size()): probs[ii] = 0.0
	if max_forced_outflows >= 0: probs[0] = p0
	if max_forced_outflows >= 1: probs[1] = p1
	if max_forced_outflows >= 2: probs[2] = p2
	if max_forced_outflows >= 3: probs[3] = p3
	var sum_p: float = 0.0
	for ii2 in range(probs.size()): sum_p += float(probs[ii2])
	if sum_p <= 0.0: probs[0] = 1.0; sum_p = 1.0
	for ii3 in range(probs.size()): probs[ii3] = float(probs[ii3]) / sum_p
	var cdf: Array = []
	cdf.resize(probs.size())
	var accp: float = 0.0
	for ii4 in range(probs.size()): accp += float(probs[ii4]); cdf[ii4] = accp
	var shore_band: float = float(settings.get("shore_band", 6.0))
	var dist_to_ocean: PackedFloat32Array = settings.get("dist_to_ocean", PackedFloat32Array())
	for lid_key in per_lake.keys():
		var arr: Array = per_lake[lid_key]
		arr.sort_custom(func(a, b): return float(a[2]) < float(b[2]))
		pour_points[lid_key] = arr
		if arr.size() == 0:
			continue
		# deterministic RNG per lake
		var local_rng := RandomNumberGenerator.new(); local_rng.seed = int(settings.get("rng_seed", 1337)) ^ int(lid_key)
		# primary
		forced_tmp.append(int(arr[0][0]))
		# extras
		var picks_extra: int = 0
		var r: float = local_rng.randf()
		for kx in range(cdf.size()):
			if r <= float(cdf[kx]): picks_extra = kx; break
		var opened: int = 0
		for ci in range(1, arr.size()):
			if opened >= picks_extra or opened >= max_forced_outflows: break
			var edge: Array = arr[ci]
			var seed_i2: int = int(edge[0])
			var p_ocean: float = 0.0
			if dist_to_ocean.size() == size and seed_i2 >= 0 and seed_i2 < size and shore_band > 0.0:
				p_ocean = clamp((shore_band - dist_to_ocean[seed_i2]) / shore_band, 0.0, 1.0)
			if local_rng.randf() <= p_ocean:
				forced_tmp.append(seed_i2)
				opened += 1
	# unique and pack
	var seen := {}
	for v in forced_tmp: seen[int(v)] = true
	var keys := seen.keys(); keys.sort()
	forced_seeds.resize(keys.size())
	for idx in range(keys.size()): forced_seeds[idx] = int(keys[idx])
	return {"outflow_seeds": forced_seeds, "pour_points": pour_points}

func compute_full(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, settings: Dictionary = {}) -> Dictionary:
	var size: int = max(0, w * h)
	var wrap_x: bool = VariantCastsUtil.to_bool(settings.get("wrap_x", true))
	var flow_dir := PackedInt32Array()
	var flow_accum := PackedFloat32Array()
	var river := PackedByteArray()
	var lake_mask := PackedByteArray()
	var lake_id := PackedInt32Array()
	var lake_level := PackedFloat32Array()
	var lake_freeze := PackedByteArray()
	flow_dir.resize(size)
	flow_accum.resize(size)
	river.resize(size)
	lake_mask.resize(size)
	lake_id.resize(size)
	lake_level.resize(size)
	lake_freeze.resize(size)
	for i0 in range(size):
		flow_dir[i0] = -1
		flow_accum[i0] = 0.0
		river[i0] = 0
		lake_mask[i0] = 0
		lake_id[i0] = 0
		lake_level[i0] = (height[i0] if i0 < height.size() else 0.0)
		lake_freeze[i0] = 0

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
				if wrap_x:
					nx = (nx + w) % w
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

	# 2c) Strict-fill basins to spill elevation; collect pour candidates and label lakes
	#     Apply climate-dependent shrink/freeze rules using optional temperature field.
	var pour_points := {} # lake_label/id -> Array of [inside_i, outside_i, cost]
	var forced_seeds_arr: Array = []
	var next_lake_label: int = 1
	# Outflow selection settings (0..max_forced_outflows). Default: 0:50%,1:35%,2:10%,3:5%
	var max_forced_outflows: int = clamp(int(settings.get("max_forced_outflows", 3)), 0, 8)
	var p0: float = float(settings.get("prob_outflow_0", 0.50))
	var p1: float = float(settings.get("prob_outflow_1", 0.35))
	var p2: float = float(settings.get("prob_outflow_2", 0.10))
	var p3: float = float(settings.get("prob_outflow_3", 0.05))
	# Build cumulative distribution up to max_forced_outflows
	var probs: Array = []
	probs.resize(max_forced_outflows + 1)
	for ii_p in range(probs.size()): probs[ii_p] = 0.0
	if max_forced_outflows >= 0: probs[0] = p0
	if max_forced_outflows >= 1: probs[1] = p1
	if max_forced_outflows >= 2: probs[2] = p2
	if max_forced_outflows >= 3: probs[3] = p3
	var sum_p: float = 0.0
	for ii_s in range(probs.size()): sum_p += float(probs[ii_s])
	if sum_p <= 0.0:
		probs.clear(); probs.resize(max(1, max_forced_outflows + 1)); probs[0] = 1.0; sum_p = 1.0
	# Normalize to 1
	for ii_n in range(probs.size()): probs[ii_n] = float(probs[ii_n]) / sum_p
	# Build cumulative
	var cdf: Array = []
	cdf.resize(probs.size())
	var accp: float = 0.0
	for ii_c in range(probs.size()):
		accp += float(probs[ii_c])
		cdf[ii_c] = accp
	for sid in sink_members.keys():
		var members: Array = sink_members[sid]
		if members.size() == 0:
			continue
		var min_h: float = 1e9
		var spill: float = 1e9
		var candidates: Array = [] # [inside_i, outside_i, cost]
		for m in members:
			var mi: int = int(m)
			var hx: float = height[mi]
			if hx < min_h:
				min_h = hx
			var mx: int = mi % w
			var my: int = floori(float(mi) / float(w))
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx: int = mx + dx
					var ny: int = my + dy
					if wrap_x:
						nx = (nx + w) % w
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var ni: int = nx + ny * w
					if sink_id[ni] == sid:
						continue
					var c: float = max(height[mi], height[ni])
					candidates.append([mi, ni, c])
					if c < spill:
						spill = c
		# Lake–ocean blending behavior
		# 1) If basin is already open to ocean (spill <= sea_level), keep a thin
		#    residual water band above sea level to avoid instant lake disappearance.
		# 2) If basin is closed (spill > sea_level), apply dryness coupling so lakes
		#    shrink as sea level drops.
		var effective_level: float = spill
		if spill <= sea_level:
			var blend_band: float = float(settings.get("lake_ocean_blend_band", 0.02))
			effective_level = min(spill + blend_band, sea_level + blend_band)
		else:
			# Tie lake water level to ocean level: as sea level lowers, lakes dry up.
			var d: float = clamp(-sea_level, 0.0, 1.0)
			if d > 0.0 and sea_level < spill:
				effective_level = spill - d * (spill - sea_level)
		# Apply temperature-based shrinkage of lakes (hot climates)
		var temp: PackedFloat32Array = settings.get("temperature", PackedFloat32Array())
		var temp_min_c: float = float(settings.get("temp_min_c", -40.0))
		var temp_max_c: float = float(settings.get("temp_max_c", 70.0))
		var shrink_hot_c: float = float(settings.get("lake_shrink_hot_c", 20.0))
		var lakes_freeze_c: float = float(settings.get("lake_freeze_c", -5.0))
		var lakes_icesheet_c: float = float(settings.get("lake_icesheet_c", -15.0))
		# Fill: mark member cells below the effective lake level
		var any_filled: bool = false
		for m2 in members:
			var i2: int = int(m2)
			var fill_here: bool = height[i2] < effective_level
			# Temperature shrink: if local temp exceeds 20 C, shrink back by a small margin
			if fill_here and temp.size() == size:
				var t_norm := temp[i2]
				var t_c := temp_min_c + t_norm * (temp_max_c - temp_min_c)
				if t_c >= shrink_hot_c:
					# shrink by thin band (~0.01 height units)
					fill_here = height[i2] < (effective_level - 0.01)
				# Freeze flags for rendering/logic
				if t_c <= lakes_freeze_c:
					lake_freeze[i2] = 1
				if t_c <= lakes_icesheet_c:
					lake_freeze[i2] = 2
			if fill_here:
				lake_mask[i2] = 1
				lake_level[i2] = effective_level
				any_filled = true
		if not any_filled:
			continue
		# Label this lake component (single-basin fill may be multiple disjoint pools in rare cases; BFS over lake_mask ∧ sink_id==sid)
		var visited := {}
		for m3 in members:
			var root: int = int(m3)
			if not (lake_mask[root] != 0):
				continue
			if visited.has(root):
				continue
			# BFS
			var q: Array = []
			q.append(root)
			visited[root] = true
			var this_label: int = next_lake_label
			next_lake_label += 1
			while q.size() > 0:
				var cur: int = int(q.pop_front())
				lake_id[cur] = this_label
				var cx: int = cur % w
				var cy: int = floori(float(cur) / float(w))
				for ddy in range(-1, 2):
					for ddx in range(-1, 2):
						if ddx == 0 and ddy == 0:
							continue
						var nx2: int = cx + ddx
						var ny2: int = cy + ddy
						if wrap_x:
							nx2 = (nx2 + w) % w
						if nx2 < 0 or ny2 < 0 or nx2 >= w or ny2 >= h:
							continue
						var ni2: int = nx2 + ny2 * w
						if visited.has(ni2):
							continue
						if lake_mask[ni2] == 0:
							continue
						visited[ni2] = true
						q.append(ni2)
		# Pour candidates: sort ascending by cost and store per resulting lake label of inside cell
		candidates.sort_custom(func(a, b): return float(a[2]) < float(b[2]))
		# Build mapping lake_label -> list of candidates that belong to that labeled component
		var tmp_map := {}
		for c3 in candidates:
			var inside_i: int = int(c3[0])
			if lake_mask[inside_i] == 0:
				continue
			var lid: int = lake_id[inside_i]
			if lid <= 0:
				continue
			if not tmp_map.has(lid): tmp_map[lid] = []
			(tmp_map[lid] as Array).append(c3)
		for lid_key in tmp_map.keys():
			pour_points[lid_key] = tmp_map[lid_key]
			# Deterministic per-lake RNG
			var local_rng := RandomNumberGenerator.new()
			local_rng.seed = int(settings.get("rng_seed", 1337)) ^ int(lid_key)
			# Always include the primary (lowest-cost) pour point
			var cand_list: Array = pour_points[lid_key]
			if cand_list.size() == 0:
				continue
			var first_edge: Array = cand_list[0]
			var primary_seed_i: int = int(first_edge[0])
			forced_seeds_arr.append(primary_seed_i)
			# Additional outflows (probabilistic, ocean-biased)
			var shore_band: float = float(settings.get("shore_band", 6.0))
			var dist_to_ocean: PackedFloat32Array = settings.get("dist_to_ocean", PackedFloat32Array())
			var alpha_ob: float = float(settings.get("alpha_outflow_ocean_bias", 0.7))
			var beta_chain: float = float(settings.get("beta_outflow_chain_bias", 0.3))
			var chain_depth_max: float = float(settings.get("chain_depth_max", 5.0))
			# Chain-depth proxy: normalized distance to ocean at primary pour point
			var p_depth: float = 0.0
			if dist_to_ocean.size() == size and primary_seed_i >= 0 and primary_seed_i < size and shore_band > 0.0 and chain_depth_max > 0.0:
				var scale: float = max(shore_band * chain_depth_max, 1.0)
				p_depth = clamp(dist_to_ocean[primary_seed_i] / scale, 0.0, 1.0)
			var max_extra: int = max(0, min(max_forced_outflows, cand_list.size()) - 1)
			# Determine desired extras count using CDF
			var picks_extra: int = 0
			var r: float = local_rng.randf()
			for kx in range(cdf.size()):
				if r <= float(cdf[kx]):
					picks_extra = kx
					break
			# Iterate next-lowest candidates and open with ocean bias until reached picks_extra or max_extra
			var opened: int = 0
			for ci in range(1, cand_list.size()):
				if opened >= picks_extra or opened >= max_extra:
					break
				var edge2: Array = cand_list[ci]
				var seed_i2: int = int(edge2[0])
				# Ocean bias probability
				var p_ocean: float = 0.0
				if dist_to_ocean.size() == size and seed_i2 >= 0 and seed_i2 < size and shore_band > 0.0:
					p_ocean = clamp((shore_band - dist_to_ocean[seed_i2]) / shore_band, 0.0, 1.0)
				# Combined probability with chain-depth proxy
				var p_combined: float = clamp(alpha_ob * p_ocean + beta_chain * p_depth, 0.0, 1.0)
				var open_r: float = local_rng.randf()
				if open_r <= p_combined:
					forced_seeds_arr.append(seed_i2)
					opened += 1

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
	# OR forced seeds into seeds list (ensure uniqueness)
	var forced_seeds := PackedInt32Array()
	forced_seeds.resize(forced_seeds_arr.size())
	for ii in range(forced_seeds_arr.size()): forced_seeds[ii] = int(forced_seeds_arr[ii])
	var seed_set := {}
	for s0 in seeds: seed_set[int(s0)] = true
	for fs in forced_seeds_arr: seed_set[int(fs)] = true
	var seeds_final: Array = []
	for k in seed_set.keys(): seeds_final.append(int(k))
	seeds_final.sort()
	for s in seeds_final:
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
		"lake_id": lake_id,
		"lake_level": lake_level,
		"lake_freeze": lake_freeze,
		"outflow_seeds": forced_seeds,
		"pour_points": pour_points,
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
