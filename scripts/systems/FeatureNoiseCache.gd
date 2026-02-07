# File: res://scripts/systems/FeatureNoiseCache.gd
extends RefCounted

## Shared low-frequency noise fields used across systems (desert split,
## glacier wiggle, shore noise, continental shelf pattern). Building these
## up-front avoids per-cell noise instantiation in hot loops.

var width: int = 0
var height: int = 0
var rng_seed: int = 0
var noise_x_scale: float = 1.0

var desert_noise_field: PackedFloat32Array = PackedFloat32Array()     # 0..1
var ice_wiggle_field: PackedFloat32Array = PackedFloat32Array()       # -1..1
var shore_noise_field: PackedFloat32Array = PackedFloat32Array()      # 0..1
var shelf_value_noise_field: PackedFloat32Array = PackedFloat32Array()# 0..1

var _rd: RenderingDevice
var _shader_file: RDShaderFile = load("res://shaders/feature_noise.glsl")
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
	if chosen_version == null:
		return null
	return file.get_spirv(chosen_version)

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _shader_file != null and not _shader.is_valid():
		var s: RDShaderSPIRV = _get_spirv(_shader_file)
		if s != null:
			_shader = _rd.shader_create_from_spirv(s)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func build(params: Dictionary) -> void:
	width = int(params.get("width", 256))
	height = int(params.get("height", 128))
	rng_seed = int(params.get("seed", 0))
	var base_freq: float = float(params.get("frequency", 0.02))
	noise_x_scale = float(params.get("noise_x_scale", 1.0))
	var shore_freq: float = max(0.01, base_freq * 4.0)
	_allocate()
	# Try GPU first
	_ensure()
	if _pipeline.is_valid():
		var size: int = max(0, width * height)
		var out_d: PackedFloat32Array = PackedFloat32Array(); out_d.resize(size)
		var out_i: PackedFloat32Array = PackedFloat32Array(); out_i.resize(size)
		var out_s: PackedFloat32Array = PackedFloat32Array(); out_s.resize(size)
		var out_v: PackedFloat32Array = PackedFloat32Array(); out_v.resize(size)
		var buf_d := _rd.storage_buffer_create(out_d.to_byte_array().size(), out_d.to_byte_array())
		var buf_i := _rd.storage_buffer_create(out_i.to_byte_array().size(), out_i.to_byte_array())
		var buf_s := _rd.storage_buffer_create(out_s.to_byte_array().size(), out_s.to_byte_array())
		var buf_v := _rd.storage_buffer_create(out_v.to_byte_array().size(), out_v.to_byte_array())
		var uniforms: Array = []
		var u: RDUniform
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_d); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_i); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_s); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_v); uniforms.append(u)
		var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
		var pc := PackedByteArray()
		var ints := PackedInt32Array([width, height, rng_seed])
		var floats := PackedFloat32Array([noise_x_scale, base_freq, shore_freq])
		pc.append_array(ints.to_byte_array()); pc.append_array(floats.to_byte_array())
		# Align to 16 bytes
		var pad := (16 - (pc.size() % 16)) % 16
		if pad > 0:
			var zeros := PackedByteArray(); zeros.resize(pad)
			pc.append_array(zeros)
		var gx: int = int(ceil(float(width) / 16.0))
		var gy: int = int(ceil(float(height) / 16.0))
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		_rd.compute_list_end()
		# Read back
		var d_bytes := _rd.buffer_get_data(buf_d)
		var i_bytes := _rd.buffer_get_data(buf_i)
		var s_bytes := _rd.buffer_get_data(buf_s)
		var v_bytes := _rd.buffer_get_data(buf_v)
		desert_noise_field = d_bytes.to_float32_array()
		ice_wiggle_field = i_bytes.to_float32_array()
		shore_noise_field = s_bytes.to_float32_array()
		shelf_value_noise_field = v_bytes.to_float32_array()
		_rd.free_rid(u_set)
		_rd.free_rid(buf_d)
		_rd.free_rid(buf_i)
		_rd.free_rid(buf_s)
		_rd.free_rid(buf_v)
		return
	# Fallback CPU
	_fill_desert_noise(rng_seed)
	_fill_ice_wiggle(rng_seed)
	_fill_shore_noise(rng_seed, shore_freq)
	_fill_shelf_value_noise(rng_seed ^ 0x5E1F)

