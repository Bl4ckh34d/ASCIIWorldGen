# File: res://scripts/systems/GPUBufferHelper.gd
extends RefCounted

# GPU Buffer Helper - Eliminates code duplication across compute shaders
# Provides standardized buffer creation and management utilities

const Log = preload("res://scripts/systems/Logger.gd")

static func _validate_rd(rd: RenderingDevice, label: String) -> bool:
	if rd == null:
		push_error("GPUBufferHelper.%s: RenderingDevice is null." % label)
		return false
	return true

static func _validate_non_negative(size: int, label: String) -> bool:
	if size < 0:
		push_error("GPUBufferHelper.%s: size must be non-negative (got %d)." % [label, size])
		return false
	return true

static func _byte_mask_to_u32_array(data: PackedByteArray) -> PackedInt32Array:
	# Fast path for empty input.
	var out := PackedInt32Array()
	var n: int = data.size()
	if n <= 0:
		return out
	out.resize(n)
	# Convert 8 bytes per outer iteration to reduce loop overhead in GDScript.
	var i: int = 0
	var limit8: int = n - (n % 8)
	while i < limit8:
		out[i] = 1 if data[i] != 0 else 0
		out[i + 1] = 1 if data[i + 1] != 0 else 0
		out[i + 2] = 1 if data[i + 2] != 0 else 0
		out[i + 3] = 1 if data[i + 3] != 0 else 0
		out[i + 4] = 1 if data[i + 4] != 0 else 0
		out[i + 5] = 1 if data[i + 5] != 0 else 0
		out[i + 6] = 1 if data[i + 6] != 0 else 0
		out[i + 7] = 1 if data[i + 7] != 0 else 0
		i += 8
	while i < n:
		out[i] = 1 if data[i] != 0 else 0
		i += 1
	return out

static func bytes_to_u32_mask(data: PackedByteArray) -> PackedInt32Array:
	"""Convert 0/!=0 bytes into 0/1 int32 mask values."""
	return _byte_mask_to_u32_array(data)

static func create_f32_buffer(rd: RenderingDevice, data: PackedFloat32Array) -> RID:
	"""Create storage buffer from float32 array"""
	if not _validate_rd(rd, "create_f32_buffer"):
		return RID()
	if data.size() == 0:
		return RID()
	var bytes := data.to_byte_array()
	if bytes.size() != data.size() * 4:
		push_error("GPUBufferHelper.create_f32_buffer: byte size mismatch.")
		return RID()
	return rd.storage_buffer_create(bytes.size(), bytes)

static func create_u32_buffer_from_bytes(rd: RenderingDevice, data: PackedByteArray) -> RID:
	"""Create storage buffer from byte array (converted to u32 in shader)"""
	if not _validate_rd(rd, "create_u32_buffer_from_bytes"):
		return RID()
	if data.size() == 0:
		return RID()
	var u32_data: PackedInt32Array = _byte_mask_to_u32_array(data)
	var u32_bytes: PackedByteArray = u32_data.to_byte_array()
	if u32_bytes.size() != data.size() * 4:
		push_error("GPUBufferHelper.create_u32_buffer_from_bytes: byte size mismatch.")
		return RID()
	return rd.storage_buffer_create(u32_bytes.size(), u32_bytes)

static func create_empty_f32_buffer(rd: RenderingDevice, size: int) -> RID:
	"""Create empty float32 buffer for output"""
	if not _validate_rd(rd, "create_empty_f32_buffer"):
		return RID()
	if not _validate_non_negative(size, "create_empty_f32_buffer"):
		return RID()
	if size <= 0:
		return RID()
	var empty_data := PackedFloat32Array()
	empty_data.resize(size)
	empty_data.fill(0.0)
	return create_f32_buffer(rd, empty_data)

static func create_uniform_buffer_set(rd: RenderingDevice, shader: RID, buffers: Array) -> RID:
	"""Create uniform set from array of buffer RIDs"""
	if not _validate_rd(rd, "create_uniform_buffer_set"):
		return RID()
	if not (shader is RID and shader.is_valid()):
		push_error("GPUBufferHelper.create_uniform_buffer_set: shader RID invalid.")
		return RID()
	var uniforms: Array = []
	var expected_binding: int = 0
	for i in range(buffers.size()):
		if not (buffers[i] is RID and buffers[i].is_valid()):
			push_error("GPUBufferHelper.create_uniform_buffer_set: invalid buffer at binding %d." % i)
			return RID()
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = expected_binding
		uniform.add_id(buffers[i])
		uniforms.append(uniform)
		expected_binding += 1
	if uniforms.is_empty():
		push_error("GPUBufferHelper.create_uniform_buffer_set: empty buffer list.")
		return RID()
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
	if not _validate_rd(rd, "read_f32_buffer"):
		return PackedFloat32Array()
	if not buffer.is_valid():
		return PackedFloat32Array()
	var bytes: PackedByteArray = rd.buffer_get_data(buffer)
	if bytes.size() % 4 != 0:
		push_warning("GPUBufferHelper.read_f32_buffer: byte size not aligned to 4 (%d)." % bytes.size())
		return PackedFloat32Array()
	return bytes.to_float32_array()

static func cleanup_buffers(rd: RenderingDevice, buffers: Array) -> void:
	"""Clean up array of GPU buffer RIDs"""
	if rd == null:
		return
	for buffer in buffers:
		if buffer is RID and buffer.is_valid():
			rd.free_rid(buffer)

static func cleanup_resources(rd: RenderingDevice, resources: Array) -> void:
	"""Clean up mixed GPU resources (buffers, uniform sets, pipelines, shaders)"""
	if rd == null:
		return
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
	var chosen_version: Variant = null
	
	# Prefer Vulkan version if available
	for v in versions:
		if v == null:
			continue
		if chosen_version == null:
			chosen_version = v
		if String(v) == "vulkan":
			chosen_version = v
			break
	if chosen_version == null:
		push_error("No non-null shader version available: " + name)
		return null
	
	var spirv = file.get_spirv(chosen_version)
	if spirv == null:
		push_error("Failed to get SPIRV from shader: " + name)
	
	return spirv

# Performance monitoring
static func measure_gpu_time(rd: RenderingDevice, operation_name: String, callable: Callable) -> float:
	"""Measure GPU operation time (rough estimate using CPU time)"""
	if rd == null:
		return -1.0
	var allow_barrier: bool = OS.is_debug_build() or VariantCasts.to_bool(Log.performance_enabled)
	var is_main_rd: bool = false
	var main_rd: RenderingDevice = RenderingServer.get_rendering_device()
	if main_rd != null and rd == main_rd:
		is_main_rd = true
	var start_time = Time.get_ticks_usec()
	callable.call()
	# submit/sync are only valid on local RenderingDevice instances in Godot 4.6.
	if not is_main_rd:
		rd.submit()
	if allow_barrier and not is_main_rd:
		# Only block in debug/perf mode; barriers can stall the whole frame.
		rd.barrier()
	var end_time = Time.get_ticks_usec()
	var elapsed_ms = float(end_time - start_time) / 1000.0
	if allow_barrier:
		Log.event_kv(Log.LogLevel.PERFORMANCE, "gpu", operation_name, "ok", -1, elapsed_ms)
	return elapsed_ms
