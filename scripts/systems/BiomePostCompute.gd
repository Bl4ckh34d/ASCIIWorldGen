# File: res://scripts/systems/BiomePostCompute.gd
extends RefCounted

## GPU version of BiomePost.apply_overrides_and_lava

var _rd: RenderingDevice
var _shader_file: RDShaderFile = load("res://shaders/biome_overrides_lava.glsl")
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
	if not _shader.is_valid() and _shader_file != null:
		var s: RDShaderSPIRV = _get_spirv(_shader_file)
		if s != null:
			_shader = _rd.shader_create_from_spirv(s)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func apply_overrides_and_lava_gpu(
		w: int, h: int,
		land_buf: RID,
		temp_buf: RID,
		moist_buf: RID,
		biome_in_buf: RID,
		lake_buf: RID,
		rock_buf: RID,
		out_biome_buf: RID,
		out_lava_buf: RID,
		temp_min_c: float,
		temp_max_c: float,
		lava_temp_threshold_c: float,
		update_lava: float = 1.0) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	if not land_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid() or not biome_in_buf.is_valid() or not out_biome_buf.is_valid() or not out_lava_buf.is_valid() or not lake_buf.is_valid() or not rock_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(biome_in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(out_biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(out_lava_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(lake_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 7; u.add_id(rock_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([temp_min_c, temp_max_c, lava_temp_threshold_c, update_lava])
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
	_rd.free_rid(u_set)
	return true
