# File: res://scripts/systems/CloudNoiseCompute.gd
extends RefCounted

# Generates a simple moving cloud coverage field on the GPU into a float buffer.

var CLOUD_NOISE_SHADER_FILE: RDShaderFile = load("res://shaders/cloud_noise.glsl")

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
		var spirv := _get_spirv(CLOUD_NOISE_SHADER_FILE)
		if spirv != null:
			_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func generate_clouds_gpu(w: int, h: int, params: Dictionary, out_buf: RID) -> bool:
	_ensure_pipeline()
	if not _pipeline.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	if not out_buf.is_valid():
		return false

	var uniforms: Array = []
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(out_buf)
	uniforms.append(u0)
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([
		w,
		h,
		int(params.get("origin_x", 0)),
		int(params.get("origin_y", 0)),
		int(params.get("world_period_x", w)),
		int(params.get("world_height", h)),
		int(params.get("seed", 0)),
		0,
	])
	var floats := PackedFloat32Array([
		float(params.get("sim_days", 0.0)),
		float(params.get("scale", 0.020)),
		float(params.get("wind_x", 0.15)),
		float(params.get("wind_y", 0.05)),
		float(params.get("coverage", 0.55)),
		float(params.get("contrast", 1.35)),
		float(params.get("overcast_floor", 0.0)),
		float(params.get("morph_strength", 0.22)),
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())

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
