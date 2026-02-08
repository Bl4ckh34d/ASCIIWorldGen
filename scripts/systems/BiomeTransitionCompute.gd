extends RefCounted

# GPU temporal transition for biome IDs.
# Blends from old -> new biome buffers with deterministic per-cell adoption.

var _rd: RenderingDevice
var _shader_file: RDShaderFile = load("res://shaders/biome_transition.glsl")
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

func blend_to_buffer(
		w: int,
		h: int,
		old_biome_buf: RID,
		new_biome_buf: RID,
			out_biome_buf: RID,
			step_general: float,
			step_cryosphere: float,
			rng_seed: int,
			epoch: int
		) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not old_biome_buf.is_valid() or not new_biome_buf.is_valid() or not out_biome_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(old_biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(new_biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(out_biome_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, rng_seed, epoch])
	var floats := PackedFloat32Array([
		clamp(step_general, 0.0, 1.0),
		clamp(step_cryosphere, 0.0, 1.0),
		0.0,
		0.0
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
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true
