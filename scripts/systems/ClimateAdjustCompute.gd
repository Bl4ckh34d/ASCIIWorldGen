# File: res://scripts/systems/ClimateAdjustCompute.gd
extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

## GPU ClimateAdjust using Godot 4 RenderingDevice and compute shaders.

const ComputeShaderBase = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")

const CLIMATE_SHADER_PATH: String = "res://shaders/climate_adjust.glsl"
const CYCLE_APPLY_SHADER_PATH: String = "res://shaders/cycle_apply.glsl"
const DAY_NIGHT_LIGHT_SHADER_PATH: String = "res://shaders/day_night_light.glsl"

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _cycle_shader: RID
var _cycle_pipeline: RID
var _light_shader: RID
var _light_pipeline: RID
var _buf_mgr: GPUBufferManager = null

func _init() -> void:
	_buf_mgr = GPUBufferManager.new()

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
	var state_climate: Dictionary = ComputeShaderBase.ensure_rd_and_pipeline(
		_rd,
		_shader,
		_pipeline,
		CLIMATE_SHADER_PATH,
		"climate_adjust"
	)
	_rd = state_climate.get("rd", null)
	_shader = state_climate.get("shader", RID())
	_pipeline = state_climate.get("pipeline", RID())
	if not VariantCasts.to_bool(state_climate.get("ok", false)):
		return

	var state_cycle: Dictionary = ComputeShaderBase.ensure_rd_and_pipeline(
		_rd,
		_cycle_shader,
		_cycle_pipeline,
		CYCLE_APPLY_SHADER_PATH,
		"cycle_apply"
	)
	_cycle_shader = state_cycle.get("shader", RID())
	_cycle_pipeline = state_cycle.get("pipeline", RID())

	var state_light: Dictionary = ComputeShaderBase.ensure_rd_and_pipeline(
		_rd,
		_light_shader,
		_light_pipeline,
		DAY_NIGHT_LIGHT_SHADER_PATH,
		"day_night_light"
	)
	_light_shader = state_light.get("shader", RID())
	_light_pipeline = state_light.get("pipeline", RID())

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
	if not buf_t.is_valid() or not buf_mb.is_valid() or not buf_u.is_valid() or not buf_v.is_valid():
		return false
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return false
	var size: int = max(0, w * h)
	if size <= 0:
		return false
	var rng_seed: int = int(params.get("seed", 0))
	var x_scale: float = max(0.0001, float(xscale))

	var temp_noise := FastNoiseLite.new()
	temp_noise.seed = rng_seed ^ 0x5151
	temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	temp_noise.frequency = 0.02

	var moist_noise := FastNoiseLite.new()
	moist_noise.seed = rng_seed ^ 0xA1A1
	moist_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	moist_noise.frequency = 0.02

	var flow_u_noise := FastNoiseLite.new()
	var flow_v_noise := FastNoiseLite.new()
	flow_u_noise.seed = rng_seed ^ 0xC0FE
	flow_v_noise.seed = rng_seed ^ 0xF00D
	flow_u_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	flow_v_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	flow_u_noise.frequency = 0.01
	flow_v_noise.frequency = 0.01

	var out_t := PackedFloat32Array()
	var out_mb := PackedFloat32Array()
	var out_u := PackedFloat32Array()
	var out_v := PackedFloat32Array()
	out_t.resize(size)
	out_mb.resize(size)
	out_u.resize(size)
	out_v.resize(size)

	var width_f: float = float(w)
	var inv_width: float = 1.0 / float(max(1, w))
	for y in range(h):
		var yf: float = float(y)
		var y_scaled: float = yf * x_scale
		for x in range(w):
			var i: int = x + y * w
			var xf: float = float(x)
			var blend_t: float = xf * inv_width
			var x0: float = xf * x_scale
			var x1: float = (xf + width_f) * x_scale
			var temp0: float = temp_noise.get_noise_2d(x0, y_scaled)
			var temp1: float = temp_noise.get_noise_2d(x1, y_scaled)
			out_t[i] = clamp(lerp(temp0, temp1, blend_t), -1.0, 1.0)

			var moist0: float = moist_noise.get_noise_2d(x0 + 100.0, y_scaled - 50.0)
			var moist1: float = moist_noise.get_noise_2d(x1 + 100.0, y_scaled - 50.0)
			out_mb[i] = clamp(lerp(moist0, moist1, blend_t), -1.0, 1.0)

			var flow_u0: float = flow_u_noise.get_noise_2d(x0 * 0.5, y_scaled * 0.5)
			var flow_u1: float = flow_u_noise.get_noise_2d(x1 * 0.5, y_scaled * 0.5)
			out_u[i] = clamp(lerp(flow_u0, flow_u1, blend_t), -1.0, 1.0)

			var flow_v0: float = flow_v_noise.get_noise_2d((x0 + 1000.0) * 0.5, (y_scaled - 777.0) * 0.5)
			var flow_v1: float = flow_v_noise.get_noise_2d((x1 + 1000.0) * 0.5, (y_scaled - 777.0) * 0.5)
			out_v[i] = clamp(lerp(flow_v0, flow_v1, blend_t), -1.0, 1.0)

	var bytes_t: PackedByteArray = out_t.to_byte_array()
	var bytes_mb: PackedByteArray = out_mb.to_byte_array()
	var bytes_u: PackedByteArray = out_u.to_byte_array()
	var bytes_v: PackedByteArray = out_v.to_byte_array()
	_rd.buffer_update(buf_t, 0, bytes_t.size(), bytes_t)
	_rd.buffer_update(buf_mb, 0, bytes_mb.size(), bytes_mb)
	_rd.buffer_update(buf_u, 0, bytes_u.size(), bytes_u)
	_rd.buffer_update(buf_v, 0, bytes_v.size(), bytes_v)
	return true

