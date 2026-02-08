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
var _seeds_buf: RID
var _front_a_buf: RID
var _front_b_buf: RID
var _buf_size: int = 0

func _river_max_iters(w: int, h: int, min_len: int) -> int:
	# Gameplay-oriented cap: shorter traces keep runtime predictable.
	# This intentionally sacrifices long-tail realism for performance.
	var cap: int = min(w + h, 96)
	return max(min_len, cap)

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
	if chosen_version == null:
		return null
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

func _ensure_frontier_buffers(size: int) -> void:
	if _buf_size == size and _seeds_buf.is_valid() and _front_a_buf.is_valid() and _front_b_buf.is_valid():
		return
	_buf_size = size
	if _seeds_buf.is_valid():
		_rd.free_rid(_seeds_buf)
	if _front_a_buf.is_valid():
		_rd.free_rid(_front_a_buf)
	if _front_b_buf.is_valid():
		_rd.free_rid(_front_b_buf)
	var bytes: int = size * 4
	_seeds_buf = _rd.storage_buffer_create(bytes)
	_front_a_buf = _rd.storage_buffer_create(bytes)
	_front_b_buf = _rd.storage_buffer_create(bytes)

func trace_rivers_gpu_buffers(
		w: int, h: int,
		land_buf: RID,
		lake_buf: RID,
		flow_dir_buf: RID,
		flow_accum_buf: RID,
		threshold: float,
		min_len: int,
		roi: Rect2i,
		out_river_buf: RID,
		clear_output: bool = true
	) -> bool:
	_ensure()
	if not _seed_pipeline.is_valid() or not _trace_pipeline.is_valid() or not _clear_pipeline.is_valid():
		return false
	if not land_buf.is_valid() or not lake_buf.is_valid() or not flow_dir_buf.is_valid() or not flow_accum_buf.is_valid() or not out_river_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	_ensure_frontier_buffers(size)
	var g1d2 := int(ceil(float(size) / 256.0))
	var uniforms_c: Array = []
	var u_set_c: RID
	var pc_c := PackedByteArray()
	var ints_c := PackedInt32Array([size])
	pc_c.append_array(ints_c.to_byte_array())
	var pad_clear := (16 - (pc_c.size() % 16)) % 16
	if pad_clear > 0:
		var z_clear := PackedByteArray()
		z_clear.resize(pad_clear)
		pc_c.append_array(z_clear)
	# Clear river output only when requested by caller (tile scheduler controls this).
	if clear_output:
		uniforms_c.clear()
		var uc := RDUniform.new()
		uc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uc.binding = 0
		uc.add_id(out_river_buf)
		uniforms_c.append(uc)
		u_set_c = _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
		var clear_output_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clear_output_list, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clear_output_list, u_set_c, 0)
		_rd.compute_list_set_push_constant(clear_output_list, pc_c, pc_c.size())
		_rd.compute_list_dispatch(clear_output_list, g1d2, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set_c)
	# Seed pass
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(flow_accum_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(flow_dir_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(_seeds_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _seed_shader, 0)
	var rx0: int = 0; var ry0: int = 0; var rx1: int = w; var ry1: int = h
	if roi.size.x > 0 and roi.size.y > 0:
		rx0 = clamp(roi.position.x, 0, max(0, w))
		ry0 = clamp(roi.position.y, 0, max(0, h))
		rx1 = clamp(roi.position.x + roi.size.x, 0, max(0, w))
		ry1 = clamp(roi.position.y + roi.size.y, 0, max(0, h))
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([threshold])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var roi_ints := PackedInt32Array([rx0, ry0, rx1, ry1])
	pc.append_array(roi_ints.to_byte_array())
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
	# Trace pass
	var buf_front_in := _seeds_buf
	var buf_front_out := _front_a_buf
	# Clear frontier out
	uniforms_c.clear()
	var uc2 := RDUniform.new(); uc2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; uc2.binding = 0; uc2.add_id(buf_front_out); uniforms_c.append(uc2)
	u_set_c = _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
	var clear_frontier_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(clear_frontier_list, _clear_pipeline)
	_rd.compute_list_bind_uniform_set(clear_frontier_list, u_set_c, 0)
	_rd.compute_list_set_push_constant(clear_frontier_list, pc_c, pc_c.size())
	_rd.compute_list_dispatch(clear_frontier_list, g1d2, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set_c)
	var max_iters: int = _river_max_iters(w, h, min_len)
	for _iter in range(max_iters):
		uniforms.clear()
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(flow_dir_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(lake_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_front_in); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_front_out); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(out_river_buf); uniforms.append(u)
		u_set = _rd.uniform_set_create(uniforms, _trace_shader, 0)
		pc = PackedByteArray(); var total_arr := PackedInt32Array([size]); pc.append_array(total_arr.to_byte_array())
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
		# swap frontiers
		var tmp := buf_front_in
		buf_front_in = buf_front_out
		buf_front_out = tmp
		# clear new out
		uniforms_c.clear()
		uc2 = RDUniform.new(); uc2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; uc2.binding = 0; uc2.add_id(buf_front_out); uniforms_c.append(uc2)
		u_set_c = _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
		pc_c = PackedByteArray(); ints_c = PackedInt32Array([size]); pc_c.append_array(ints_c.to_byte_array())
		pad_clear = (16 - (pc_c.size() % 16)) % 16
		if pad_clear > 0:
			var z_clear3 := PackedByteArray(); z_clear3.resize(pad_clear)
			pc_c.append_array(z_clear3)
		clear_frontier_list = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clear_frontier_list, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clear_frontier_list, u_set_c, 0)
		_rd.compute_list_set_push_constant(clear_frontier_list, pc_c, pc_c.size())
		_rd.compute_list_dispatch(clear_frontier_list, g1d2, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set_c)
		_rd.free_rid(u_set)
	# GPU-only: skip CPU pruning in this path
	return true
