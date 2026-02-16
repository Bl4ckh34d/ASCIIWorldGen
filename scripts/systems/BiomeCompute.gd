# File: res://scripts/systems/BiomeCompute.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

const ComputeShaderBaseUtil = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")

const BIOME_SHADER_PATH: String = "res://shaders/biome_classify.glsl"
const BIOME_SMOOTH_SHADER_PATH: String = "res://shaders/biome_smooth.glsl"
const BIOME_REAPPLY_SHADER_PATH: String = "res://shaders/biome_reapply.glsl"

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _smooth_shader: RID
var _smooth_pipeline: RID
var _reapply_shader: RID
var _reapply_pipeline: RID
var _buf_mgr: GPUBufferManager = null

var _fertility_dummy_size: int = -1
var _noise_dummy_seeded: bool = false
var _last_height_min: float = -1.0
var _last_height_max: float = 1.0
var _last_ocean_fraction: float = 0.5

func _init() -> void:
	_buf_mgr = GPUBufferManager.new()

func _ensure_main() -> bool:
	var main_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_shader,
		_pipeline,
		BIOME_SHADER_PATH,
		"biome_classify"
	)
	_rd = main_state.get("rd", null)
	_shader = main_state.get("shader", RID())
	_pipeline = main_state.get("pipeline", RID())
	return VariantCastsUtil.to_bool(main_state.get("ok", false))

func _ensure_smooth() -> bool:
	if not _ensure_main():
		return false
	var smooth_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_smooth_shader,
		_smooth_pipeline,
		BIOME_SMOOTH_SHADER_PATH,
		"biome_smooth"
	)
	_smooth_shader = smooth_state.get("shader", RID())
	_smooth_pipeline = smooth_state.get("pipeline", RID())
	return VariantCastsUtil.to_bool(smooth_state.get("ok", false))

func _ensure_reapply() -> bool:
	if not _ensure_main():
		return false
	var reapply_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_reapply_shader,
		_reapply_pipeline,
		BIOME_REAPPLY_SHADER_PATH,
		"biome_reapply"
	)
	_reapply_shader = reapply_state.get("shader", RID())
	_reapply_pipeline = reapply_state.get("pipeline", RID())
	return VariantCastsUtil.to_bool(reapply_state.get("ok", false))

func is_gpu_available() -> bool:
	"""Check if GPU compute is available and functional"""
	return _ensure_main() and _rd != null and _shader.is_valid() and _pipeline.is_valid()

