# File: res://scripts/core/ErrorHandler.gd
class_name ErrorHandler
extends RefCounted

# Standardized error handling patterns for the world generation system
# Provides consistent error reporting, recovery, and logging

enum ErrorSeverity {
	INFO = 0,
	WARNING = 1,
	ERROR = 2,
	CRITICAL = 3
}

enum ErrorCode {
	NONE = 0,
	
	# GPU/Rendering errors
	GPU_UNAVAILABLE = 1000,
	SHADER_LOAD_FAILED = 1001,
	PIPELINE_CREATE_FAILED = 1002,
	BUFFER_CREATE_FAILED = 1003,
	
	# Memory errors
	OUT_OF_MEMORY = 2000,
	ARRAY_SIZE_MISMATCH = 2001,
	INVALID_DIMENSIONS = 2002,
	
	# File/Resource errors
	FILE_NOT_FOUND = 3000,
	RESOURCE_LOAD_FAILED = 3001,
	CHECKPOINT_CORRUPTED = 3002,
	
	# Simulation errors
	WORLD_GENERATION_FAILED = 4000,
	CLIMATE_COMPUTE_FAILED = 4001,
	SYSTEM_TIMEOUT = 4002,
	
	# Configuration errors
	INVALID_CONFIG = 5000,
	PARAMETER_OUT_OF_RANGE = 5001,
	SEED_INVALID = 5002
}

class ErrorResult:
	var success: bool = false
	var error_code: ErrorCode = ErrorCode.NONE
	var severity: ErrorSeverity = ErrorSeverity.INFO
	var message: String = ""
	var context: String = ""
	var recovery_suggested: bool = false
	var recovery_message: String = ""
	
	func _init(p_success: bool, p_code: ErrorCode = ErrorCode.NONE, p_message: String = "", p_context: String = "", p_severity: ErrorSeverity = ErrorSeverity.INFO):
		success = p_success
		error_code = p_code
		message = p_message
		context = p_context
		severity = p_severity
	
	func set_recovery(recovery_msg: String) -> ErrorResult:
		recovery_suggested = true
		recovery_message = recovery_msg
		return self
	
	func log() -> void:
		ErrorHandler.log_error(self)

# Static error handling functions
const WorldConstants = preload("res://scripts/core/WorldConstants.gd")
static func success(message: String = "") -> ErrorResult:
	"""Create a success result"""
	return ErrorResult.new(true, ErrorCode.NONE, message)

static func error(code: ErrorCode, message: String, context: String = "", severity: ErrorSeverity = ErrorSeverity.ERROR) -> ErrorResult:
	"""Create an error result"""
	return ErrorResult.new(false, code, message, context, severity)

static func gpu_unavailable(context: String = "") -> ErrorResult:
	"""Standard GPU unavailable error"""
	return error(ErrorCode.GPU_UNAVAILABLE, "GPU compute unavailable - falling back to CPU", context, ErrorSeverity.WARNING).set_recovery("Check GPU drivers and Vulkan support")

static func shader_failed(shader_name: String, details: String = "") -> ErrorResult:
	"""Standard shader loading failure"""
	var msg = "Failed to load shader: " + shader_name
	if details != "":
		msg += " (" + details + ")"
	return error(ErrorCode.SHADER_LOAD_FAILED, msg, "ShaderLoader", ErrorSeverity.ERROR).set_recovery("Check shader file exists and is valid GLSL")

static func memory_error(operation: String, size_mb: float = 0.0) -> ErrorResult:
	"""Standard memory allocation error"""
	var msg = "Memory allocation failed during: " + operation
	if size_mb > 0.0:
		msg += " (%.1f MB)" % size_mb
	return error(ErrorCode.OUT_OF_MEMORY, msg, "MemoryManager", ErrorSeverity.CRITICAL).set_recovery("Reduce world size or close other applications")

static func array_size_mismatch(expected: int, actual: int, context: String = "") -> ErrorResult:
	"""Standard array size mismatch error"""
	var msg = "Array size mismatch: expected %d, got %d" % [expected, actual]
	return error(ErrorCode.ARRAY_SIZE_MISMATCH, msg, context, ErrorSeverity.ERROR).set_recovery("Regenerate world data or check system compatibility")

static func file_not_found(path: String) -> ErrorResult:
	"""Standard file not found error"""
	return error(ErrorCode.FILE_NOT_FOUND, "File not found: " + path, "FileSystem", ErrorSeverity.ERROR).set_recovery("Check file path and permissions")

static func world_generation_failed(stage: String, details: String = "") -> ErrorResult:
	"""Standard world generation failure"""
	var msg = "World generation failed at stage: " + stage
	if details != "":
		msg += " - " + details
	return error(ErrorCode.WORLD_GENERATION_FAILED, msg, "WorldGenerator", ErrorSeverity.ERROR).set_recovery("Try different seed or reduce world complexity")

