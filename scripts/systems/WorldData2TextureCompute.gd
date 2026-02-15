# File: res://scripts/systems/WorldData2TextureCompute.gd
extends RefCounted

# Packs surface/is_land/beach buffers into an RGBA32F texture (char_index set to 0).
# Surface source can be biome_id (default) or rock_type (bedrock mode).

var DATA2_TEX_SHADER: RDShaderFile = load("res://shaders/world_data2_from_buffers.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _tex_rid: RID
var _tex: Texture2DRD
var _width: int = 0
var _height: int = 0

func _sync_rd() -> bool:
	var current_rd: RenderingDevice = RenderingServer.get_rendering_device()
	if current_rd == null:
		_rd = null
		_shader = RID()
		_pipeline = RID()
		_tex_rid = RID()
		_tex = null
		_width = 0
		_height = 0
		return false
	if _rd != current_rd:
		# RenderingDevice changed; old RIDs are no longer safe to reuse.
		_rd = current_rd
		_shader = RID()
		_pipeline = RID()
		_tex_rid = RID()
		_tex = null
		_width = 0
		_height = 0
	return true

func _tex_wrapper_rid_valid() -> bool:
	if _tex == null:
		return false
	var rid_v: Variant = null
	if _tex.has_method("get_texture_rd_rid"):
		rid_v = _tex.call("get_texture_rd_rid")
	elif _tex.has_method("get_texture_rd"):
		rid_v = _tex.call("get_texture_rd")
	else:
		return false
	if not (rid_v is RID):
		return false
	var rid_w: RID = rid_v as RID
	return rid_w.is_valid() and rid_w == _tex_rid

func _is_tex_rid_usable() -> bool:
	if _rd == null:
		return false
	if not _tex_rid.is_valid():
		return false
	if not _tex_wrapper_rid_valid():
		return false
	if _rd.has_method("texture_is_valid"):
		return bool(_rd.texture_is_valid(_tex_rid))
	return true

func _reset_texture_only() -> void:
	if _rd != null and _tex_rid.is_valid():
		_rd.free_rid(_tex_rid)
	_tex_rid = RID()
	_tex = null

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

func _ensure_pipeline() -> bool:
	if not _sync_rd():
		return false
	if not _shader.is_valid():
		var spirv := _get_spirv(DATA2_TEX_SHADER)
		if spirv != null:
			_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	return _pipeline.is_valid()

func _ensure_texture(w: int, h: int) -> bool:
	if not _sync_rd():
		return false
	w = max(1, int(w))
	h = max(1, int(h))
	if _is_tex_rid_usable() and w == _width and h == _height and _tex != null:
		return true
	_reset_texture_only()
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
	if not _tex_rid.is_valid():
		_tex = null
		return false
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
		return false
	return _is_tex_rid_usable()

func _build_uniforms(
	biome_buf: RID,
	land_buf: RID,
	beach_buf: RID,
	rock_buf: RID,
	use_rock_local: bool
) -> Array:
	var uniforms: Array = []
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(biome_buf)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 1
	u.add_id(land_buf)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 2
	u.add_id(beach_buf)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 4
	u.add_id(rock_buf if use_rock_local else biome_buf)
	uniforms.append(u)
	var img_u := RDUniform.new()
	img_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img_u.binding = 3
	img_u.add_id(_tex_rid)
	uniforms.append(img_u)
	return uniforms

func update_from_buffers(
	w: int,
	h: int,
	biome_buf: RID,
	land_buf: RID,
	beach_buf: RID,
	rock_buf: RID = RID(),
	use_rock: bool = false
) -> Texture2D:
	if not _ensure_pipeline():
		return null
	if not biome_buf.is_valid() or not land_buf.is_valid() or not beach_buf.is_valid():
		return null
	var use_rock_local: bool = use_rock and rock_buf.is_valid()
	if not _ensure_texture(w, h):
		return null
	# Last-second RD drift guard before creating uniform sets.
	if _rd != RenderingServer.get_rendering_device():
		if not _sync_rd():
			return null
		if not _ensure_pipeline():
			return null
		if not _ensure_texture(w, h):
			return null
		if not _is_tex_rid_usable():
			return null
	var uniforms: Array = _build_uniforms(biome_buf, land_buf, beach_buf, rock_buf, use_rock_local)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	if not u_set.is_valid():
		# Recover once from stale output texture RID.
		_reset_texture_only()
		if not _ensure_texture(w, h) or not _is_tex_rid_usable():
			return null
		uniforms = _build_uniforms(biome_buf, land_buf, beach_buf, rock_buf, use_rock_local)
		u_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not u_set.is_valid():
		push_error("WorldData2TextureCompute: uniform_set_create failed (w=%d h=%d tex_valid=%s)." % [w, h, str(_is_tex_rid_usable())])
		return null
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if use_rock_local else 0), 0])
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
