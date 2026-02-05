# File: res://scripts/systems/WorldData1TextureCompute.gd
extends RefCounted

# Packs height/temperature/moisture/light buffers into an RGBA32F texture.

var DATA1_TEX_SHADER: RDShaderFile = load("res://shaders/world_data1_from_buffers.glsl")

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
	var chosen_version = versions[0]
	for v in versions:
		if String(v) == "vulkan":
			chosen_version = v
			break
	return file.get_spirv(chosen_version)

func _ensure_pipeline() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		var spirv := _get_spirv(DATA1_TEX_SHADER)
		if spirv != null:
			_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func _ensure_texture(w: int, h: int) -> void:
	if _tex_rid.is_valid() and w == _width and h == _height:
		return
	if _tex_rid.is_valid():
		_rd.free_rid(_tex_rid)
	_tex_rid = RID()
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
	_tex_rid = _rd.texture_create(fmt, view)
	_tex = Texture2DRD.new()
	if _tex.has_method("set_texture_rd_rid"):
		_tex.set_texture_rd_rid(_tex_rid)
	elif _tex.has_method("set_texture_rd"):
		_tex.set_texture_rd(_tex_rid)
	else:
		_tex = null
		push_warning("Texture2DRD has no RD texture setter; falling back to CPU textures.")

func update_from_buffers(w: int, h: int, height_buf: RID, temp_buf: RID, moist_buf: RID, light_buf: RID) -> Texture2D:
	_ensure_pipeline()
	if not _pipeline.is_valid():
		return null
	if not height_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid() or not light_buf.is_valid():
		return null
	_ensure_texture(w, h)
	if _tex == null:
		return null
	var uniforms: Array = []
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(height_buf)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 1
	u.add_id(temp_buf)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 2
	u.add_id(moist_buf)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 3
	u.add_id(light_buf)
	uniforms.append(u)
	var img_u := RDUniform.new()
	img_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img_u.binding = 4
	img_u.add_id(_tex_rid)
	uniforms.append(img_u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
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
	_rd.free_rid(u_set)
	return _tex

func get_texture() -> Texture2D:
	return _tex
