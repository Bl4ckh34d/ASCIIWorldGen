# File: res://scripts/systems/FlowCompute.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

const ComputeShaderBaseUtil = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")

const FLOW_DIR_SHADER_PATH: String = "res://shaders/flow_dir.glsl"
const FLOW_ACCUM_SHADER_PATH: String = "res://shaders/flow_accum.glsl"
const FLOW_PUSH_SHADER_PATH: String = "res://shaders/flow_push.glsl"
const CLEAR_U32_SHADER_PATH: String = "res://shaders/clear_u32.glsl"
const COPY_U32_SHADER_PATH: String = "res://shaders/copy_u32.glsl"
const U32_TO_F32_SHADER_PATH: String = "res://shaders/u32_to_f32.glsl"

var _rd: RenderingDevice
var _dir_shader: RID
var _dir_pipeline: RID
var _acc_shader: RID
var _acc_pipeline: RID
var _push_shader: RID
var _push_pipeline: RID
var _clear_shader: RID
var _clear_pipeline: RID
var _copy_shader: RID
var _copy_pipeline: RID
var _u32_to_f32_shader: RID
var _u32_to_f32_pipeline: RID
var _owned_buffer_manager: GPUBufferManager = null

func _init() -> void:
	_owned_buffer_manager = GPUBufferManager.new()

func _ensure() -> bool:
	var dir_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_dir_shader,
		_dir_pipeline,
		FLOW_DIR_SHADER_PATH,
		"flow_dir"
	)
	_rd = dir_state.get("rd", null)
	_dir_shader = dir_state.get("shader", RID())
	_dir_pipeline = dir_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(dir_state.get("ok", false)):
		return false

	var push_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_push_shader,
		_push_pipeline,
		FLOW_PUSH_SHADER_PATH,
		"flow_push"
	)
	_push_shader = push_state.get("shader", RID())
	_push_pipeline = push_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(push_state.get("ok", false)):
		return false

	var clear_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_clear_shader,
		_clear_pipeline,
		CLEAR_U32_SHADER_PATH,
		"clear_u32"
	)
	_clear_shader = clear_state.get("shader", RID())
	_clear_pipeline = clear_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(clear_state.get("ok", false)):
		return false

	var copy_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_copy_shader,
		_copy_pipeline,
		COPY_U32_SHADER_PATH,
		"copy_u32"
	)
	_copy_shader = copy_state.get("shader", RID())
	_copy_pipeline = copy_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(copy_state.get("ok", false)):
		return false

	var conv_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_u32_to_f32_shader,
		_u32_to_f32_pipeline,
		U32_TO_F32_SHADER_PATH,
		"u32_to_f32"
	)
	_u32_to_f32_shader = conv_state.get("shader", RID())
	_u32_to_f32_pipeline = conv_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(conv_state.get("ok", false)):
		return false

	# Optional compatibility pipeline (currently not used by compute_flow_gpu_buffers).
	var acc_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_acc_shader,
		_acc_pipeline,
		FLOW_ACCUM_SHADER_PATH,
		"flow_accum"
	)
	_acc_shader = acc_state.get("shader", RID())
	_acc_pipeline = acc_state.get("pipeline", RID())
	return true

