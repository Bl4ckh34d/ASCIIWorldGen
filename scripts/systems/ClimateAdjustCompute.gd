# File: res://scripts/systems/ClimateAdjustCompute.gd
extends RefCounted

## GPU ClimateAdjust using Godot 4 RenderingDevice and compute shaders.

var CLIMATE_SHADER_FILE: RDShaderFile = load("res://shaders/climate_adjust.glsl")
var CLIMATE_NOISE_SHADER_FILE: RDShaderFile = load("res://shaders/climate_noise.glsl")
var CYCLE_APPLY_SHADER_FILE: RDShaderFile = load("res://shaders/cycle_apply.glsl")
var DAY_NIGHT_LIGHT_SHADER_FILE: RDShaderFile = load("res://shaders/day_night_light.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _cycle_shader: RID
var _cycle_pipeline: RID
var _light_shader: RID
var _light_pipeline: RID

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
	if chosen_version == null:
		return null
	return file.get_spirv(chosen_version)

func _compute_stage_error_text(spirv: RDShaderSPIRV) -> String:
	if spirv == null:
		return "null spirv"
	if spirv.has_method("get_stage_compile_error"):
		return str(spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)).strip_edges()
	if "compute_stage_compile_error" in spirv:
		return str(spirv.compute_stage_compile_error).strip_edges()
	return ""

func _compute_stage_bytecode_size(spirv: RDShaderSPIRV) -> int:
	if spirv == null:
		return 0
	if spirv.has_method("get_stage_bytecode"):
		var bc = spirv.get_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE)
		if typeof(bc) == TYPE_PACKED_BYTE_ARRAY:
			return bc.size()
	if "compute_stage_bytecode" in spirv:
		var bc2 = spirv.compute_stage_bytecode
		if typeof(bc2) == TYPE_PACKED_BYTE_ARRAY:
			return bc2.size()
	return -1

func _ensure_device_and_pipeline() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(CLIMATE_SHADER_FILE)
		if spirv == null:
			push_error("ClimateAdjustCompute: failed to load SPIR-V for res://shaders/climate_adjust.glsl")
			return
		var compile_err: String = _compute_stage_error_text(spirv)
		if not compile_err.is_empty():
			push_error("ClimateAdjustCompute: climate_adjust compute compile error: %s" % compile_err)
			return
		var bc_size: int = _compute_stage_bytecode_size(spirv)
		if bc_size == 0:
			push_error("ClimateAdjustCompute: climate_adjust compute bytecode is empty")
			return
		_shader = _rd.shader_create_from_spirv(spirv)
		if not _shader.is_valid():
			push_error("ClimateAdjustCompute: shader_create_from_spirv failed for res://shaders/climate_adjust.glsl")
			return
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	if not _cycle_shader.is_valid():
		var cycle_spirv: RDShaderSPIRV = _get_spirv(CYCLE_APPLY_SHADER_FILE)
		if cycle_spirv != null:
			_cycle_shader = _rd.shader_create_from_spirv(cycle_spirv)
	if not _cycle_pipeline.is_valid() and _cycle_shader.is_valid():
		_cycle_pipeline = _rd.compute_pipeline_create(_cycle_shader)
	if not _light_shader.is_valid():
		var light_spirv: RDShaderSPIRV = _get_spirv(DAY_NIGHT_LIGHT_SHADER_FILE)
		if light_spirv != null:
			_light_shader = _rd.shader_create_from_spirv(light_spirv)
	if not _light_pipeline.is_valid() and _light_shader.is_valid():
		_light_pipeline = _rd.compute_pipeline_create(_light_shader)

func _pack_push_constants(width: int, height: int, params: Dictionary, ocean_frac: float) -> PackedByteArray:
	var arr := PackedByteArray()
	var ints := PackedInt32Array([width, height])
	var floats := PackedFloat32Array([
		float(params.get("sea_level", 0.0)),
		float(params.get("temp_base_offset", 0.0)),
		float(params.get("temp_scale", 1.0)),
		float(params.get("moist_base_offset", 0.0)),
		float(params.get("moist_scale", 1.0)),
		float(params.get("continentality_scale", 1.0)),
		float(ocean_frac),
		float(params.get("noise_x_scale", 1.0)),
		float(params.get("season_phase", 0.0)),
		float(params.get("season_amp_equator", 0.0)),
		float(params.get("season_amp_pole", 0.0)),
		float(params.get("season_ocean_damp", 0.0)),
		float(params.get("diurnal_amp_equator", 0.0)),
		float(params.get("diurnal_amp_pole", 0.0)),
		float(params.get("diurnal_ocean_damp", 0.0)),
		float(params.get("time_of_day", 0.0)),
	])
	arr.append_array(ints.to_byte_array())
	arr.append_array(floats.to_byte_array())
	return arr

