# File: res://scripts/systems/ComputeShaderBase.gd
extends RefCounted

# Base class for GPU compute shaders - eliminates duplication
# Provides standard initialization, error handling, and resource management

const GPUBufferHelper = preload("res://scripts/systems/GPUBufferHelper.gd")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _shader_file: RDShaderFile
var _shader_name: String

func _init(shader_file: RDShaderFile, name: String = ""):
	_shader_file = shader_file
	_shader_name = name

func _ensure_device_and_pipeline() -> bool:
	"""Standard initialization pattern with error handling"""
	# Get rendering device
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
		if _rd == null:
			push_error("Failed to get RenderingDevice for " + _shader_name)
			return false
	
	# Create shader
	if not _shader.is_valid():
		if not GPUBufferHelper.validate_shader_file(_shader_file, _shader_name):
			return false
		
		var spirv = GPUBufferHelper.get_spirv_safe(_shader_file, _shader_name)
		if spirv == null:
			return false
		
		_shader = _rd.shader_create_from_spirv(spirv)
		if not _shader.is_valid():
			push_error("Failed to create shader: " + _shader_name)
			return false
	
	# Create pipeline
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
		if not _pipeline.is_valid():
			push_error("Failed to create compute pipeline: " + _shader_name)
			return false
	
	return _pipeline.is_valid()

func is_available() -> bool:
	"""Check if compute shader is available and functional"""
	return _ensure_device_and_pipeline()

func get_rendering_device() -> RenderingDevice:
	"""Get the rendering device (ensures initialization)"""
	_ensure_device_and_pipeline()
	return _rd

func get_shader() -> RID:
	"""Get the shader RID (ensures initialization)"""
	_ensure_device_and_pipeline()
	return _shader

func get_pipeline() -> RID:
	"""Get the pipeline RID (ensures initialization)"""
	_ensure_device_and_pipeline()
	return _pipeline

func dispatch_compute(width: int, height: int, uniform_set: RID, push_constants: PackedByteArray = PackedByteArray(), local_size_x: int = 16, local_size_y: int = 16) -> bool:
	"""Standard compute dispatch with error handling"""
	if not _ensure_device_and_pipeline():
		return false
	
	var groups = GPUBufferHelper.calculate_dispatch_groups(width, height, local_size_x, local_size_y)
	
	var cl_id = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl_id, _pipeline)
	_rd.compute_list_bind_uniform_set(cl_id, uniform_set, 0)
	
	if push_constants.size() > 0:
		_rd.compute_list_set_push_constant(cl_id, push_constants, push_constants.size())
	
	_rd.compute_list_dispatch(cl_id, groups.x, groups.y, 1)
	_rd.compute_list_end()
	
	return true

func create_buffers_from_arrays(input_arrays: Array) -> Array:
	"""Create GPU buffers from input arrays (mixed types)"""
	if not _ensure_device_and_pipeline():
		return []
	
	var buffers: Array = []
	for arr in input_arrays:
		var buffer: RID
		if arr is PackedFloat32Array:
			buffer = GPUBufferHelper.create_f32_buffer(_rd, arr)
		elif arr is PackedByteArray:
			buffer = GPUBufferHelper.create_u32_buffer_from_bytes(_rd, arr)
		elif arr is int:
			# Create empty buffer of specified size
			buffer = GPUBufferHelper.create_empty_f32_buffer(_rd, arr)
		else:
			push_warning("Unsupported array type in create_buffers_from_arrays")
			buffer = RID()
		
		buffers.append(buffer)
	
	return buffers

func cleanup_resources(resources: Array) -> void:
	"""Clean up GPU resources safely"""
	if _rd != null:
		GPUBufferHelper.cleanup_resources(_rd, resources)

func _notification(what: int) -> void:
	"""Automatic cleanup on destruction"""
	if what == NOTIFICATION_PREDELETE:
		if _rd != null and _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _rd != null and _shader.is_valid():
			_rd.free_rid(_shader)

# Utility methods for common operations
func read_output_buffer(buffer: RID) -> PackedFloat32Array:
	"""Read float32 data from output buffer"""
	if not _rd or not buffer.is_valid():
		return PackedFloat32Array()
	return GPUBufferHelper.read_f32_buffer(_rd, buffer)

func pack_standard_push_constants(width: int, height: int, params: Dictionary) -> PackedByteArray:
	"""Pack standard push constants for most compute shaders"""
	var float_params := PackedFloat32Array()
	
	# Add common parameters in standard order
	var common_keys = ["sea_level", "temp_base_offset", "temp_scale", "moist_base_offset", "moist_scale"]
	for key in common_keys:
		if key in params:
			float_params.append(float(params[key]))
	
	return GPUBufferHelper.pack_push_constants_basic(width, height, float_params)

# Performance monitoring
func measure_operation(operation_name: String, callable: Callable) -> float:
	"""Measure GPU operation performance"""
	if _rd == null:
		return 0.0
	return GPUBufferHelper.measure_gpu_time(_rd, operation_name, callable)