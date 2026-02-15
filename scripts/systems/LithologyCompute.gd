# File: res://scripts/systems/LithologyCompute.gd
extends RefCounted

const LITHOLOGY_SHADER_FILE: RDShaderFile = preload("res://shaders/lithology_classify.glsl")

const ROCK_BASALTIC: int = 0
const ROCK_GRANITIC: int = 1
const ROCK_SEDIMENTARY_CLASTIC: int = 2
const ROCK_LIMESTONE: int = 3
const ROCK_METAMORPHIC: int = 4
const ROCK_VOLCANIC_ASH: int = 5

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

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

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(LITHOLOGY_SHADER_FILE)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func classify_to_buffer(
		w: int,
		h: int,
		height_buf: RID,
		land_buf: RID,
		temp_buf: RID,
		moist_buf: RID,
		lava_buf: RID,
		desert_buf: RID,
		params: Dictionary,
		out_rock_buf: RID
	) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if w <= 0 or h <= 0:
		return false
	if not height_buf.is_valid() or not land_buf.is_valid():
		return false
	if not temp_buf.is_valid() or not moist_buf.is_valid():
		return false
	if not lava_buf.is_valid() or not out_rock_buf.is_valid():
		return false

	var use_desert: bool = desert_buf.is_valid()
	var desert_use: RID = desert_buf
	if not use_desert:
		var dummy_f := PackedFloat32Array()
		dummy_f.resize(1)
		dummy_f.fill(0.5)
		desert_use = _rd.storage_buffer_create(dummy_f.to_byte_array().size(), dummy_f.to_byte_array())

	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(height_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(desert_use); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(lava_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(out_rock_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([
		w,
		h,
		int(params.get("seed", 0)),
		(1 if use_desert else 0),
	])
	var floats := PackedFloat32Array([
		float(params.get("min_h", 0.0)),
		float(params.get("max_h", 1.0)),
		float(params.get("noise_x_scale", 1.0)),
		0.0,
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
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
	if not use_desert:
		_rd.free_rid(desert_use)
	return true

func cleanup() -> void:
	if _rd != null:
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()

