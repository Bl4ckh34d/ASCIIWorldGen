# File: res://scripts/systems/FlowCompute.gd
extends RefCounted

const FLOW_DIR_SHADER := preload("res://shaders/flow_dir.glsl")
const FLOW_ACCUM_SHADER := preload("res://shaders/flow_accum.glsl")
const FLOW_PUSH_SHADER := preload("res://shaders/flow_push.glsl")
var CLEAR_U32_SHADER_FILE: RDShaderFile = load("res://shaders/clear_u32.glsl")

var _rd: RenderingDevice
var _dir_shader: RID
var _dir_pipeline: RID
var _acc_shader: RID
var _acc_pipeline: RID
var _push_shader: RID
var _push_pipeline: RID
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
	if not _dir_shader.is_valid():
		var s := _get_spirv(FLOW_DIR_SHADER)
		if s == null:
			return
		_dir_shader = _rd.shader_create_from_spirv(s)
	if not _dir_pipeline.is_valid() and _dir_shader.is_valid():
		_dir_pipeline = _rd.compute_pipeline_create(_dir_shader)
	if not _acc_shader.is_valid():
		var s2 := _get_spirv(FLOW_ACCUM_SHADER)
		if s2 == null:
			return
		_acc_shader = _rd.shader_create_from_spirv(s2)
	if not _acc_pipeline.is_valid() and _acc_shader.is_valid():
		_acc_pipeline = _rd.compute_pipeline_create(_acc_shader)
	if not _push_shader.is_valid():
		var s3 := _get_spirv(FLOW_PUSH_SHADER)
		if s3 == null:
			return
		_push_shader = _rd.shader_create_from_spirv(s3)
	if not _push_pipeline.is_valid() and _push_shader.is_valid():
		_push_pipeline = _rd.compute_pipeline_create(_push_shader)
	if not _clear_shader.is_valid():
		var sc: RDShaderSPIRV = _get_spirv(CLEAR_U32_SHADER_FILE)
		if sc == null:
			return
		_clear_shader = _rd.shader_create_from_spirv(sc)
	if not _clear_pipeline.is_valid() and _clear_shader.is_valid():
		_clear_pipeline = _rd.compute_pipeline_create(_clear_shader)

