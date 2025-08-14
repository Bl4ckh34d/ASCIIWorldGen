# File: res://scripts/systems/DistanceTransformCompute.gd
extends RefCounted

const DT_SHADER := preload("res://shaders/distance_transform.glsl")

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
		_rd = RenderingServer.create_local_rendering_device()
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(DT_SHADER)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func ocean_distance_to_land(w: int, h: int, is_land: PackedByteArray, wrap_x: bool) -> PackedFloat32Array:
	_ensure()
	if not _shader.is_valid() or not _pipeline.is_valid():
		return PackedFloat32Array()
	var size: int = max(0, w * h)
	var dist_a := PackedFloat32Array()
	dist_a.resize(size)
	var dist_b := PackedFloat32Array()
	dist_b.resize(size)
	for i in range(size):
		dist_a[i] = 0.0 if (i < is_land.size() and is_land[i] != 0) else 1e9
		dist_b[i] = dist_a[i]
	# Convert land mask to u32 to match GLSL uint[]
	var land_u32 := PackedInt32Array()
	land_u32.resize(size)
	for j in range(size):
		land_u32[j] = 1 if (j < is_land.size() and is_land[j] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var buf_in := _rd.storage_buffer_create(dist_a.to_byte_array().size(), dist_a.to_byte_array())
	var buf_out := _rd.storage_buffer_create(dist_b.to_byte_array().size(), dist_b.to_byte_array())

	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buf_land)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 1
	u.add_id(buf_in)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 2
	u.add_id(buf_out)
	uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if wrap_x else 0), 0])
	pc.append_array(ints.to_byte_array())
	# Align to 16 bytes
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))

	# forward pass
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()

	# swap buffers for backward pass
	_rd.free_rid(u_set)
	_rd.free_rid(buf_in)
	# make input = out, out = new buffer
	buf_in = buf_out
	buf_out = _rd.storage_buffer_create(dist_a.to_byte_array().size(), dist_a.to_byte_array())
	uniforms.clear()
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buf_land)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 1
	u.add_id(buf_in)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 2
	u.add_id(buf_out)
	uniforms.append(u)
	u_set = _rd.uniform_set_create(uniforms, _shader, 0)
	pc = PackedByteArray()
	ints = PackedInt32Array([w, h, (1 if wrap_x else 0), 1])
	pc.append_array(ints.to_byte_array())
	# Align to 16 bytes
	var pad2 := (16 - (pc.size() % 16)) % 16
	if pad2 > 0:
		var zeros2 := PackedByteArray(); zeros2.resize(pad2)
		pc.append_array(zeros2)
	cl = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()

	var out_bytes := _rd.buffer_get_data(buf_out)
	var out_dist: PackedFloat32Array = out_bytes.to_float32_array()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_in)
	_rd.free_rid(buf_out)
	return out_dist
