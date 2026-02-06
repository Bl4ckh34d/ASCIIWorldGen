# File: res://scripts/intro/IntroBigBangCompute.gd
extends RefCounted

# GPU-only compute wrapper for the intro quote and big-bang background.

var INTRO_SHADER_FILE: RDShaderFile = load("res://shaders/intro_bigbang.glsl")
var STAGE2_SHADER_FILE: RDShaderFile = load("res://shaders/intro_stage2_sun.glsl")
var MYCELIUM_SIM_SHADER_FILE: RDShaderFile = load("res://shaders/intro_mycelium_sim.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _stage2_shader: RID
var _stage2_pipeline: RID
var _myc_shader: RID
var _myc_pipeline: RID
var _texture_rid: RID
var _myc_tex_a: RID
var _myc_tex_b: RID
var _texture: Texture2DRD
var _width: int = 0
var _height: int = 0
var _myc_src_is_a: bool = true
var _myc_reset_pending: bool = true
var _was_bigbang_phase: bool = false

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

func _spirv_has_compile_errors(spirv: RDShaderSPIRV, shader_name: String) -> bool:
	if spirv == null:
		return true
	var compute_error_v: Variant = spirv.get("compile_error_compute")
	var compute_error: String = compute_error_v if compute_error_v is String else (str(compute_error_v) if compute_error_v != null else "")
	if not compute_error.is_empty():
		push_error("IntroBigBangCompute: compile error in %s: %s" % [shader_name, compute_error])
		return true
	var base_error_v: Variant = spirv.get("base_error")
	var base_error: String = base_error_v if base_error_v is String else (str(base_error_v) if base_error_v != null else "")
	if not base_error.is_empty():
		push_error("IntroBigBangCompute: base error in %s: %s" % [shader_name, base_error])
		return true
	return false

func _ensure_pipelines() -> bool:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return false

	if not _shader.is_valid():
		var spirv := _get_spirv(INTRO_SHADER_FILE)
		if spirv != null and not _spirv_has_compile_errors(spirv, "intro_bigbang.glsl"):
			_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

	if not _myc_shader.is_valid():
		var myc_spirv := _get_spirv(MYCELIUM_SIM_SHADER_FILE)
		if myc_spirv != null and not _spirv_has_compile_errors(myc_spirv, "intro_mycelium_sim.glsl"):
			_myc_shader = _rd.shader_create_from_spirv(myc_spirv)
	if not _myc_pipeline.is_valid() and _myc_shader.is_valid():
		_myc_pipeline = _rd.compute_pipeline_create(_myc_shader)

	if not _stage2_shader.is_valid():
		var stage2_spirv := _get_spirv(STAGE2_SHADER_FILE)
		if stage2_spirv != null and not _spirv_has_compile_errors(stage2_spirv, "intro_stage2_sun.glsl"):
			_stage2_shader = _rd.shader_create_from_spirv(stage2_spirv)
	if not _stage2_pipeline.is_valid() and _stage2_shader.is_valid():
		_stage2_pipeline = _rd.compute_pipeline_create(_stage2_shader)

	return _pipeline.is_valid() and _myc_pipeline.is_valid() and _stage2_pipeline.is_valid()

func _create_storage_texture(w: int, h: int) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = w
	fmt.height = h
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	var view := RDTextureView.new()
	return _rd.texture_create(fmt, view)

func _free_rid_if_valid(rid: RID) -> RID:
	if _rd != null and rid.is_valid():
		_rd.free_rid(rid)
	return RID()

func _ensure_textures(w: int, h: int) -> bool:
	if w <= 0 or h <= 0:
		return false
	if _texture_rid.is_valid() and _myc_tex_a.is_valid() and _myc_tex_b.is_valid() and w == _width and h == _height and _texture != null:
		return true

	_texture_rid = _free_rid_if_valid(_texture_rid)
	_myc_tex_a = _free_rid_if_valid(_myc_tex_a)
	_myc_tex_b = _free_rid_if_valid(_myc_tex_b)
	_texture = null
	_width = w
	_height = h

	_texture_rid = _create_storage_texture(w, h)
	_myc_tex_a = _create_storage_texture(w, h)
	_myc_tex_b = _create_storage_texture(w, h)
	if not _texture_rid.is_valid():
		_texture_rid = _free_rid_if_valid(_texture_rid)
		_myc_tex_a = _free_rid_if_valid(_myc_tex_a)
		_myc_tex_b = _free_rid_if_valid(_myc_tex_b)
		return false
	if not _myc_tex_a.is_valid() or not _myc_tex_b.is_valid():
		_texture_rid = _free_rid_if_valid(_texture_rid)
		_myc_tex_a = _free_rid_if_valid(_myc_tex_a)
		_myc_tex_b = _free_rid_if_valid(_myc_tex_b)
		return false

	_texture = Texture2DRD.new()
	if _texture.has_method("set_texture_rd_rid"):
		_texture.set_texture_rd_rid(_texture_rid)
	elif _texture.has_method("set_texture_rd"):
		_texture.set_texture_rd(_texture_rid)
	else:
		_texture = null
		return false

	_myc_src_is_a = true
	_myc_reset_pending = true
	_was_bigbang_phase = false
	return _texture != null

func _current_mycelium_rid() -> RID:
	return _myc_tex_a if _myc_src_is_a else _myc_tex_b

func _dispatch_mycelium_step(
		width: int,
		height: int,
		phase_time: float,
		total_time: float,
		bigbang_progress: float,
		fade_alpha: float,
		seed_alpha: float,
		reset_state: bool
	) -> void:
	var src_rid: RID = _myc_tex_a if _myc_src_is_a else _myc_tex_b
	var dst_rid: RID = _myc_tex_b if _myc_src_is_a else _myc_tex_a
	if not src_rid.is_valid() or not dst_rid.is_valid():
		return

	var uniforms: Array = []
	var src_uniform := RDUniform.new()
	src_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	src_uniform.binding = 0
	src_uniform.add_id(src_rid)
	uniforms.append(src_uniform)

	var dst_uniform := RDUniform.new()
	dst_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	dst_uniform.binding = 1
	dst_uniform.add_id(dst_rid)
	uniforms.append(dst_uniform)

	var u_set := _rd.uniform_set_create(uniforms, _myc_shader, 0)
	if not u_set.is_valid():
		return

	var pc := PackedByteArray()
	var ints := PackedInt32Array([width, height, 1 if reset_state else 0, 0])
	var floats := PackedFloat32Array([
		total_time,
		phase_time,
		bigbang_progress,
		fade_alpha,
		seed_alpha,
		2.0,
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
	_rd.compute_list_bind_compute_pipeline(cl, _myc_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()

	_rd.free_rid(u_set)
	_myc_src_is_a = !_myc_src_is_a
	_myc_reset_pending = false

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
	if not _ensure_pipelines():
		return null
	if not _ensure_textures(width, height):
		return null

	var in_bigbang: bool = phase == 1
	if in_bigbang and not _was_bigbang_phase:
		_myc_reset_pending = true
	_was_bigbang_phase = in_bigbang

	if in_bigbang:
		var sim_steps: int = 2
		if bigbang_progress < 0.24:
			sim_steps = 6
		elif bigbang_progress < 0.60:
			sim_steps = 4
		elif bigbang_progress < 1.10:
			sim_steps = 3
		for i in range(sim_steps):
			var do_reset: bool = _myc_reset_pending and i == 0
			_dispatch_mycelium_step(
				width,
				height,
				phase_time,
				total_time,
				bigbang_progress,
				fade_alpha,
				quote_alpha,
				do_reset
			)

	var uniforms: Array = []
	var image_uniform := RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 0
	image_uniform.add_id(_texture_rid)
	uniforms.append(image_uniform)

	var myc_uniform := RDUniform.new()
	myc_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	myc_uniform.binding = 1
	var myc_rid: RID = _current_mycelium_rid()
	if not myc_rid.is_valid():
		return null
	myc_uniform.add_id(myc_rid)
	uniforms.append(myc_uniform)

	var active_shader: RID = _shader
	var active_pipeline: RID = _pipeline
	if phase == 2:
		active_shader = _stage2_shader
		active_pipeline = _stage2_pipeline
	if not active_shader.is_valid() or not active_pipeline.is_valid():
		return null

	var u_set := _rd.uniform_set_create(uniforms, active_shader, 0)
	if not u_set.is_valid():
		return null

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
	_rd.compute_list_bind_compute_pipeline(cl, active_pipeline)
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
	if _rd != null:
		if _texture_rid.is_valid():
			_rd.free_rid(_texture_rid)
		if _myc_tex_a.is_valid():
			_rd.free_rid(_myc_tex_a)
		if _myc_tex_b.is_valid():
			_rd.free_rid(_myc_tex_b)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
		if _myc_pipeline.is_valid():
			_rd.free_rid(_myc_pipeline)
		if _myc_shader.is_valid():
			_rd.free_rid(_myc_shader)
		if _stage2_pipeline.is_valid():
			_rd.free_rid(_stage2_pipeline)
		if _stage2_shader.is_valid():
			_rd.free_rid(_stage2_shader)
	_texture_rid = RID()
	_myc_tex_a = RID()
	_myc_tex_b = RID()
	_pipeline = RID()
	_shader = RID()
	_myc_pipeline = RID()
	_myc_shader = RID()
	_stage2_pipeline = RID()
	_stage2_shader = RID()
