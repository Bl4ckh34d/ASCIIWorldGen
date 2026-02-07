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

func trace_rivers(w: int, h: int, is_land: PackedByteArray, lake_mask: PackedByteArray, flow_dir: PackedInt32Array, flow_accum: PackedFloat32Array, threshold: float, min_len: int, forced_seeds: PackedInt32Array = PackedInt32Array()) -> PackedByteArray:
	_ensure()
	if not _seed_pipeline.is_valid() or not _trace_pipeline.is_valid():
		return PackedByteArray()
	var size: int = max(0, w * h)
	# GPU-only: caller provides absolute threshold; avoid CPU percentile sort.
	var thr: float = max(0.0, threshold)
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
	var max_iters: int = _river_max_iters(w, h, min_len)
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
		var clear_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clear_list, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clear_list, u_set_c, 0)
		_rd.compute_list_set_push_constant(clear_list, pc_c, pc_c.size())
		_rd.compute_list_dispatch(clear_list, g1d2, 1, 1)
		_rd.compute_list_end(); _rd.free_rid(u_set_c)
		_rd.free_rid(u_set)
	# Read back river mask produced by GPU tracing.
	var river_bytes := _rd.buffer_get_data(buf_river)
	var river_u32_out := river_bytes.to_int32_array()
	var river_out := PackedByteArray(); river_out.resize(size)
	for k in range(size): river_out[k] = 1 if (k < river_u32_out.size() and river_u32_out[k] != 0) else 0
	_rd.free_rid(buf_acc)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_dir)
	# Free only the buffers we created explicitly: seeds and the initial transient frontier_out
	_rd.free_rid(buf_seeds)
	_rd.free_rid(buf_front_initial)
	_rd.free_rid(buf_river)
	_rd.free_rid(buf_lake)
	return river_out

