# File: res://scripts/systems/CloudOverlayCompute.gd
extends RefCounted

var CLOUD_SHADER_FILE: RDShaderFile = load("res://shaders/cloud_overlay.glsl")

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
		var s: RDShaderSPIRV = _get_spirv(CLOUD_SHADER_FILE)
		if s != null:
			_shader = _rd.shader_create_from_spirv(s)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)

func compute_clouds_to_buffer(w: int, h: int, temp_buf: RID, moist_buf: RID, land_buf: RID, phase: float, seed: int, out_buf: RID) -> bool:
	"""GPU-only: write clouds into an existing buffer (no readback)."""
	_ensure()
	if not _pipeline.is_valid():
		return false
	if not temp_buf.is_valid() or not moist_buf.is_valid() or not land_buf.is_valid() or not out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(out_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, seed])
	var floats := PackedFloat32Array([phase])
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
	_rd.free_rid(u_set)
	return true

func compute_clouds(w: int, h: int, temp: PackedFloat32Array, moist: PackedFloat32Array, is_land: PackedByteArray, phase: float, seed: int) -> PackedFloat32Array:
	_ensure()
	if not _pipeline.is_valid():
		return _compute_clouds_cpu(w, h, temp, moist, phase, seed)
	var size: int = max(0, w * h)
	var buf_t := _rd.storage_buffer_create(temp.to_byte_array().size(), temp.to_byte_array())
	var buf_m := _rd.storage_buffer_create(moist.to_byte_array().size(), moist.to_byte_array())
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	for i in range(size): land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var clouds := PackedFloat32Array(); clouds.resize(size)
	var buf_out := _rd.storage_buffer_create(clouds.to_byte_array().size(), clouds.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_t); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_m); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_out); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h, seed]); var floats := PackedFloat32Array([phase]);
	pc.append_array(ints.to_byte_array()); pc.append_array(floats.to_byte_array())
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
	var bytes := _rd.buffer_get_data(buf_out)
	var out := bytes.to_float32_array()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_t)
	_rd.free_rid(buf_m)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_out)
	if out.size() != size:
		return _compute_clouds_cpu(w, h, temp, moist, phase, seed)
	return out
	
func _compute_clouds_cpu(w: int, h: int, temp: PackedFloat32Array, moist: PackedFloat32Array, phase: float, seed: int) -> PackedFloat32Array:
	var size: int = max(0, w * h)
	var out := PackedFloat32Array()
	out.resize(size)
	if size == 0:
		return out
	var two_pi := TAU
	var base_noise := FastNoiseLite.new()
	base_noise.seed = int(seed) ^ 0x13579BDF
	base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	base_noise.frequency = 1.0
	var low_noise := FastNoiseLite.new()
	low_noise.seed = int(seed) ^ 0x9E3779B
	low_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	low_noise.frequency = 1.0
	for y in range(h):
		var lat_signed: float = (float(y) / float(max(1, h - 1)) - 0.5) * 2.0
		var lat: float = abs(lat_signed)
		var base: float = clamp(1.0 - 0.15 * lat, 0.0, 1.0)
		var mid: float = clamp(1.0 - abs(lat - 0.45) / 0.35, 0.0, 1.0)
		var wind_strength: float = pow(mid, 1.3)
		var eq: float = clamp(1.0 - lat / 0.25, 0.0, 1.0)
		eq = pow(eq, 1.15)
		var polar: float = clamp((lat - 0.65) / 0.35, 0.0, 1.0)
		polar = pow(polar, 1.1)
		var hem: float = 1.0 if lat_signed >= 0.0 else -1.0
		var eq_dir: float = -1.0
		var polar_dir: float = -1.0
		var drift_dir: float = hem * (1.0 - eq) * (1.0 - polar) + eq_dir * eq + polar_dir * polar
		var drift: float = drift_dir * (wind_strength + 0.5 * eq + 0.4 * polar) * phase * 12.0
		var drift_vec := Vector2(drift, 0.0)
		for x in range(w):
			var i: int = x + y * w
			var adv: float = 0.08 * sin(two_pi * (float(x) / float(max(1, w)) + phase))
			var p := Vector2(float(x), float(y)) * 0.035 + drift_vec
			var curl := _curl_noise(base_noise, p.x * 0.7, p.y * 0.7, 0.5)
			var pp := p + curl * 2.6 + Vector2(phase * 3.0, phase * 1.4)
			var wdist: float = _worley(pp * 1.0, seed)
			var worley_val: float = exp(-wdist * 2.3)
			var fbm_val: float = _fbm(base_noise, pp * 0.85, 4) * 0.5 + 0.5
			var noise: float = clamp(worley_val * 0.75 + fbm_val * 0.25, 0.0, 1.0)
			var large: float = _fbm(low_noise, Vector2(float(x), float(y)) * 0.004 + Vector2(float(seed % 997) * 0.02, float(seed % 503) * 0.031) + Vector2(phase * 2.0, -phase * 1.2) + drift_vec * 0.35, 3) * 0.5 + 0.5
			large = _smoothstep(0.3, 0.7, large)
			large = pow(large, 1.8)
			var large_mult: float = lerp(0.05, 1.7, large)
			var core: float = _smoothstep(0.35, 0.7, noise)
			var cov: float = base * (0.25 + 0.75 * core)
			cov = clamp((cov + adv * (0.2 + 0.8 * core)) * large_mult, 0.0, 1.0)
			var humid: float = 0.0
			if i < moist.size():
				humid = clamp(moist[i], 0.0, 1.0)
			var humid_boost: float = _smoothstep(0.2, 0.85, humid)
			cov = clamp(cov * (0.45 + 0.95 * humid_boost) + humid_boost * 0.08, 0.0, 1.0)
			out[i] = cov
	return out

