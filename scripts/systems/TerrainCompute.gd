# File: res://scripts/systems/TerrainCompute.gd
extends RefCounted

const TERRAIN_SHADER := preload("res://shaders/terrain_gen.glsl")
var FBM_SHADER_FILE: RDShaderFile = load("res://shaders/noise_fbm.glsl")

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
		var spirv: RDShaderSPIRV = _get_spirv(TERRAIN_SHADER)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

static func _build_noise_fields(w: int, h: int, params: Dictionary) -> Dictionary:
	var rng_seed: int = int(params.get("seed", 0))
	var frequency: float = float(params.get("frequency", 0.02))
	var octaves: int = int(params.get("octaves", 5))
	var lacunarity: float = float(params.get("lacunarity", 2.0))
	var gain: float = float(params.get("gain", 0.5))
	var warp: float = float(params.get("warp", 24.0))
	var wrap_x: bool = bool(params.get("wrap_x", true))
	var noise_x_scale: float = float(params.get("noise_x_scale", 1.0))

	var noise := FastNoiseLite.new()
	noise.seed = rng_seed
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_lacunarity = lacunarity
	noise.fractal_gain = gain

	var warp_noise := FastNoiseLite.new()
	warp_noise.seed = rng_seed ^ 0x9E3779B9
	warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp_noise.frequency = frequency * 1.5
	warp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	warp_noise.fractal_octaves = 3
	warp_noise.fractal_lacunarity = 2.0
	warp_noise.fractal_gain = 0.5

	var base_noise := FastNoiseLite.new()
	base_noise.seed = rng_seed ^ 1234567
	base_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	base_noise.frequency = max(0.002, frequency * 0.4)
	base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	base_noise.fractal_octaves = 4
	base_noise.fractal_lacunarity = 2.0
	base_noise.fractal_gain = 0.5

	var fbm_base := PackedFloat32Array()
	fbm_base.resize(w * h)
	var cont_base := PackedFloat32Array()
	cont_base.resize(w * h)
	var warp_x_field := PackedFloat32Array()
	warp_x_field.resize(w * h)
	var warp_y_field := PackedFloat32Array()
	warp_y_field.resize(w * h)

	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			# Base FBM and continental mask at grid points (shader will sample bilinear)
			if wrap_x:
				var t2 := float(x) / float(max(1, w))
				var n0 := noise.get_noise_2d(float(x) * noise_x_scale, float(y))
				var n1 := noise.get_noise_2d((float(x) + float(w)) * noise_x_scale, float(y))
				fbm_base[i] = lerp(n0, n1, t2)
				var c0 := base_noise.get_noise_2d(float(x) * 0.5 * noise_x_scale, float(y) * 0.5)
				var c1 := base_noise.get_noise_2d((float(x) + float(w)) * 0.5 * noise_x_scale, float(y) * 0.5)
				cont_base[i] = lerp(c0, c1, t2)
			else:
				fbm_base[i] = noise.get_noise_2d(float(x) * noise_x_scale, float(y))
				cont_base[i] = base_noise.get_noise_2d(float(x) * 0.5 * noise_x_scale, float(y) * 0.5)
			# Domain warp fields with optional wrap blending
			if wrap_x:
				var w0 := warp_noise.get_noise_2d(float(x) * 0.8 * noise_x_scale, float(y) * 0.8)
				var w1 := warp_noise.get_noise_2d((float(x) + float(w)) * 0.8 * noise_x_scale, float(y) * 0.8)
				var t := float(x) / float(max(1, w))
				warp_x_field[i] = lerp(w0, w1, t) * warp
				var v0 := warp_noise.get_noise_2d((float(x) + 1000.0) * 0.8 * noise_x_scale, (float(y) - 777.0) * 0.8)
				var v1 := warp_noise.get_noise_2d((float(x) + float(w) + 1000.0) * 0.8 * noise_x_scale, (float(y) - 777.0) * 0.8)
				warp_y_field[i] = lerp(v0, v1, t) * warp
			else:
				warp_x_field[i] = warp_noise.get_noise_2d(float(x) * 0.8 * noise_x_scale, float(y) * 0.8) * warp
				warp_y_field[i] = warp_noise.get_noise_2d((float(x) + 1000.0) * 0.8 * noise_x_scale, (float(y) - 777.0) * 0.8) * warp

	return {
		"fbm_base": fbm_base,
		"cont_base": cont_base,
		"warp_x": warp_x_field,
		"warp_y": warp_y_field,
	}

