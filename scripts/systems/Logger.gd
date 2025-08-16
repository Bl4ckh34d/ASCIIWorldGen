# File: res://scripts/systems/Logger.gd
extends RefCounted

# Centralized logging system to replace debug prints
# Provides configurable log levels and performance monitoring

enum LogLevel {
	DEBUG = 0,
	INFO = 1,
	WARNING = 2,
	ERROR = 3,
	PERFORMANCE = 4
}

static var current_level: LogLevel = LogLevel.INFO
static var performance_enabled: bool = false

static func set_log_level(level: LogLevel) -> void:
	current_level = level

static func enable_performance_logging(enabled: bool) -> void:
	performance_enabled = enabled

static func debug(message: String, context: String = "") -> void:
	_log(LogLevel.DEBUG, message, context)

static func info(message: String, context: String = "") -> void:
	_log(LogLevel.INFO, message, context)

static func warning(message: String, context: String = "") -> void:
	_log(LogLevel.WARNING, message, context)

static func error(message: String, context: String = "") -> void:
	_log(LogLevel.ERROR, message, context)

static func performance(message: String, context: String = "") -> void:
	if performance_enabled:
		_log(LogLevel.PERFORMANCE, message, context)

static func _log(level: LogLevel, message: String, context: String) -> void:
	if level < current_level:
		return
	
	var prefix: String
	match level:
		LogLevel.DEBUG:
			prefix = "[DEBUG]"
		LogLevel.INFO:
			prefix = "[INFO]"
		LogLevel.WARNING:
			prefix = "[WARN]"
		LogLevel.ERROR:
			prefix = "[ERROR]"
		LogLevel.PERFORMANCE:
			prefix = "[PERF]"
	
	var full_message = prefix
	if context != "":
		full_message += " [" + context + "]"
	full_message += " " + message
	
	print(full_message)

# Performance measurement utilities
static func measure_time(operation_name: String, callable: Callable, context: String = "") -> float:
	var start_time = Time.get_ticks_usec()
	callable.call()
	var end_time = Time.get_ticks_usec()
	var elapsed_ms = float(end_time - start_time) / 1000.0
	
	performance("Operation '%s' took %.2f ms" % [operation_name, elapsed_ms], context)
	return elapsed_ms

# Memory usage monitoring
static func log_memory_usage(operation: String, context: String = "") -> void:
	# Godot 4: approximate using Performance monitor (static memory)
	var total_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0)
	performance("Memory after %s: %.1f MB peak" % [operation, total_mb], context)