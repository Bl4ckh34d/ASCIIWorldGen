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
		var s: RDShaderSPIRV = _get_spirv(CLOUD_SHADER_FILE)
		if s != null:
			_shader = _rd.shader_create_from_spirv(s)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func compute_clouds(w: int, h: int, temp: PackedFloat32Array, moist: PackedFloat32Array, is_land: PackedByteArray, phase: float) -> PackedFloat32Array:
	_ensure()
	if not _pipeline.is_valid():
		return PackedFloat32Array()
	var size: int = max(0, w * h)
	var buf_t := _rd.storage_buffer_create(temp.to_byte_array().size(), temp.to_byte_array())
	var buf_m := _rd.storage_buffer_create(moist.to_byte_array().size(), moist.to_byte_array())
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	for i in range(size): land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var clouds := PackedFloat32Array(); clouds.resize(size)
	var buf_out := _rd.storage_buffer_create(clouds.to_byte_array().size(), clouds.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_t); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_m); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_out); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h]); var floats := PackedFloat32Array([phase]);
	pc.append_array(ints.to_byte_array()); pc.append_array(floats.to_byte_array())
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
	var bytes := _rd.buffer_get_data(buf_out)
	var out := bytes.to_float32_array()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_t)
	_rd.free_rid(buf_m)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_out)
	return out


