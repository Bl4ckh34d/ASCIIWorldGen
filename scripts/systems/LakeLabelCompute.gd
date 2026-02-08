extends RefCounted

var PROPAGATE_SHADER_FILE: RDShaderFile = load("res://shaders/lake_label_propagate.glsl")
var MARK_BOUNDARY_SHADER_FILE: RDShaderFile = load("res://shaders/lake_mark_boundary.glsl")
var SEED_FROM_LAND_SHADER_FILE: RDShaderFile = load("res://shaders/lake_label_seed_from_land.glsl")
var APPLY_BOUNDARY_SHADER_FILE: RDShaderFile = load("res://shaders/lake_label_apply_boundary.glsl")
var CLEAR_U32_SHADER_FILE: RDShaderFile = load("res://shaders/clear_u32.glsl")

var _rd: RenderingDevice
var _prop_shader: RID
var _prop_pipeline: RID
var _mark_shader: RID
var _mark_pipeline: RID
var _seed_shader: RID
var _seed_pipeline: RID
var _apply_shader: RID
var _apply_pipeline: RID
var _clear_shader: RID
var _clear_pipeline: RID

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

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	if not _prop_shader.is_valid():
		var s: RDShaderSPIRV = _get_spirv(PROPAGATE_SHADER_FILE)
		if s == null:
			return
		_prop_shader = _rd.shader_create_from_spirv(s)
	if not _prop_pipeline.is_valid() and _prop_shader.is_valid():
		_prop_pipeline = _rd.compute_pipeline_create(_prop_shader)
	if not _mark_shader.is_valid():
		var s2: RDShaderSPIRV = _get_spirv(MARK_BOUNDARY_SHADER_FILE)
		if s2 == null:
			return
		_mark_shader = _rd.shader_create_from_spirv(s2)
	if not _mark_pipeline.is_valid() and _mark_shader.is_valid():
		_mark_pipeline = _rd.compute_pipeline_create(_mark_shader)
	if not _seed_shader.is_valid():
		var s3: RDShaderSPIRV = _get_spirv(SEED_FROM_LAND_SHADER_FILE)
		if s3 != null:
			_seed_shader = _rd.shader_create_from_spirv(s3)
	if not _seed_pipeline.is_valid() and _seed_shader.is_valid():
		_seed_pipeline = _rd.compute_pipeline_create(_seed_shader)
	if not _apply_shader.is_valid():
		var s4: RDShaderSPIRV = _get_spirv(APPLY_BOUNDARY_SHADER_FILE)
		if s4 != null:
			_apply_shader = _rd.shader_create_from_spirv(s4)
	if not _apply_pipeline.is_valid() and _apply_shader.is_valid():
		_apply_pipeline = _rd.compute_pipeline_create(_apply_shader)
	if not _clear_shader.is_valid():
		var cs: RDShaderSPIRV = _get_spirv(CLEAR_U32_SHADER_FILE)
		if cs != null:
			_clear_shader = _rd.shader_create_from_spirv(cs)
	if not _clear_pipeline.is_valid() and _clear_shader.is_valid():
		_clear_pipeline = _rd.compute_pipeline_create(_clear_shader)

