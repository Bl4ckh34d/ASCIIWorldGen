# File: res://scripts/systems/DistanceTransformCompute.gd
extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const ComputeShaderBase = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")

const DT_SHADER_PATH: String = "res://shaders/distance_transform.glsl"

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _buf_mgr: GPUBufferManager = null

func _init() -> void:
	_buf_mgr = GPUBufferManager.new()

func _ensure() -> bool:
	var state: Dictionary = ComputeShaderBase.ensure_rd_and_pipeline(
		_rd,
		_shader,
		_pipeline,
		DT_SHADER_PATH,
		"distance_transform"
	)
	_rd = state.get("rd", null)
	_shader = state.get("shader", RID())
	_pipeline = state.get("pipeline", RID())
	return VariantCasts.to_bool(state.get("ok", false))

func _dispatch_mode(
		w: int,
		h: int,
		wrap_x: bool,
		mode: int,
		buf_land: RID,
		buf_in: RID,
		buf_out: RID
	) -> bool:
	if not _pipeline.is_valid():
		return false
	if not buf_land.is_valid() or not buf_in.is_valid() or not buf_out.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buf_land)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 1
	u.add_id(buf_in)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 2
	u.add_id(buf_out)
	uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if wrap_x else 0), mode])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBase.validate_push_constant_size(pc, 16, "DistanceTransformCompute.dispatch"):
		_rd.free_rid(u_set)
		return false
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func ocean_distance_to_land_gpu_buffers(
		w: int,
		h: int,
		land_buf: RID,
		wrap_x: bool,
		dist_out_buf: RID,
		dist_tmp_buf: RID
	) -> bool:
	if not _ensure():
		return false
	if not _shader.is_valid() or not _pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not land_buf.is_valid() or not dist_out_buf.is_valid() or not dist_tmp_buf.is_valid():
		return false
	# mode 2: seed distances from land mask into dist_out_buf
	if not _dispatch_mode(w, h, wrap_x, 2, land_buf, dist_tmp_buf, dist_out_buf):
		return false
	# mode 0: forward pass
	if not _dispatch_mode(w, h, wrap_x, 0, land_buf, dist_out_buf, dist_tmp_buf):
		return false
	# mode 1: backward pass
	if not _dispatch_mode(w, h, wrap_x, 1, land_buf, dist_tmp_buf, dist_out_buf):
		return false
	return true

func distance_to_coast_gpu_buffers(
		w: int,
		h: int,
		land_buf: RID,
		wrap_x: bool,
		dist_out_buf: RID,
		dist_tmp_buf: RID
	) -> bool:
	# Reusable alias API used by climate systems; kept separate for clearer callsites.
	return ocean_distance_to_land_gpu_buffers(w, h, land_buf, wrap_x, dist_out_buf, dist_tmp_buf)

func distance_to_coast_from_land_mask(
		w: int,
		h: int,
		land_mask: PackedByteArray,
		wrap_x: bool,
		dist_out_buf: RID,
		dist_tmp_buf: RID,
		buffer_manager: Object = null
	) -> bool:
	if w <= 0 or h <= 0:
		return false
	var size: int = w * h
	if land_mask.size() != size:
		push_error("DistanceTransformCompute: land mask size mismatch.")
		return false
	var bm: Object = buffer_manager
	if bm == null:
		if _buf_mgr == null:
			_buf_mgr = GPUBufferManager.new()
		bm = _buf_mgr
	var u32_land := PackedInt32Array()
	u32_land.resize(size)
	for i in range(size):
		u32_land[i] = 1 if land_mask[i] != 0 else 0
	var land_buf: RID = bm.ensure_buffer("dt_land_mask", size * 4, u32_land.to_byte_array())
	if not land_buf.is_valid():
		return false
	return distance_to_coast_gpu_buffers(w, h, land_buf, wrap_x, dist_out_buf, dist_tmp_buf)

func cleanup() -> void:
	if _buf_mgr != null:
		_buf_mgr.cleanup()
	ComputeShaderBase.free_rids(_rd, [_pipeline, _shader])
	_pipeline = RID()
	_shader = RID()