func generate(w: int, h: int, params: Dictionary) -> Dictionary:
	_ensure()
	if not _shader.is_valid() or not _pipeline.is_valid():
		return {}
	var size: int = max(0, w * h)
	if size == 0:
		return {}
	var sea_level: float = float(params.get("sea_level", 0.0))
	var wrap_x: bool = bool(params.get("wrap_x", true))
	var noise_x_scale: float = float(params.get("noise_x_scale", 1.0))
	var warp_amount: float = float(params.get("warp", 24.0))

	# If FBM shader is available, build noise fields on GPU; else fall back to CPU
	var buf_warp_x: RID
	var buf_warp_y: RID
	var buf_fbm: RID
	var buf_cont: RID
	var fbm_spirv: RDShaderSPIRV = _get_spirv(FBM_SHADER_FILE)
	if fbm_spirv != null:
		var fbm_shader: RID = _rd.shader_create_from_spirv(fbm_spirv)
		var fbm_pipeline: RID = _rd.compute_pipeline_create(fbm_shader)
		# Allocate outputs
		var out_fbm := PackedFloat32Array(); out_fbm.resize(size)
		var out_cont := PackedFloat32Array(); out_cont.resize(size)
		var out_wx := PackedFloat32Array(); out_wx.resize(size)
		var out_wy := PackedFloat32Array(); out_wy.resize(size)
		buf_fbm = _rd.storage_buffer_create(out_fbm.to_byte_array().size(), out_fbm.to_byte_array())
		buf_cont = _rd.storage_buffer_create(out_cont.to_byte_array().size(), out_cont.to_byte_array())
		buf_warp_x = _rd.storage_buffer_create(out_wx.to_byte_array().size(), out_wx.to_byte_array())
		buf_warp_y = _rd.storage_buffer_create(out_wy.to_byte_array().size(), out_wy.to_byte_array())
		# Bind and dispatch
		var uniforms_n: Array = []
		var un: RDUniform
		un = RDUniform.new(); un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; un.binding = 0; un.add_id(buf_fbm); uniforms_n.append(un)
		un = RDUniform.new(); un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; un.binding = 1; un.add_id(buf_cont); uniforms_n.append(un)
		un = RDUniform.new(); un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; un.binding = 2; un.add_id(buf_warp_x); uniforms_n.append(un)
		un = RDUniform.new(); un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; un.binding = 3; un.add_id(buf_warp_y); uniforms_n.append(un)
		var u_set_n := _rd.uniform_set_create(uniforms_n, fbm_shader, 0)
		var pc_n := PackedByteArray()
		# Order must match shader push constant struct exactly
		var ints_n := PackedInt32Array([w, h, 1, int(params.get("seed", 0))])
		var floats_n := PackedFloat32Array([
			float(params.get("frequency", 0.02)),
			max(0.002, float(params.get("frequency", 0.02)) * 0.4),
			float(params.get("noise_x_scale", 1.0)),
			float(params.get("warp", 24.0)),
			float(params.get("lacunarity", 2.0)),
			float(params.get("gain", 0.5)),
		])
		var ints_n_tail := PackedInt32Array([int(params.get("octaves", 5))])
		pc_n.append_array(ints_n.to_byte_array())
		pc_n.append_array(floats_n.to_byte_array())
		pc_n.append_array(ints_n_tail.to_byte_array())
		# Align to 16-byte multiple for Vulkan push constants
		var pad_n := (16 - (pc_n.size() % 16)) % 16
		if pad_n > 0:
			var zeros_n := PackedByteArray(); zeros_n.resize(pad_n)
			pc_n.append_array(zeros_n)
		var gx_n: int = int(ceil(float(w) / 16.0))
		var gy_n: int = int(ceil(float(h) / 16.0))
		var cl_n := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl_n, fbm_pipeline)
		_rd.compute_list_bind_uniform_set(cl_n, u_set_n, 0)
		_rd.compute_list_set_push_constant(cl_n, pc_n, pc_n.size())
		_rd.compute_list_dispatch(cl_n, gx_n, gy_n, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set_n)
		_rd.free_rid(fbm_pipeline)
		_rd.free_rid(fbm_shader)
	else:
		var nf: Dictionary = _build_noise_fields(w, h, params)
		buf_warp_x = _rd.storage_buffer_create(nf["warp_x"].to_byte_array().size(), nf["warp_x"].to_byte_array())
		buf_warp_y = _rd.storage_buffer_create(nf["warp_y"].to_byte_array().size(), nf["warp_y"].to_byte_array())
		buf_fbm = _rd.storage_buffer_create(nf["fbm_base"].to_byte_array().size(), nf["fbm_base"].to_byte_array())
		buf_cont = _rd.storage_buffer_create(nf["cont_base"].to_byte_array().size(), nf["cont_base"].to_byte_array())
	var out_height := PackedFloat32Array(); out_height.resize(size)
	var out_land_u32 := PackedInt32Array(); out_land_u32.resize(size)
	var buf_out_height := _rd.storage_buffer_create(out_height.to_byte_array().size(), out_height.to_byte_array())
	var buf_out_land := _rd.storage_buffer_create(out_land_u32.to_byte_array().size(), out_land_u32.to_byte_array())

	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_warp_x); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_warp_y); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_fbm); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_cont); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_out_height); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(buf_out_land); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, (1 if wrap_x else 0)])
	var floats := PackedFloat32Array([sea_level, noise_x_scale, warp_amount])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	# Align to 16-byte multiple
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
	# On main device, no explicit submit/sync

	var h_bytes := _rd.buffer_get_data(buf_out_height)
	var land_bytes := _rd.buffer_get_data(buf_out_land)
	var height_out: PackedFloat32Array = h_bytes.to_float32_array()
	var land_u32: PackedInt32Array = land_bytes.to_int32_array()
	var is_land := PackedByteArray()
	is_land.resize(size)
	for i2 in range(size):
		is_land[i2] = 1 if (i2 < land_u32.size() and land_u32[i2] != 0) else 0

	_rd.free_rid(u_set)
	_rd.free_rid(buf_warp_x)
	_rd.free_rid(buf_warp_y)
	_rd.free_rid(buf_fbm)
	_rd.free_rid(buf_cont)
	_rd.free_rid(buf_out_height)
	_rd.free_rid(buf_out_land)

	return {
		"height": height_out,
		"is_land": is_land,
	}
