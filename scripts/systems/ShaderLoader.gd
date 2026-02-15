# File: res://scripts/systems/ShaderLoader.gd
extends RefCounted

# Centralized shader loading with comprehensive error handling
# Prevents silent failures and provides detailed error reporting

const Log = preload("res://scripts/systems/Logger.gd")

static var _loaded_shaders: Dictionary = {}
static var _failed_shaders: Dictionary = {} # path -> {last_fail_msec, fail_count, last_warn_msec, last_modified}

const _RETRY_COOLDOWN_MSEC: int = 2000
const _WARN_COOLDOWN_MSEC: int = 3000

static func load_shader_safe(path: String) -> RDShaderFile:
	"""Load shader with comprehensive error handling and caching"""
	
	# Check cache first
	if path in _loaded_shaders:
		return _loaded_shaders[path]
	
	var now_msec: int = Time.get_ticks_msec()
	var fail_v: Variant = _failed_shaders.get(path, null)
	# Check if this shader previously failed recently.
	if typeof(fail_v) == TYPE_DICTIONARY:
		var fail: Dictionary = fail_v as Dictionary
		var last_fail: int = int(fail.get("last_fail_msec", 0))
		var last_warn: int = int(fail.get("last_warn_msec", 0))
		var prev_modified: int = int(fail.get("last_modified", -1))
		var cur_modified: int = FileAccess.get_modified_time(path) if ResourceLoader.exists(path) else -1
		var unchanged: bool = cur_modified == prev_modified
		if unchanged and (now_msec - last_fail) < _RETRY_COOLDOWN_MSEC:
			# Avoid warning spam in hot paths.
			if (now_msec - last_warn) >= _WARN_COOLDOWN_MSEC:
				push_warning("ShaderLoader: Skipping recently failed shader (will retry automatically): " + path)
				fail["last_warn_msec"] = now_msec
				_failed_shaders[path] = fail
			return null
		# Retry after cooldown or after source file changed.
		_failed_shaders.erase(path)
	
	# Attempt to load
	var shader_file = _attempt_load(path)
	
	if shader_file != null:
		_loaded_shaders[path] = shader_file
		_failed_shaders.erase(path)
		Log.event_kv(Log.LogLevel.INFO, "shader", "load", "ok", -1, -1.0, {"path": path})
	else:
		var prev_count: int = 0
		if typeof(fail_v) == TYPE_DICTIONARY:
			prev_count = int((fail_v as Dictionary).get("fail_count", 0))
		var modified: int = FileAccess.get_modified_time(path) if ResourceLoader.exists(path) else -1
		_failed_shaders[path] = {
			"last_fail_msec": now_msec,
			"fail_count": prev_count + 1,
			"last_warn_msec": now_msec,
			"last_modified": modified,
		}
		Log.event_kv(Log.LogLevel.ERROR, "shader", "load", "failed", -1, -1.0, {"path": path})
		push_error("ShaderLoader: Failed to load: " + path)
	
	return shader_file

static func _attempt_load(path: String) -> RDShaderFile:
	"""Internal shader loading with detailed error reporting"""
	
	# Do not hard-fail on exists() here. In some runtime/export setups the source path
	# can resolve through remap/import even when exists() returns false.
	if not ResourceLoader.exists(path):
		push_warning("ShaderLoader: exists() returned false, attempting load anyway: " + path)

	# Attempt to load resource
	var resource: Resource = ResourceLoader.load(path, "RDShaderFile")
	if resource == null:
		# Fallback loader path.
		resource = load(path)
	if resource == null:
		push_error("ShaderLoader: Failed to load resource: " + path)
		return null
	
	# Check if it's the correct type
	if not resource is RDShaderFile:
		push_error("ShaderLoader: Resource is not RDShaderFile: " + path + " (got: " + str(type_string(typeof(resource))) + ")")
		return null
	
	var shader_file = resource as RDShaderFile
	
	# Validate shader file contents
	var versions = shader_file.get_version_list()
	if versions.is_empty():
		push_error("ShaderLoader: Shader has no versions: " + path)
		return null
	
	# Test SPIRV generation
	var chosen_version = _choose_best_version(versions)
	var spirv = shader_file.get_spirv(chosen_version)
	if spirv == null:
		push_error("ShaderLoader: Failed to get SPIRV for version '" + str(chosen_version) + "': " + path)
		return null
	# Godot 4.6: RDShaderSPIRV has no is_valid() method; non-null object is the validity check here.
	
	# debug removed
	return shader_file

