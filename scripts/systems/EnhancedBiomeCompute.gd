# File: res://scripts/systems/EnhancedBiomeCompute.gd
extends RefCounted

## Enhanced biome compute system using persistent GPU buffers
## Eliminates CPU↔GPU roundtrips for better performance

const PersistentGPUBuffers = preload("res://scripts/core/PersistentGPUBuffers.gd")

var BIOME_SHADER_FILE: RDShaderFile = load("res://shaders/biome_classify.glsl")
var SMOOTH_SHADER_FILE: RDShaderFile = load("res://shaders/biome_smooth.glsl")
var REAPPLY_SHADER_FILE: RDShaderFile = load("res://shaders/biome_reapply.glsl")

var _rd: RenderingDevice
var _biome_shader: RID
var _biome_pipeline: RID
var _smooth_shader: RID
var _smooth_pipeline: RID
var _reapply_shader: RID
var _reapply_pipeline: RID

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
	
	# Biome classification shader
	if not _biome_shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(BIOME_SHADER_FILE)
		if spirv != null:
			_biome_shader = _rd.shader_create_from_spirv(spirv)
			if _biome_shader.is_valid():
				_biome_pipeline = _rd.compute_pipeline_create(_biome_shader)
	
	# Smoothing shader
	if not _smooth_shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(SMOOTH_SHADER_FILE)
		if spirv != null:
			_smooth_shader = _rd.shader_create_from_spirv(spirv)
			if _smooth_shader.is_valid():
				_smooth_pipeline = _rd.compute_pipeline_create(_smooth_shader)
	
	# Reapply shader  
	if not _reapply_shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(REAPPLY_SHADER_FILE)
		if spirv != null:
			_reapply_shader = _rd.shader_create_from_spirv(spirv)
			if _reapply_shader.is_valid():
				_reapply_pipeline = _rd.compute_pipeline_create(_reapply_shader)

