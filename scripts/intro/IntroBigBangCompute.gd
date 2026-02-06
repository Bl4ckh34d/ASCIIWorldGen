# File: res://scripts/intro/IntroBigBangCompute.gd
extends RefCounted

# GPU-only compute wrapper for the intro quote and big-bang background.

var INTRO_SHADER_FILE: RDShaderFile = load("res://shaders/intro_bigbang.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _texture_rid: RID
var _texture: Texture2DRD
var _width: int = 0
var _height: int = 0

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

func _ensure_pipeline() -> bool:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return false
	if not _shader.is_valid():
		var spirv := _get_spirv(INTRO_SHADER_FILE)
		if spirv != null:
			_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	return _pipeline.is_valid()

func _ensure_texture(w: int, h: int) -> bool:
	if w <= 0 or h <= 0:
		return false
	if _texture_rid.is_valid() and w == _width and h == _height and _texture != null:
		return true
	if _texture_rid.is_valid():
		_rd.free_rid(_texture_rid)
	_texture_rid = RID()
	_texture = null
	_width = w
	_height = h

	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = w
	fmt.height = h
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	var view := RDTextureView.new()
	_texture_rid = _rd.texture_create(fmt, view)
	if not _texture_rid.is_valid():
		return false

	_texture = Texture2DRD.new()
	if _texture.has_method("set_texture_rd_rid"):
		_texture.set_texture_rd_rid(_texture_rid)
	elif _texture.has_method("set_texture_rd"):
		_texture.set_texture_rd(_texture_rid)
	else:
		_texture = null
		return false
	return _texture != null

func render(
		width: int,
		height: int,
		phase: int,
		intro_phase: int,
		phase_time: float,
		total_time: float,
		quote_alpha: float,
		bigbang_progress: float,
		star_alpha: float,
		fade_alpha: float,
		space_alpha: float,
		pan_progress: float,
		zoom_scale: float,
		planet_x: float,
		planet_preview_x: float,
		orbit_y: float,
		orbit_x_min: float,
		orbit_x_max: float,
		sun_start_center: Vector2,
		sun_end_center: Vector2,
		sun_radius: float,
		zone_inner_radius: float,
		zone_outer_radius: float,
		planet_has_position: bool
	) -> Texture2D:
	if not _ensure_pipeline():
		return null
	if not _ensure_texture(width, height):
		return null

	var uniforms: Array = []
	var image_uniform := RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 0
	image_uniform.add_id(_texture_rid)
	uniforms.append(image_uniform)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([width, height, phase, intro_phase])
	var floats := PackedFloat32Array([
		phase_time,
		total_time,
		quote_alpha,
		bigbang_progress,
		star_alpha,
		fade_alpha,
		space_alpha,
		pan_progress,
		zoom_scale,
		planet_x,
		planet_preview_x,
		orbit_y,
		orbit_x_min,
		orbit_x_max,
		sun_start_center.x,
		sun_start_center.y,
		sun_end_center.x,
		sun_end_center.y,
		sun_radius,
		zone_inner_radius,
		zone_outer_radius,
		1.0 if planet_has_position else 0.0,
		0.0,
		0.0
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())

	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)

	var gx: int = int(ceil(float(width) / 8.0))
	var gy: int = int(ceil(float(height) / 8.0))

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()

	_rd.free_rid(u_set)
	return _texture

func get_texture() -> Texture2D:
	return _texture

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if _rd != null and _texture_rid.is_valid():
		_rd.free_rid(_texture_rid)
	if _rd != null and _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _rd != null and _shader.is_valid():
		_rd.free_rid(_shader)