static func invalid_config(parameter: String, value: String, expected: String = "") -> ErrorResult:
	"""Standard configuration error"""
	var msg = "Invalid configuration: %s = %s" % [parameter, value]
	if expected != "":
		msg += " (expected: " + expected + ")"
	return error(ErrorCode.INVALID_CONFIG, msg, "Configuration", ErrorSeverity.WARNING).set_recovery("Reset to default values or check parameter ranges")

static func log_error(err: ErrorResult) -> void:
	"""Log error with appropriate severity"""
	var prefix: String
	match err.severity:
		ErrorSeverity.INFO:
			prefix = "[INFO]"
		ErrorSeverity.WARNING:
			prefix = "[WARN]"
		ErrorSeverity.ERROR:
			prefix = "[ERROR]"
		ErrorSeverity.CRITICAL:
			prefix = "[CRITICAL]"
	
	var full_message = prefix
	if err.context != "":
		full_message += " [" + err.context + "]"
	full_message += " " + err.message
	if err.error_code != ErrorCode.NONE:
		full_message += " (Code: " + str(err.error_code) + ")"
	
	# Use appropriate Godot logging function
	match err.severity:
		ErrorSeverity.INFO:
			# print removed
			push_warning(full_message)
		ErrorSeverity.WARNING:
			push_warning(full_message)
		ErrorSeverity.ERROR, ErrorSeverity.CRITICAL:
			push_error(full_message)
	
	# Log recovery suggestion if available
	if err.recovery_suggested:
		push_warning("  → Recovery: " + err.recovery_message)

# Validation functions
static func validate_world_dimensions(width: int, height: int) -> ErrorResult:
	"""Validate world dimensions"""
	if width <= 0 or height <= 0:
		return invalid_config("world_dimensions", "%dx%d" % [width, height], "positive integers")
	
	var total_cells = width * height
	if total_cells > WorldConstants.MAX_WORLD_CELLS:
		return invalid_config("world_size", str(total_cells), "max " + str(WorldConstants.MAX_WORLD_CELLS) + " cells")
	
	return success("World dimensions valid")

static func validate_array_sizes(arrays: Dictionary, expected_size: int) -> ErrorResult:
	"""Validate multiple arrays have expected size"""
	for name in arrays:
		var arr = arrays[name]
		var size = 0
		if arr is PackedFloat32Array or arr is PackedByteArray or arr is PackedInt32Array:
			size = arr.size()
		
		if size != expected_size:
			return array_size_mismatch(expected_size, size, "Array: " + name)
	
	return success("All arrays have correct size")

static func validate_temperature_range(temp_min: float, temp_max: float) -> ErrorResult:
	"""Validate temperature range is reasonable"""
	if temp_min >= temp_max:
		return invalid_config("temperature_range", "min=%.1f, max=%.1f" % [temp_min, temp_max], "min < max")
	
	if temp_min < -100.0 or temp_max > 200.0:
		return invalid_config("temperature_range", "min=%.1f, max=%.1f" % [temp_min, temp_max], "reasonable Earth-like values")
	
	return success("Temperature range valid")

# Recovery functions
static func attempt_gpu_fallback(operation_name: String, cpu_callable: Callable) -> ErrorResult:
	"""Attempt CPU fallback when GPU operation fails"""
	if cpu_callable.is_valid():
		cpu_callable.call()
		log_error(gpu_unavailable("During " + operation_name))
		return success("CPU fallback successful for: " + operation_name)
	return error(ErrorCode.SYSTEM_TIMEOUT, "Both GPU and CPU fallback failed for: " + operation_name, "FallbackSystem", ErrorSeverity.CRITICAL)

static func attempt_memory_recovery(operation: String, reduce_callable: Callable) -> ErrorResult:
	"""Attempt to recover from memory issues"""
	# Force garbage collection (approximate via Performance monitor)
	var before_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0)
	
	# Call system cleanup
	if reduce_callable.is_valid():
		reduce_callable.call()
	
	# Force GC again (re-check static memory)
	var after_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0)
	var freed_mb = before_mb - after_mb
	
	if freed_mb > 0:
		return success("Memory recovery freed %.1f MB for: %s" % [freed_mb, operation])
	else:
		return memory_error("Recovery failed for: " + operation)

# Error reporting for specific systems
class GPUSystemError extends ErrorResult:
	var shader_name: String = ""
	var gpu_available: bool = false
	
	func _init(p_shader: String, p_gpu_available: bool, p_message: String):
		super(false, ErrorCode.SHADER_LOAD_FAILED, p_message, "GPU System", ErrorSeverity.ERROR)
		shader_name = p_shader
		gpu_available = p_gpu_available

class ValidationError extends ErrorResult:
	var parameter_name: String = ""
	var actual_value: String = ""
	var expected_value: String = ""
	
	func _init(p_param: String, p_actual: String, p_expected: String):
		super(false, ErrorCode.PARAMETER_OUT_OF_RANGE, "Parameter validation failed", "Validation", ErrorSeverity.WARNING)
		parameter_name = p_param
		actual_value = p_actual
		expected_value = p_expected
		message = "%s: got '%s', expected '%s'" % [parameter_name, actual_value, expected_value]