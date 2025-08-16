# File: res://scripts/systems/ShaderLoader.gd
extends RefCounted

# Centralized shader loading with comprehensive error handling
# Prevents silent failures and provides detailed error reporting

static var _loaded_shaders: Dictionary = {}
static var _failed_shaders: Array = []

static func load_shader_safe(path: String) -> RDShaderFile:
	"""Load shader with comprehensive error handling and caching"""
	
	# Check cache first
	if path in _loaded_shaders:
		return _loaded_shaders[path]
	
	# Check if this shader previously failed
	if path in _failed_shaders:
		push_warning("ShaderLoader: Skipping previously failed shader: " + path)
		return null
	
	# Attempt to load
	var shader_file = _attempt_load(path)
	
	if shader_file != null:
		_loaded_shaders[path] = shader_file
	else:
		_failed_shaders.append(path)
		push_error("ShaderLoader: Failed to load: " + path)
	
	return shader_file

static func _attempt_load(path: String) -> RDShaderFile:
	"""Internal shader loading with detailed error reporting"""
	
	# Check if file exists
	if not ResourceLoader.exists(path):
		push_error("ShaderLoader: Shader file does not exist: " + path)
		return null
	
	# Check if file can be loaded (Godot 4.4 compatible)
	var recognized_extensions = ResourceLoader.get_recognized_extensions_for_type("RDShaderFile")
	var file_extension = path.get_extension()
	if not file_extension in recognized_extensions:
		push_error("ShaderLoader: Unrecognized shader file extension: " + file_extension + " in " + path)
		return null
	
	# Attempt to load resource
	var resource = load(path)
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
	
	# Test spirv validity 
	if not spirv.is_valid():
		push_error("ShaderLoader: Generated SPIRV is invalid: " + path)
		return null
	
	# debug removed
	return shader_file

static func _choose_best_version(versions: Array) -> Variant:
	"""Choose the best shader version (prefer Vulkan)"""
	# Prefer Vulkan if available
	for v in versions:
		if String(v) == "vulkan":
			return v
	
	# Fall back to first available version
	return versions[0]

static func create_shader_and_pipeline(rd: RenderingDevice, shader_file: RDShaderFile, name: String = "") -> Dictionary:
	"""Create both shader and pipeline with error handling"""
	
	if rd == null:
		push_error("ShaderLoader: RenderingDevice is null for shader: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	if shader_file == null:
		push_error("ShaderLoader: Shader file is null for: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	# Get SPIRV
	var versions = shader_file.get_version_list()
	var chosen_version = _choose_best_version(versions)
	var spirv = shader_file.get_spirv(chosen_version)
	
	if spirv == null:
		push_error("ShaderLoader: Failed to get SPIRV for: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	# Create shader
	var shader_rid = rd.shader_create_from_spirv(spirv)
	if not shader_rid.is_valid():
		push_error("ShaderLoader: Failed to create shader from SPIRV: " + name)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	# Create pipeline
	var pipeline_rid = rd.compute_pipeline_create(shader_rid)
	if not pipeline_rid.is_valid():
		push_error("ShaderLoader: Failed to create compute pipeline: " + name)
		# Clean up shader
		rd.free_rid(shader_rid)
		return {"shader": RID(), "pipeline": RID(), "success": false}
	
	# debug removed
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
	
	var device_info = {
		"gpu_compute_available": true,
		"vulkan_available": true,
		"device_name": rd.get_device_name(),
		"device_vendor": rd.get_device_vendor_name(),
		"driver_version": str(rd.get_driver_version()),
		"memory_mb": rd.get_memory_usage(RenderingDevice.MEMORY_TEXTURES) / (1024 * 1024)
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
		"failed_shaders": _failed_shaders
	}