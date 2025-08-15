# File: res://scripts/systems/VolcanismCompute.gd
extends RefCounted

var VOLCANISM_SHADER: RDShaderFile = load("res://shaders/volcanism.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

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

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(VOLCANISM_SHADER)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func step(w: int, h: int, boundary_mask_i32: PackedInt32Array, lava_in: PackedFloat32Array, dt_days: float, rates: Dictionary, phase: float, rng_seed: int) -> PackedFloat32Array:
	_ensure()
	if not _pipeline.is_valid():
		return PackedFloat32Array()
	var size: int = max(0, w * h)
	if boundary_mask_i32.size() != size:
		return PackedFloat32Array()
	var lava_prev := lava_in
	if lava_prev.size() != size:
		lava_prev = PackedFloat32Array(); lava_prev.resize(size)
	var buf_bnd := _rd.storage_buffer_create(boundary_mask_i32.to_byte_array().size(), boundary_mask_i32.to_byte_array())
	var buf_in := _rd.storage_buffer_create(lava_prev.to_byte_array().size(), lava_prev.to_byte_array())
	var out := PackedFloat32Array(); out.resize(size)
	var buf_out := _rd.storage_buffer_create(out.to_byte_array().size(), out.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_bnd); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_in); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_out); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var decay: float = float(rates.get("decay_rate_per_day", 0.01))
	var spawn_b: float = float(rates.get("spawn_boundary_rate_per_day", 0.02))
	var spawn_h: float = float(rates.get("hotspot_rate_per_day", 0.005))
	var thr: float = float(rates.get("hotspot_threshold", 0.995))
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, int(rng_seed)])
	var bthr: float = float(rates.get("boundary_spawn_threshold", 0.999))
	var floats := PackedFloat32Array([dt_days, decay, spawn_b, spawn_h, thr, bthr, fposmod(phase, 1.0)])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
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
	var out_bytes := _rd.buffer_get_data(buf_out)
	var lava_out: PackedFloat32Array = out_bytes.to_float32_array()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_bnd)
	_rd.free_rid(buf_in)
	_rd.free_rid(buf_out)
	return lava_out


