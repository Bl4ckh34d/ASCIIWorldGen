# File: res://scripts/systems/RainErosionCompute.gd
extends RefCounted

var EROSION_SHADER_FILE: RDShaderFile = load("res://shaders/rain_erosion.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

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
		var spirv: RDShaderSPIRV = _get_spirv(EROSION_SHADER_FILE)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func apply_gpu_buffers(
	w: int,
	h: int,
	height_in_buf: RID,
	moisture_buf: RID,
	flow_accum_buf: RID,
	land_buf: RID,
	lake_buf: RID,
	lava_buf: RID,
	biome_buf: RID,
	rock_buf: RID,
	dt_days: float,
	sea_level: float,
	base_rate_per_day: float,
	max_rate_per_day: float,
	noise_phase: float,
	glacier_smoothing_bias: float,
	cryo_rate_scale: float,
	cryo_cap_scale: float,
	biome_ice_sheet_id: int,
	biome_glacier_id: int,
	biome_desert_ice_id: int,
	height_out_buf: RID
) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if not height_in_buf.is_valid() or not moisture_buf.is_valid() or not flow_accum_buf.is_valid():
		return false
	if not land_buf.is_valid() or not lake_buf.is_valid() or not lava_buf.is_valid() or not biome_buf.is_valid():
		return false
	if not rock_buf.is_valid():
		return false
	if not height_out_buf.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false

	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(height_in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(moisture_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(flow_accum_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(lake_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(lava_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 7; u.add_id(height_out_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 8; u.add_id(rock_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, biome_ice_sheet_id, biome_glacier_id, biome_desert_ice_id, 0, 0, 0])
	var floats := PackedFloat32Array([
		dt_days,
		sea_level,
		base_rate_per_day,
		max_rate_per_day,
		noise_phase,
		clamp(glacier_smoothing_bias, 0.0, 1.0),
		max(0.1, cryo_rate_scale),
		max(0.1, cryo_cap_scale)
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
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
	return true
