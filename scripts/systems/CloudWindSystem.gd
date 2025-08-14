# File: res://scripts/systems/CloudWindSystem.gd
extends RefCounted

# Cloud/wind basic: generate wind bands with eddies and advect clouds each cadence.
# Also reuse CloudOverlayCompute as a humidity-driven source/injection field.

var generator: Object = null
var cloud_compute: Object = null
var coupling_enabled: bool = true
var base_rain_strength: float = 0.08
var base_evap_strength: float = 0.06

# Wind and advection params (cells per simulated day)
var adv_cells_per_day: float = 6.0
var diffusion_rate_per_day: float = 0.08
var injection_rate_per_day: float = 0.12

# Cycle modulation (UI-tunable): scales diurnal/seasonal effects on clouds/wind
var diurnal_mod_amp: float = 0.5
var seasonal_mod_amp: float = 0.5

var wind_u: PackedFloat32Array = PackedFloat32Array()
var wind_v: PackedFloat32Array = PackedFloat32Array()
var _tmp_clouds: PackedFloat32Array = PackedFloat32Array()
var _noise_u: FastNoiseLite
var _noise_v: FastNoiseLite
var _advec_shader: RDShaderFile = load("res://shaders/cloud_advection.glsl")
var _advec_shader_rid: RID
var _advec_pipeline: RID
var _wind_shader: RDShaderFile = load("res://shaders/wind_field.glsl")
var _wind_shader_rid: RID
var _wind_pipeline: RID

func initialize(gen: Object) -> void:
	generator = gen
	cloud_compute = load("res://scripts/systems/CloudOverlayCompute.gd").new()
	_noise_u = FastNoiseLite.new()
	_noise_v = FastNoiseLite.new()
	if "config" in generator:
		var rng_seed_local: int = int(generator.config.rng_seed)
		_noise_u.seed = rng_seed_local ^ 0xC0FFEE
		_noise_v.seed = rng_seed_local ^ 0xBADC0DE
	_noise_u.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_v.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_u.frequency = 0.015
	_noise_v.frequency = 0.015
	# Prepare advection shader if available
	var rd := RenderingServer.create_local_rendering_device()
	if _advec_shader != null:
		var spirv := _advec_shader.get_spirv() if "get_spirv" in _advec_shader else null
		if spirv != null:
			_advec_shader_rid = rd.shader_create_from_spirv(spirv)
			_advec_pipeline = rd.compute_pipeline_create(_advec_shader_rid)
	if _wind_shader != null:
		var spirv2 := _wind_shader.get_spirv() if "get_spirv" in _wind_shader else null
		if spirv2 != null:
			_wind_shader_rid = rd.shader_create_from_spirv(spirv2)
			_wind_pipeline = rd.compute_pipeline_create(_wind_shader_rid)

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null or world == null:
		return {}
	var w: int = generator.config.width
	var h: int = generator.config.height
	if generator.last_temperature.size() != w * h or generator.last_moisture.size() != w * h:
		return {}
	_ensure_buffers(w, h)
	# 1) Update wind field (bands + eddies evolving with phase)
	# GPU-only: wind update via compute if pipeline is ready; else skip
	var _prefer_gpu: bool = true
	var sim_days: float = float(world.simulation_time_days)
	var tod: float = fposmod(sim_days, 1.0)
	var doy: float = fposmod(sim_days / 365.0, 1.0)
	var diurnal_factor: float = 0.5 - 0.5 * cos(6.28318 * tod) # 0 at midnight, 1 at midday
	var seasonal_factor: float = cos(6.28318 * doy)
	if _wind_pipeline.is_valid():
		_update_wind_field_gpu(world, w, h)
	# 2) Build humidity-driven source field via GPU overlay compute
	var phase: float = fposmod(float(world.simulation_time_days) / 365.0, 1.0)
	var source: PackedFloat32Array = PackedFloat32Array()
	if cloud_compute and "compute_clouds" in cloud_compute:
		source = cloud_compute.compute_clouds(w, h, generator.last_temperature, generator.last_moisture, generator.last_is_land, phase)
	if source.size() != w * h:
		return {}
	# 3) Initialize clouds if missing; else advect previous field
	if generator.last_clouds.size() != w * h:
		generator.last_clouds = source
	else:
		# GPU-only advection; if pipeline missing, skip advection this tick
		var _prefer_gpu_adv: bool = true
		if _advec_pipeline.is_valid():
			_advect_and_mix_clouds_gpu(dt_days, w, h, source)
	# 4) Moisture coupling with diurnal/seasonal modulation
	if coupling_enabled:
		var rain_mult: float = 1.0 + diurnal_mod_amp * (diurnal_factor - 0.5) * 0.6 + seasonal_mod_amp * seasonal_factor * 0.2
		var evap_mult: float = 1.0 - diurnal_mod_amp * (diurnal_factor - 0.5) * 0.3 - seasonal_mod_amp * seasonal_factor * 0.1
		rain_mult = clamp(rain_mult, 0.5, 1.6)
		evap_mult = clamp(evap_mult, 0.5, 1.6)
		_apply_cloud_moisture_coupling(dt_days, w, h, rain_mult, evap_mult)
	return {"dirty_fields": PackedStringArray(["wind", "clouds", "moisture"]) }

