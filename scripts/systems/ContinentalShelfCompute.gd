# File: res://scripts/systems/ContinentalShelfCompute.gd
extends RefCounted

const SHELF_SHADER_FILE := preload("res://shaders/continental_shelf.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.create_local_rendering_device()
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = SHELF_SHADER_FILE.get_spirv("vulkan")
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func compute(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, sea_level: float, water_distance: PackedFloat32Array, shore_noise_field: PackedFloat32Array, shallow_threshold: float, shore_band: float, wrap_x: bool, noise_x_scale: float) -> Dictionary:
	_ensure()
	if not _shader.is_valid() or not _pipeline.is_valid():
		return {}
	var size: int = max(0, w * h)
	var buf_h := _rd.storage_buffer_create(height.to_byte_array().size(), height.to_byte_array())
	var buf_land := _rd.storage_buffer_create(is_land.size(), is_land)
	var buf_dist := _rd.storage_buffer_create(water_distance.to_byte_array().size(), water_distance.to_byte_array())
	var buf_noise := _rd.storage_buffer_create(shore_noise_field.to_byte_array().size(), shore_noise_field.to_byte_array())
	var out_turq_arr := PackedByteArray(); out_turq_arr.resize(size)
	var out_beach_arr := PackedByteArray(); out_beach_arr.resize(size)
	var out_strength_arr := PackedFloat32Array(); out_strength_arr.resize(size)
	var buf_out_turq := _rd.storage_buffer_create(out_turq_arr.size(), out_turq_arr)
	var buf_out_beach := _rd.storage_buffer_create(out_beach_arr.size(), out_beach_arr)
	var buf_out_strength := _rd.storage_buffer_create(out_strength_arr.to_byte_array().size(), out_strength_arr.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_h); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_dist); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_noise); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_out_turq); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(buf_out_beach); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(buf_out_strength); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([sea_level, shallow_threshold, shore_band, (1.0 if wrap_x else 0.0), noise_x_scale])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.submit(); _rd.sync()
	var turq_bytes := _rd.buffer_get_data(buf_out_turq)
	var beach_bytes := _rd.buffer_get_data(buf_out_beach)
	var strength_bytes := _rd.buffer_get_data(buf_out_strength)
	var turq := turq_bytes # PackedByteArray
	var beach := beach_bytes # PackedByteArray
	var strength: PackedFloat32Array = strength_bytes.to_float32_array()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_h)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_dist)
	_rd.free_rid(buf_noise)
	_rd.free_rid(buf_out_turq)
	_rd.free_rid(buf_out_beach)
	_rd.free_rid(buf_out_strength)
	return {
		"turquoise_water": turq,
		"beach": beach,
		"turquoise_strength": strength,
	}


