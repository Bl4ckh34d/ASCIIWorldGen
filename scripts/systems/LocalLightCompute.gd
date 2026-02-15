# File: res://scripts/systems/LocalLightCompute.gd
extends RefCounted

# Computes a local-view light field on the GPU (day/night + hillshade) using fixed lon/lat.

var LOCAL_LIGHT_SHADER_FILE: RDShaderFile = load("res://shaders/local_light.glsl")

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

func _ensure_pipeline() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		var spirv := _get_spirv(LOCAL_LIGHT_SHADER_FILE)
		if spirv != null:
			_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func evaluate_light_field_gpu(w: int, h: int, params: Dictionary, height_buf: RID, out_buf: RID) -> bool:
	_ensure_pipeline()
	if not _pipeline.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	if not height_buf.is_valid() or not out_buf.is_valid():
		return false

	var uniforms: Array = []
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(out_buf)
	uniforms.append(u0)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(height_buf)
	uniforms.append(u1)
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([
		float(params.get("day_of_year", 0.0)),
		float(params.get("time_of_day", 0.0)),
		float(params.get("base", 0.008)),
		float(params.get("contrast", 0.992)),
		float(params.get("fixed_lon", 0.0)),
		float(params.get("fixed_phi", 0.0)),
		float(params.get("sim_days", 0.0)),
		float(params.get("relief_strength", 0.12)),
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
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(uniform_set)
	return true

func cleanup() -> void:
	if _rd != null:
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()
	_rd = null
