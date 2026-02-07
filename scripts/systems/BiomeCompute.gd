# File: res://scripts/systems/BiomeCompute.gd
extends RefCounted

var BIOME_SHADER_FILE: RDShaderFile = load("res://shaders/biome_classify.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _smooth_shader_file: RDShaderFile = load("res://shaders/biome_smooth.glsl")
var _smooth_shader: RID
var _smooth_pipeline: RID
var _reapply_shader_file: RDShaderFile = load("res://shaders/biome_reapply.glsl")
var _reapply_shader: RID
var _reapply_pipeline: RID

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null:
		push_error("BiomeCompute: Shader file is null")
		return null
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		push_error("BiomeCompute: No shader versions available")
		return null
	var chosen_version = versions[0]
	for v in versions:
		if String(v) == "vulkan":
			chosen_version = v
			break
	if chosen_version == null:
		push_error("BiomeCompute: No non-null shader version available")
		return null
	var spirv = file.get_spirv(chosen_version)
	if spirv == null:
		push_error("BiomeCompute: Failed to get SPIRV for version: " + str(chosen_version))
	return spirv

func _ensure() -> void:
	# GPU device initialization with error handling
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
		if _rd == null:
			push_error("BiomeCompute: RenderingDevice unavailable - GPU compute not supported")
			return
	
	# Main biome shader initialization
	if not _shader.is_valid():
		var s: RDShaderSPIRV = _get_spirv(BIOME_SHADER_FILE)
		if s == null:
			push_error("BiomeCompute: Failed to load biome shader - falling back to CPU")
			return
		_shader = _rd.shader_create_from_spirv(s)
		if not _shader.is_valid():
			push_error("BiomeCompute: Failed to create biome shader from SPIRV")
			return
	
	# Pipeline creation
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
		if not _pipeline.is_valid():
			push_error("BiomeCompute: Failed to create compute pipeline")
			return
	
	# Smooth shader initialization (optional)
	if not _smooth_shader.is_valid():
		var s2: RDShaderSPIRV = _get_spirv(_smooth_shader_file)
		if s2 != null:
			_smooth_shader = _rd.shader_create_from_spirv(s2)
			if not _smooth_shader.is_valid():
				push_warning("BiomeCompute: Failed to create smooth shader - smoothing disabled")
	
	if not _smooth_pipeline.is_valid() and _smooth_shader.is_valid():
		_smooth_pipeline = _rd.compute_pipeline_create(_smooth_shader)
		if not _smooth_pipeline.is_valid():
			push_warning("BiomeCompute: Failed to create smooth pipeline - smoothing disabled")
	if not _reapply_shader.is_valid():
		var s3: RDShaderSPIRV = _get_spirv(_reapply_shader_file)
		if s3 != null:
			_reapply_shader = _rd.shader_create_from_spirv(s3)
	if not _reapply_pipeline.is_valid() and _reapply_shader.is_valid():
		_reapply_pipeline = _rd.compute_pipeline_create(_reapply_shader)

func is_gpu_available() -> bool:
	"""Check if GPU compute is available and functional"""
	_ensure()
	return _rd != null and _shader.is_valid() and _pipeline.is_valid()

func classify(w: int, h: int,
		height: PackedFloat32Array,
		is_land: PackedByteArray,
		temperature: PackedFloat32Array,
		moisture: PackedFloat32Array,
		beach_mask: PackedByteArray,
		desert_field: PackedFloat32Array,
		params: Dictionary,
		fertility: PackedFloat32Array = PackedFloat32Array(),
		_lake_mask: PackedByteArray = PackedByteArray(),
		_river_mask: PackedByteArray = PackedByteArray()) -> PackedInt32Array:
	_ensure()
	if not _pipeline.is_valid():
		return PackedInt32Array()
	var size: int = max(0, w * h)
	if size == 0:
		return PackedInt32Array()
	# Inputs
	var buf_h := _rd.storage_buffer_create(height.to_byte_array().size(), height.to_byte_array())
	var is_land_u32 := PackedInt32Array(); is_land_u32.resize(size)
	for i in range(size): is_land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	var buf_land := _rd.storage_buffer_create(is_land_u32.to_byte_array().size(), is_land_u32.to_byte_array())
	var buf_t := _rd.storage_buffer_create(temperature.to_byte_array().size(), temperature.to_byte_array())
	var buf_m := _rd.storage_buffer_create(moisture.to_byte_array().size(), moisture.to_byte_array())
	var beach_u32 := PackedInt32Array(); beach_u32.resize(size)
	for j in range(size): beach_u32[j] = 1 if (j < beach_mask.size() and beach_mask[j] != 0) else 0
	var buf_beach := _rd.storage_buffer_create(beach_u32.to_byte_array().size(), beach_u32.to_byte_array())
	var use_desert: bool = desert_field.size() == size
	var buf_desert: RID
	if use_desert:
		buf_desert = _rd.storage_buffer_create(desert_field.to_byte_array().size(), desert_field.to_byte_array())
	else:
		# create minimal buffer when not used to satisfy binding
		var dummy := PackedFloat32Array(); dummy.resize(1)
		buf_desert = _rd.storage_buffer_create(dummy.to_byte_array().size(), dummy.to_byte_array())
	var fert_use := fertility
	if fert_use.size() != size:
		fert_use = PackedFloat32Array()
		fert_use.resize(size)
		fert_use.fill(0.5)
	var buf_fert := _rd.storage_buffer_create(fert_use.to_byte_array().size(), fert_use.to_byte_array())
	# Output
	var out_biomes := PackedInt32Array(); out_biomes.resize(size)
	var buf_out := _rd.storage_buffer_create(out_biomes.to_byte_array().size(), out_biomes.to_byte_array())

	# Uniform set
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_h); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_t); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_m); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_beach); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(buf_desert); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(buf_out); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 7; u.add_id(buf_fert); uniforms.append(u)
	# Keep a dummy extra binding for compatibility with older layouts.
	var dummy := PackedInt32Array(); dummy.resize(1)
	var dummy_buf := _rd.storage_buffer_create(dummy.to_byte_array().size(), dummy.to_byte_array())
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 8; u.add_id(dummy_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

	# Push constants
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var freeze_norm: float = float(params.get("freeze_temp_threshold", 0.16))
	# Animated jitter to break banding; controllable via params
	var noise_c: float = float(params.get("biome_noise_strength_c", 0.8))
	var moist_jitter: float = float(params.get("biome_moist_jitter", 0.06))
	var phase: float = float(params.get("biome_phase", 0.0))
	# freeze provided as normalized threshold in GPU to match effective temperature space
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
	# Real map height min/max for normalized relief thresholds
	var min_h: float = 1e9
	var max_h: float = -1e9
	for hi in range(size):
		var hv: float = height[hi]
		if hv < min_h: min_h = hv
		if hv > max_h: max_h = hv
	var floats2 := PackedFloat32Array([
		min_h,
		max_h,
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	pc.append_array(floats2.to_byte_array())
	var tail := PackedInt32Array([ (1 if use_desert else 0) ])
	pc.append_array(tail.to_byte_array())
	# Align to 16-byte multiple
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)

	# Dispatch
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()

	# Optional smoothing pass into a new buffer
	var biomes: PackedInt32Array
	if _smooth_pipeline.is_valid():
		var buf_smoothed := _rd.storage_buffer_create(out_biomes.to_byte_array().size(), out_biomes.to_byte_array())
		var uniforms_s: Array = []
		var us: RDUniform
		us = RDUniform.new(); us.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; us.binding = 0; us.add_id(buf_out); uniforms_s.append(us)
		us = RDUniform.new(); us.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; us.binding = 1; us.add_id(buf_smoothed); uniforms_s.append(us)
		var u_set_s := _rd.uniform_set_create(uniforms_s, _smooth_shader, 0)
		var pc_s := PackedByteArray(); var ints_s := PackedInt32Array([w, h]); pc_s.append_array(ints_s.to_byte_array())
		# Align push constants
		var pad_s := (16 - (pc_s.size() % 16)) % 16
		if pad_s > 0:
			var zeros_s := PackedByteArray(); zeros_s.resize(pad_s)
			pc_s.append_array(zeros_s)
		var gx2 := int(ceil(float(w) / 16.0))
		var gy2 := int(ceil(float(h) / 16.0))
		var cl2 := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl2, _smooth_pipeline)
		_rd.compute_list_bind_uniform_set(cl2, u_set_s, 0)
		_rd.compute_list_set_push_constant(cl2, pc_s, pc_s.size())
		_rd.compute_list_dispatch(cl2, gx2, gy2, 1)
		_rd.compute_list_end()
		# Optional re-apply pass for ocean ice sheets and land glaciers
		if _reapply_pipeline.is_valid():
			# Inputs for re-apply: smoothed as input, copy result to same size out
			var buf_reapply_out := _rd.storage_buffer_create(out_biomes.to_byte_array().size(), out_biomes.to_byte_array())
			var uniforms_r: Array = []
			var ur: RDUniform
			ur = RDUniform.new(); ur.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ur.binding = 0; ur.add_id(buf_smoothed); uniforms_r.append(ur)
			ur = RDUniform.new(); ur.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ur.binding = 1; ur.add_id(buf_reapply_out); uniforms_r.append(ur)
			ur = RDUniform.new(); ur.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ur.binding = 2; ur.add_id(buf_land); uniforms_r.append(ur)
			ur = RDUniform.new(); ur.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ur.binding = 3; ur.add_id(buf_h); uniforms_r.append(ur)
			ur = RDUniform.new(); ur.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ur.binding = 4; ur.add_id(buf_t); uniforms_r.append(ur)
			ur = RDUniform.new(); ur.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ur.binding = 5; ur.add_id(buf_m); uniforms_r.append(ur)
			# ice wiggle field: if available provide, else provide dummy zero buffer
			var ice_field := PackedFloat32Array()
			ice_field.resize(size)
			for ii in range(size): ice_field[ii] = 0.0
			var buf_ice := _rd.storage_buffer_create(ice_field.to_byte_array().size(), ice_field.to_byte_array())
			ur = RDUniform.new(); ur.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; ur.binding = 6; ur.add_id(buf_ice); uniforms_r.append(ur)
			var u_set_r := _rd.uniform_set_create(uniforms_r, _reapply_shader, 0)
			var pc_r := PackedByteArray()
			var ints_r := PackedInt32Array([w, h])
			var floats_r := PackedFloat32Array([
				float(params.get("temp_min_c", -40.0)),
				float(params.get("temp_max_c", 70.0)),
				float(params.get("height_scale_m", 6000.0)),
				float(params.get("lapse_c_per_km", 5.5)),
				-7.0, 2.2, # ocean ice threshold and wiggle amplitude
			])
			pc_r.append_array(ints_r.to_byte_array()); pc_r.append_array(floats_r.to_byte_array())
			var pad_r := (16 - (pc_r.size() % 16)) % 16
			if pad_r > 0:
				var zeros_r := PackedByteArray(); zeros_r.resize(pad_r)
				pc_r.append_array(zeros_r)
			var cl3 := _rd.compute_list_begin()
			_rd.compute_list_bind_compute_pipeline(cl3, _reapply_pipeline)
			_rd.compute_list_bind_uniform_set(cl3, u_set_r, 0)
			_rd.compute_list_set_push_constant(cl3, pc_r, pc_r.size())
			_rd.compute_list_dispatch(cl3, gx2, gy2, 1)
			_rd.compute_list_end()
			var bytes3 := _rd.buffer_get_data(buf_reapply_out)
			biomes = bytes3.to_int32_array()
			_rd.free_rid(u_set_r)
			_rd.free_rid(buf_reapply_out)
			_rd.free_rid(buf_ice)
		else:
			var bytes2 := _rd.buffer_get_data(buf_smoothed)
			biomes = bytes2.to_int32_array()
		_rd.free_rid(u_set_s)
		_rd.free_rid(buf_smoothed)
	else:
		var bytes := _rd.buffer_get_data(buf_out)
		biomes = bytes.to_int32_array()

	# Cleanup
	_rd.free_rid(u_set)
	_rd.free_rid(buf_h)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_t)
	_rd.free_rid(buf_m)
	_rd.free_rid(buf_beach)
	_rd.free_rid(buf_desert)
	_rd.free_rid(buf_fert)
	_rd.free_rid(buf_out)
	_rd.free_rid(dummy_buf)

	return biomes