func classify_to_buffer(w: int, h: int,
		height_buf: RID,
		land_buf: RID,
		temp_buf: RID,
		moist_buf: RID,
		beach_buf: RID,
		desert_buf: RID,
		fertility_buf: RID,
		params: Dictionary,
		out_biome_buf: RID,
		biome_noise_buf: RID = RID()) -> bool:
	if not _ensure_main():
		return false
	if not _pipeline.is_valid():
		return false
	if not height_buf.is_valid() or not land_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid() or not beach_buf.is_valid() or not out_biome_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	var use_desert: bool = desert_buf.is_valid()
	var desert_buf_use: RID = desert_buf
	if not use_desert:
		var dummy_f := PackedFloat32Array([0.0])
		desert_buf_use = _buf_mgr.ensure_buffer("biome_dummy_desert", 4, dummy_f.to_byte_array())
	var use_fertility: bool = fertility_buf.is_valid()
	var fertility_buf_use: RID = fertility_buf
	if not use_fertility:
		var fert_name: String = "biome_dummy_fertility_%d" % size
		fertility_buf_use = _buf_mgr.ensure_buffer(fert_name, size * 4)
		if _fertility_dummy_size != size:
			var fert_default := PackedFloat32Array()
			fert_default.resize(size)
			fert_default.fill(0.5)
			_buf_mgr.update_buffer(fert_name, fert_default.to_byte_array())
			_fertility_dummy_size = size
	var use_biome_noise: bool = biome_noise_buf.is_valid()
	var biome_noise_buf_use: RID = biome_noise_buf
	if not use_biome_noise:
		biome_noise_buf_use = _buf_mgr.ensure_buffer("biome_dummy_noise", 4)
		if not _noise_dummy_seeded:
			var noise_default := PackedFloat32Array([0.5])
			_buf_mgr.update_buffer("biome_dummy_noise", noise_default.to_byte_array())
			_noise_dummy_seeded = true
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(height_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(beach_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(desert_buf_use); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(out_biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 7; u.add_id(fertility_buf_use); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 8; u.add_id(biome_noise_buf_use); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	if not u_set.is_valid():
		return false
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var freeze_norm: float = float(params.get("freeze_temp_threshold", 0.16))
	var noise_c: float = float(params.get("biome_noise_strength_c", 0.8))
	var moist_jitter: float = float(params.get("biome_moist_jitter", 0.06))
	var phase: float = float(params.get("biome_phase", 0.0))
	var world_metrics: Dictionary = {}
	var world_metrics_v: Variant = params.get("world_state_metrics", {})
	if typeof(world_metrics_v) == TYPE_DICTIONARY:
		world_metrics = world_metrics_v as Dictionary
	var floats := PackedFloat32Array([
		float(params.get("temp_min_c", -40.0)),
		float(params.get("temp_max_c", 70.0)),
		float(params.get("height_scale_m", 6000.0)),
		float(params.get("lapse_c_per_km", 5.5)),
		freeze_norm,
		noise_c,
		moist_jitter,
		phase,
		float(params.get("biome_moist_jitter2", 0.03)),
		float(params.get("biome_moist_islands", 0.35)),
		float(params.get("biome_moist_elev_dry", 0.35)),
	])
	# Height metrics can come from cached WorldState metrics for GPU-only runtime.
	var min_h: float = float(world_metrics.get("min_h", params.get("min_h", 0.0)))
	var max_h: float = float(world_metrics.get("max_h", params.get("max_h", 1.0)))
	_last_ocean_fraction = clamp(float(world_metrics.get("ocean_fraction", params.get("ocean_fraction", _last_ocean_fraction))), 0.0, 1.0)
	_last_height_min = min_h
	_last_height_max = max_h
	var floats2 := PackedFloat32Array([min_h, max_h])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	pc.append_array(floats2.to_byte_array())
	var tail := PackedInt32Array([ (1 if use_desert else 0), (1 if use_biome_noise else 0) ])
	pc.append_array(tail.to_byte_array())
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
	var do_smooth: bool = VariantCastsUtil.to_bool(params.get("biome_smoothing_enabled", true))
	if do_smooth:
		var smooth_passes: int = max(1, int(params.get("biome_smoothing_passes", 1)))
		if not _apply_smoothing_passes(w, h, out_biome_buf, smooth_passes):
			return false
	return true

func _apply_smoothing_passes(w: int, h: int, biome_buf: RID, passes: int) -> bool:
	if not _ensure_smooth():
		return false
	if _rd == null or not _smooth_pipeline.is_valid() or not biome_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size <= 0:
		return false
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	var tmp_name: String = "biome_smooth_tmp_%d" % size
	var tmp_buf: RID = _buf_mgr.ensure_buffer(tmp_name, size * 4)
	if not tmp_buf.is_valid():
		return false

	var total_passes: int = max(1, passes)
	# Keep the final result in biome_buf without CPU copies.
	if (total_passes % 2) != 0:
		total_passes += 1

	var read_buf: RID = biome_buf
	var write_buf: RID = tmp_buf
	for _p in range(total_passes):
		if not _dispatch_smooth_pass(w, h, read_buf, write_buf):
			return false
		var t: RID = read_buf
		read_buf = write_buf
		write_buf = t
	return read_buf == biome_buf

func _dispatch_smooth_pass(w: int, h: int, in_buf: RID, out_buf: RID) -> bool:
	if _rd == null or not _smooth_pipeline.is_valid() or not in_buf.is_valid() or not out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(out_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _smooth_shader, 0)
	if not u_set.is_valid():
		return false
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	pc.append_array(ints.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 16, "BiomeCompute.smooth"):
		_rd.free_rid(u_set)
		return false
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _smooth_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func reapply_cryosphere_to_buffer(
		w: int,
		h: int,
		biome_in_buf: RID,
		biome_out_buf: RID,
		land_buf: RID,
		height_buf: RID,
		temp_buf: RID,
		moist_buf: RID,
		temp_min_c: float,
		temp_max_c: float,
		height_scale_m: float = 6000.0,
		lapse_c_per_km: float = 5.5,
		ocean_ice_base_thresh_c: float = -7.0,
		ocean_ice_wiggle_amp_c: float = 2.2
	) -> bool:
	if not _ensure_reapply():
		return false
	if not _reapply_pipeline.is_valid():
		return false
	if not biome_in_buf.is_valid() or not biome_out_buf.is_valid():
		return false
	if not land_buf.is_valid() or not height_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	var ice_name: String = "biome_reapply_ice_%d" % size
	var buf_ice: RID = _buf_mgr.ensure_buffer(ice_name, size * 4)
	_buf_mgr.clear_buffer(ice_name, 0)
	if not buf_ice.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(biome_in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(biome_out_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(height_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(buf_ice); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _reapply_shader, 0)
	if not u_set.is_valid():
		return false
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([
		temp_min_c,
		temp_max_c,
		height_scale_m,
		lapse_c_per_km,
		ocean_ice_base_thresh_c,
		ocean_ice_wiggle_amp_c,
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
	_rd.compute_list_bind_compute_pipeline(cl, _reapply_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func cleanup() -> void:
	if _buf_mgr != null:
		_buf_mgr.cleanup()
	ComputeShaderBaseUtil.free_rids(_rd, [
		_pipeline,
		_shader,
		_smooth_pipeline,
		_smooth_shader,
		_reapply_pipeline,
		_reapply_shader,
	])
	_pipeline = RID()
	_shader = RID()
	_smooth_pipeline = RID()
	_smooth_shader = RID()
	_reapply_pipeline = RID()
	_reapply_shader = RID()
