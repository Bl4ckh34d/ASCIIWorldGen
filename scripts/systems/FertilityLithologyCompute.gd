# File: res://scripts/systems/FertilityLithologyCompute.gd
extends RefCounted

const FERTILITY_SHADER_FILE: RDShaderFile = preload("res://shaders/fertility_lithology_update.glsl")
const FERTILITY_SEED_SHADER_FILE: RDShaderFile = preload("res://shaders/fertility_seed_from_lithology.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _seed_shader: RID
var _seed_pipeline: RID

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
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(FERTILITY_SHADER_FILE)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	if not _seed_shader.is_valid():
		var seed_spirv: RDShaderSPIRV = _get_spirv(FERTILITY_SEED_SHADER_FILE)
		if seed_spirv != null:
			_seed_shader = _rd.shader_create_from_spirv(seed_spirv)
	if not _seed_pipeline.is_valid() and _seed_shader.is_valid():
		_seed_pipeline = _rd.compute_pipeline_create(_seed_shader)

func update_gpu_buffers(
		w: int,
		h: int,
		rock_buf: RID,
		rock_candidate_buf: RID,
		biome_buf: RID,
		land_buf: RID,
		moisture_buf: RID,
		flow_buf: RID,
		lava_buf: RID,
		fertility_buf: RID,
		dt_days: float,
		weathering_rate: float = 0.08,
		humus_rate: float = 0.05,
		flow_scale: float = 64.0
	) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not rock_buf.is_valid() or not rock_candidate_buf.is_valid():
		return false
	if not biome_buf.is_valid() or not land_buf.is_valid():
		return false
	if not moisture_buf.is_valid() or not flow_buf.is_valid():
		return false
	if not lava_buf.is_valid() or not fertility_buf.is_valid():
		return false

	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(rock_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(rock_candidate_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(moisture_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(flow_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(lava_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 7; u.add_id(fertility_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([
		clamp(dt_days, 0.0, 12.0),
		max(0.0001, weathering_rate),
		max(0.0001, humus_rate),
		max(1.0, flow_scale),
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
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func seed_from_lithology_gpu_buffers(
		w: int,
		h: int,
		rock_buf: RID,
		land_buf: RID,
		moisture_buf: RID,
		lava_buf: RID,
		fertility_buf: RID,
		reset_existing: bool
	) -> bool:
	_ensure()
	if not _seed_pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not rock_buf.is_valid() or not land_buf.is_valid():
		return false
	if not moisture_buf.is_valid() or not lava_buf.is_valid() or not fertility_buf.is_valid():
		return false

	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(rock_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(moisture_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(lava_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(fertility_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _seed_shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([
		w,
		h,
		(1 if reset_existing else 0),
		0,
	])
	var floats := PackedFloat32Array([
		0.25, # blend when not resetting
		0.20,
		0.0,
		0.0,
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
	_rd.compute_list_bind_compute_pipeline(cl, _seed_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true
