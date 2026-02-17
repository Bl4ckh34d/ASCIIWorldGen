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
		var spirv: RDShaderSPIRV = _get_spirv(VOLCANISM_SHADER)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func step_gpu_buffers(w: int, h: int, boundary_buf: RID, lava_buf: RID, dt_days: float, rates: Dictionary, phase: float, rng_seed: int) -> bool:
	"""GPU-only update: read/write lava in-place from persistent buffers (no readback)."""
	_ensure()
	if not _pipeline.is_valid():
		return false
	if not boundary_buf.is_valid() or not lava_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(boundary_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(lava_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var decay: float = float(rates.get("decay_rate_per_day", 0.01))
	var spawn_b: float = float(rates.get("spawn_boundary_rate_per_day", 0.02))
	var spawn_h: float = float(rates.get("hotspot_rate_per_day", 0.005))
	var thr: float = float(rates.get("hotspot_threshold", 0.995))
	var bthr: float = float(rates.get("boundary_spawn_threshold", 0.999))
	var pc := PackedByteArray()
	# Must match shader layout exactly:
	# int width, int height, float dt, float decay, float spawn_b, float spawn_h,
	# float hotspot_threshold, float boundary_spawn_threshold, float phase, int seed
	var head_ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([dt_days, decay, spawn_b, spawn_h, thr, bthr, fposmod(phase, 1.0)])
	var tail_ints := PackedInt32Array([int(rng_seed)])
	pc.append_array(head_ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	pc.append_array(tail_ints.to_byte_array())
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
	return true

func cleanup() -> void:
	if _rd != null:
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()
