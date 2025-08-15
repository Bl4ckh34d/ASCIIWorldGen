extends RefCounted

# File: res://scripts/systems/LakeLabelFromMaskCompute.gd
# Labels lakes from a provided LakeMask (1 = lake) using GPU propagate similar to legacy

var PROPAGATE_SHADER_FILE: RDShaderFile = load("res://shaders/lake_label_from_mask.glsl")
var CLEAR_U32_SHADER_FILE: RDShaderFile = load("res://shaders/clear_u32.glsl")

var _rd: RenderingDevice
var _prop_shader: RID
var _prop_pipeline: RID
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
	if not _prop_shader.is_valid():
		var s := _get_spirv(PROPAGATE_SHADER_FILE)
		if s == null:
			return
		_prop_shader = _rd.shader_create_from_spirv(s)
	if not _prop_pipeline.is_valid() and _prop_shader.is_valid():
		_prop_pipeline = _rd.compute_pipeline_create(_prop_shader)
	if not _clear_shader.is_valid():
		var cs := _get_spirv(CLEAR_U32_SHADER_FILE)
		if cs == null:
			return
		_clear_shader = _rd.shader_create_from_spirv(cs)
	if not _clear_pipeline.is_valid() and _clear_shader.is_valid():
		_clear_pipeline = _rd.compute_pipeline_create(_clear_shader)

func label_from_mask(w: int, h: int, lake_mask: PackedByteArray, wrap_x: bool) -> Dictionary:
	_ensure()
	if not _prop_pipeline.is_valid():
		return {}
	var size: int = max(0, w * h)
	if size == 0:
		return {}
	# Initialize labels >0 for lake pixels, 0 otherwise
	var labels := PackedInt32Array(); labels.resize(size)
	var in_mask := PackedInt32Array(); in_mask.resize(size)
	for i in range(size):
		var is_lake: bool = (i < lake_mask.size() and lake_mask[i] != 0)
		in_mask[i] = 1 if is_lake else 0
		labels[i] = (i + 1) if is_lake else 0
	var buf_mask := _rd.storage_buffer_create(in_mask.to_byte_array().size(), in_mask.to_byte_array())
	var buf_labels := _rd.storage_buffer_create(labels.to_byte_array().size(), labels.to_byte_array())
	# Create convergence flag buffer
	var changed_flag := PackedInt32Array([0])
	var buf_changed := _rd.storage_buffer_create(changed_flag.to_byte_array().size(), changed_flag.to_byte_array())
	# Uniforms
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_mask); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_labels); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_changed); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _prop_shader, 0)
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h, (1 if wrap_x else 0)])
	pc.append_array(ints.to_byte_array())
	# Align push constants to 16 bytes as required by RD
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))
	# Iterate with convergence detection
	var max_iters: int = 128
	for _it in range(max_iters):
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _prop_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		_rd.compute_list_end()
		# Check convergence
		var flag_bytes := _rd.buffer_get_data(buf_changed)
		var flag_i := flag_bytes.to_int32_array()
		var changed := (flag_i.size() > 0 and flag_i[0] != 0)
		if not changed:
			break
		# Reset changed flag
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
	# Read back and compact labels to small ids
	var labels_bytes := _rd.buffer_get_data(buf_labels)
	var labels_out: PackedInt32Array = labels_bytes.to_int32_array()
	var lake := PackedByteArray(); lake.resize(size)
	var lake_id := PackedInt32Array(); lake_id.resize(size)
	var map_lbl_to_id := {}
	var next_id: int = 1
	for i2 in range(size):
		var lbl: int = labels_out[i2]
		if lbl > 0:
			lake[i2] = 1
			if not map_lbl_to_id.has(lbl):
				map_lbl_to_id[lbl] = next_id
				next_id += 1
			lake_id[i2] = int(map_lbl_to_id[lbl])
		else:
			lake[i2] = 0
			lake_id[i2] = 0
	_rd.free_rid(u_set)
	_rd.free_rid(buf_mask)
	_rd.free_rid(buf_labels)
	_rd.free_rid(buf_changed)
	return {"lake": lake, "lake_id": lake_id}
