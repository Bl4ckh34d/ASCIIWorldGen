extends RefCounted

# File: res://scripts/systems/PourPointReduceCompute.gd
# GPU marks boundary candidate cells per lake; CPU then samples minimal cost per lake efficiently.

var MARK_SHADER_FILE: RDShaderFile = load("res://shaders/lake_mark_boundary_candidates.glsl")

var _rd: RenderingDevice
var _mark_shader: RID
var _mark_pipeline: RID

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null:
		return null
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		return null
	var chosen = versions[0]
	for v in versions:
		if String(v) == "vulkan":
			chosen = v
			break
	return file.get_spirv(chosen)

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _mark_shader.is_valid():
		var s := _get_spirv(MARK_SHADER_FILE)
		if s == null:
			return
		_mark_shader = _rd.shader_create_from_spirv(s)
	if not _mark_pipeline.is_valid() and _mark_shader.is_valid():
		_mark_pipeline = _rd.compute_pipeline_create(_mark_shader)

func mark_candidates(w: int, h: int, lake_mask: PackedByteArray, is_land: PackedByteArray, wrap_x: bool) -> PackedInt32Array:
	_ensure()
	if not _mark_pipeline.is_valid():
		return PackedInt32Array()
	var size: int = max(0, w * h)
	if size == 0:
		return PackedInt32Array()
	# Build u32 buffers for lake mask and land
	var lake_u32 := PackedInt32Array(); lake_u32.resize(size)
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	for i in range(size):
		lake_u32[i] = 1 if (i < lake_mask.size() and lake_mask[i] != 0) else 0
		land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	var buf_lake := _rd.storage_buffer_create(lake_u32.to_byte_array().size(), lake_u32.to_byte_array())
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var out_u32 := PackedInt32Array(); out_u32.resize(size)
	for i2 in range(size): out_u32[i2] = 0
	var buf_out := _rd.storage_buffer_create(out_u32.to_byte_array().size(), out_u32.to_byte_array())
	# Uniforms and push constants
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_lake); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_out); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _mark_shader, 0)
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h, (1 if wrap_x else 0)])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _mark_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	var out_bytes := _rd.buffer_get_data(buf_out)
	var marked := out_bytes.to_int32_array()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_lake)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_out)
	return marked