func _apply_cloud_moisture_coupling(dt_days: float, w: int, h: int, rain_mult: float, evap_mult: float) -> void:
	if generator == null:
		return
	var _size: int = w * h
	if generator.last_moisture.size() != _size or generator.last_clouds.size() != _size:
		return
	# Rates per simulated day (tuned conservatively, scaled by base strengths)
	var rain_rate_land: float = base_rain_strength * rain_mult
	var rain_rate_ocean: float = base_rain_strength * 0.65 * rain_mult
	var evap_rate_ocean: float = base_evap_strength * evap_mult
	var evap_rate_land: float = base_evap_strength * 0.5 * evap_mult
	var m: PackedFloat32Array = generator.last_moisture
	var c: PackedFloat32Array = generator.last_clouds
	var is_land: PackedByteArray = generator.last_is_land
	for i in range(_size):
		var land: bool = (i < is_land.size()) and (is_land[i] != 0)
		var cloud_cov: float = clamp(c[i], 0.0, 1.0)
		var rain_rate: float = rain_rate_land if land else rain_rate_ocean
		var evap_rate: float = evap_rate_land if land else evap_rate_ocean
		var delta: float = dt_days * (rain_rate * cloud_cov - evap_rate * (1.0 - cloud_cov))
		m[i] = clamp(m[i] + delta, 0.0, 1.0)
	generator.last_moisture = m

func _ensure_buffers(w: int, h: int) -> void:
	var size: int = w * h
	if wind_u.size() != size:
		wind_u.resize(size)
	if wind_v.size() != size:
		wind_v.resize(size)
	if _tmp_clouds.size() != size:
		_tmp_clouds.resize(size)

func _update_wind_field(world: Object, w: int, h: int) -> void:
	var _size: int = w * h
	var t: float = float(world.simulation_time_days)
	var phase: float = fposmod(t * 0.03, 1.0)
	for y in range(h):
		var lat: float = abs(float(y) / max(1.0, float(h) - 1.0) - 0.5) * 2.0
		# Zonal bands: negative u near equator (easterlies), positive u at mid-lats (westerlies), negative near poles
		var band_u: float = 0.0
		if lat < 0.3:
			band_u = -1.0
		elif lat < 0.7:
			band_u = 0.8
		else:
			band_u = -0.6
		for x in range(w):
			var i: int = x + y * w
			# Eddy noise adds curl-like local variation
			var nx: float = float(x) * 0.05
			var ny: float = float(y) * 0.05
			var nu: float = 0.35 * _noise_u.get_noise_2d(nx + phase * 20.0, ny - phase * 10.0)
			var nv: float = 0.35 * _noise_v.get_noise_2d(nx - phase * 15.0, ny + phase * 18.0)
			# Seasonal/diurnal scaling of band strength
			var sim_days: float = float(world.simulation_time_days)
			var tod: float = fposmod(sim_days, 1.0)
			var doy: float = fposmod(sim_days / 365.0, 1.0)
			var diurnal_factor: float = 0.5 - 0.5 * cos(6.28318 * tod)
			var seasonal_factor: float = cos(6.28318 * doy)
			var wind_mult: float = 1.0 + seasonal_mod_amp * seasonal_factor * 0.2 + diurnal_mod_amp * (diurnal_factor - 0.5) * 0.1
			wind_u[i] = (band_u * wind_mult) + nu
			# Meridional component small and sign-changing with latitude
			var v_band: float = 0.25 * sin(6.28318 * lat * 1.5)
			wind_v[i] = (v_band * wind_mult) + nv * 0.6

