extends RefCounted

# File: res://scripts/systems/LakeLabelFromMaskCompute.gd
# Labels lakes from a provided LakeMask (1 = lake) using GPU propagate similar to legacy

var PROPAGATE_SHADER_FILE: RDShaderFile = load("res://shaders/lake_label_from_mask.glsl")
var SEED_SHADER_FILE: RDShaderFile = load("res://shaders/lake_label_seed_from_mask.glsl")
var CLEAR_U32_SHADER_FILE: RDShaderFile = load("res://shaders/clear_u32.glsl")

var _rd: RenderingDevice
var _prop_shader: RID
var _prop_pipeline: RID
var _seed_shader: RID
var _seed_pipeline: RID
var _clear_shader: RID
var _clear_pipeline: RID

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
	if not _prop_shader.is_valid():
		var s := _get_spirv(PROPAGATE_SHADER_FILE)
		if s == null:
			return
		_prop_shader = _rd.shader_create_from_spirv(s)
	if not _prop_pipeline.is_valid() and _prop_shader.is_valid():
		_prop_pipeline = _rd.compute_pipeline_create(_prop_shader)
	if not _seed_shader.is_valid():
		var ss := _get_spirv(SEED_SHADER_FILE)
		if ss != null:
			_seed_shader = _rd.shader_create_from_spirv(ss)
	if not _seed_pipeline.is_valid() and _seed_shader.is_valid():
		_seed_pipeline = _rd.compute_pipeline_create(_seed_shader)
	if not _clear_shader.is_valid():
		var cs := _get_spirv(CLEAR_U32_SHADER_FILE)
		if cs == null:
			return
		_clear_shader = _rd.shader_create_from_spirv(cs)
	if not _clear_pipeline.is_valid() and _clear_shader.is_valid():
		_clear_pipeline = _rd.compute_pipeline_create(_clear_shader)

func label_from_mask_gpu_buffers(
		w: int,
		h: int,
		lake_mask_buf: RID,
		wrap_x: bool,
		out_lake_id_buf: RID,
		iterations: int = 0
	) -> bool:
	_ensure()
	if not _seed_pipeline.is_valid() or not _prop_pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not lake_mask_buf.is_valid() or not out_lake_id_buf.is_valid():
		return false
	var size: int = w * h
	var changed_zero := PackedInt32Array([0])
	var buf_changed := _rd.storage_buffer_create(changed_zero.to_byte_array().size(), changed_zero.to_byte_array())
	# Seed labels as unique ids on lake pixels.
	var seed_uniforms: Array = []
	var su: RDUniform
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 0; su.add_id(lake_mask_buf); seed_uniforms.append(su)
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 1; su.add_id(out_lake_id_buf); seed_uniforms.append(su)
	var seed_set := _rd.uniform_set_create(seed_uniforms, _seed_shader, 0)
	var seed_pc := PackedByteArray()
	seed_pc.append_array(PackedInt32Array([size, 0, 0, 0]).to_byte_array())
	var seed_pad := (16 - (seed_pc.size() % 16)) % 16
	if seed_pad > 0:
		var seed_zeros := PackedByteArray()
		seed_zeros.resize(seed_pad)
		seed_pc.append_array(seed_zeros)
	var g1d: int = int(ceil(float(size) / 256.0))
	var seed_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(seed_list, _seed_pipeline)
	_rd.compute_list_bind_uniform_set(seed_list, seed_set, 0)
	_rd.compute_list_set_push_constant(seed_list, seed_pc, seed_pc.size())
	_rd.compute_list_dispatch(seed_list, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(seed_set)
	# Propagate labels in-place for a fixed iteration budget (no readback convergence).
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(lake_mask_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(out_lake_id_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_changed); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _prop_shader, 0)
	var pc := PackedByteArray()
	pc.append_array(PackedInt32Array([w, h, (1 if wrap_x else 0), 0]).to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var max_iters: int = max(1, iterations if iterations > 0 else max(w, h))
	for _it in range(max_iters):
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _prop_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		_rd.compute_list_end()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_changed)
	return true
