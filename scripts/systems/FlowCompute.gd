# File: res://scripts/systems/FlowCompute.gd
extends RefCounted

const FLOW_DIR_SHADER := preload("res://shaders/flow_dir.glsl")
const FLOW_ACCUM_SHADER := preload("res://shaders/flow_accum.glsl")
const FLOW_PUSH_SHADER := preload("res://shaders/flow_push.glsl")

var _rd: RenderingDevice
var _dir_shader: RID
var _dir_pipeline: RID
var _acc_shader: RID
var _acc_pipeline: RID
var _push_shader: RID
var _push_pipeline: RID

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.create_local_rendering_device()
	if not _dir_shader.is_valid():
		var s := FLOW_DIR_SHADER.get_spirv("vulkan"); if s == null: return
		_dir_shader = _rd.shader_create_from_spirv(s)
	if not _dir_pipeline.is_valid() and _dir_shader.is_valid():
		_dir_pipeline = _rd.compute_pipeline_create(_dir_shader)
	if not _acc_shader.is_valid():
		var s2 := FLOW_ACCUM_SHADER.get_spirv("vulkan"); if s2 == null: return
		_acc_shader = _rd.shader_create_from_spirv(s2)
	if not _acc_pipeline.is_valid() and _acc_shader.is_valid():
		_acc_pipeline = _rd.compute_pipeline_create(_acc_shader)
	if not _push_shader.is_valid():
		var s3 := FLOW_PUSH_SHADER.get_spirv("vulkan"); if s3 == null: return
		_push_shader = _rd.shader_create_from_spirv(s3)
	if not _push_pipeline.is_valid() and _push_shader.is_valid():
		_push_pipeline = _rd.compute_pipeline_create(_push_shader)

func compute_flow(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, wrap_x: bool) -> Dictionary:
	_ensure()
	if not _dir_pipeline.is_valid() or not _acc_pipeline.is_valid():
		return {}
	var size: int = max(0, w * h)
	var buf_h := _rd.storage_buffer_create(height.to_byte_array().size(), height.to_byte_array())
	var buf_land := _rd.storage_buffer_create(is_land.size(), is_land)
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
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h, (1 if wrap_x else 0)])
	pc.append_array(ints.to_byte_array())
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _dir_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end(); _rd.submit(); _rd.sync()

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
	pc = PackedByteArray(); var total_arr: PackedInt32Array = PackedInt32Array([size]); pc.append_array(total_arr.to_byte_array())
	var g1d: int = int(ceil(float(size) / 256.0))
	var max_iters: int = 4 # small worlds; for larger, raise or switch to topological order
	for _pass in range(max_iters):
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _push_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, g1d, 1, 1)
		_rd.compute_list_end(); _rd.submit(); _rd.sync()
		# swap frontier_out -> frontier_in, and zero out frontier_out
		var front_bytes := _rd.buffer_get_data(buf_front_out)
		frontier_in = front_bytes.to_int32_array()
		_rd.free_rid(buf_front_in)
		buf_front_in = _rd.storage_buffer_create(frontier_in.to_byte_array().size(), frontier_in.to_byte_array())
		# zero out frontier_out
		for z in range(size): frontier_out[z] = 0
		_rd.free_rid(buf_front_out)
		buf_front_out = _rd.storage_buffer_create(frontier_out.to_byte_array().size(), frontier_out.to_byte_array())
		uniforms.clear()
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_dir); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_front_in); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_total); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_front_out); uniforms.append(u)
		u_set = _rd.uniform_set_create(uniforms, _push_shader, 0)

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


