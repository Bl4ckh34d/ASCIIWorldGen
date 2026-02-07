# File: res://scripts/systems/ClimateAdjustCompute.gd
extends RefCounted

## GPU ClimateAdjust using Godot 4 RenderingDevice and a compute shader.

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
	return file.get_spirv(chosen_version)

func _ensure_device_and_pipeline() -> void:
	if _rd == null:
		# Use main rendering device to avoid version mismatch with imported SPIR-V
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		# Ensure shader import resource exists and has compute entry
		var spirv: RDShaderSPIRV = _get_spirv(CLIMATE_SHADER_FILE)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
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

func _create_storage_buffer_from_f32(data: PackedFloat32Array) -> RID:
	var bytes := data.to_byte_array()
	return _rd.storage_buffer_create(bytes.size(), bytes)

func _create_storage_buffer_from_u8(data: PackedByteArray) -> RID:
	# Raw bytes accepted; treat as u32 in shader when needed by casting
	return _rd.storage_buffer_create(data.size(), data)

func _create_storage_buffer_from_f32_list(values: Array) -> RID:
	var fa := PackedFloat32Array(values)
	return _create_storage_buffer_from_f32(fa)

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
		# Seasonal constants
		float(params.get("season_phase", 0.0)),
		float(params.get("season_amp_equator", 0.0)),
		float(params.get("season_amp_pole", 0.0)),
		float(params.get("season_ocean_damp", 0.0)),
		# Diurnal constants
		float(params.get("diurnal_amp_equator", 0.0)),
		float(params.get("diurnal_amp_pole", 0.0)),
		float(params.get("diurnal_ocean_damp", 0.0)),
		float(params.get("time_of_day", 0.0)),
	])
	arr.append_array(ints.to_byte_array())
	arr.append_array(floats.to_byte_array())
	return arr

func _compute_noise_fields_gpu(w: int, h: int, params: Dictionary, xscale: float) -> Dictionary:
	# Build climate base noise fields on GPU if shader is available
	if CLIMATE_NOISE_SHADER_FILE == null:
		return {}
	var spirv: RDShaderSPIRV = _get_spirv(CLIMATE_NOISE_SHADER_FILE)
	if spirv == null:
		return {}
	var shader: RID = _rd.shader_create_from_spirv(spirv)
	var pipeline: RID = _rd.compute_pipeline_create(shader)
	var size: int = max(0, w * h)
	var out_t := PackedFloat32Array(); out_t.resize(size)
	var out_mb := PackedFloat32Array(); out_mb.resize(size)
	var out_mr := PackedFloat32Array(); out_mr.resize(size)
	var out_u := PackedFloat32Array(); out_u.resize(size)
	var out_v := PackedFloat32Array(); out_v.resize(size)
	var buf_t := _rd.storage_buffer_create(out_t.to_byte_array().size(), out_t.to_byte_array())
	var buf_mb := _rd.storage_buffer_create(out_mb.to_byte_array().size(), out_mb.to_byte_array())
	var buf_mr := _rd.storage_buffer_create(out_mr.to_byte_array().size(), out_mr.to_byte_array())
	var buf_u := _rd.storage_buffer_create(out_u.to_byte_array().size(), out_u.to_byte_array())
	var buf_v := _rd.storage_buffer_create(out_v.to_byte_array().size(), out_v.to_byte_array())
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
	# Align to 16-byte multiple; shader expects 32 bytes due to padding
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
	# Read back
	var t_bytes := _rd.buffer_get_data(buf_t)
	var mb_bytes := _rd.buffer_get_data(buf_mb)
	var mr_bytes := _rd.buffer_get_data(buf_mr)
	var u_bytes := _rd.buffer_get_data(buf_u)
	var v_bytes := _rd.buffer_get_data(buf_v)
	var out := {
		"temp_noise": t_bytes.to_float32_array(),
		"moist_noise_base_offset": mb_bytes.to_float32_array(),
		"moist_noise_raw": mr_bytes.to_float32_array(),
		"flow_u": u_bytes.to_float32_array(),
		"flow_v": v_bytes.to_float32_array(),
	}
	_rd.free_rid(u_set)
	_rd.free_rid(buf_t)
	_rd.free_rid(buf_mb)
	_rd.free_rid(buf_mr)
	_rd.free_rid(buf_u)
	_rd.free_rid(buf_v)
	_rd.free_rid(pipeline)
	_rd.free_rid(shader)
	return out