func _dispatch_copy_u32(src: RID, dst: RID, count: int) -> bool:
	if not _copy_pipeline.is_valid():
		return false
	var uniforms: Array = []
	var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(src); uniforms.append(u0)
	var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(dst); uniforms.append(u1)
	var u_set := _rd.uniform_set_create(uniforms, _copy_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([count])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 16, "FlowCompute.copy_u32"):
		_rd.free_rid(u_set)
		return false
	var g1d: int = int(ceil(float(count) / 256.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _copy_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func _dispatch_clear_u32(buf: RID, count: int) -> bool:
	if not _clear_pipeline.is_valid():
		return false
	var uniforms: Array = []
	var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(buf); uniforms.append(u0)
	var u_set := _rd.uniform_set_create(uniforms, _clear_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([count])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 16, "FlowCompute.clear_u32"):
		_rd.free_rid(u_set)
		return false
	var g1d: int = int(ceil(float(count) / 256.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _clear_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func _dispatch_u32_to_f32(src: RID, dst: RID, count: int) -> bool:
	if not _u32_to_f32_pipeline.is_valid():
		return false
	var uniforms: Array = []
	var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(src); uniforms.append(u0)
	var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(dst); uniforms.append(u1)
	var u_set := _rd.uniform_set_create(uniforms, _u32_to_f32_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([count])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 16, "FlowCompute.u32_to_f32"):
		_rd.free_rid(u_set)
		return false
	var g1d: int = int(ceil(float(count) / 256.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _u32_to_f32_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func compute_flow_gpu_buffers(w: int, h: int, height_buf: RID, land_buf: RID, wrap_x: bool, out_dir_buf: RID, out_acc_buf: RID, roi: Rect2i = Rect2i(0,0,0,0), buffer_manager: Object = null) -> bool:
	if not _ensure():
		return false
	if not _dir_pipeline.is_valid() or not _push_pipeline.is_valid() or not _u32_to_f32_pipeline.is_valid():
		return false
	if not height_buf.is_valid() or not land_buf.is_valid() or not out_dir_buf.is_valid() or not out_acc_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	# Flow direction pass
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(height_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(out_dir_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _dir_shader, 0)
	var rx0: int = 0; var ry0: int = 0; var rx1: int = w; var ry1: int = h
	if roi.size.x > 0 and roi.size.y > 0:
		rx0 = clamp(roi.position.x, 0, max(0, w))
		ry0 = clamp(roi.position.y, 0, max(0, h))
		rx1 = clamp(roi.position.x + roi.size.x, 0, max(0, w))
		ry1 = clamp(roi.position.y + roi.size.y, 0, max(0, h))
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if wrap_x else 0), rx0, ry0, rx1, ry1])
	pc.append_array(ints.to_byte_array())
	var pad0 := (16 - (pc.size() % 16)) % 16
	if pad0 > 0:
		var zeros0 := PackedByteArray(); zeros0.resize(pad0)
		pc.append_array(zeros0)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 32, "FlowCompute.dir"):
		_rd.free_rid(u_set)
		return false
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _dir_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	# Accumulation buffers
	var total_buf: RID
	var front_in_buf: RID
	var front_out_buf: RID
	var bytes: int = size * 4
	var bm: Object = buffer_manager
	if bm == null:
		if _owned_buffer_manager == null:
			_owned_buffer_manager = GPUBufferManager.new()
		bm = _owned_buffer_manager
	total_buf = bm.ensure_buffer("flow_total_u32", bytes)
	front_in_buf = bm.ensure_buffer("flow_front_in", bytes)
	front_out_buf = bm.ensure_buffer("flow_front_out", bytes)
	if not (total_buf.is_valid() and front_in_buf.is_valid() and front_out_buf.is_valid()):
		return false
	# total = land, frontier_in = land, frontier_out = 0
	if not _dispatch_copy_u32(land_buf, total_buf, size):
		return false
	if not _dispatch_copy_u32(land_buf, front_in_buf, size):
		return false
	if not _dispatch_clear_u32(front_out_buf, size):
		return false
	# Push pass
	uniforms.clear()
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(out_dir_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(front_in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(total_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(front_out_buf); uniforms.append(u)
	u_set = _rd.uniform_set_create(uniforms, _push_shader, 0)
	pc = PackedByteArray()
	var push_consts := PackedInt32Array([size, rx0, ry0, rx1, ry1, w])
	pc.append_array(push_consts.to_byte_array())
	var pad_p := (16 - (pc.size() % 16)) % 16
	if pad_p > 0:
		var zeros_p := PackedByteArray(); zeros_p.resize(pad_p)
		pc.append_array(zeros_p)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 32, "FlowCompute.push"):
		_rd.free_rid(u_set)
		return false
	var g1d: int = int(ceil(float(size) / 256.0))
	var max_iters: int = 4
	for _pass in range(max_iters):
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _push_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, g1d, 1, 1)
		_rd.compute_list_end()
		# swap frontier buffers and clear new out
		var tmp_buf := front_in_buf
		front_in_buf = front_out_buf
		front_out_buf = tmp_buf
		if not _dispatch_clear_u32(front_out_buf, size):
			_rd.free_rid(u_set)
			return false
		# rebuild uniform set for swapped frontiers
		uniforms.clear()
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(out_dir_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(front_in_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(total_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(front_out_buf); uniforms.append(u)
		_rd.free_rid(u_set)
		u_set = _rd.uniform_set_create(uniforms, _push_shader, 0)
	_rd.free_rid(u_set)
	# Convert total u32 -> float accumulation
	return _dispatch_u32_to_f32(total_buf, out_acc_buf, size)

func cleanup() -> void:
	if _owned_buffer_manager != null:
		_owned_buffer_manager.cleanup()
	ComputeShaderBaseUtil.free_rids(_rd, [
		_dir_pipeline, _dir_shader,
		_acc_pipeline, _acc_shader,
		_push_pipeline, _push_shader,
		_clear_pipeline, _clear_shader,
		_copy_pipeline, _copy_shader,
		_u32_to_f32_pipeline, _u32_to_f32_shader,
	])
	_dir_pipeline = RID()
	_dir_shader = RID()
	_acc_pipeline = RID()
	_acc_shader = RID()
	_push_pipeline = RID()
	_push_shader = RID()
	_clear_pipeline = RID()
	_clear_shader = RID()
	_copy_pipeline = RID()
	_copy_shader = RID()
	_u32_to_f32_pipeline = RID()
	_u32_to_f32_shader = RID()
