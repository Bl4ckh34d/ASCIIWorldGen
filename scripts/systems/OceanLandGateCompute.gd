extends RefCounted

# Reconciles land/ocean mask with inland lake mask:
# - Inland water (lake=1) is treated as land in is_land.
# - Optionally clears lake/lake_id outputs when lakes are disabled.

var _shader_file: RDShaderFile = load("res://shaders/ocean_land_gate.glsl")
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null:
		return null
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		return null
	var chosen: Variant = null
	for v in versions:
		if v == null:
			continue
		if chosen == null:
			chosen = v
		if String(v) == "vulkan":
			chosen = v
			break
	if chosen == null:
		return null
	return file.get_spirv(chosen)

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	if not _shader.is_valid():
		var s: RDShaderSPIRV = _get_spirv(_shader_file)
		if s != null:
			_shader = _rd.shader_create_from_spirv(s)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func apply(
		w: int,
		h: int,
		land_buf: RID,
		lake_buf: RID,
		lake_id_buf: RID,
		keep_lakes: bool
	) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not land_buf.is_valid() or not lake_buf.is_valid() or not lake_id_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(lake_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(lake_id_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if keep_lakes else 0), 0])
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

func cleanup() -> void:
	if _rd != null:
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()