func _compute_noise_fields(w: int, h: int, base: Dictionary, xscale: float) -> Dictionary:
	var size := w * h
	var temp_noise_values := PackedFloat32Array(); temp_noise_values.resize(size)
	var moist_noise_base_offset := PackedFloat32Array(); moist_noise_base_offset.resize(size)
	var moist_noise_raw := PackedFloat32Array(); moist_noise_raw.resize(size)
	var flow_u_vals := PackedFloat32Array(); flow_u_vals.resize(size)
	var flow_v_vals := PackedFloat32Array(); flow_v_vals.resize(size)
	var temp_noise: Object = base["temp_noise"]
	var moist_noise: Object = base["moist_noise"]
	var flow_u: Object = base["flow_u"]
	var flow_v: Object = base["flow_v"]
	for y in range(h):
		for x in range(w):
			var i := x + y * w
			temp_noise_values[i] = temp_noise.get_noise_2d(x * xscale, y)
			moist_noise_base_offset[i] = moist_noise.get_noise_2d(x * xscale + 100.0, y - 50.0)
			moist_noise_raw[i] = moist_noise.get_noise_2d(x * xscale, y)
			flow_u_vals[i] = flow_u.get_noise_2d(x * 0.5 * xscale, y * 0.5)
			flow_v_vals[i] = flow_v.get_noise_2d((x * xscale + 1000.0) * 0.5, (y - 777.0) * 0.5)
	return {
		"temp_noise": temp_noise_values,
		"moist_noise_base_offset": moist_noise_base_offset,
		"moist_noise_raw": moist_noise_raw,
		"flow_u": flow_u_vals,
		"flow_v": flow_v_vals,
	}

func evaluate(w: int, h: int,
		height: PackedFloat32Array,
		is_land: PackedByteArray,
		base: Dictionary,
		params: Dictionary,
		distance_to_coast: PackedFloat32Array,
		ocean_frac: float) -> Dictionary:
	_ensure_device_and_pipeline()

	var size: int = max(0, w * h)
	if size == 0:
		return {"temperature": PackedFloat32Array(), "moisture": PackedFloat32Array(), "precip": PackedFloat32Array()}

	# Build climate noise fields on GPU; no CPU fallback in GPU-only mode.
	var xscale: float = float(params.get("noise_x_scale", 1.0))
	var nf: Dictionary = _compute_noise_fields_gpu(w, h, params, xscale)
	if nf.is_empty():
		return {}

	if not _shader.is_valid() or not _pipeline.is_valid():
		return {}

	# Create buffers
	var buf_height: RID = _create_storage_buffer_from_f32(height)
	# Convert land mask to u32 for GLSL uint[]
	var is_land_u32 := PackedInt32Array(); is_land_u32.resize(size)
	for i_mask in range(size):
		is_land_u32[i_mask] = 1 if (i_mask < is_land.size() and is_land[i_mask] != 0) else 0
	var buf_is_land: RID = _rd.storage_buffer_create(is_land_u32.to_byte_array().size(), is_land_u32.to_byte_array())
	var buf_dist: RID = _create_storage_buffer_from_f32(distance_to_coast)
	var buf_temp_noise: RID = _create_storage_buffer_from_f32(nf["temp_noise"])
	var buf_moist_base_offset: RID = _create_storage_buffer_from_f32(nf["moist_noise_base_offset"])
	# moist_raw not used directly in shader; keep only base-offset variant
	var buf_flow_u: RID = _create_storage_buffer_from_f32(nf["flow_u"])
	var buf_flow_v: RID = _create_storage_buffer_from_f32(nf["flow_v"])
	var out_temp := PackedFloat32Array(); out_temp.resize(size)
	var out_moist := PackedFloat32Array(); out_moist.resize(size)
	var out_precip := PackedFloat32Array(); out_precip.resize(size)
	var buf_out_temp: RID = _create_storage_buffer_from_f32(out_temp)
	var buf_out_moist: RID = _create_storage_buffer_from_f32(out_moist)
	var buf_out_precip: RID = _create_storage_buffer_from_f32(out_precip)

	# Bind uniforms (set=0)
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(buf_height); uniforms.append(u0)
	var u1: RDUniform = RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(buf_is_land); uniforms.append(u1)
	var u2: RDUniform = RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u2.binding = 2; u2.add_id(buf_dist); uniforms.append(u2)
	var u3: RDUniform = RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u3.binding = 3; u3.add_id(buf_temp_noise); uniforms.append(u3)
	var u4: RDUniform = RDUniform.new(); u4.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u4.binding = 4; u4.add_id(buf_moist_base_offset); uniforms.append(u4)
	var u5: RDUniform = RDUniform.new(); u5.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u5.binding = 5; u5.add_id(buf_flow_u); uniforms.append(u5)
	var u6: RDUniform = RDUniform.new(); u6.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u6.binding = 6; u6.add_id(buf_flow_v); uniforms.append(u6)
	var u7: RDUniform = RDUniform.new(); u7.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u7.binding = 7; u7.add_id(buf_out_temp); uniforms.append(u7)
	var u8: RDUniform = RDUniform.new(); u8.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u8.binding = 8; u8.add_id(buf_out_moist); uniforms.append(u8)
	var u9: RDUniform = RDUniform.new(); u9.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u9.binding = 9; u9.add_id(buf_out_precip); uniforms.append(u9)

	if not _shader.is_valid():
		return {}
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := _pack_push_constants(w, h, params, ocean_frac)
	# Align to 16 bytes to satisfy Vulkan push constant alignment
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

	# Read back outputs
	var temp_bytes: PackedByteArray = _rd.buffer_get_data(buf_out_temp)
	var moist_bytes: PackedByteArray = _rd.buffer_get_data(buf_out_moist)
	var precip_bytes: PackedByteArray = _rd.buffer_get_data(buf_out_precip)
	var temp_out: PackedFloat32Array = temp_bytes.to_float32_array()
	var moist_out: PackedFloat32Array = moist_bytes.to_float32_array()
	var precip_out: PackedFloat32Array = precip_bytes.to_float32_array()

	# Cleanup transient resources
	_rd.free_rid(uniform_set)
	_rd.free_rid(buf_height)
	_rd.free_rid(buf_is_land)
	_rd.free_rid(buf_dist)
	_rd.free_rid(buf_temp_noise)
	_rd.free_rid(buf_moist_base_offset)
	_rd.free_rid(buf_flow_u)
	_rd.free_rid(buf_flow_v)
	_rd.free_rid(buf_out_temp)
	_rd.free_rid(buf_out_moist)
	_rd.free_rid(buf_out_precip)

	return {
		"temperature": temp_out,
		"moisture": moist_out,
		"precip": precip_out,
	}

