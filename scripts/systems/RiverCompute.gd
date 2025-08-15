# File: res://scripts/systems/RiverCompute.gd
extends RefCounted

const SEED_NMS_SHADER := preload("res://shaders/river_seed_nms.glsl")
const TRACE_SHADER := preload("res://shaders/river_trace.glsl")
var CLEAR_U32_SHADER_FILE: RDShaderFile = load("res://shaders/clear_u32.glsl")

var _rd: RenderingDevice
var _seed_shader: RID
var _seed_pipeline: RID
var _trace_shader: RID
var _trace_pipeline: RID
var _clear_shader: RID
var _clear_pipeline: RID

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null:
		return null
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		return null
	var chosen_version = versions[0]
	for v in versions:
		if String(v) == "vulkan":
			chosen_version = v
			break
	return file.get_spirv(chosen_version)

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _seed_shader.is_valid():
		var s := _get_spirv(SEED_NMS_SHADER)
		if s == null:
			return
		_seed_shader = _rd.shader_create_from_spirv(s)
	if not _seed_pipeline.is_valid() and _seed_shader.is_valid():
		_seed_pipeline = _rd.compute_pipeline_create(_seed_shader)
	if not _trace_shader.is_valid():
		var s2 := _get_spirv(TRACE_SHADER)
		if s2 == null:
			return
		_trace_shader = _rd.shader_create_from_spirv(s2)
	if not _trace_pipeline.is_valid() and _trace_shader.is_valid():
		_trace_pipeline = _rd.compute_pipeline_create(_trace_shader)
	if not _clear_shader.is_valid():
		var sc: RDShaderSPIRV = _get_spirv(CLEAR_U32_SHADER_FILE)
		if sc == null:
			return
		_clear_shader = _rd.shader_create_from_spirv(sc)
	if not _clear_pipeline.is_valid() and _clear_shader.is_valid():
		_clear_pipeline = _rd.compute_pipeline_create(_clear_shader)

func trace_rivers(w: int, h: int, is_land: PackedByteArray, lake_mask: PackedByteArray, flow_dir: PackedInt32Array, flow_accum: PackedFloat32Array, percentile: float, min_len: int, forced_seeds: PackedInt32Array = PackedInt32Array()) -> PackedByteArray:
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
	# Convert masks to u32 for GLSL
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	var lake_u32 := PackedInt32Array(); lake_u32.resize(size)
	for i in range(size):
		land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
		lake_u32[i] = 1 if (i < lake_mask.size() and lake_mask[i] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var buf_dir := _rd.storage_buffer_create(flow_dir.to_byte_array().size(), flow_dir.to_byte_array())
	# Seeds as u32 buffer
	var seeds_u32 := PackedInt32Array(); seeds_u32.resize(size)
	for i in range(size): seeds_u32[i] = 0
	# Pre-stage forced seeds (set to 1) before NMS OR
	for k in range(min(size, forced_seeds.size())):
		var idx := forced_seeds[k]
		if idx >= 0 and idx < size: seeds_u32[idx] = 1
	var buf_seeds := _rd.storage_buffer_create(seeds_u32.to_byte_array().size(), seeds_u32.to_byte_array())
	# Seed pass
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_acc); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_dir); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_seeds); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _seed_shader, 0)
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h]); var f := PackedFloat32Array([thr]); pc.append_array(ints.to_byte_array()); pc.append_array(f.to_byte_array())
	# Align to 16 bytes
	var pad_seed := (16 - (pc.size() % 16)) % 16
	if pad_seed > 0:
		var z_seed := PackedByteArray(); z_seed.resize(pad_seed)
		pc.append_array(z_seed)
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _seed_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	# Trace pass (multi-iteration)
	# Use GPU-only ping-pong for tracing frontier
	var buf_front_in := buf_seeds
	var frontier_out := PackedInt32Array(); frontier_out.resize(size)
	var buf_front_out := _rd.storage_buffer_create(frontier_out.to_byte_array().size(), frontier_out.to_byte_array())
	var buf_front_initial := buf_front_out
	var river_u32 := PackedInt32Array(); river_u32.resize(size)
	var buf_river := _rd.storage_buffer_create(river_u32.to_byte_array().size(), river_u32.to_byte_array())
	var buf_lake := _rd.storage_buffer_create(lake_u32.to_byte_array().size(), lake_u32.to_byte_array())
	var max_iters: int = max(min_len, 32)
	for _iter in range(max_iters):
		uniforms.clear()
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_dir); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_lake); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_front_in); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_front_out); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(buf_river); uniforms.append(u)
		u_set = _rd.uniform_set_create(uniforms, _trace_shader, 0)
		pc = PackedByteArray(); var total_arr := PackedInt32Array([size]); pc.append_array(total_arr.to_byte_array())
		# Align to 16 bytes
		var pad_trace := (16 - (pc.size() % 16)) % 16
		if pad_trace > 0:
			var z_trace := PackedByteArray(); z_trace.resize(pad_trace)
			pc.append_array(z_trace)
		var g1d := int(ceil(float(size) / 256.0))
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _trace_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, g1d, 1, 1)
		_rd.compute_list_end()
		# swap frontier buffers (GPU-only)
		var tmp := buf_front_in
		buf_front_in = buf_front_out
		buf_front_out = tmp
		# zero new out buffer on GPU using clear_u32
		var uniforms_c: Array = []
		var uc := RDUniform.new(); uc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; uc.binding = 0; uc.add_id(buf_front_out); uniforms_c.append(uc)
		var u_set_c := _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
		var pc_c := PackedByteArray(); var ints_c := PackedInt32Array([size]); pc_c.append_array(ints_c.to_byte_array())
		# Align to 16 bytes
		var pad_clear := (16 - (pc_c.size() % 16)) % 16
		if pad_clear > 0:
			var z_clear := PackedByteArray(); z_clear.resize(pad_clear)
			pc_c.append_array(z_clear)
		var g1d2 := int(ceil(float(size) / 256.0))
		var clc := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clc, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clc, u_set_c, 0)
		_rd.compute_list_set_push_constant(clc, pc_c, pc_c.size())
		_rd.compute_list_dispatch(clc, g1d2, 1, 1)
		_rd.compute_list_end(); _rd.free_rid(u_set_c)
		_rd.free_rid(u_set)
	# Prune short rivers on CPU (quick pass)
	var river_bytes := _rd.buffer_get_data(buf_river)
	var river_u32_out := river_bytes.to_int32_array()
	var river_out := PackedByteArray(); river_out.resize(size)
	for k in range(size): river_out[k] = 1 if (k < river_u32_out.size() and river_u32_out[k] != 0) else 0
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
	# Free only the buffers we created explicitly: seeds and the initial transient frontier_out
	_rd.free_rid(buf_seeds)
	_rd.free_rid(buf_front_initial)
	_rd.free_rid(buf_river)
	_rd.free_rid(buf_lake)
	return river_out
