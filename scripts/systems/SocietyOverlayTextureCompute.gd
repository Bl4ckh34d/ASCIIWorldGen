extends RefCounted

# Packs society sim buffers (wildlife + human pop) into an RGBA32F Texture2DRD for rendering overlays.


var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipeline: RID = RID()
var _tex_rid: RID = RID()
var _tex: Texture2DRD = null
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
		# RenderingDevice changed: drop stale GPU resource handles.
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
	if not rid_w.is_valid():
		return false
	return rid_w == _tex_rid

func _is_tex_rid_usable() -> bool:
	if _rd == null:
		return false
	if not _tex_rid.is_valid():
		return false
	if not _tex_wrapper_rid_valid():
		return false
	if _rd != null and _rd.has_method("texture_is_valid"):
		return bool(_rd.texture_is_valid(_tex_rid))
	return true

func _reset_texture_only() -> void:
	if _rd != null and _tex_rid.is_valid():
		_rd.free_rid(_tex_rid)
	_tex_rid = RID()
	_tex = null

func _ensure_pipeline() -> bool:
	if not _sync_rd():
		return false
	var state: Dictionary = ComputeShaderBase.ensure_rd_and_pipeline(
		_rd,
		_shader,
		_pipeline,
		"res://shaders/society/society_overlay_pack.glsl",
		"society_overlay_pack"
	)
	_rd = state.get("rd", null)
	_shader = state.get("shader", RID())
	_pipeline = state.get("pipeline", RID())
	return VariantCasts.to_bool(state.get("ok", false))

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
		return false
	return true

func _build_uniforms(wild_f32: RID, pop_f32: RID, state_i32: RID) -> Array:
	var uniforms: Array = []
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(wild_f32)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 1
	u.add_id(pop_f32)
	uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 2
	u.add_id(state_i32)
	uniforms.append(u)
	var img_u := RDUniform.new()
	img_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img_u.binding = 3
	img_u.add_id(_tex_rid)
	uniforms.append(img_u)
	return uniforms

func update_from_buffers(w: int, h: int, wild_f32: RID, pop_f32: RID, state_i32: RID, pop_ref: float = 120.0) -> Texture2D:
	if not _ensure_pipeline():
		return null
	if not (wild_f32.is_valid() and pop_f32.is_valid() and state_i32.is_valid()):
		return null
	if not _ensure_texture(w, h):
		return null
	# Last-second RD drift guard before creating/binding uniform sets.
	if _rd != RenderingServer.get_rendering_device():
		if not _sync_rd():
			return null
		if not _ensure_pipeline():
			return null
		if not _ensure_texture(w, h):
			return null
		if not _is_tex_rid_usable():
			return null

	var uniforms: Array = _build_uniforms(wild_f32, pop_f32, state_i32)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	if not u_set.is_valid():
		# Recover from stale image RID by rebuilding output texture and retrying once.
		_reset_texture_only()
		if not _ensure_texture(w, h) or not _is_tex_rid_usable():
			return null
		uniforms = _build_uniforms(wild_f32, pop_f32, state_i32)
		u_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not u_set.is_valid():
		push_error("SocietyOverlayTextureCompute: uniform_set_create failed (w=%d h=%d tex_valid=%s)." % [w, h, str(_is_tex_rid_usable())])
		return null

	var pc := PackedByteArray()
	var ints := PackedInt32Array([int(w), int(h), 0, 0])
	pc.append_array(ints.to_byte_array())
	var floats := PackedFloat32Array([float(pop_ref), 0.0, 0.0, 0.0])
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBase.validate_push_constant_size(pc, 32, "SocietyOverlayTextureCompute"):
		if u_set.is_valid():
			_rd.free_rid(u_set)
		return null

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
