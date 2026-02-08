# File: res://scripts/systems/CloudOverlayCompute.gd
extends RefCounted

var CLOUD_SHADER_FILE: RDShaderFile = load("res://shaders/cloud_overlay.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null:
		return null
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		return null
	var chosen_version: Variant = null
	for v in versions:
		if v == null:
			continue
		if chosen_version == null:
			chosen_version = v
		if String(v) == "vulkan":
			chosen_version = v
			break
	if chosen_version == null:
		return null
	return file.get_spirv(chosen_version)

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		var s: RDShaderSPIRV = _get_spirv(CLOUD_SHADER_FILE)
		if s != null:
			_shader = _rd.shader_create_from_spirv(s)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func compute_clouds_to_buffer(
		w: int,
		h: int,
		temp_buf: RID,
		moist_buf: RID,
		land_buf: RID,
		light_buf: RID,
		biome_buf: RID,
		height_buf: RID,
			wind_u_buf: RID,
			wind_v_buf: RID,
			phase: float,
			rng_seed: int,
			out_buf: RID
		) -> bool:
	"""GPU-only: write clouds into an existing buffer (no readback)."""
	_ensure()
	if not _pipeline.is_valid():
		return false
	if not temp_buf.is_valid() or not moist_buf.is_valid() or not land_buf.is_valid() or not light_buf.is_valid() or not biome_buf.is_valid() or not height_buf.is_valid() or not wind_u_buf.is_valid() or not wind_v_buf.is_valid() or not out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(light_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(height_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(wind_u_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 7; u.add_id(wind_v_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 8; u.add_id(out_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, rng_seed])
	var floats := PackedFloat32Array([phase])
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