# Fast path: apply only seasonal and diurnal cycles to existing temperature
func apply_cycles_only(w: int, h: int,
		current_temperature: PackedFloat32Array,
		is_land: PackedByteArray,
		distance_to_coast: PackedFloat32Array,
		params: Dictionary) -> PackedFloat32Array:
	_ensure_device_and_pipeline()
	
	var size: int = max(0, w * h)
	if size == 0 or not _cycle_pipeline.is_valid():
		return current_temperature
	
	# Convert land mask to u32
	var is_land_u32 := PackedInt32Array(); is_land_u32.resize(size)
	for i in range(size):
		is_land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	
	# Create buffers
	var buf_temp_in: RID = _create_storage_buffer_from_f32(current_temperature)
	var buf_is_land: RID = _rd.storage_buffer_create(is_land_u32.to_byte_array().size(), is_land_u32.to_byte_array())
	var buf_dist: RID = _create_storage_buffer_from_f32(distance_to_coast)
	var out_temp := PackedFloat32Array(); out_temp.resize(size)
	var buf_out_temp: RID = _create_storage_buffer_from_f32(out_temp)
	
	# Bind uniforms
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(buf_temp_in); uniforms.append(u0)
	var u1: RDUniform = RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(buf_is_land); uniforms.append(u1)
	var u2: RDUniform = RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u2.binding = 2; u2.add_id(buf_dist); uniforms.append(u2)
	var u3: RDUniform = RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u3.binding = 3; u3.add_id(buf_out_temp); uniforms.append(u3)
	
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _cycle_shader, 0)
	
	# Pack push constants for cycle shader
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
	
	# Align to 16 bytes
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
	
	# Read back output
	var temp_bytes: PackedByteArray = _rd.buffer_get_data(buf_out_temp)
	var temp_result: PackedFloat32Array = temp_bytes.to_float32_array()
	
	# Cleanup
	_rd.free_rid(uniform_set)
	_rd.free_rid(buf_temp_in)
	_rd.free_rid(buf_is_land)
	_rd.free_rid(buf_dist)
	_rd.free_rid(buf_out_temp)
	
	return temp_result

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

# Evaluate day-night light field
func evaluate_light_field(w: int, h: int, params: Dictionary) -> PackedFloat32Array:
	_ensure_device_and_pipeline()
	
	var size: int = max(0, w * h)
	if size == 0 or not _light_pipeline.is_valid():
		return PackedFloat32Array()
	
	# Create output buffer
	var out_light := PackedFloat32Array(); out_light.resize(size)
	var buf_light: RID = _create_storage_buffer_from_f32(out_light)
	
	# Bind uniforms
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(buf_light); uniforms.append(u0)
	
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _light_shader, 0)
	
	# Pack push constants for light shader
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
	
	# Align to 16 bytes
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
	
	# Read back output
	var light_bytes: PackedByteArray = _rd.buffer_get_data(buf_light)
	var light_result: PackedFloat32Array = light_bytes.to_float32_array()
	
	# Cleanup
	_rd.free_rid(uniform_set)
	_rd.free_rid(buf_light)
	
	return light_result

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