func compute_flow(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, wrap_x: bool, roi: Rect2i = Rect2i(0,0,0,0)) -> Dictionary:
	_ensure()
	if not _dir_pipeline.is_valid() or not _acc_pipeline.is_valid():
		return {}
	var size: int = max(0, w * h)
	var buf_h := _rd.storage_buffer_create(height.to_byte_array().size(), height.to_byte_array())
	# is_land as u32 for GLSL
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	for i in range(size): land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var flow_dir := PackedInt32Array(); flow_dir.resize(size)
	for i in range(size): flow_dir[i] = -1
	var buf_dir := _rd.storage_buffer_create(flow_dir.to_byte_array().size(), flow_dir.to_byte_array())

	# Flow direction pass
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_h); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_dir); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _dir_shader, 0)
	# ROI bounds
	var rx0: int = 0; var ry0: int = 0; var rx1: int = w; var ry1: int = h
	if roi.size.x > 0 and roi.size.y > 0:
		rx0 = clamp(roi.position.x, 0, max(0, w))
		ry0 = clamp(roi.position.y, 0, max(0, h))
		rx1 = clamp(roi.position.x + roi.size.x, 0, max(0, w))
		ry1 = clamp(roi.position.y + roi.size.y, 0, max(0, h))
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h, (1 if wrap_x else 0), rx0, ry0, rx1, ry1])
	pc.append_array(ints.to_byte_array())
	# Align to 16 bytes (push constants often require 16-byte multiples)
	var pad0 := (16 - (pc.size() % 16)) % 16
	if pad0 > 0:
		var zeros0 := PackedByteArray(); zeros0.resize(pad0)
		pc.append_array(zeros0)
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _dir_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()

	# Accumulation via frontier propagation (seed all land with 1, push downstream)
	var total_u := PackedInt32Array(); total_u.resize(size)
	var frontier_in := PackedInt32Array(); frontier_in.resize(size)
	var frontier_out := PackedInt32Array(); frontier_out.resize(size)
	for i2 in range(size):
		var v := (1 if (i2 < is_land.size() and is_land[i2] != 0) else 0)
		total_u[i2] = v
		frontier_in[i2] = v
		frontier_out[i2] = 0
	var buf_total := _rd.storage_buffer_create(total_u.to_byte_array().size(), total_u.to_byte_array())
	var buf_front_in := _rd.storage_buffer_create(frontier_in.to_byte_array().size(), frontier_in.to_byte_array())
	var buf_front_out := _rd.storage_buffer_create(frontier_out.to_byte_array().size(), frontier_out.to_byte_array())
	# push constants and uniform set
	uniforms.clear()
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_dir); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_front_in); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_total); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_front_out); uniforms.append(u)
	u_set = _rd.uniform_set_create(uniforms, _push_shader, 0)
	pc = PackedByteArray()
	# push constants for push pass: total_cells, roi, width
	var push_consts := PackedInt32Array([size, rx0, ry0, rx1, ry1, w])
	pc.append_array(push_consts.to_byte_array())
	# Align to 16 bytes
	var pad_p := (16 - (pc.size() % 16)) % 16
	if pad_p > 0:
		var zeros_p := PackedByteArray(); zeros_p.resize(pad_p)
		pc.append_array(zeros_p)
	var g1d: int = int(ceil(float(size) / 256.0))
	var max_iters: int = 4 # small worlds; for larger, raise or add empty-frontier early exit
	for _pass in range(max_iters):
		# Push pass
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _push_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, g1d, 1, 1)
		_rd.compute_list_end()
		# Ping-pong: swap frontier buffers (GPU-only) and clear the new frontier_out
		var tmp_buf := buf_front_in
		buf_front_in = buf_front_out
		buf_front_out = tmp_buf
		# Clear the new out buffer on GPU
		var uniforms_c: Array = []
		var uc := RDUniform.new(); uc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; uc.binding = 0; uc.add_id(buf_front_out); uniforms_c.append(uc)
		var u_set_c := _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
		var pc_c := PackedByteArray(); var ints_c := PackedInt32Array([size]); pc_c.append_array(ints_c.to_byte_array())
		# Align to 16 bytes
		var pad_c := (16 - (pc_c.size() % 16)) % 16
		if pad_c > 0:
			var zeros_c := PackedByteArray(); zeros_c.resize(pad_c)
			pc_c.append_array(zeros_c)
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set_c, 0)
		_rd.compute_list_set_push_constant(cl, pc_c, pc_c.size())
		_rd.compute_list_dispatch(cl, g1d, 1, 1)
		_rd.compute_list_end(); _rd.free_rid(u_set_c)
		# Rebuild push uniform set with swapped buffers
		uniforms.clear()
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_dir); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_front_in); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_total); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_front_out); uniforms.append(u)
		u_set = _rd.uniform_set_create(uniforms, _push_shader, 0)

	# No explicit sync on main device
	var dir_bytes := _rd.buffer_get_data(buf_dir)
	var total_bytes := _rd.buffer_get_data(buf_total)
	var dir_out: PackedInt32Array = dir_bytes.to_int32_array()
	var acc_out_u: PackedInt32Array = total_bytes.to_int32_array()
	var acc_out := PackedFloat32Array(); acc_out.resize(size)
	for k in range(size): acc_out[k] = float(acc_out_u[k])
	_rd.free_rid(u_set)
	_rd.free_rid(buf_h)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_dir)
	_rd.free_rid(buf_total)
	_rd.free_rid(buf_front_in)
	_rd.free_rid(buf_front_out)
	return { "flow_dir": dir_out, "flow_accum": acc_out }