func _update_wind_field_gpu(world: Object, w: int, h: int) -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if not _wind_pipeline.is_valid():
		return
	var size: int = w * h
	if wind_u.size() != size: wind_u.resize(size)
	if wind_v.size() != size: wind_v.resize(size)
	var u_buf := rd.storage_buffer_create(wind_u.to_byte_array().size(), wind_u.to_byte_array())
	var v_buf := rd.storage_buffer_create(wind_v.to_byte_array().size(), wind_v.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(u_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(v_buf); uniforms.append(u)
	var u_set := rd.uniform_set_create(uniforms, _wind_shader_rid, 0)
	var phase: float = fposmod(float(world.simulation_time_days) * 0.03, 1.0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([phase])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _wind_pipeline)
	rd.compute_list_bind_uniform_set(cl, u_set, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, gx, gy, 1)
	rd.compute_list_end()
	# Read back wind
	var u_bytes := rd.buffer_get_data(u_buf)
	var v_bytes := rd.buffer_get_data(v_buf)
	wind_u = u_bytes.to_float32_array()
	wind_v = v_bytes.to_float32_array()
	rd.free_rid(u_set)
	rd.free_rid(u_buf)
	rd.free_rid(v_buf)

func _advect_and_mix_clouds(dt_days: float, w: int, h: int, source: PackedFloat32Array) -> void:
	var size: int = w * h
	var adv_scale: float = max(0.0, adv_cells_per_day) * dt_days
	var diff_alpha: float = clamp(diffusion_rate_per_day * dt_days, 0.0, 1.0)
	var inj_alpha: float = clamp(injection_rate_per_day * dt_days, 0.0, 1.0)
	var prev: PackedFloat32Array = generator.last_clouds
	# Semi-Lagrangian advection with wrap-X
	for y in range(h):
		for x in range(w):
			var i: int = x + y * w
			var u: float = wind_u[i]
			var v: float = wind_v[i]
			var sx: float = float(x) - adv_scale * u
			var sy: float = float(y) - adv_scale * v
			var adv_val: float = _sample_bilinear_wrap_x(prev, w, h, sx, sy)
			_tmp_clouds[i] = adv_val
	# Diffusion toward neighborhood mean
	for y2 in range(h):
		for x2 in range(w):
			var i2: int = x2 + y2 * w
			var l: int = ((x2 - 1 + w) % w) + y2 * w
			var r: int = ((x2 + 1) % w) + y2 * w
			var t: int = x2 + max(0, y2 - 1) * w
			var b: int = x2 + min(h - 1, y2 + 1) * w
			var nbr: float = ( _tmp_clouds[l] + _tmp_clouds[r] + _tmp_clouds[t] + _tmp_clouds[b] ) * 0.25
			_tmp_clouds[i2] = lerp(_tmp_clouds[i2], nbr, diff_alpha)
	# Injection from humidity-driven source
	for i3 in range(size):
		_tmp_clouds[i3] = clamp(_tmp_clouds[i3] * (1.0 - inj_alpha) + source[i3] * inj_alpha, 0.0, 1.0)
	generator.last_clouds = _tmp_clouds.duplicate()

func _advect_and_mix_clouds_gpu(dt_days: float, w: int, h: int, source: PackedFloat32Array) -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if not _advec_pipeline.is_valid():
		return
	var size: int = w * h
	var in_buf := rd.storage_buffer_create(generator.last_clouds.to_byte_array().size(), generator.last_clouds.to_byte_array())
	var u_buf := rd.storage_buffer_create(wind_u.to_byte_array().size(), wind_u.to_byte_array())
	var v_buf := rd.storage_buffer_create(wind_v.to_byte_array().size(), wind_v.to_byte_array())
	var src_buf := rd.storage_buffer_create(source.to_byte_array().size(), source.to_byte_array())
	var out_arr := PackedFloat32Array(); out_arr.resize(size)
	var out_buf := rd.storage_buffer_create(out_arr.to_byte_array().size(), out_arr.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(u_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(v_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(src_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(out_buf); uniforms.append(u)
	var u_set := rd.uniform_set_create(uniforms, _advec_shader_rid, 0)
	var adv_scale: float = max(0.0, adv_cells_per_day) * dt_days
	var diff_alpha: float = clamp(diffusion_rate_per_day * dt_days, 0.0, 1.0)
	var inj_alpha: float = clamp(injection_rate_per_day * dt_days, 0.0, 1.0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([adv_scale, diff_alpha, inj_alpha])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _advec_pipeline)
	rd.compute_list_bind_uniform_set(cl, u_set, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, gx, gy, 1)
	rd.compute_list_end()
	var out_bytes := rd.buffer_get_data(out_buf)
	generator.last_clouds = out_bytes.to_float32_array()
	rd.free_rid(u_set)
	rd.free_rid(in_buf)
	rd.free_rid(u_buf)
	rd.free_rid(v_buf)
	rd.free_rid(src_buf)
	rd.free_rid(out_buf)

func _sample_bilinear_wrap_x(arr: PackedFloat32Array, w: int, h: int, fx: float, fy: float) -> float:
	# Wrap horizontally, clamp vertically
	var x: float = fx
	var y: float = clamp(fy, 0.0, float(h - 1))
	var x0i: int = int(floor(x))
	var y0: int = int(floor(y))
	var tx: float = x - float(x0i)
	var ty: float = y - float(y0)
	var x0: int = ((x0i % w) + w) % w
	var x1: int = (x0 + 1) % w
	var y1: int = min(y0 + 1, h - 1)
	var i00: int = x0 + y0 * w
	var i10: int = x1 + y0 * w
	var i01: int = x0 + y1 * w
	var i11: int = x1 + y1 * w
	var v00: float = arr[i00]
	var v10: float = arr[i10]
	var v01: float = arr[i01]
	var v11: float = arr[i11]
	var vx0: float = lerp(v00, v10, tx)
	var vx1: float = lerp(v01, v11, tx)
	return lerp(vx0, vx1, ty)

func set_coupling_enabled(v: bool) -> void:
	coupling_enabled = v

func set_coupling(rain_strength: float, evap_strength: float) -> void:
	base_rain_strength = clamp(rain_strength, 0.0, 0.5)
	base_evap_strength = clamp(evap_strength, 0.0, 0.5)

func set_cycle_modulation(diurnal_amp: float, seasonal_amp: float) -> void:
	diurnal_mod_amp = clamp(diurnal_amp, 0.0, 2.0)
	seasonal_mod_amp = clamp(seasonal_amp, 0.0, 2.0)
