# File: res://scripts/systems/EnhancedClimateCompute.gd
extends RefCounted

## Enhanced climate compute system using persistent GPU buffers
## Eliminates CPU↔GPU roundtrips for game-like performance

const PersistentGPUBuffers = preload("res://scripts/core/PersistentGPUBuffers.gd")

var CLIMATE_SHADER_FILE: RDShaderFile = load("res://shaders/climate_adjust.glsl")
var CYCLE_APPLY_SHADER_FILE: RDShaderFile = load("res://shaders/cycle_apply.glsl")
var DAY_NIGHT_LIGHT_SHADER_FILE: RDShaderFile = load("res://shaders/day_night_light.glsl")

var _rd: RenderingDevice
var _climate_shader: RID
var _climate_pipeline: RID
var _cycle_shader: RID
var _cycle_pipeline: RID
var _light_shader: RID
var _light_pipeline: RID

# Performance tracking
var last_update_time_ms: float = 0.0

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

func _ensure_pipelines() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	
	# Climate shader
	if not _climate_shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(CLIMATE_SHADER_FILE)
		if spirv != null:
			_climate_shader = _rd.shader_create_from_spirv(spirv)
			if _climate_shader.is_valid():
				_climate_pipeline = _rd.compute_pipeline_create(_climate_shader)
	
	# Cycle shader
	if not _cycle_shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(CYCLE_APPLY_SHADER_FILE)
		if spirv != null:
			_cycle_shader = _rd.shader_create_from_spirv(spirv)
			if _cycle_shader.is_valid():
				_cycle_pipeline = _rd.compute_pipeline_create(_cycle_shader)
	
	# Light shader
	if not _light_shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(DAY_NIGHT_LIGHT_SHADER_FILE)
		if spirv != null:
			_light_shader = _rd.shader_create_from_spirv(spirv)
			if _light_shader.is_valid():
				_light_pipeline = _rd.compute_pipeline_create(_light_shader)

func update_light_field_persistent(world_state: Object, params: Dictionary) -> void:
	# Update day-night lighting using persistent buffers - NO CPU READBACK!
	_ensure_pipelines()
	
	if not _light_pipeline.is_valid():
		print("EnhancedClimateCompute: Light pipeline not available")
		return
	
	var start_time: int = Time.get_ticks_msec()
	
	var w: int = world_state.width
	var h: int = world_state.height
	
	# Get persistent light buffer
	var light_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.LIGHT)
	if not light_buffer.is_valid():
		print("EnhancedClimateCompute: Light buffer not available")
		return
	
	# Bind light buffer
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(light_buffer)
	uniforms.append(u0)
	
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _light_shader, 0)
	
	# Pack push constants
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var time_of_day_val: float = float(params.get("time_of_day", 0.0))
	var floats := PackedFloat32Array([
		float(params.get("season_phase", 0.0)),  # day_of_year
		time_of_day_val,
		float(params.get("day_night_base", 0.25)),
		float(params.get("day_night_contrast", 0.75)),
	])
	
	# Debug: Print time_of_day values occasionally
	if int(time_of_day_val * 100) % 10 == 0:  # Every 0.1 time units
		print("EnhancedClimateCompute: time_of_day=", time_of_day_val)
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	
	# Align to 16 bytes
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	
	var groups_x: int = int(ceil(float(w) / 16.0))
	var groups_y: int = int(ceil(float(h) / 16.0))
	
	# Dispatch compute
	var cl_id: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_id, _light_pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
	_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
	_rd.compute_list_end()
	
	# Submit - no wait needed in Godot 4
	_rd.submit()
	
	# Cleanup
	_rd.free_rid(uniform_set)
	
	last_update_time_ms = float(Time.get_ticks_msec() - start_time)

func apply_cycles_only_persistent(world_state: Object, params: Dictionary) -> void:
	# Apply seasonal/diurnal cycles using persistent buffers - NO CPU READBACK!
	_ensure_pipelines()
	
	if not _cycle_pipeline.is_valid():
		print("EnhancedClimateCompute: Cycle pipeline not available")
		return
	
	var start_time: int = Time.get_ticks_msec()
	
	var w: int = world_state.width
	var h: int = world_state.height
	
	# Get persistent buffers
	var temp_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.TEMPERATURE)
	var land_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.IS_LAND)
	var dist_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.DISTANCE)
	
	if not (temp_buffer.is_valid() and land_buffer.is_valid() and dist_buffer.is_valid()):
		print("EnhancedClimateCompute: Required buffers not available")
		return
	
	# Bind buffers
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(temp_buffer)
	uniforms.append(u0)
	
	var u1: RDUniform = RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(land_buffer)
	uniforms.append(u1)
	
	var u2: RDUniform = RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u2.binding = 2
	u2.add_id(dist_buffer)
	uniforms.append(u2)
	
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _cycle_shader, 0)
	
	# Pack push constants for cycle shader
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([
		float(params.get("continentality_scale", 1.0)),
		float(params.get("season_phase", 0.0)),
		float(params.get("season_amp_equator", 0.0)),
		float(params.get("season_amp_pole", 0.0)),
		float(params.get("season_ocean_damp", 0.0)),
		float(params.get("diurnal_amp_equator", 0.0)),
		float(params.get("diurnal_amp_pole", 0.0)),
		float(params.get("diurnal_ocean_damp", 0.0)),
		float(params.get("time_of_day", 0.0)),
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
	
	# Dispatch compute
	var cl_id: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_id, _cycle_pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
	_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
	_rd.compute_list_end()
	
	# Submit
	_rd.submit()
	
	# Cleanup
	_rd.free_rid(uniform_set)
	
	last_update_time_ms += float(Time.get_ticks_msec() - start_time)

func cleanup() -> void:
	if _rd != null:
		if _climate_pipeline.is_valid():
			_rd.free_rid(_climate_pipeline)
		if _climate_shader.is_valid():
			_rd.free_rid(_climate_shader)
		if _cycle_pipeline.is_valid():
			_rd.free_rid(_cycle_pipeline)
		if _cycle_shader.is_valid():
			_rd.free_rid(_cycle_shader)
		if _light_pipeline.is_valid():
			_rd.free_rid(_light_pipeline)
		if _light_shader.is_valid():
			_rd.free_rid(_light_shader)
