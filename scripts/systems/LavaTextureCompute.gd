# File: res://scripts/systems/LavaTextureCompute.gd
extends RefCounted

# Packs lava mask buffer into an RD texture for GPU-only rendering.

var LAVA_TEX_SHADER: RDShaderFile = load("res://shaders/lava_buffer_to_tex.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _tex_rid: RID
var _tex: Texture2DRD
var _width: int = 0
var _height: int = 0

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null:
		return null
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		return null
	var chosen_version: Variant = null
	for v in versions:
		if v == null:
			continue
		if chosen_version == null:
			chosen_version = v
		if String(v) == "vulkan":
			chosen_version = v
			break
	if chosen_version == null:
		return null
	return file.get_spirv(chosen_version)

func _ensure_pipeline() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		var spirv := _get_spirv(LAVA_TEX_SHADER)
		if spirv != null:
			_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func _ensure_texture(w: int, h: int) -> void:
	w = max(1, int(w))
	h = max(1, int(h))
	if _tex_rid.is_valid() and w == _width and h == _height:
		return
	if _tex_rid.is_valid():
		_rd.free_rid(_tex_rid)
	_tex_rid = RID()
	_width = w
	_height = h
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.width = w
	fmt.height = h
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var view := RDTextureView.new()
	_tex_rid = _rd.texture_create(fmt, view)
	if not _tex_rid.is_valid():
		_tex = null
		return
	_tex = Texture2DRD.new()
	if _tex.has_method("set_texture_rd_rid"):
		_tex.set_texture_rd_rid(_tex_rid)
	elif _tex.has_method("set_texture_rd"):
		_tex.set_texture_rd(_tex_rid)
	else:
		_tex = null
		if _tex_rid.is_valid():
			_rd.free_rid(_tex_rid)
		_tex_rid = RID()
		push_error("Texture2DRD has no RD texture setter; GPU-only mode disables CPU texture fallback.")

func update_from_buffer(w: int, h: int, lava_buf: RID) -> Texture2D:
	_ensure_pipeline()
	if not _pipeline.is_valid():
		return null
	if not lava_buf.is_valid():
		return null
	_ensure_texture(w, h)
	if _tex == null or not _tex_rid.is_valid():
		return null
	var uniforms: Array = []
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(lava_buf)
	uniforms.append(u)
	var img_u := RDUniform.new()
	img_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img_u.binding = 1
	img_u.add_id(_tex_rid)
	uniforms.append(img_u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	if not u_set.is_valid():
		return null
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	if u_set.is_valid():
		_rd.free_rid(u_set)
	return _tex

func get_texture() -> Texture2D:
	return _tex

func cleanup() -> void:
	if _rd != null:
		if _tex_rid.is_valid():
			_rd.free_rid(_tex_rid)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
	_tex_rid = RID()
	_pipeline = RID()
	_shader = RID()
	_tex = null
	_width = 0
	_height = 0
