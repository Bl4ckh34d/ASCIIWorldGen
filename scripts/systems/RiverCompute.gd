# File: res://scripts/systems/RiverCompute.gd
extends RefCounted

const SEED_NMS_SHADER := preload("res://shaders/river_seed_nms.glsl")
const TRACE_SHADER := preload("res://shaders/river_trace.glsl")

var _rd: RenderingDevice
var _seed_shader: RID
var _seed_pipeline: RID
var _trace_shader: RID
var _trace_pipeline: RID

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.create_local_rendering_device()
	if not _seed_shader.is_valid():
		var s := SEED_NMS_SHADER.get_spirv("vulkan"); if s == null: return
		_seed_shader = _rd.shader_create_from_spirv(s)
	if not _seed_pipeline.is_valid() and _seed_shader.is_valid():
		_seed_pipeline = _rd.compute_pipeline_create(_seed_shader)
	if not _trace_shader.is_valid():
		var s2 := TRACE_SHADER.get_spirv("vulkan"); if s2 == null: return
		_trace_shader = _rd.shader_create_from_spirv(s2)
	if not _trace_pipeline.is_valid() and _trace_shader.is_valid():
		_trace_pipeline = _rd.compute_pipeline_create(_trace_shader)

func trace_rivers(w: int, h: int, is_land: PackedByteArray, lake_mask: PackedByteArray, flow_dir: PackedInt32Array, flow_accum: PackedFloat32Array, percentile: float, min_len: int) -> PackedByteArray:
	_ensure()
	if not _seed_pipeline.is_valid() or not _trace_pipeline.is_valid():
		return PackedByteArray()
	var size: int = max(0, w * h)
	# Compute threshold by percentile on CPU (simple sort)
	var acc_vals: Array = []
	for i in range(size): if is_land[i] != 0: acc_vals.append(flow_accum[i])
	acc_vals.sort()
	var thr_idx: int = clamp(int(floor(float(acc_vals.size() - 1) * percentile)), 0, max(0, acc_vals.size() - 1))
	var thr: float = 4.0
	if acc_vals.size() > 0: thr = max(4.0, float(acc_vals[thr_idx]))
	# Buffers
	var buf_acc := _rd.storage_buffer_create(flow_accum.to_byte_array().size(), flow_accum.to_byte_array())
	var buf_land := _rd.storage_buffer_create(is_land.size(), is_land)
	var buf_dir := _rd.storage_buffer_create(flow_dir.to_byte_array().size(), flow_dir.to_byte_array())
	var buf_seeds_arr := PackedByteArray(); buf_seeds_arr.resize(size)
	var buf_seeds := _rd.storage_buffer_create(buf_seeds_arr.size(), buf_seeds_arr)
	# Seed pass
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_acc); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_dir); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_seeds); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _seed_shader, 0)
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h]); var f := PackedFloat32Array([thr]); pc.append_array(ints.to_byte_array()); pc.append_array(f.to_byte_array())
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _seed_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end(); _rd.submit(); _rd.sync()
	_rd.free_rid(u_set)
	# Trace pass (multi-iteration)
	var frontier_in_bytes := _rd.buffer_get_data(buf_seeds)
	var frontier_in := frontier_in_bytes # PackedByteArray
	var buf_front_in := buf_seeds
	var frontier_out := PackedByteArray(); frontier_out.resize(size)
	var buf_front_out := _rd.storage_buffer_create(frontier_out.size(), frontier_out)
	var river := PackedByteArray(); river.resize(size)
	var buf_river := _rd.storage_buffer_create(river.size(), river)
	var max_iters: int = max(min_len, 32)
	for _iter in range(max_iters):
		uniforms.clear()
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_dir); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_front_in); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(_rd.storage_buffer_create(is_land.size(), is_land)); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_front_out); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_river); uniforms.append(u)
		u_set = _rd.uniform_set_create(uniforms, _trace_shader, 0)
		pc = PackedByteArray(); var total_arr := PackedInt32Array([size]); pc.append_array(total_arr.to_byte_array())
		var g1d := int(ceil(float(size) / 256.0))
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _trace_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, g1d, 1, 1)
		_rd.compute_list_end(); _rd.submit(); _rd.sync()
		# swap frontier buffers; reset out
		var out_bytes := _rd.buffer_get_data(buf_front_out)
		frontier_in = out_bytes
		_rd.free_rid(buf_front_in)
		buf_front_in = _rd.storage_buffer_create(frontier_in.size(), frontier_in)
		for i in range(size): frontier_out[i] = 0
		_rd.free_rid(buf_front_out)
		buf_front_out = _rd.storage_buffer_create(frontier_out.size(), frontier_out)
		_rd.free_rid(u_set)
	# Prune short rivers on CPU (quick pass)
	var river_bytes := _rd.buffer_get_data(buf_river)
	var river_out := river_bytes
	if min_len > 1:
		var visited := PackedByteArray(); visited.resize(size)
		for i2 in range(size): visited[i2] = 0
		for start in range(size):
			if river_out[start] == 0 or visited[start] != 0: continue
			var comp: Array = []
			var q: Array = []; q.append(start); visited[start] = 1
			while q.size() > 0:
				var cur: int = int(q.pop_front())
				comp.append(cur)
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0: continue
						var nx := (cur % w) + dx
						var ny := int(floor(float(cur) / float(w))) + dy
						if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
						var ni := nx + ny * w
						if river_out[ni] == 0 or visited[ni] != 0: continue
						visited[ni] = 1; q.append(ni)
			if comp.size() < min_len:
				for p in comp: river_out[int(p)] = 0
	_rd.free_rid(buf_acc)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_dir)
	_rd.free_rid(buf_seeds)
	_rd.free_rid(buf_front_in)
	_rd.free_rid(buf_front_out)
	_rd.free_rid(buf_river)
	return river_out