static func _choose_best_version(versions: Array) -> Variant:
	"""Choose the best shader version (prefer Vulkan)"""
	if versions.is_empty():
		return null
	var first_valid: Variant = null
	# Prefer Vulkan if available
	for v in versions:
		if v == null:
			continue
		if first_valid == null:
			first_valid = v
		if String(v) == "vulkan":
			return v
	
	# Fall back to first non-null available version
	return first_valid

static func create_shader_and_pipeline(rd: RenderingDevice, shader_file: RDShaderFile, name: String = "") -> Dictionary:
	"""Create both shader and pipeline with error handling"""
	
	if rd == null:
		Log.event_kv(Log.LogLevel.ERROR, "shader", "create_pipeline", "rd_null", -1, -1.0, {"name": name})
		push_error("ShaderLoader: RenderingDevice is null for shader: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	if shader_file == null:
		Log.event_kv(Log.LogLevel.ERROR, "shader", "create_pipeline", "file_null", -1, -1.0, {"name": name})
		push_error("ShaderLoader: Shader file is null for: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	# Get SPIRV
	var versions = shader_file.get_version_list()
	var chosen_version = _choose_best_version(versions)
	if chosen_version == null:
		Log.event_kv(Log.LogLevel.ERROR, "shader", "create_pipeline", "no_version", -1, -1.0, {"name": name})
		push_error("ShaderLoader: No non-null shader version for: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	var spirv = shader_file.get_spirv(chosen_version)
	
	if spirv == null:
		Log.event_kv(Log.LogLevel.ERROR, "shader", "create_pipeline", "spirv_null", -1, -1.0, {"name": name, "version": str(chosen_version)})
		push_error("ShaderLoader: Failed to get SPIRV for: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	# Create shader
	var shader_rid = rd.shader_create_from_spirv(spirv)
	if not shader_rid.is_valid():
		Log.event_kv(Log.LogLevel.ERROR, "shader", "create_pipeline", "shader_create_failed", -1, -1.0, {"name": name})
		push_error("ShaderLoader: Failed to create shader from SPIRV: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	# Create pipeline
	var pipeline_rid = rd.compute_pipeline_create(shader_rid)
	if not pipeline_rid.is_valid():
		Log.event_kv(Log.LogLevel.ERROR, "shader", "create_pipeline", "pipeline_create_failed", -1, -1.0, {"name": name})
		push_error("ShaderLoader: Failed to create compute pipeline: " + name)
		# Clean up shader
		rd.free_rid(shader_rid)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	Log.event_kv(Log.LogLevel.INFO, "shader", "create_pipeline", "ok", -1, -1.0, {"name": name, "version": str(chosen_version)})
	return {"shader": shader_rid, "pipeline": pipeline_rid, "success": true}

static func get_system_capabilities() -> Dictionary:
	"""Get system GPU compute capabilities"""
	var rd = RenderingServer.get_rendering_device()
	if rd == null:
		return {
			"gpu_compute_available": false,
			"vulkan_available": false,
			"error": "RenderingDevice unavailable"
		}

	var device_name: String = ""
	if rd.has_method("get_device_name"):
		device_name = String(rd.call("get_device_name"))
	var vendor_name: String = ""
	if rd.has_method("get_device_vendor_name"):
		vendor_name = String(rd.call("get_device_vendor_name"))
	# Godot 4.6 RenderingDevice does not expose a portable driver-version API.
	var driver_version: String = "unknown"
	var memory_mb: float = -1.0
	if rd.has_method("get_memory_usage"):
		var mem_bytes: Variant = rd.callv("get_memory_usage", [int(RenderingDevice.MEMORY_TEXTURES)])
		memory_mb = float(mem_bytes) / (1024.0 * 1024.0)

	var device_info = {
		"gpu_compute_available": true,
		"vulkan_available": true,
		"device_name": device_name,
		"device_vendor": vendor_name,
		"driver_version": driver_version,
		"memory_mb": memory_mb
	}

	return device_info

static func clear_cache() -> void:
	"""Clear shader cache (useful for development)"""
	_loaded_shaders.clear()
	_failed_shaders.clear()
	# debug removed

static func get_cache_stats() -> Dictionary:
	"""Get shader cache statistics"""
	return {
		"loaded_count": _loaded_shaders.size(),
		"failed_count": _failed_shaders.size(),
		"loaded_shaders": _loaded_shaders.keys(),
		"failed_shaders": _failed_shaders.keys()
	}