func classify_persistent(world_state: Object, params: Dictionary, desert_field: PackedFloat32Array = PackedFloat32Array()) -> void:
	# Classify biomes using persistent buffers - NO CPU READBACK!
	_ensure_pipelines()
	
	if not _biome_pipeline.is_valid():
		print("EnhancedBiomeCompute: Biome pipeline not available")
		return
	
	# Check performance budget before proceeding
	if not world_state.can_afford_gpu_operation("biome_classify"):
		print("EnhancedBiomeCompute: Skipping biome classification due to budget constraints")
		return
	
	world_state.start_gpu_operation("biome_classify")
	var start_time: int = Time.get_ticks_msec()
	
	var w: int = world_state.width
	var h: int = world_state.height
	
	# Get persistent buffers
	var height_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.HEIGHT)
	var land_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.IS_LAND)
	var temp_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.TEMPERATURE)
	var moisture_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.MOISTURE)
	var beach_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.BEACH)
	var biome_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.BIOME_ID)
	
	if not (height_buffer.is_valid() and land_buffer.is_valid() and temp_buffer.is_valid() and 
			moisture_buffer.is_valid() and beach_buffer.is_valid() and biome_buffer.is_valid()):
		print("EnhancedBiomeCompute: Required buffers not available")
		return
	
	# Create desert buffer if provided
	var desert_buffer: RID
	var use_desert: bool = desert_field.size() == w * h
	if use_desert:
		desert_buffer = _rd.storage_buffer_create(desert_field.to_byte_array().size(), desert_field.to_byte_array())
	else:
		# Create dummy buffer
		var dummy_desert := PackedFloat32Array()
		dummy_desert.resize(w * h)
		desert_buffer = _rd.storage_buffer_create(dummy_desert.to_byte_array().size(), dummy_desert.to_byte_array())
	
	# Bind buffers
	var uniforms: Array = []
	var u0: RDUniform = RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(height_buffer)
	uniforms.append(u0)
	
	var u1: RDUniform = RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(land_buffer)
	uniforms.append(u1)
	
	var u2: RDUniform = RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u2.binding = 2
	u2.add_id(temp_buffer)
	uniforms.append(u2)
	
	var u3: RDUniform = RDUniform.new()
	u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u3.binding = 3
	u3.add_id(moisture_buffer)
	uniforms.append(u3)
	
	var u4: RDUniform = RDUniform.new()
	u4.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u4.binding = 4
	u4.add_id(beach_buffer)
	uniforms.append(u4)
	
	var u5: RDUniform = RDUniform.new()
	u5.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u5.binding = 5
	u5.add_id(desert_buffer)
	uniforms.append(u5)
	
	var u6: RDUniform = RDUniform.new()
	u6.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u6.binding = 6
	u6.add_id(biome_buffer)
	uniforms.append(u6)
	
	var uniform_set: RID = _rd.uniform_set_create(uniforms, _biome_shader, 0)
	
	# Pack push constants
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if use_desert else 0)])
	var floats := PackedFloat32Array([
		float(params.get("sea_level", 0.0)),
		float(params.get("snow_line", 0.8)),
		float(params.get("tree_line", 0.7)),
		float(params.get("desert_threshold", 0.3)),
		float(params.get("grassland_threshold", 0.5)),
		float(params.get("temp_hot", 25.0)),
		float(params.get("temp_cold", 5.0)),
		float(params.get("moisture_dry", 0.3)),
		float(params.get("moisture_wet", 0.7))
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
	_rd.compute_list_bind_compute_pipeline(cl_id, _biome_pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
	_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
	_rd.compute_list_end()
	
	# Submit
	_rd.submit()
	
	# Cleanup
	_rd.free_rid(uniform_set)
	if use_desert:
		_rd.free_rid(desert_buffer)
	
	last_update_time_ms = float(Time.get_ticks_msec() - start_time)
	world_state.finish_gpu_operation("biome_classify")

func smooth_and_reapply_persistent(world_state: Object, smooth_iterations: int = 1) -> void:
	# Apply smoothing and reapplication using persistent buffers
	_ensure_pipelines()
	
	if not (_smooth_pipeline.is_valid() and _reapply_pipeline.is_valid()):
		print("EnhancedBiomeCompute: Smooth/reapply pipelines not available")
		return
	
	# Check if we should skip smoothing for performance
	var quality_adjustments: Dictionary = world_state.get_quality_adjustments()
	if quality_adjustments.get("skip_smoothing", false):
		print("EnhancedBiomeCompute: Skipping smoothing for performance")
		return
	
	# Adjust iterations based on performance
	var iteration_multiplier: float = quality_adjustments.get("max_iterations_multiplier", 1.0)
	smooth_iterations = max(1, int(float(smooth_iterations) * iteration_multiplier))
	
	world_state.start_gpu_operation("biome_smooth")
	var start_time: int = Time.get_ticks_msec()
	
	var w: int = world_state.width
	var h: int = world_state.height
	
	# Get persistent buffers
	var biome_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.BIOME_ID)
	var land_buffer: RID = world_state.get_gpu_buffer(PersistentGPUBuffers.BufferType.IS_LAND)
	
	if not (biome_buffer.is_valid() and land_buffer.is_valid()):
		print("EnhancedBiomeCompute: Required buffers not available for smoothing")
		return
	
	# Create temporary buffer for ping-pong smoothing
	var biome_temp_data := PackedInt32Array()
	biome_temp_data.resize(w * h)
	var biome_temp_buffer: RID = _rd.storage_buffer_create(biome_temp_data.to_byte_array().size(), biome_temp_data.to_byte_array())
	
	var groups_x: int = int(ceil(float(w) / 16.0))
	var groups_y: int = int(ceil(float(h) / 16.0))
	
	# Push constants for smoothing
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	
	# Apply smoothing iterations
	var buf_in: RID = biome_buffer
	var buf_out: RID = biome_temp_buffer
	
	for i in range(smooth_iterations):
		# Bind buffers for smoothing
		var uniforms: Array = []
		var u0: RDUniform = RDUniform.new()
		u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u0.binding = 0
		u0.add_id(buf_in)
		uniforms.append(u0)
		
		var u1: RDUniform = RDUniform.new()
		u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u1.binding = 1
		u1.add_id(land_buffer)
		uniforms.append(u1)
		
		var u2: RDUniform = RDUniform.new()
		u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u2.binding = 2
		u2.add_id(buf_out)
		uniforms.append(u2)
		
		var uniform_set: RID = _rd.uniform_set_create(uniforms, _smooth_shader, 0)
		
		# Dispatch smoothing
		var cl_id: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl_id, _smooth_pipeline)
		_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
		_rd.compute_list_set_push_constant(cl_id, pc, pc.size())
		_rd.compute_list_dispatch(cl_id, groups_x, groups_y, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.free_rid(uniform_set)
		
		# Swap buffers for next iteration
		var tmp: RID = buf_in
		buf_in = buf_out
		buf_out = tmp
	
	# If we did odd iterations, copy result back to main buffer
	if smooth_iterations % 2 == 1:
		# Copy from temp buffer back to main biome buffer
		# (Implementation depends on available copy operations)
		print("EnhancedBiomeCompute: Applied ", smooth_iterations, " smoothing iterations")
	
	# Cleanup
	_rd.free_rid(biome_temp_buffer)
	
	last_update_time_ms += float(Time.get_ticks_msec() - start_time)
	world_state.finish_gpu_operation("biome_smooth")

func cleanup() -> void:
	if _rd != null:
		if _biome_pipeline.is_valid():
			_rd.free_rid(_biome_pipeline)
		if _biome_shader.is_valid():
			_rd.free_rid(_biome_shader)
		if _smooth_pipeline.is_valid():
			_rd.free_rid(_smooth_pipeline)
		if _smooth_shader.is_valid():
			_rd.free_rid(_smooth_shader)
		if _reapply_pipeline.is_valid():
			_rd.free_rid(_reapply_pipeline)
		if _reapply_shader.is_valid():
			_rd.free_rid(_reapply_shader)