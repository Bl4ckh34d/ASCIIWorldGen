# File: res://scripts/systems/TerrainCompute.gd
extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const ComputeShaderBase = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")

const TERRAIN_SHADER_PATH: String = "res://shaders/terrain_gen.glsl"
const FBM_SHADER_PATH: String = "res://shaders/noise_fbm.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipeline: RID = RID()
var _fbm_shader: RID = RID()
var _fbm_pipeline: RID = RID()
var _buf_mgr: GPUBufferManager = null
var _buf_size: int = 0
var _buf_fbm: RID = RID()
var _buf_cont: RID = RID()
var _buf_warp_x: RID = RID()
var _buf_warp_y: RID = RID()

func _init() -> void:
	_buf_mgr = GPUBufferManager.new()

func _ensure() -> bool:
	var terrain_state: Dictionary = ComputeShaderBase.ensure_rd_and_pipeline(
		_rd,
		_shader,
		_pipeline,
		TERRAIN_SHADER_PATH,
		"terrain_gen"
	)
	_rd = terrain_state.get("rd", null)
	_shader = terrain_state.get("shader", RID())
	_pipeline = terrain_state.get("pipeline", RID())
	if not VariantCasts.to_bool(terrain_state.get("ok", false)):
		return false

	var fbm_state: Dictionary = ComputeShaderBase.ensure_rd_and_pipeline(
		_rd,
		_fbm_shader,
		_fbm_pipeline,
		FBM_SHADER_PATH,
		"noise_fbm"
	)
	_fbm_shader = fbm_state.get("shader", RID())
	_fbm_pipeline = fbm_state.get("pipeline", RID())
	return VariantCasts.to_bool(fbm_state.get("ok", false))

func _ensure_intermediate_buffers(size: int) -> bool:
	if size <= 0:
		return false
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	if _buf_size == size and _buf_fbm.is_valid() and _buf_cont.is_valid() and _buf_warp_x.is_valid() and _buf_warp_y.is_valid():
		return true
	_buf_size = size
	var bytes_size: int = size * 4
	_buf_fbm = _buf_mgr.ensure_buffer("terrain_fbm", bytes_size)
	_buf_cont = _buf_mgr.ensure_buffer("terrain_cont", bytes_size)
	_buf_warp_x = _buf_mgr.ensure_buffer("terrain_warp_x", bytes_size)
	_buf_warp_y = _buf_mgr.ensure_buffer("terrain_warp_y", bytes_size)
	return _buf_fbm.is_valid() and _buf_cont.is_valid() and _buf_warp_x.is_valid() and _buf_warp_y.is_valid()

func _dispatch_noise_fbm(w: int, h: int, params: Dictionary, wrap_x: bool) -> bool:
	var uniforms_n: Array = []
	var un: RDUniform
	un = RDUniform.new(); un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; un.binding = 0; un.add_id(_buf_fbm); uniforms_n.append(un)
	un = RDUniform.new(); un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; un.binding = 1; un.add_id(_buf_cont); uniforms_n.append(un)
	un = RDUniform.new(); un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; un.binding = 2; un.add_id(_buf_warp_x); uniforms_n.append(un)
	un = RDUniform.new(); un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; un.binding = 3; un.add_id(_buf_warp_y); uniforms_n.append(un)
	var u_set_n: RID = _rd.uniform_set_create(uniforms_n, _fbm_shader, 0)

	var pc_n := PackedByteArray()
	var ints_n := PackedInt32Array([
		w,
		h,
		(1 if wrap_x else 0),
		int(params.get("seed", 0)),
	])
	var base_freq: float = float(params.get("frequency", 0.02))
	var floats_n := PackedFloat32Array([
		base_freq,
		max(0.002, base_freq * 0.4),
		float(params.get("noise_x_scale", 1.0)),
		float(params.get("warp", 24.0)),
		float(params.get("lacunarity", 2.0)),
		float(params.get("gain", 0.5)),
	])
	var ints_n_tail := PackedInt32Array([int(params.get("octaves", 5))])
	pc_n.append_array(ints_n.to_byte_array())
	pc_n.append_array(floats_n.to_byte_array())
	pc_n.append_array(ints_n_tail.to_byte_array())
	var pad_n: int = (16 - (pc_n.size() % 16)) % 16
	if pad_n > 0:
		var zeros_n := PackedByteArray()
		zeros_n.resize(pad_n)
		pc_n.append_array(zeros_n)
	if not ComputeShaderBase.validate_push_constant_size(pc_n, 48, "TerrainCompute.noise_fbm"):
		_rd.free_rid(u_set_n)
		return false

	var gx_n: int = int(ceil(float(w) / 16.0))
	var gy_n: int = int(ceil(float(h) / 16.0))
	var cl_n := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_n, _fbm_pipeline)
	_rd.compute_list_bind_uniform_set(cl_n, u_set_n, 0)
	_rd.compute_list_set_push_constant(cl_n, pc_n, pc_n.size())
	_rd.compute_list_dispatch(cl_n, gx_n, gy_n, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set_n)
	return true

func _dispatch_terrain(w: int, h: int, sea_level: float, noise_x_scale: float, warp_amount: float, wrap_x: bool, out_height_buf: RID, out_land_buf: RID) -> bool:
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(_buf_warp_x); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(_buf_warp_y); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(_buf_fbm); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(_buf_cont); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(out_height_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(out_land_buf); uniforms.append(u)
	var u_set: RID = _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if wrap_x else 0)])
	var floats := PackedFloat32Array([sea_level, noise_x_scale, warp_amount])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad: int = (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBase.validate_push_constant_size(pc, 32, "TerrainCompute.terrain"):
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

func generate_to_buffers(
		w: int,
		h: int,
		params: Dictionary,
		out_height_buf: RID,
		out_land_buf: RID
	) -> bool:
	if not _ensure():
		return false
	if not _shader.is_valid() or not _pipeline.is_valid() or not _fbm_shader.is_valid() or not _fbm_pipeline.is_valid():
		return false

	var size: int = max(0, w * h)
	if size == 0:
		return false
	if not out_height_buf.is_valid() or not out_land_buf.is_valid():
		return false
	if not _ensure_intermediate_buffers(size):
		return false

	var sea_level: float = float(params.get("sea_level", 0.0))
	var wrap_x: bool = VariantCasts.to_bool(params.get("wrap_x", true))
	var noise_x_scale: float = float(params.get("noise_x_scale", 1.0))
	var warp_amount: float = float(params.get("warp", 24.0))

	if not _dispatch_noise_fbm(w, h, params, wrap_x):
		return false
	return _dispatch_terrain(w, h, sea_level, noise_x_scale, warp_amount, wrap_x, out_height_buf, out_land_buf)

func generate(_w: int, _h: int, _params: Dictionary) -> Dictionary:
	push_error("TerrainCompute.generate() is disabled in GPU-only mode; use generate_to_buffers().")
	return {}

func cleanup() -> void:
	if _buf_mgr != null:
		_buf_mgr.cleanup()
	ComputeShaderBase.free_rids(_rd, [
		_pipeline,
		_shader,
		_fbm_pipeline,
		_fbm_shader,
	])
	_pipeline = RID()
	_shader = RID()
	_fbm_pipeline = RID()
	_fbm_shader = RID()
	_buf_fbm = RID()
	_buf_cont = RID()
	_buf_warp_x = RID()
	_buf_warp_y = RID()
	_buf_size = 0
