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
	if chosen_version == null:
		return null
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

func compute_clouds_to_buffer(
		w: int,
		h: int,
		temp_buf: RID,
		moist_buf: RID,
		land_buf: RID,
		light_buf: RID,
		biome_buf: RID,
		phase: float,
		seed: int,
		out_buf: RID
	) -> bool:
	"""GPU-only: write clouds into an existing buffer (no readback)."""
	_ensure()
	if not _pipeline.is_valid():
		return false
	if not temp_buf.is_valid() or not moist_buf.is_valid() or not land_buf.is_valid() or not light_buf.is_valid() or not biome_buf.is_valid() or not out_buf.is_valid():
		return false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(temp_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(moist_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(light_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(biome_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(out_buf); uniforms.append(u)
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

func compute_clouds(
		w: int,
		h: int,
		temp: PackedFloat32Array,
		moist: PackedFloat32Array,
		is_land: PackedByteArray,
		light: PackedFloat32Array = PackedFloat32Array(),
		biomes: PackedInt32Array = PackedInt32Array(),
		phase: float = 0.0,
		seed: int = 0,
		_allow_cpu_fallback: bool = false
	) -> PackedFloat32Array:
	_ensure()
	if not _pipeline.is_valid():
		return PackedFloat32Array()
	var size: int = max(0, w * h)
	var buf_t := _rd.storage_buffer_create(temp.to_byte_array().size(), temp.to_byte_array())
	var buf_m := _rd.storage_buffer_create(moist.to_byte_array().size(), moist.to_byte_array())
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	for i in range(size): land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var light_vals := PackedFloat32Array(); light_vals.resize(size)
	if light.size() == size:
		light_vals = light
	else:
		light_vals.fill(0.75)
	var buf_light := _rd.storage_buffer_create(light_vals.to_byte_array().size(), light_vals.to_byte_array())
	var biome_vals := PackedInt32Array(); biome_vals.resize(size)
	if biomes.size() == size:
		biome_vals = biomes
	else:
		biome_vals.fill(0)
	var buf_biome := _rd.storage_buffer_create(biome_vals.to_byte_array().size(), biome_vals.to_byte_array())
	var clouds := PackedFloat32Array(); clouds.resize(size)
	var buf_out := _rd.storage_buffer_create(clouds.to_byte_array().size(), clouds.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_t); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_m); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_light); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_biome); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(buf_out); uniforms.append(u)
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
	_rd.free_rid(buf_light)
	_rd.free_rid(buf_biome)
	_rd.free_rid(buf_out)
	if out.size() != size:
		return PackedFloat32Array()
	return out
	
func _compute_clouds_cpu(
		w: int,
		h: int,
		temp: PackedFloat32Array,
		moist: PackedFloat32Array,
		is_land: PackedByteArray,
		light: PackedFloat32Array,
		biomes: PackedInt32Array,
		phase: float,
		seed: int
	) -> PackedFloat32Array:
	var size: int = max(0, w * h)
	var out := PackedFloat32Array()
	out.resize(size)
	if size == 0:
		return out
	var base_noise := FastNoiseLite.new()
	base_noise.seed = int(seed) ^ 0x13579BDF
	base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	base_noise.frequency = 1.0
	var low_noise := FastNoiseLite.new()
	low_noise.seed = int(seed) ^ 0x9E3779B
	low_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	low_noise.frequency = 1.0
	var seed_mod: float = float(seed % 4096)
	var light_vals := light
	if light_vals.size() != size:
		light_vals = PackedFloat32Array()
		light_vals.resize(size)
		light_vals.fill(0.75)
	for y in range(h):
		var lat_signed: float = (float(y) / float(max(1, h - 1)) - 0.5) * 2.0
		var abs_lat: float = abs(lat_signed)
		for x in range(w):
			var i: int = x + y * w
			var temp_v: float = clamp(temp[i] if i < temp.size() else 0.5, 0.0, 1.0)
			var humid_v: float = clamp(moist[i] if i < moist.size() else 0.5, 0.0, 1.0)
			var light_v: float = clamp(light_vals[i], 0.0, 1.0)
			var is_land_px: bool = (i < is_land.size() and is_land[i] != 0)
			var biome_id: int = biomes[i] if i < biomes.size() else 0
			var veg: float = _biome_vegetation_factor(biome_id) if is_land_px else 0.0
			var daylight: float = _smoothstep(0.18, 0.90, light_v)
			var night: float = 1.0 - daylight
			var warm: float = _smoothstep(0.30, 0.88, temp_v)
			var humid_drive: float = _smoothstep(0.26, 0.96, humid_v)
			var p := Vector2(float(x), float(y))
			var p_seeded := p + Vector2(seed_mod * 0.137, seed_mod * 0.071)
			var regime_p := p_seeded * 0.004 + Vector2(phase * 0.14, -phase * 0.10)
			regime_p.x += sin(TAU * (float(y) / float(max(1, h - 1)) * 0.8 + phase * 0.11)) * 5.0
			var regime: float = _fbm(low_noise, regime_p, 4) * 0.5 + 0.5
			var regime_mask: float = _smoothstep(0.30, 0.72, regime)
			var warp_a: Vector2 = _curl_noise(base_noise, p_seeded.x * 0.020 + phase * 0.22, p_seeded.y * 0.020 - phase * 0.18, 0.5)
			var warp_b: Vector2 = _curl_noise(low_noise, p_seeded.x * 0.045 - phase * 0.31, p_seeded.y * 0.045 + phase * 0.27, 0.5)
			var mid_p := p_seeded * 0.016 + warp_a * 2.6 + Vector2(phase * 0.55, -phase * 0.41)
			var mid: float = _fbm(base_noise, mid_p, 5) * 0.5 + 0.5
			var mid_core: float = _smoothstep(0.44, 0.80, mid)
			var cell: float = _worley(mid_p * 1.05 + warp_b * 1.2, seed)
			var billow: float = _smoothstep(0.22, 0.90, exp(-cell * 2.25))
			var high_p := p_seeded * 0.046 + warp_b * 3.4 + Vector2(phase * 0.95, -phase * 0.73)
			var wisps: float = _fbm(low_noise, high_p, 3) * 0.5 + 0.5
			wisps = _smoothstep(0.48, 0.84, wisps)
			var structure: float = (mid_core * 0.54 + billow * 0.34 + wisps * 0.12) * lerp(0.70, 1.25, regime_mask)
			var ocean_boost: float = 0.0 if is_land_px else (0.14 + 0.18 * warm + 0.10 * night)
			var veg_boost: float = (0.22 * veg * (0.45 + 0.55 * warm)) if is_land_px else 0.0
			var convective: float = (0.18 * daylight * warm) if is_land_px else (0.10 * daylight * warm)
			var night_stratus: float = (0.06 * night * humid_v) if is_land_px else (0.16 * night * humid_v)
			var lat_dry: float = _smoothstep(0.72, 1.0, abs_lat) * 0.12
			var potential: float = clamp(
				humid_drive * (0.54 + 0.46 * warm)
				+ ocean_boost
				+ veg_boost
				+ convective
				+ night_stratus
				- lat_dry,
				0.0,
				1.0
			)
			var threshold: float = lerp(0.66, 0.36, potential)
			var density: float = _smoothstep(threshold - 0.11, threshold + 0.12, structure)
			var anvil: float = _smoothstep(0.62, 0.92, wisps + mid * 0.35) * (0.35 + 0.65 * daylight * warm)
			var cov: float = density * (0.44 + 0.56 * potential) + anvil * 0.16 * potential
			cov *= lerp(0.82, 1.15, regime_mask)
			cov += humid_v * 0.08 * regime_mask
			out[i] = clamp(cov, 0.0, 1.0)
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

func _biome_vegetation_factor(biome_id: int) -> float:
	match biome_id:
		10, 11, 12, 13, 14, 15:
			return 1.0
		22, 23:
			return 0.75
		6, 7, 21, 29, 30, 33, 36, 37, 40:
			return 0.55
		16, 18, 19, 34, 41:
			return 0.22
		2:
			return 0.15
		3, 4, 5, 25, 26, 28:
			return 0.05
		_:
			return 0.18