# ROI-aware variant: only seed within roi, then trace globally from those seeds.
func trace_rivers_roi(
		w: int, h: int,
		is_land: PackedByteArray,
		lake_mask: PackedByteArray,
		flow_dir: PackedInt32Array,
		flow_accum: PackedFloat32Array,
		threshold: float = 4.0,
		min_len: int = 5,
		roi: Rect2i = Rect2i(0,0,0,0),
		forced_seeds: PackedInt32Array = PackedInt32Array()
	) -> PackedByteArray:
	_ensure()
	if not _seed_pipeline.is_valid() or not _trace_pipeline.is_valid():
		return PackedByteArray()
	var size: int = max(0, w * h)

	# GPU-only: caller provides absolute threshold; avoid CPU percentile sort.
	var thr: float = max(0.0, threshold)

	# Buffers: inputs
	var buf_acc := _rd.storage_buffer_create(flow_accum.to_byte_array().size(), flow_accum.to_byte_array())
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	for k in range(size): land_u32[k] = 1 if (k < is_land.size() and is_land[k] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var buf_dir := _rd.storage_buffer_create(flow_dir.to_byte_array().size(), flow_dir.to_byte_array())
	var lake_u32 := PackedInt32Array(); lake_u32.resize(size)
	for k in range(size): lake_u32[k] = 1 if (k < lake_mask.size() and lake_mask[k] != 0) else 0
	var buf_lake := _rd.storage_buffer_create(lake_u32.to_byte_array().size(), lake_u32.to_byte_array())

	# Seeds buffer (u32 flags)
	var seeds_u32 := PackedInt32Array(); seeds_u32.resize(size)
	for k in range(size): seeds_u32[k] = 0
	if forced_seeds.size() > 0:
		for idx in forced_seeds: if idx >= 0 and idx < size: seeds_u32[int(idx)] = 1
	var buf_seeds := _rd.storage_buffer_create(seeds_u32.to_byte_array().size(), seeds_u32.to_byte_array())

	# Seed selection pass with ROI clipping in shader
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_acc); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_dir); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_seeds); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _seed_shader, 0)
	# Push constants: width, height, threshold, rx0, ry0, rx1, ry1
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	pc.append_array(ints.to_byte_array())
	var f := PackedFloat32Array([thr]); pc.append_array(f.to_byte_array())
	var rx0: int = 0; var ry0: int = 0; var rx1: int = w; var ry1: int = h
	if roi.size.x > 0 and roi.size.y > 0:
		rx0 = clamp(roi.position.x, 0, max(0, w))
		ry0 = clamp(roi.position.y, 0, max(0, h))
		rx1 = clamp(roi.position.x + roi.size.x, 0, max(0, w))
		ry1 = clamp(roi.position.y + roi.size.y, 0, max(0, h))
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

	# Trace pass: ping-pong
	var buf_front_in := buf_seeds
	var frontier_out := PackedInt32Array(); frontier_out.resize(size)
	for k in range(size): frontier_out[k] = 0
	var buf_front_out := _rd.storage_buffer_create(frontier_out.to_byte_array().size(), frontier_out.to_byte_array())
	var river_u32 := PackedInt32Array(); river_u32.resize(size)
	for k in range(size): river_u32[k] = 0
	var buf_river := _rd.storage_buffer_create(river_u32.to_byte_array().size(), river_u32.to_byte_array())

	# Clear helper uniforms for frontier_out
	var uniforms_c: Array = []
	var uc := RDUniform.new(); uc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; uc.binding = 0; uc.add_id(buf_front_out); uniforms_c.append(uc)
	var u_set_c := _rd.uniform_set_create(uniforms_c, _clear_shader, 0)

	# Iterative trace
	var total_cells_i := PackedInt32Array([size])
	var pc_trace := PackedByteArray(); pc_trace.append_array(total_cells_i.to_byte_array())
	var pad_tr := (16 - (pc_trace.size() % 16)) % 16
	if pad_tr > 0:
		var z_tr := PackedByteArray(); z_tr.resize(pad_tr); pc_trace.append_array(z_tr)
	var g1d := int(ceil(float(size) / 256.0))
	var max_iters_roi: int = _river_max_iters(w, h, min_len)
	for it in range(max_iters_roi): # allow rivers to reach sinks
		# trace step
		var uniforms_t: Array = []
		var ut: RDUniform
		ut = RDUniform.new(); ut.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ut.binding = 0; ut.add_id(buf_dir); uniforms_t.append(ut)
		ut = RDUniform.new(); ut.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ut.binding = 1; ut.add_id(buf_land); uniforms_t.append(ut)
		ut = RDUniform.new(); ut.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ut.binding = 2; ut.add_id(buf_lake); uniforms_t.append(ut)
		ut = RDUniform.new(); ut.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ut.binding = 3; ut.add_id(buf_front_in); uniforms_t.append(ut)
		ut = RDUniform.new(); ut.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ut.binding = 4; ut.add_id(buf_front_out); uniforms_t.append(ut)
		ut = RDUniform.new(); ut.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ut.binding = 5; ut.add_id(buf_river); uniforms_t.append(ut)
		var u_set_t := _rd.uniform_set_create(uniforms_t, _trace_shader, 0)
		var clt := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clt, _trace_pipeline)
		_rd.compute_list_bind_uniform_set(clt, u_set_t, 0)
		_rd.compute_list_set_push_constant(clt, pc_trace, pc_trace.size())
		_rd.compute_list_dispatch(clt, g1d, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set_t)

		# Swap frontiers and clear out
		var tmp := buf_front_in; buf_front_in = buf_front_out; buf_front_out = tmp
		var pc_c := PackedByteArray(); pc_c.append_array(PackedInt32Array([size]).to_byte_array())
		var pad_c := (16 - (pc_c.size() % 16)) % 16
		if pad_c > 0: var zc := PackedByteArray(); zc.resize(pad_c); pc_c.append_array(zc)
		var clear_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clear_list, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clear_list, u_set_c, 0)
		_rd.compute_list_set_push_constant(clear_list, pc_c, pc_c.size())
		_rd.compute_list_dispatch(clear_list, g1d, 1, 1)
		_rd.compute_list_end()

	# Read back rivers
	var river_bytes := _rd.buffer_get_data(buf_river)
	var river_u32_out := river_bytes.to_int32_array()
	var river_out := PackedByteArray(); river_out.resize(size)
	for k in range(size): river_out[k] = 1 if (k < river_u32_out.size() and river_u32_out[k] != 0) else 0

	# Cleanup (avoid double-free since buf_front_in and buf_seeds can point to same buffer)
	_rd.free_rid(buf_acc); _rd.free_rid(buf_land); _rd.free_rid(buf_dir)
	_rd.free_rid(buf_front_in); _rd.free_rid(buf_front_out); _rd.free_rid(buf_river); _rd.free_rid(buf_lake)

	return river_out