func label_lakes_gpu_buffers(
		w: int,
		h: int,
		land_buf: RID,
		wrap_x: bool,
		out_lake_buf: RID,
		out_lake_id_buf: RID,
		iterations: int = 0
	) -> bool:
	_ensure()
	if not _seed_pipeline.is_valid() or not _prop_pipeline.is_valid() or not _mark_pipeline.is_valid() or not _apply_pipeline.is_valid() or not _clear_pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not land_buf.is_valid() or not out_lake_buf.is_valid() or not out_lake_id_buf.is_valid():
		return false
	var size: int = w * h
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var g1d: int = int(ceil(float(size) / 256.0))
	var labels_zero := PackedInt32Array()
	labels_zero.resize(size)
	var buf_labels := _rd.storage_buffer_create(labels_zero.to_byte_array().size(), labels_zero.to_byte_array())
	var flags_zero := PackedInt32Array()
	flags_zero.resize(size + 1)
	var buf_boundary := _rd.storage_buffer_create(flags_zero.to_byte_array().size(), flags_zero.to_byte_array())

	# Seed water labels from the land mask.
	var seed_uniforms: Array = []
	var su: RDUniform
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 0; su.add_id(land_buf); seed_uniforms.append(su)
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 1; su.add_id(buf_labels); seed_uniforms.append(su)
	var seed_set := _rd.uniform_set_create(seed_uniforms, _seed_shader, 0)
	var seed_pc := PackedByteArray()
	seed_pc.append_array(PackedInt32Array([w, h, 0, 0]).to_byte_array())
	var seed_pad := (16 - (seed_pc.size() % 16)) % 16
	if seed_pad > 0:
		var seed_zeros := PackedByteArray()
		seed_zeros.resize(seed_pad)
		seed_pc.append_array(seed_zeros)
	var seed_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(seed_list, _seed_pipeline)
	_rd.compute_list_bind_uniform_set(seed_list, seed_set, 0)
	_rd.compute_list_set_push_constant(seed_list, seed_pc, seed_pc.size())
	_rd.compute_list_dispatch(seed_list, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(seed_set)

	# Propagate labels in-place.
	var prop_uniforms: Array = []
	var pu: RDUniform
	pu = RDUniform.new(); pu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; pu.binding = 0; pu.add_id(land_buf); prop_uniforms.append(pu)
	pu = RDUniform.new(); pu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; pu.binding = 1; pu.add_id(buf_labels); prop_uniforms.append(pu)
	var prop_set := _rd.uniform_set_create(prop_uniforms, _prop_shader, 0)
	var prop_pc := PackedByteArray()
	prop_pc.append_array(PackedInt32Array([w, h, (1 if wrap_x else 0), 0]).to_byte_array())
	var prop_pad := (16 - (prop_pc.size() % 16)) % 16
	if prop_pad > 0:
		var prop_zeros := PackedByteArray()
		prop_zeros.resize(prop_pad)
		prop_pc.append_array(prop_zeros)
	var max_iters: int = max(1, iterations if iterations > 0 else max(w, h))
	for _it in range(max_iters):
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _prop_pipeline)
		_rd.compute_list_bind_uniform_set(cl, prop_set, 0)
		_rd.compute_list_set_push_constant(cl, prop_pc, prop_pc.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		_rd.compute_list_end()
	_rd.free_rid(prop_set)

	# Clear boundary flags buffer.
	var clear_uniforms: Array = []
	var cu := RDUniform.new()
	cu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	cu.binding = 0
	cu.add_id(buf_boundary)
	clear_uniforms.append(cu)
	var clear_set := _rd.uniform_set_create(clear_uniforms, _clear_shader, 0)
	var clear_pc := PackedByteArray()
	clear_pc.append_array(PackedInt32Array([size + 1, 0, 0, 0]).to_byte_array())
	var clear_pad := (16 - (clear_pc.size() % 16)) % 16
	if clear_pad > 0:
		var clear_zeros := PackedByteArray()
		clear_zeros.resize(clear_pad)
		clear_pc.append_array(clear_zeros)
	var clear_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(clear_list, _clear_pipeline)
	_rd.compute_list_bind_uniform_set(clear_list, clear_set, 0)
	_rd.compute_list_set_push_constant(clear_list, clear_pc, clear_pc.size())
	_rd.compute_list_dispatch(clear_list, int(ceil(float(size + 1) / 256.0)), 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(clear_set)

	# Mark labels that touch map boundaries.
	var mark_uniforms: Array = []
	var mu: RDUniform
	mu = RDUniform.new(); mu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; mu.binding = 0; mu.add_id(buf_labels); mark_uniforms.append(mu)
	mu = RDUniform.new(); mu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; mu.binding = 1; mu.add_id(buf_boundary); mark_uniforms.append(mu)
	var mark_set := _rd.uniform_set_create(mark_uniforms, _mark_shader, 0)
	var mark_pc := PackedByteArray()
	mark_pc.append_array(PackedInt32Array([w, h, 0, 0]).to_byte_array())
	var mark_pad := (16 - (mark_pc.size() % 16)) % 16
	if mark_pad > 0:
		var mark_zeros := PackedByteArray()
		mark_zeros.resize(mark_pad)
		mark_pc.append_array(mark_zeros)
	var mark_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(mark_list, _mark_pipeline)
	_rd.compute_list_bind_uniform_set(mark_list, mark_set, 0)
	_rd.compute_list_set_push_constant(mark_list, mark_pc, mark_pc.size())
	_rd.compute_list_dispatch(mark_list, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(mark_set)

	# Finalize inland-lake mask and ids from labels/flags.
	var apply_uniforms: Array = []
	var au: RDUniform
	au = RDUniform.new(); au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; au.binding = 0; au.add_id(buf_labels); apply_uniforms.append(au)
	au = RDUniform.new(); au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; au.binding = 1; au.add_id(buf_boundary); apply_uniforms.append(au)
	au = RDUniform.new(); au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; au.binding = 2; au.add_id(out_lake_buf); apply_uniforms.append(au)
	au = RDUniform.new(); au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; au.binding = 3; au.add_id(out_lake_id_buf); apply_uniforms.append(au)
	var apply_set := _rd.uniform_set_create(apply_uniforms, _apply_shader, 0)
	var apply_pc := PackedByteArray()
	apply_pc.append_array(PackedInt32Array([size, 0, 0, 0]).to_byte_array())
	var apply_pad := (16 - (apply_pc.size() % 16)) % 16
	if apply_pad > 0:
		var apply_zeros := PackedByteArray()
		apply_zeros.resize(apply_pad)
		apply_pc.append_array(apply_zeros)
	var apply_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(apply_list, _apply_pipeline)
	_rd.compute_list_bind_uniform_set(apply_list, apply_set, 0)
	_rd.compute_list_set_push_constant(apply_list, apply_pc, apply_pc.size())
	_rd.compute_list_dispatch(apply_list, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(apply_set)

	_rd.free_rid(buf_labels)
	_rd.free_rid(buf_boundary)
	return true