func evaluate_to_buffers_gpu(
		w: int,
		h: int,
		height_buf: RID,
		land_buf: RID,
		distance_buf: RID,
		light_buf: RID,
		params: Dictionary,
		ocean_frac: float,
		out_temp_buf: RID,
		out_moist_buf: RID,
		out_precip_buf: RID
	) -> bool:
	_ensure_device_and_pipeline()
	if not _shader.is_valid() or not _pipeline.is_valid():
		return false
	if not height_buf.is_valid() or not land_buf.is_valid() or not distance_buf.is_valid() or not light_buf.is_valid():
		return false
	if not out_temp_buf.is_valid() or not out_moist_buf.is_valid() or not out_precip_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	var bytes_size: int = size * 4
	var buf_temp_noise: RID = _buf_mgr.ensure_buffer("clim_temp_noise", bytes_size)
	var buf_moist_base_offset: RID = _buf_mgr.ensure_buffer("clim_moist_base", bytes_size)
	var buf_flow_u: RID = _buf_mgr.ensure_buffer("clim_flow_u", bytes_size)
	var buf_flow_v: RID = _buf_mgr.ensure_buffer("clim_flow_v", bytes_size)
	if not (buf_temp_noise.is_valid() and buf_moist_base_offset.is_valid() and buf_flow_u.is_valid() and buf_flow_v.is_valid()):
		return false
	var xscale: float = float(params.get("noise_x_scale", 1.0))
	var noise_ok: bool = _compute_noise_fields_gpu_to_buffers(w, h, params, xscale, buf_temp_noise, buf_moist_base_offset, buf_flow_u, buf_flow_v)
	if not noise_ok:
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
	var u10: RDUniform = RDUniform.new(); u10.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u10.binding = 10; u10.add_id(light_buf); uniforms.append(u10)
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := _pack_push_constants(w, h, params, ocean_frac)
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBase.validate_push_constant_size(pc, 80, "ClimateAdjustCompute.evaluate"):
		return false
	var groups_x: int = int(ceil(float(w) / 16.0))
	var groups_y: int = int(ceil(float(h) / 16.0))
	var cl_id: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_id, _pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
	_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
	_rd.compute_list_end()
	_rd.free_rid(uniform_set)
	return true

# GPU-only fast path: apply cycles in-place or into provided output buffer (no readback).
func apply_cycles_only_gpu(w: int, h: int, temp_buf: RID, land_buf: RID, dist_buf: RID, light_buf: RID, params: Dictionary, out_buf: RID) -> bool:
	_ensure_device_and_pipeline()
	var size: int = max(0, w * h)
	if size == 0 or not _cycle_pipeline.is_valid():
		return false
	if not temp_buf.is_valid() or not land_buf.is_valid() or not dist_buf.is_valid() or not light_buf.is_valid() or not out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(temp_buf); uniforms.append(u0)
	var u1: RDUniform = RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(land_buf); uniforms.append(u1)
	var u2: RDUniform = RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u2.binding = 2; u2.add_id(dist_buf); uniforms.append(u2)
	var u3: RDUniform = RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u3.binding = 3; u3.add_id(out_buf); uniforms.append(u3)
	var u4: RDUniform = RDUniform.new(); u4.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u4.binding = 4; u4.add_id(light_buf); uniforms.append(u4)
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
	if not ComputeShaderBase.validate_push_constant_size(pc, 64, "ClimateAdjustCompute.cycle"):
		return false
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
func evaluate_light_field_gpu(w: int, h: int, params: Dictionary, height_buf: RID, out_buf: RID) -> bool:
	_ensure_device_and_pipeline()
	var size: int = max(0, w * h)
	if size == 0 or not _light_pipeline.is_valid():
		return false
	if not height_buf.is_valid() or not out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(out_buf)
	uniforms.append(u0)
	var u1: RDUniform = RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(height_buf)
	uniforms.append(u1)
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _light_shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var day_of_year: float = float(params.get("day_of_year", 0.0))
	var time_of_day: float = float(params.get("time_of_day", 0.0))
	var floats := PackedFloat32Array([
		day_of_year,
		time_of_day,
		float(params.get("day_night_base", 0.008)),
		float(params.get("day_night_contrast", 0.992)),
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
	if not ComputeShaderBase.validate_push_constant_size(pc, 48, "ClimateAdjustCompute.light"):
		return false
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

func cleanup() -> void:
	if _buf_mgr != null:
		_buf_mgr.cleanup()
	ComputeShaderBase.free_rids(_rd, [
		_pipeline,
		_shader,
		_cycle_pipeline,
		_cycle_shader,
		_light_pipeline,
		_light_shader,
	])
	_pipeline = RID()
	_shader = RID()
	_cycle_pipeline = RID()
	_cycle_shader = RID()
	_light_pipeline = RID()
	_light_shader = RID()
