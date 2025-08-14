extends RefCounted

var PROPAGATE_SHADER_FILE: RDShaderFile = load("res://shaders/lake_label_propagate.glsl")
var MARK_BOUNDARY_SHADER_FILE: RDShaderFile = load("res://shaders/lake_mark_boundary.glsl")

var _rd: RenderingDevice
var _prop_shader: RID
var _prop_pipeline: RID
var _mark_shader: RID
var _mark_pipeline: RID

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

func label_lakes(w: int, h: int, is_land: PackedByteArray, wrap_x: bool) -> Dictionary:
	_ensure()
	if not _prop_pipeline.is_valid() or not _mark_pipeline.is_valid():
		return {}
	var size: int = max(0, w * h)
	if size == 0:
		return {"lake": PackedByteArray(), "lake_id": PackedInt32Array()}

	# Prepare inputs
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	var labels := PackedInt32Array(); labels.resize(size)
	for i in range(size):
		var is_water: bool = (i < is_land.size() and is_land[i] == 0)
		land_u32[i] = 0 if is_water else 1
		labels[i] = (i + 1) if is_water else 0

	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var buf_labels := _rd.storage_buffer_create(labels.to_byte_array().size(), labels.to_byte_array())

	# Uniform set for propagate
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_labels); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _prop_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if wrap_x else 0)])
	pc.append_array(ints.to_byte_array())
	# Align to 16 bytes
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))

	# Iterate label propagation
	var max_iters: int = 128
	for _it in range(max_iters):
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _prop_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		_rd.compute_list_end()

	# Mark boundary-connected labels
	var boundary_flags := PackedInt32Array(); boundary_flags.resize(size + 1)
	for i2 in range(size + 1): boundary_flags[i2] = 0
	var buf_boundary := _rd.storage_buffer_create(boundary_flags.to_byte_array().size(), boundary_flags.to_byte_array())
	uniforms.clear()
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_labels); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_boundary); uniforms.append(u)
	var u_set2 := _rd.uniform_set_create(uniforms, _mark_shader, 0)
	pc = PackedByteArray(); ints = PackedInt32Array([w, h]); pc.append_array(ints.to_byte_array())
	# Align to 16 bytes
	pad = (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros2 := PackedByteArray(); zeros2.resize(pad)
		pc.append_array(zeros2)
	var cl2 := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl2, _mark_pipeline)
	_rd.compute_list_bind_uniform_set(cl2, u_set2, 0)
	_rd.compute_list_set_push_constant(cl2, pc, pc.size())
	_rd.compute_list_dispatch(cl2, gx, gy, 1)
	_rd.compute_list_end()

	# Read back and compact on CPU
	var labels_bytes := _rd.buffer_get_data(buf_labels)
	var flags_bytes := _rd.buffer_get_data(buf_boundary)
	var labels_out: PackedInt32Array = labels_bytes.to_int32_array()
	var flags_out: PackedInt32Array = flags_bytes.to_int32_array()
	var lake := PackedByteArray(); lake.resize(size)
	var lake_id := PackedInt32Array(); lake_id.resize(size)
	var label_to_id := {}
	var next_id: int = 1
	for p in range(size):
		var lbl: int = labels_out[p]
		if lbl > 0 and (lbl < flags_out.size()) and flags_out[lbl] == 0:
			lake[p] = 1
			if not label_to_id.has(lbl):
				label_to_id[lbl] = next_id
				next_id += 1
			lake_id[p] = int(label_to_id[lbl])
		else:
			lake[p] = 0
			lake_id[p] = 0

	# Cleanup
	_rd.free_rid(u_set)
	_rd.free_rid(u_set2)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_labels)
	_rd.free_rid(buf_boundary)

	return {
		"lake": lake,
		"lake_id": lake_id,
	}