func _allocate() -> void:
	var n: int = max(0, width * height)
	desert_noise_field.resize(n)
	ice_wiggle_field.resize(n)
	shore_noise_field.resize(n)
	shelf_value_noise_field.resize(n)

func _fill_desert_noise(s: int) -> void:
	var n := FastNoiseLite.new()
	n.seed = s ^ 0x00BEEF
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.008
	var xscale: float = max(0.0001, noise_x_scale)
	for y in range(height):
		for x in range(width):
			var i: int = x + y * width
			var t: float = float(x) / float(max(1, width))
			var n0: float = n.get_noise_2d(float(x) * xscale, float(y))
			var n1: float = n.get_noise_2d((float(x) + float(width)) * xscale, float(y))
			desert_noise_field[i] = lerp(n0, n1, t) * 0.5 + 0.5

func _fill_ice_wiggle(s: int) -> void:
	var n := FastNoiseLite.new()
	n.seed = s ^ 0x0001CE
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.01
	var xscale2: float = max(0.0001, noise_x_scale)
	for y in range(height):
		for x in range(width):
			var i: int = x + y * width
			var t: float = float(x) / float(max(1, width))
			var n0: float = n.get_noise_2d(float(x) * xscale2, float(y))
			var n1: float = n.get_noise_2d((float(x) + float(width)) * xscale2, float(y))
			ice_wiggle_field[i] = lerp(n0, n1, t) # -1..1

func _fill_shore_noise(s: int, freq: float) -> void:
	var n := FastNoiseLite.new()
	n.seed = s ^ 0xA5F1523D
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 3
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5
	var xscale3: float = max(0.0001, noise_x_scale)
	for y in range(height):
		for x in range(width):
			var i: int = x + y * width
			var t: float = float(x) / float(max(1, width))
			var n0: float = n.get_noise_2d(float(x) * xscale3, float(y))
			var n1: float = n.get_noise_2d((float(x) + float(width)) * xscale3, float(y))
			shore_noise_field[i] = lerp(n0, n1, t) * 0.5 + 0.5

func _fill_shelf_value_noise(s: int) -> void:
	# Coarse value-like noise as used by AsciiStyler for shelf variation.
	# Implement simple lattice hashing/interpolation here to avoid per-call cost.
	var scale: float = 20.0
	for y in range(height):
		for x in range(width):
			var i: int = x + y * width
			var t: float = float(x) / float(max(1, width))
			var sv0: float = _value_noise(float(x), float(y), scale, s)
			var sv1: float = _value_noise(float(x + width), float(y), scale, s)
			shelf_value_noise_field[i] = lerp(sv0, sv1, t)

func _value_noise(px: float, py: float, scale: float, s: int) -> float:
	var sx: float = px / max(0.0001, scale)
	var sy: float = py / max(0.0001, scale)
	var xi: int = int(floor(sx))
	var yi: int = int(floor(sy))
	var tx: float = sx - float(xi)
	var ty: float = sy - float(yi)
	var h00: float = float(_hash(xi + 0, yi + 0, s) % 1000) / 1000.0
	var h10: float = float(_hash(xi + 1, yi + 0, s) % 1000) / 1000.0
	var h01: float = float(_hash(xi + 0, yi + 1, s) % 1000) / 1000.0
	var h11: float = float(_hash(xi + 1, yi + 1, s) % 1000) / 1000.0
	var nx0: float = lerp(h00, h10, tx)
	var nx1: float = lerp(h01, h11, tx)
	return lerp(nx0, nx1, ty)

static func _hash(x: int, y: int, s: int) -> int:
	return abs(int(x) * 73856093 ^ int(y) * 19349663 ^ int(s) * 83492791)
