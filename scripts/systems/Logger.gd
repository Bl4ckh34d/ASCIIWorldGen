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
static var json_enabled: bool = true

static func set_log_level(level: LogLevel) -> void:
	current_level = level

static func enable_performance_logging(enabled: bool) -> void:
	performance_enabled = enabled

static func enable_json_logging(enabled: bool) -> void:
	json_enabled = enabled

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
	
	# central logger; route to Godot warnings for visibility without spam
	push_warning(full_message)

static func _level_name(level: LogLevel) -> String:
	match level:
		LogLevel.DEBUG:
			return "debug"
		LogLevel.INFO:
			return "info"
		LogLevel.WARNING:
			return "warn"
		LogLevel.ERROR:
			return "error"
		LogLevel.PERFORMANCE:
			return "perf"
	return "info"

static func event(level: LogLevel, fields: Dictionary) -> void:
	# Structured JSON logging for perf plans. Keep keys stable for downstream tooling.
	if level < current_level:
		return
	if not json_enabled:
		_log(level, JSON.stringify(fields), "json")
		return
	var out: Dictionary = fields.duplicate(true)
	if not out.has("module"):
		out["module"] = "generic"
	if not out.has("op"):
		out["op"] = "event"
	if not out.has("status"):
		out["status"] = "ok"
	if not out.has("bytes"):
		out["bytes"] = -1
	if not out.has("ms"):
		out["ms"] = -1.0
	out["ts_msec"] = int(Time.get_ticks_msec())
	out["level"] = _level_name(level)
	if not out.has("rd_available"):
		out["rd_available"] = (RenderingServer.get_rendering_device() != null)
	var line: String = JSON.stringify(out)
	if level == LogLevel.ERROR:
		push_error(line)
	elif level == LogLevel.WARNING:
		push_warning(line)
	else:
		print(line)

static func event_kv(
	level: LogLevel,
	module: String,
	op: String,
	status: String = "ok",
	bytes: int = -1,
	ms: float = -1.0,
	extra: Dictionary = {}
) -> void:
	var d: Dictionary = {
		"module": module,
		"op": op,
		"status": status,
	}
	if bytes >= 0:
		d["bytes"] = int(bytes)
	if ms >= 0.0:
		d["ms"] = float(ms)
	for k in extra.keys():
		d[k] = extra[k]
	event(level, d)

# Performance measurement utilities
static func measure_time(operation_name: String, callable: Callable, context: String = "") -> float:
	var start_time = Time.get_ticks_usec()
	callable.call()
	var end_time = Time.get_ticks_usec()
	var elapsed_ms = float(end_time - start_time) / 1000.0
	
	performance("Operation '%s' took %.2f ms" % [operation_name, elapsed_ms], context)
	if performance_enabled:
		event_kv(LogLevel.PERFORMANCE, context if not context.is_empty() else "perf", operation_name, "ok", -1, elapsed_ms)
	return elapsed_ms

# Memory usage monitoring
static func log_memory_usage(operation: String, context: String = "") -> void:
	# Godot 4: approximate using Performance monitor (static memory)
	var total_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0)
	performance("Memory after %s: %.1f MB peak" % [operation, total_mb], context)
