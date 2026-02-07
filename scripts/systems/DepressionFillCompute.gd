extends RefCounted

# File: res://scripts/systems/DepressionFillCompute.gd
# GPU minimax relaxation to compute drainage elevation E (Phase 2 scaffolding)

var FILL_SHADER_FILE: RDShaderFile = load("res://shaders/depression_fill.glsl")
var FILL_SEED_SHADER_FILE: RDShaderFile = load("res://shaders/depression_fill_seed.glsl")
var LAKE_MASK_SHADER_FILE: RDShaderFile = load("res://shaders/lake_mask_from_fill.glsl")

var _rd: RenderingDevice
var _fill_shader: RID
var _fill_pipeline: RID
var _fill_seed_shader: RID
var _fill_seed_pipeline: RID
var _lake_mask_shader: RID
var _lake_mask_pipeline: RID
var CLEAR_U32_SHADER_FILE: RDShaderFile = load("res://shaders/clear_u32.glsl")
var _clear_shader: RID
var _clear_pipeline: RID

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
	if _rd == null:
		return
	if not _fill_shader.is_valid():
		var s := _get_spirv(FILL_SHADER_FILE)
		if s == null:
			return
		_fill_shader = _rd.shader_create_from_spirv(s)
	if not _fill_pipeline.is_valid() and _fill_shader.is_valid():
		_fill_pipeline = _rd.compute_pipeline_create(_fill_shader)
	if not _fill_seed_shader.is_valid():
		var ss := _get_spirv(FILL_SEED_SHADER_FILE)
		if ss != null:
			_fill_seed_shader = _rd.shader_create_from_spirv(ss)
	if not _fill_seed_pipeline.is_valid() and _fill_seed_shader.is_valid():
		_fill_seed_pipeline = _rd.compute_pipeline_create(_fill_seed_shader)
	if not _lake_mask_shader.is_valid():
		var ms := _get_spirv(LAKE_MASK_SHADER_FILE)
		if ms != null:
			_lake_mask_shader = _rd.shader_create_from_spirv(ms)
	if not _lake_mask_pipeline.is_valid() and _lake_mask_shader.is_valid():
		_lake_mask_pipeline = _rd.compute_pipeline_create(_lake_mask_shader)
	if not _clear_shader.is_valid():
		var cs := _get_spirv(CLEAR_U32_SHADER_FILE)
		if cs == null:
			return
		_clear_shader = _rd.shader_create_from_spirv(cs)
	if not _clear_pipeline.is_valid() and _clear_shader.is_valid():
		_clear_pipeline = _rd.compute_pipeline_create(_clear_shader)

func compute_lake_mask_gpu_buffers(
		w: int,
		h: int,
		height_buf: RID,
		land_buf: RID,
		wrap_x: bool,
		iterations: int,
		e_primary_buf: RID,
		e_tmp_buf: RID,
		out_lake_mask_buf: RID
	) -> bool:
	_ensure()
	if not _fill_pipeline.is_valid() or not _fill_seed_pipeline.is_valid() or not _lake_mask_pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not height_buf.is_valid() or not land_buf.is_valid() or not e_primary_buf.is_valid() or not e_tmp_buf.is_valid() or not out_lake_mask_buf.is_valid():
		return false
	var size: int = w * h
	var g1d: int = int(ceil(float(size) / 256.0))
	var changed_zero := PackedInt32Array([0])
	var changed_buf := _rd.storage_buffer_create(changed_zero.to_byte_array().size(), changed_zero.to_byte_array())

	# Seed E from terrain/ocean boundaries on GPU.
	var seed_uniforms: Array = []
	var su: RDUniform
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 0; su.add_id(height_buf); seed_uniforms.append(su)
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 1; su.add_id(land_buf); seed_uniforms.append(su)
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 2; su.add_id(e_primary_buf); seed_uniforms.append(su)
	var seed_set := _rd.uniform_set_create(seed_uniforms, _fill_seed_shader, 0)
	var seed_pc := PackedByteArray()
	seed_pc.append_array(PackedInt32Array([w, h, size, 0]).to_byte_array())
	var seed_pad := (16 - (seed_pc.size() % 16)) % 16
	if seed_pad > 0:
		var seed_zeros := PackedByteArray()
		seed_zeros.resize(seed_pad)
		seed_pc.append_array(seed_zeros)
	var seed_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(seed_list, _fill_seed_pipeline)
	_rd.compute_list_bind_uniform_set(seed_list, seed_set, 0)
	_rd.compute_list_set_push_constant(seed_list, seed_pc, seed_pc.size())
	_rd.compute_list_dispatch(seed_list, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(seed_set)

	var e_in: RID = e_primary_buf
	var e_out: RID = e_tmp_buf
	var iters: int = max(1, iterations)
	for _it in range(iters):
		var uniforms: Array = []
		var u: RDUniform
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(height_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(e_in); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(e_out); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(changed_buf); uniforms.append(u)
		var u_set := _rd.uniform_set_create(uniforms, _fill_shader, 0)
		var pc := PackedByteArray()
		pc.append_array(PackedInt32Array([w, h, (1 if wrap_x else 0), size]).to_byte_array())
		pc.append_array(PackedFloat32Array([0.0005]).to_byte_array())
		var pad := (16 - (pc.size() % 16)) % 16
		if pad > 0:
			var zeros := PackedByteArray()
			zeros.resize(pad)
			pc.append_array(zeros)
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _fill_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, g1d, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set)
		var tmp: RID = e_in
		e_in = e_out
		e_out = tmp

	# Convert final E to lake mask directly on GPU.
	var mask_uniforms: Array = []
	var mu: RDUniform
	mu = RDUniform.new(); mu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; mu.binding = 0; mu.add_id(height_buf); mask_uniforms.append(mu)
	mu = RDUniform.new(); mu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; mu.binding = 1; mu.add_id(land_buf); mask_uniforms.append(mu)
	mu = RDUniform.new(); mu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; mu.binding = 2; mu.add_id(e_in); mask_uniforms.append(mu)
	mu = RDUniform.new(); mu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; mu.binding = 3; mu.add_id(out_lake_mask_buf); mask_uniforms.append(mu)
	var mask_set := _rd.uniform_set_create(mask_uniforms, _lake_mask_shader, 0)
	var mask_pc := PackedByteArray()
	mask_pc.append_array(PackedInt32Array([size, 0, 0, 0]).to_byte_array())
	var mask_pad := (16 - (mask_pc.size() % 16)) % 16
	if mask_pad > 0:
		var mask_zeros := PackedByteArray()
		mask_zeros.resize(mask_pad)
		mask_pc.append_array(mask_zeros)
	var mask_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(mask_list, _lake_mask_pipeline)
	_rd.compute_list_bind_uniform_set(mask_list, mask_set, 0)
	_rd.compute_list_set_push_constant(mask_list, mask_pc, mask_pc.size())
	_rd.compute_list_dispatch(mask_list, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(mask_set)
	_rd.free_rid(changed_buf)
	return true
