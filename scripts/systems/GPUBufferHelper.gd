# File: res://scripts/systems/GPUBufferHelper.gd
extends RefCounted

# GPU Buffer Helper - Eliminates code duplication across compute shaders
# Provides standardized buffer creation and management utilities

static func create_f32_buffer(rd: RenderingDevice, data: PackedFloat32Array) -> RID:
	"""Create storage buffer from float32 array"""
	if data.size() == 0:
		return RID()
	var bytes := data.to_byte_array()
	return rd.storage_buffer_create(bytes.size(), bytes)

static func create_u32_buffer_from_bytes(rd: RenderingDevice, data: PackedByteArray) -> RID:
	"""Create storage buffer from byte array (converted to u32 in shader)"""
	if data.size() == 0:
		return RID()
	# Convert byte array to u32 array for proper shader access
	var u32_data := PackedInt32Array()
	u32_data.resize(data.size())
	for i in range(data.size()):
		u32_data[i] = 1 if data[i] != 0 else 0
	return rd.storage_buffer_create(u32_data.to_byte_array().size(), u32_data.to_byte_array())

static func create_empty_f32_buffer(rd: RenderingDevice, size: int) -> RID:
	"""Create empty float32 buffer for output"""
	if size <= 0:
		return RID()
	var empty_data := PackedFloat32Array()
	empty_data.resize(size)
	empty_data.fill(0.0)
	return create_f32_buffer(rd, empty_data)

static func create_uniform_buffer_set(rd: RenderingDevice, shader: RID, buffers: Array) -> RID:
	"""Create uniform set from array of buffer RIDs"""
	var uniforms: Array = []
	for i in range(buffers.size()):
		if buffers[i] is RID and buffers[i].is_valid():
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			uniform.binding = i
			uniform.add_id(buffers[i])
			uniforms.append(uniform)
	return rd.uniform_set_create(uniforms, shader, 0)

static func pack_push_constants_basic(width: int, height: int, float_params: PackedFloat32Array = PackedFloat32Array()) -> PackedByteArray:
	"""Pack basic push constants with width, height, and optional float parameters"""
	var pc := PackedByteArray()
	var ints := PackedInt32Array([width, height])
	pc.append_array(ints.to_byte_array())
	if float_params.size() > 0:
		pc.append_array(float_params.to_byte_array())
	
	# Align to 16-byte boundary for Vulkan
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)
	
	return pc

static func calculate_dispatch_groups(width: int, height: int, local_size_x: int = 16, local_size_y: int = 16) -> Vector2i:
	"""Calculate dispatch group counts for given dimensions and local work group size"""
	var groups_x: int = int(ceil(float(width) / float(local_size_x)))
	var groups_y: int = int(ceil(float(height) / float(local_size_y)))
	return Vector2i(groups_x, groups_y)

static func read_f32_buffer(rd: RenderingDevice, buffer: RID) -> PackedFloat32Array:
	"""Read float32 data from GPU buffer"""
	if not buffer.is_valid():
		return PackedFloat32Array()
	var bytes: PackedByteArray = rd.buffer_get_data(buffer)
	return bytes.to_float32_array()

static func cleanup_buffers(rd: RenderingDevice, buffers: Array) -> void:
	"""Clean up array of GPU buffer RIDs"""
	for buffer in buffers:
		if buffer is RID and buffer.is_valid():
			rd.free_rid(buffer)

static func cleanup_resources(rd: RenderingDevice, resources: Array) -> void:
	"""Clean up mixed GPU resources (buffers, uniform sets, pipelines, shaders)"""
	for resource in resources:
		if resource is RID and resource.is_valid():
			rd.free_rid(resource)

# Error handling utilities
static func validate_shader_file(file: RDShaderFile, name: String = "") -> bool:
	"""Validate shader file and log errors"""
	if file == null:
		push_error("Shader file is null: " + name)
		return false
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		push_error("No shader versions available: " + name)
		return false
	return true

static func get_spirv_safe(file: RDShaderFile, name: String = "") -> RDShaderSPIRV:
	"""Safely get SPIRV from shader file with error handling"""
	if not validate_shader_file(file, name):
		return null
	
	var versions: Array = file.get_version_list()
	var chosen_version = versions[0]
	
	# Prefer Vulkan version if available
	for v in versions:
		if String(v) == "vulkan":
			chosen_version = v
			break
	
	var spirv = file.get_spirv(chosen_version)
	if spirv == null:
		push_error("Failed to get SPIRV from shader: " + name)
	
	return spirv

# Performance monitoring
static func measure_gpu_time(rd: RenderingDevice, operation_name: String, callable: Callable) -> float:
	"""Measure GPU operation time (rough estimate using CPU time)"""
	var start_time = Time.get_ticks_usec()
	callable.call()
	rd.submit()  # Ensure GPU work is submitted
	rd.barrier()  # Wait for completion (expensive but accurate)
	var end_time = Time.get_ticks_usec()
	var elapsed_ms = float(end_time - start_time) / 1000.0
	# debug removed
	return elapsed_ms