func _compute_noise_fields_gpu_to_buffers(
		w: int,
		h: int,
		params: Dictionary,
		xscale: float,
		buf_t: RID,
		buf_mb: RID,
		buf_u: RID,
		buf_v: RID
	) -> bool:
	if CLIMATE_NOISE_SHADER_FILE == null:
		return false
	if not buf_t.is_valid() or not buf_mb.is_valid() or not buf_u.is_valid() or not buf_v.is_valid():
		return false
	var spirv: RDShaderSPIRV = _get_spirv(CLIMATE_NOISE_SHADER_FILE)
	if spirv == null:
		return false
	var shader: RID = _rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		return false
	var pipeline: RID = _rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		_rd.free_rid(shader)
		return false
	var size: int = max(0, w * h)
	var out_mr := PackedFloat32Array(); out_mr.resize(size)
	var buf_mr := _rd.storage_buffer_create(out_mr.to_byte_array().size(), out_mr.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_t); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_mb); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_mr); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_u); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_v); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, shader, 0)
	var pc := PackedByteArray()
	var wrap_x_int: int = 1
	var seed_val: int = int(params.get("seed", 0))
	var ints := PackedInt32Array([w, h, wrap_x_int, seed_val])
	var floats := PackedFloat32Array([xscale])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_mr)
	_rd.free_rid(pipeline)
	_rd.free_rid(shader)
	return true

func evaluate_to_buffers_gpu(
		w: int,
		h: int,
		height_buf: RID,
		land_buf: RID,
		distance_buf: RID,
		params: Dictionary,
		ocean_frac: float,
		out_temp_buf: RID,
		out_moist_buf: RID,
		out_precip_buf: RID
	) -> bool:
	_ensure_device_and_pipeline()
	if not _shader.is_valid() or not _pipeline.is_valid():
		return false
	if not height_buf.is_valid() or not land_buf.is_valid() or not distance_buf.is_valid():
		return false
	if not out_temp_buf.is_valid() or not out_moist_buf.is_valid() or not out_precip_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	var dummy := PackedFloat32Array(); dummy.resize(size)
	var buf_temp_noise: RID = _rd.storage_buffer_create(dummy.to_byte_array().size(), dummy.to_byte_array())
	var buf_moist_base_offset: RID = _rd.storage_buffer_create(dummy.to_byte_array().size(), dummy.to_byte_array())
	var buf_flow_u: RID = _rd.storage_buffer_create(dummy.to_byte_array().size(), dummy.to_byte_array())
	var buf_flow_v: RID = _rd.storage_buffer_create(dummy.to_byte_array().size(), dummy.to_byte_array())
	var xscale: float = float(params.get("noise_x_scale", 1.0))
	var noise_ok: bool = _compute_noise_fields_gpu_to_buffers(w, h, params, xscale, buf_temp_noise, buf_moist_base_offset, buf_flow_u, buf_flow_v)
	if not noise_ok:
		_rd.free_rid(buf_temp_noise)
		_rd.free_rid(buf_moist_base_offset)
		_rd.free_rid(buf_flow_u)
		_rd.free_rid(buf_flow_v)
		return false
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(height_buf); uniforms.append(u0)
	var u1: RDUniform = RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(land_buf); uniforms.append(u1)
	var u2: RDUniform = RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u2.binding = 2; u2.add_id(distance_buf); uniforms.append(u2)
	var u3: RDUniform = RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u3.binding = 3; u3.add_id(buf_temp_noise); uniforms.append(u3)
	var u4: RDUniform = RDUniform.new(); u4.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u4.binding = 4; u4.add_id(buf_moist_base_offset); uniforms.append(u4)
	var u5: RDUniform = RDUniform.new(); u5.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u5.binding = 5; u5.add_id(buf_flow_u); uniforms.append(u5)
	var u6: RDUniform = RDUniform.new(); u6.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u6.binding = 6; u6.add_id(buf_flow_v); uniforms.append(u6)
	var u7: RDUniform = RDUniform.new(); u7.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u7.binding = 7; u7.add_id(out_temp_buf); uniforms.append(u7)
	var u8: RDUniform = RDUniform.new(); u8.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u8.binding = 8; u8.add_id(out_moist_buf); uniforms.append(u8)
	var u9: RDUniform = RDUniform.new(); u9.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u9.binding = 9; u9.add_id(out_precip_buf); uniforms.append(u9)
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := _pack_push_constants(w, h, params, ocean_frac)
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var groups_x: int = int(ceil(float(w) / 16.0))
	var groups_y: int = int(ceil(float(h) / 16.0))
	var cl_id: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_id, _pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
	_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
	_rd.compute_list_end()
	_rd.free_rid(uniform_set)
	_rd.free_rid(buf_temp_noise)
	_rd.free_rid(buf_moist_base_offset)
	_rd.free_rid(buf_flow_u)
	_rd.free_rid(buf_flow_v)
	return true

