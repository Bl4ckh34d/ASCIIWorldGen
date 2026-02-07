# File: res://scripts/systems/RiverPostCompute.gd
extends RefCounted

var DELTA_SHADER_FILE: RDShaderFile = load("res://shaders/river_delta.glsl")

var _rd: RenderingDevice
var _delta_shader: RID
var _delta_pipeline: RID
var _broken: bool = false

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
	if not _delta_shader.is_valid() and not _broken:
		var s: RDShaderSPIRV = _get_spirv(DELTA_SHADER_FILE)
		if s == null:
			_broken = true
			return
		var sh := _rd.shader_create_from_spirv(s)
		if sh.is_valid():
			_delta_shader = sh
		else:
			_broken = true
	if not _delta_pipeline.is_valid() and _delta_shader.is_valid():
		_delta_pipeline = _rd.compute_pipeline_create(_delta_shader)

func widen_deltas_gpu_buffers(
		w: int,
		h: int,
		river_in_buf: RID,
		land_buf: RID,
		dist_buf: RID,
		flow_accum_buf: RID,
		max_shore_dist: float,
		min_source_accum: float,
		river_out_buf: RID
	) -> bool:
	_ensure()
	if not _delta_pipeline.is_valid() or _broken:
		return false
	if not river_in_buf.is_valid() or not land_buf.is_valid() or not dist_buf.is_valid() or not flow_accum_buf.is_valid() or not river_out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(river_in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(dist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(flow_accum_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(river_out_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _delta_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([max_shore_dist, min_source_accum])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _delta_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true