func _hash_u32(x: int, y: int, seed: int) -> int:
	var h: int = x * 1664525 + y * 1013904223 + seed * 374761393
	h = int((h ^ (h >> 16)) * 2246822519)
	h = int((h ^ (h >> 13)) * 3266489917)
	h = int(h ^ (h >> 16))
	return h & 0xffffffff

func _hash_f(x: int, y: int, seed: int) -> float:
	return float(_hash_u32(x, y, seed)) / 4294967296.0

func _worley(p: Vector2, seed: int) -> float:
	var cell_x: int = int(floor(p.x))
	var cell_y: int = int(floor(p.y))
	var min_dist: float = 1e9
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cx: int = cell_x + dx
			var cy: int = cell_y + dy
			var rx: float = _hash_f(cx, cy, seed ^ 0xA1B2C3)
			var ry: float = _hash_f(cx, cy, seed ^ 0xC3B2A1)
			var fx: float = float(cx) + rx
			var fy: float = float(cy) + ry
			var dxp: float = fx - p.x
			var dyp: float = fy - p.y
			var d: float = dxp * dxp + dyp * dyp
			if d < min_dist:
				min_dist = d
	return sqrt(min_dist)

func _fbm(noise: FastNoiseLite, p: Vector2, octaves: int) -> float:
	var amp: float = 0.55
	var sum: float = 0.0
	var freq: float = 1.0
	for _i in range(octaves):
		sum += amp * noise.get_noise_2d(p.x * freq, p.y * freq)
		freq *= 2.0
		amp *= 0.5
	return sum

func _curl_noise(noise: FastNoiseLite, x: float, y: float, eps: float) -> Vector2:
	var n1: float = noise.get_noise_2d(x, y + eps)
	var n2: float = noise.get_noise_2d(x, y - eps)
	var n3: float = noise.get_noise_2d(x + eps, y)
	var n4: float = noise.get_noise_2d(x - eps, y)
	var grad_x: float = (n1 - n2) / (2.0 * eps)
	var grad_y: float = (n3 - n4) / (2.0 * eps)
	return Vector2(grad_x, -grad_y)

func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t: float = clamp((x - edge0) / max(0.0001, edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
