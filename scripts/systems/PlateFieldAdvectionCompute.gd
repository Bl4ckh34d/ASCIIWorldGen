# File: res://scripts/systems/PlateFieldAdvectionCompute.gd
extends RefCounted

const FIELD_SHADER_FILE: RDShaderFile = preload("res://shaders/plate_field_advection_i32.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

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
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(FIELD_SHADER_FILE)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func advect_i32_gpu_buffers(
		w: int,
		h: int,
		field_in_buf: RID,
		plate_id_buf: RID,
		plate_vel_u: PackedFloat32Array,
		plate_vel_v: PackedFloat32Array,
		dt_days: float,
		drift_cells_per_day: float,
		field_out_buf: RID
	) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not field_in_buf.is_valid() or not plate_id_buf.is_valid() or not field_out_buf.is_valid():
		return false
	var num_plates: int = min(plate_vel_u.size(), plate_vel_v.size())
	if num_plates <= 0:
		return false

	var buf_pu := _rd.storage_buffer_create(plate_vel_u.to_byte_array().size(), plate_vel_u.to_byte_array())
	var buf_pv := _rd.storage_buffer_create(plate_vel_v.to_byte_array().size(), plate_vel_v.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(field_in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(plate_id_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_pu); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_pv); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(field_out_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, num_plates, 0])
	var floats := PackedFloat32Array([dt_days, drift_cells_per_day, 0.0, 0.0])
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
	_rd.free_rid(buf_pu)
	_rd.free_rid(buf_pv)
	return true

