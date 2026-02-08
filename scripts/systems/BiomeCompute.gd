# File: res://scripts/systems/BiomeCompute.gd
extends RefCounted

var BIOME_SHADER_FILE: RDShaderFile = load("res://shaders/biome_classify.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _smooth_shader_file: RDShaderFile = load("res://shaders/biome_smooth.glsl")
var _smooth_shader: RID
var _smooth_pipeline: RID
var _reapply_shader_file: RDShaderFile = load("res://shaders/biome_reapply.glsl")
var _reapply_shader: RID
var _reapply_pipeline: RID

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null:
		push_error("BiomeCompute: Shader file is null")
		return null
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		push_error("BiomeCompute: No shader versions available")
		return null
	var chosen_version = versions[0]
	for v in versions:
		if String(v) == "vulkan":
			chosen_version = v
			break
	if chosen_version == null:
		push_error("BiomeCompute: No non-null shader version available")
		return null
	var spirv = file.get_spirv(chosen_version)
	if spirv == null:
		push_error("BiomeCompute: Failed to get SPIRV for version: " + str(chosen_version))
	return spirv

func _ensure() -> void:
	# GPU device initialization with error handling
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
		if _rd == null:
			push_error("BiomeCompute: RenderingDevice unavailable - GPU compute not supported")
			return
	
	# Main biome shader initialization
	if not _shader.is_valid():
		var s: RDShaderSPIRV = _get_spirv(BIOME_SHADER_FILE)
		if s == null:
			push_error("BiomeCompute: Failed to load biome shader - falling back to CPU")
			return
		_shader = _rd.shader_create_from_spirv(s)
		if not _shader.is_valid():
			push_error("BiomeCompute: Failed to create biome shader from SPIRV")
			return
	
	# Pipeline creation
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
		if not _pipeline.is_valid():
			push_error("BiomeCompute: Failed to create compute pipeline")
			return
	
	# Smooth shader initialization (optional)
	if not _smooth_shader.is_valid():
		var s2: RDShaderSPIRV = _get_spirv(_smooth_shader_file)
		if s2 != null:
			_smooth_shader = _rd.shader_create_from_spirv(s2)
			if not _smooth_shader.is_valid():
				push_warning("BiomeCompute: Failed to create smooth shader - smoothing disabled")
	
	if not _smooth_pipeline.is_valid() and _smooth_shader.is_valid():
		_smooth_pipeline = _rd.compute_pipeline_create(_smooth_shader)
		if not _smooth_pipeline.is_valid():
			push_warning("BiomeCompute: Failed to create smooth pipeline - smoothing disabled")
	if not _reapply_shader.is_valid():
		var s3: RDShaderSPIRV = _get_spirv(_reapply_shader_file)
		if s3 != null:
			_reapply_shader = _rd.shader_create_from_spirv(s3)
	if not _reapply_pipeline.is_valid() and _reapply_shader.is_valid():
		_reapply_pipeline = _rd.compute_pipeline_create(_reapply_shader)

func is_gpu_available() -> bool:
	"""Check if GPU compute is available and functional"""
	_ensure()
	return _rd != null and _shader.is_valid() and _pipeline.is_valid()

func classify_to_buffer(w: int, h: int,
		height_buf: RID,
		land_buf: RID,
		temp_buf: RID,
		moist_buf: RID,
		beach_buf: RID,
		desert_buf: RID,
		fertility_buf: RID,
		params: Dictionary,
		out_biome_buf: RID,
		biome_noise_buf: RID = RID()) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if not height_buf.is_valid() or not land_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid() or not beach_buf.is_valid() or not out_biome_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	var use_desert: bool = desert_buf.is_valid()
	var desert_buf_use: RID = desert_buf
	if not use_desert:
		var dummy_f := PackedFloat32Array(); dummy_f.resize(1)
		desert_buf_use = _rd.storage_buffer_create(dummy_f.to_byte_array().size(), dummy_f.to_byte_array())
	var use_fertility: bool = fertility_buf.is_valid()
	var fertility_buf_use: RID = fertility_buf
	if not use_fertility:
		var fert_default := PackedFloat32Array()
		fert_default.resize(size)
		fert_default.fill(0.5)
		fertility_buf_use = _rd.storage_buffer_create(fert_default.to_byte_array().size(), fert_default.to_byte_array())
	var use_biome_noise: bool = biome_noise_buf.is_valid()
	var biome_noise_buf_use: RID = biome_noise_buf
	if not use_biome_noise:
		var noise_default := PackedFloat32Array()
		noise_default.resize(1)
		noise_default[0] = 0.5
		biome_noise_buf_use = _rd.storage_buffer_create(noise_default.to_byte_array().size(), noise_default.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(height_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(beach_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(desert_buf_use); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(out_biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 7; u.add_id(fertility_buf_use); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 8; u.add_id(biome_noise_buf_use); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var freeze_norm: float = float(params.get("freeze_temp_threshold", 0.16))
	var noise_c: float = float(params.get("biome_noise_strength_c", 0.8))
	var moist_jitter: float = float(params.get("biome_moist_jitter", 0.06))
	var phase: float = float(params.get("biome_phase", 0.0))
	var floats := PackedFloat32Array([
		float(params.get("temp_min_c", -40.0)),
		float(params.get("temp_max_c", 70.0)),
		float(params.get("height_scale_m", 6000.0)),
		float(params.get("lapse_c_per_km", 5.5)),
		freeze_norm,
		noise_c,
		moist_jitter,
		phase,
		float(params.get("biome_moist_jitter2", 0.03)),
		float(params.get("biome_moist_islands", 0.35)),
		float(params.get("biome_moist_elev_dry", 0.35)),
	])
	# min/max from params if supplied; else compute from CPU height not available in GPU-only path
	var min_h: float = float(params.get("min_h", 0.0))
	var max_h: float = float(params.get("max_h", 1.0))
	var floats2 := PackedFloat32Array([min_h, max_h])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	pc.append_array(floats2.to_byte_array())
	var tail := PackedInt32Array([ (1 if use_desert else 0), (1 if use_biome_noise else 0) ])
	pc.append_array(tail.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	if not use_desert:
		_rd.free_rid(desert_buf_use)
	if not use_fertility:
		_rd.free_rid(fertility_buf_use)
	if not use_biome_noise:
		_rd.free_rid(biome_noise_buf_use)
	return true

func reapply_cryosphere_to_buffer(
		w: int,
		h: int,
		biome_in_buf: RID,
		biome_out_buf: RID,
		land_buf: RID,
		height_buf: RID,
		temp_buf: RID,
		moist_buf: RID,
		temp_min_c: float,
		temp_max_c: float,
		height_scale_m: float = 6000.0,
		lapse_c_per_km: float = 5.5,
		ocean_ice_base_thresh_c: float = -7.0,
		ocean_ice_wiggle_amp_c: float = 2.2
	) -> bool:
	_ensure()
	if not _reapply_pipeline.is_valid():
		return false
	if not biome_in_buf.is_valid() or not biome_out_buf.is_valid():
		return false
	if not land_buf.is_valid() or not height_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	var ice_field := PackedFloat32Array()
	ice_field.resize(size)
	ice_field.fill(0.0)
	var buf_ice := _rd.storage_buffer_create(ice_field.to_byte_array().size(), ice_field.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(biome_in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(biome_out_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(height_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(buf_ice); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _reapply_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([
		temp_min_c,
		temp_max_c,
		height_scale_m,
		lapse_c_per_km,
		ocean_ice_base_thresh_c,
		ocean_ice_wiggle_amp_c,
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _reapply_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_ice)
	return true

