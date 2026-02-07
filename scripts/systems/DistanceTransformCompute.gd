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
	if chosen_version == null:
		return null
	return file.get_spirv(chosen_version)

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(DT_SHADER)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func _dispatch_mode(
		w: int,
		h: int,
		wrap_x: bool,
		mode: int,
		buf_land: RID,
		buf_in: RID,
		buf_out: RID
	) -> bool:
	if not _pipeline.is_valid():
		return false
	if not buf_land.is_valid() or not buf_in.is_valid() or not buf_out.is_valid():
		return false
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
	var ints := PackedInt32Array([w, h, (1 if wrap_x else 0), mode])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
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

func ocean_distance_to_land_gpu_buffers(
		w: int,
		h: int,
		land_buf: RID,
		wrap_x: bool,
		dist_out_buf: RID,
		dist_tmp_buf: RID
	) -> bool:
	_ensure()
	if not _shader.is_valid() or not _pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not land_buf.is_valid() or not dist_out_buf.is_valid() or not dist_tmp_buf.is_valid():
		return false
	# mode 2: seed distances from land mask into dist_out_buf
	if not _dispatch_mode(w, h, wrap_x, 2, land_buf, dist_tmp_buf, dist_out_buf):
		return false
	# mode 0: forward pass
	if not _dispatch_mode(w, h, wrap_x, 0, land_buf, dist_out_buf, dist_tmp_buf):
		return false
	# mode 1: backward pass
	if not _dispatch_mode(w, h, wrap_x, 1, land_buf, dist_tmp_buf, dist_out_buf):
		return false
	return true

func ocean_distance_to_land(w: int, h: int, is_land: PackedByteArray, wrap_x: bool) -> PackedFloat32Array:
	_ensure()
	if not _shader.is_valid() or not _pipeline.is_valid():
		return PackedFloat32Array()
	var size: int = max(0, w * h)
	# Convert land mask to u32 to match GLSL uint[]
	var land_u32 := PackedInt32Array()
	land_u32.resize(size)
	for j in range(size):
		land_u32[j] = 1 if (j < is_land.size() and is_land[j] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var zeros := PackedByteArray()
	zeros.resize(size * 4)
	var buf_out := _rd.storage_buffer_create(zeros.size(), zeros)
	var buf_tmp := _rd.storage_buffer_create(zeros.size(), zeros)
	var ok: bool = ocean_distance_to_land_gpu_buffers(w, h, buf_land, wrap_x, buf_out, buf_tmp)
	if not ok:
		_rd.free_rid(buf_land)
		_rd.free_rid(buf_out)
		_rd.free_rid(buf_tmp)
		return PackedFloat32Array()
	var out_bytes := _rd.buffer_get_data(buf_out)
	var out_dist: PackedFloat32Array = out_bytes.to_float32_array()
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_out)
	_rd.free_rid(buf_tmp)
	return out_dist