func classify_to_buffer(w: int, h: int,
		height_buf: RID,
		land_buf: RID,
		temp_buf: RID,
		moist_buf: RID,
		beach_buf: RID,
		desert_buf: RID,
		fertility_buf: RID,
		params: Dictionary,
		out_biome_buf: RID) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if not height_buf.is_valid() or not land_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid() or not beach_buf.is_valid() or not out_biome_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	var use_desert: bool = desert_buf.is_valid()
	var desert_buf_use: RID = desert_buf
	if not use_desert:
		var dummy_f := PackedFloat32Array(); dummy_f.resize(1)
		desert_buf_use = _rd.storage_buffer_create(dummy_f.to_byte_array().size(), dummy_f.to_byte_array())
	var use_fertility: bool = fertility_buf.is_valid()
	var fertility_buf_use: RID = fertility_buf
	if not use_fertility:
		var fert_default := PackedFloat32Array()
		fert_default.resize(size)
		fert_default.fill(0.5)
		fertility_buf_use = _rd.storage_buffer_create(fert_default.to_byte_array().size(), fert_default.to_byte_array())
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
	# Bind dummy buffer for compatibility with layout slot 8.
	var dummy := PackedInt32Array(); dummy.resize(1)
	var dummy_buf := _rd.storage_buffer_create(dummy.to_byte_array().size(), dummy.to_byte_array())
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 8; u.add_id(dummy_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var freeze_norm: float = float(params.get("freeze_temp_threshold", 0.16))
	var noise_c: float = float(params.get("biome_noise_strength_c", 0.8))
	var moist_jitter: float = float(params.get("biome_moist_jitter", 0.06))
	var phase: float = float(params.get("biome_phase", 0.0))
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
	# min/max from params if supplied; else compute from CPU height not available in GPU-only path
	var min_h: float = float(params.get("min_h", 0.0))
	var max_h: float = float(params.get("max_h", 1.0))
	var floats2 := PackedFloat32Array([min_h, max_h])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	pc.append_array(floats2.to_byte_array())
	var tail := PackedInt32Array([ (1 if use_desert else 0) ])
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
	_rd.free_rid(dummy_buf)
	if not use_desert:
		_rd.free_rid(desert_buf_use)
	if not use_fertility:
		_rd.free_rid(fertility_buf_use)
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
	_ensure()
	if not _reapply_pipeline.is_valid():
		return false
	if not biome_in_buf.is_valid() or not biome_out_buf.is_valid():
		return false
	if not land_buf.is_valid() or not height_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	var ice_field := PackedFloat32Array()
	ice_field.resize(size)
	ice_field.fill(0.0)
	var buf_ice := _rd.storage_buffer_create(ice_field.to_byte_array().size(), ice_field.to_byte_array())
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
	_rd.free_rid(buf_ice)
	return true