# GPU-only fast path: apply cycles in-place or into provided output buffer (no readback).
func apply_cycles_only_gpu(w: int, h: int, temp_buf: RID, land_buf: RID, dist_buf: RID, params: Dictionary, out_buf: RID) -> bool:
	_ensure_device_and_pipeline()
	var size: int = max(0, w * h)
	if size == 0 or not _cycle_pipeline.is_valid():
		return false
	if not temp_buf.is_valid() or not land_buf.is_valid() or not dist_buf.is_valid() or not out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(temp_buf); uniforms.append(u0)
	var u1: RDUniform = RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(land_buf); uniforms.append(u1)
	var u2: RDUniform = RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u2.binding = 2; u2.add_id(dist_buf); uniforms.append(u2)
	var u3: RDUniform = RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u3.binding = 3; u3.add_id(out_buf); uniforms.append(u3)
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _cycle_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([
		float(params.get("season_phase", 0.0)),
		float(params.get("season_amp_equator", 0.0)),
		float(params.get("season_amp_pole", 0.0)),
		float(params.get("season_ocean_damp", 0.0)),
		float(params.get("diurnal_amp_equator", 0.0)),
		float(params.get("diurnal_amp_pole", 0.0)),
		float(params.get("diurnal_ocean_damp", 0.0)),
		float(params.get("time_of_day", 0.0)),
		float(params.get("continentality_scale", 1.0)),
		float(params.get("temp_base_offset_delta", 0.0)),
		float(params.get("temp_scale_ratio", 1.0)),
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var groups_x: int = int(ceil(float(w) / 16.0))
	var groups_y: int = int(ceil(float(h) / 16.0))
	var cl_id: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_id, _cycle_pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
	_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
	_rd.compute_list_end()
	_rd.free_rid(uniform_set)
	return true

# GPU-only path: write light field into a provided buffer (no readback).
func evaluate_light_field_gpu(w: int, h: int, params: Dictionary, out_buf: RID) -> bool:
	_ensure_device_and_pipeline()
	var size: int = max(0, w * h)
	if size == 0 or not _light_pipeline.is_valid():
		return false
	if not out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(out_buf)
	uniforms.append(u0)
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _light_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var day_of_year: float = float(params.get("day_of_year", 0.0))
	var time_of_day: float = float(params.get("time_of_day", 0.0))
	var floats := PackedFloat32Array([
		day_of_year,
		time_of_day,
		float(params.get("day_night_base", 0.25)),
		float(params.get("day_night_contrast", 0.75)),
		float(params.get("moon_count", 0.0)),
		float(params.get("moon_seed", 0.0)),
		float(params.get("moon_shadow_strength", 0.55)),
		float(params.get("sim_days", day_of_year * 365.0 + time_of_day)),
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var groups_x: int = int(ceil(float(w) / 16.0))
	var groups_y: int = int(ceil(float(h) / 16.0))
	var cl_id: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_id, _light_pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
	_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
	_rd.compute_list_end()
	_rd.free_rid(uniform_set)
	return true
