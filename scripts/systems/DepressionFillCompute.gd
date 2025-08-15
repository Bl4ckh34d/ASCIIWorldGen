extends RefCounted

# File: res://scripts/systems/DepressionFillCompute.gd
# GPU minimax relaxation to compute drainage elevation E (Phase 2 scaffolding)

var FILL_SHADER_FILE: RDShaderFile = load("res://shaders/depression_fill.glsl")

var _rd: RenderingDevice
var _fill_shader: RID
var _fill_pipeline: RID
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
	if not _fill_shader.is_valid():
		var s := _get_spirv(FILL_SHADER_FILE)
		if s == null:
			return
		_fill_shader = _rd.shader_create_from_spirv(s)
	if not _fill_pipeline.is_valid() and _fill_shader.is_valid():
		_fill_pipeline = _rd.compute_pipeline_create(_fill_shader)
	if not _clear_shader.is_valid():
		var cs := _get_spirv(CLEAR_U32_SHADER_FILE)
		if cs == null:
			return
		_clear_shader = _rd.shader_create_from_spirv(cs)
	if not _clear_pipeline.is_valid() and _clear_shader.is_valid():
		_clear_pipeline = _rd.compute_pipeline_create(_clear_shader)

func compute_E(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, wrap_x: bool, iterations: int = 128) -> Dictionary:
	_ensure()
	if not _fill_pipeline.is_valid():
		return {}
	var size: int = max(0, w * h)
	if size == 0:
		return {}
	var buf_h := _rd.storage_buffer_create(height.to_byte_array().size(), height.to_byte_array())
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	for i in range(size): land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	# Two ping-pong buffers for E
	var init_E := PackedFloat32Array(); init_E.resize(size)
	for i2 in range(size):
		var y := int(floor(float(i2)/float(w)))
		var on_vert_edge := (y == 0 or y == h - 1)
		var ocean := (i2 < is_land.size() and is_land[i2] == 0)
		# Initialize to terrain height for oceans and vertical edges; large elsewhere
		init_E[i2] = height[i2] if (ocean or on_vert_edge) else 1.0e9
	var buf_e_in := _rd.storage_buffer_create(init_E.to_byte_array().size(), init_E.to_byte_array())
	var buf_e_out := _rd.storage_buffer_create(init_E.to_byte_array().size(), init_E.to_byte_array())
	# Create convergence flag buffer
	var changed_flag := PackedInt32Array([0])
	var buf_changed := _rd.storage_buffer_create(changed_flag.to_byte_array().size(), changed_flag.to_byte_array())
	# Uniform set
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_h); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	# E_in and E_out will be bound dynamically inside loop
	var gx: int = int(ceil(float(size) / 256.0))
	var iters: int = max(1, iterations)
	for _pass in range(iters):
		var uniforms_set: Array = uniforms.duplicate()
		var u_ei := RDUniform.new(); u_ei.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u_ei.binding = 2; u_ei.add_id(buf_e_in); uniforms_set.append(u_ei)
		var u_eo := RDUniform.new(); u_eo.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u_eo.binding = 3; u_eo.add_id(buf_e_out); uniforms_set.append(u_eo)
		var u_changed := RDUniform.new(); u_changed.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u_changed.binding = 4; u_changed.add_id(buf_changed); uniforms_set.append(u_changed)
		var u_set := _rd.uniform_set_create(uniforms_set, _fill_shader, 0)
		var pc := PackedByteArray();
		var ints := PackedInt32Array([w, h, (1 if wrap_x else 0), size])
		pc.append_array(ints.to_byte_array())
		var epsf := PackedFloat32Array([0.0005])
		pc.append_array(epsf.to_byte_array())
		# Align to 16 bytes
		var pad := (16 - (pc.size() % 16)) % 16
		if pad > 0:
			var zeros := PackedByteArray(); zeros.resize(pad)
			pc.append_array(zeros)
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _fill_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, gx, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set)
		# Read changed flag
		var flag_bytes := _rd.buffer_get_data(buf_changed)
		var flag_i := flag_bytes.to_int32_array()
		var changed := (flag_i.size() > 0 and flag_i[0] != 0)
		if not changed:
			break
		# Reset changed flag via CLEAR shader
		var u_clear := RDUniform.new(); u_clear.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u_clear.binding = 0; u_clear.add_id(buf_changed)
		var u_set_c := _rd.uniform_set_create([u_clear], _clear_shader, 0)
		var pc_c := PackedByteArray(); pc_c.append_array(PackedInt32Array([1]).to_byte_array())
		var padc := (16 - (pc_c.size() % 16)) % 16
		if padc > 0:
			var zc := PackedByteArray(); zc.resize(padc); pc_c.append_array(zc)
		var clc := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clc, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clc, u_set_c, 0)
		_rd.compute_list_set_push_constant(clc, pc_c, pc_c.size())
		_rd.compute_list_dispatch(clc, 1, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set_c)
		# Swap E buffers
		var tmp := buf_e_in
		buf_e_in = buf_e_out
		buf_e_out = tmp
	# Read back E
	var e_bytes := _rd.buffer_get_data(buf_e_in)
	var E := e_bytes.to_float32_array()
	# Compute lake mask on CPU: land and E > H
	var lake := PackedByteArray(); lake.resize(size)
	for k in range(size):
		var land := (k < is_land.size() and is_land[k] != 0)
		lake[k] = 1 if (land and E[k] > (height[k] if k < height.size() else 0.0)) else 0
	# Cleanup
	_rd.free_rid(buf_h)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_e_in)
	_rd.free_rid(buf_e_out)
	_rd.free_rid(buf_changed)
	return {"E": E, "lake": lake}
