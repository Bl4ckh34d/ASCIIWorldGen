# File: res://scripts/systems/ClimateAdjustCompute.gd
extends RefCounted

## GPU ClimateAdjust using Godot 4 RenderingDevice and a compute shader.
## CPU fallback kept by caller.

const CLIMATE_SHADER_FILE := preload("res://shaders/climate_adjust.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

func _ensure_device_and_pipeline() -> void:
	if _rd == null:
		# Create isolated compute device; avoids interfering with main renderer
		_rd = RenderingServer.create_local_rendering_device()
	if not _shader.is_valid():
		# Ensure shader import resource exists and has compute entry
		var spirv: RDShaderSPIRV = CLIMATE_SHADER_FILE.get_spirv("vulkan")
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

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
	])
	arr.append_array(ints.to_byte_array())
	arr.append_array(floats.to_byte_array())
	return arr

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

	# Build noise fields once on CPU; upload as buffers
	var xscale: float = float(params.get("noise_x_scale", 1.0))
	var nf: Dictionary = _compute_noise_fields(w, h, base, xscale)

	if not _shader.is_valid() or not _pipeline.is_valid():
		return {}

	# Create buffers
	var buf_height: RID = _create_storage_buffer_from_f32(height)
	var buf_is_land: RID = _create_storage_buffer_from_u8(is_land)
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

	var groups_x: int = int(ceil(float(w) / 16.0))
	var groups_y: int = int(ceil(float(h) / 16.0))

	var cl_id: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_id, _pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
	_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

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
