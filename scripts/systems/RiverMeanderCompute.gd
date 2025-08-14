# File: res://scripts/systems/RiverMeanderCompute.gd
extends RefCounted

var MEANDER_SHADER: RDShaderFile = load("res://shaders/river_meander.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null: return null
	var versions: Array = file.get_version_list()
	if versions.is_empty(): return null
	var chosen_version = versions[0]
	for v in versions:
		if String(v) == "vulkan": chosen_version = v; break
	return file.get_spirv(chosen_version)

func _ensure() -> void:
	if _rd == null: _rd = RenderingServer.create_local_rendering_device()
	if not _shader.is_valid():
		var s: RDShaderSPIRV = _get_spirv(MEANDER_SHADER)
		if s == null: return
		_shader = _rd.shader_create_from_spirv(s)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func step(w: int, h: int, flow_dir: PackedInt32Array, flow_accum: PackedFloat32Array, river_in: PackedByteArray, dt_days: float, lateral_rate: float, noise_amp: float, phase: float) -> PackedByteArray:
	_ensure()
	if not _pipeline.is_valid(): return PackedByteArray()
	var size: int = max(0, w * h)
	if flow_dir.size() != size or flow_accum.size() != size or river_in.size() != size:
		return PackedByteArray()
	# River masks as int buffer for compute
	var river_u := PackedInt32Array(); river_u.resize(size)
	for i in range(size): river_u[i] = (1 if river_in[i] != 0 else 0)
	var buf_fd := _rd.storage_buffer_create(flow_dir.to_byte_array().size(), flow_dir.to_byte_array())
	var buf_fa := _rd.storage_buffer_create(flow_accum.to_byte_array().size(), flow_accum.to_byte_array())
	var buf_in := _rd.storage_buffer_create(river_u.to_byte_array().size(), river_u.to_byte_array())
	var out := PackedInt32Array(); out.resize(size)
	var buf_out := _rd.storage_buffer_create(out.to_byte_array().size(), out.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_fd); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_fa); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_in); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_out); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([dt_days, lateral_rate, noise_amp, fposmod(phase, 1.0)])
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
	var out_bytes := _rd.buffer_get_data(buf_out)
	var out_u: PackedInt32Array = out_bytes.to_int32_array()
	var out_mask := PackedByteArray(); out_mask.resize(size)
	for k in range(size): out_mask[k] = (1 if out_u[k] != 0 else 0)
	_rd.free_rid(u_set)
	_rd.free_rid(buf_fd)
	_rd.free_rid(buf_fa)
	_rd.free_rid(buf_in)
	_rd.free_rid(buf_out)
	return out_mask


