# File: res://scripts/systems/CloudWindSystem.gd
extends RefCounted

# Cloud/wind basic: generate wind bands with eddies and advect clouds each cadence.
# Also reuse CloudOverlayCompute as a humidity-driven source/injection field.

var generator: Object = null
var cloud_compute: Object = null
var time_system: Object = null
var coupling_enabled: bool = true
var base_rain_strength: float = 0.09
var base_evap_strength: float = 0.10

# Wind and advection params (cells per simulated day)
var adv_cells_per_day: float = 4.6
var diffusion_rate_per_day: float = 0.006
var injection_rate_per_day: float = 0.020
var cloud_time_scale: float = 7.0
var cloud_phase_speed: float = 0.28
var cloud_floor: float = 0.0
var cloud_contrast: float = 1.02
var min_cloud_global: float = 0.0
var curl_strength: float = 0.35
var cloud_injection_scale: float = 55.0
var cloud_injection_min: float = 0.0
var structure_sharpen: float = 0.02
var source_pin_strength: float = 0.20
var detail_preserve: float = 0.86
var cloud_decay_rate_per_day: float = 2.1
var cloud_dissipation_rate_per_day: float = 3.6
var max_cloud_step_days: float = 0.16
var max_moist_step_days: float = 0.14
var max_substeps_per_tick: int = 2
var max_adv_shift_cells: float = 1.8
var max_diff_alpha: float = 0.35
var max_decay_alpha: float = 0.30
var max_injection_alpha: float = 0.14
var polar_flow_strength: float = 0.45
var polar_flow_dir: float = -1.0
var polar_curl_boost: float = 0.25
var vortex_rotate_strength: float = 0.6
var humidity_mix_rate_per_day: float = 0.09
var humidity_relax_rate_per_day: float = 0.05
var condensation_rate_per_day: float = 0.10
var precipitation_rate_per_day: float = 0.18
var vegetation_evap_boost: float = 0.55

# Cycle modulation (UI-tunable): scales diurnal/seasonal effects on clouds/wind
var diurnal_mod_amp: float = 0.5
var seasonal_mod_amp: float = 0.5

var wind_u: PackedFloat32Array = PackedFloat32Array()
var wind_v: PackedFloat32Array = PackedFloat32Array()
var _tmp_clouds: PackedFloat32Array = PackedFloat32Array()
var _noise_u: FastNoiseLite
var _noise_v: FastNoiseLite
var _noise_curl: FastNoiseLite
var _noise_curl2: FastNoiseLite
var _advec_shader: RDShaderFile = load("res://shaders/cloud_advection.glsl")
var _advec_shader_rid: RID
var _advec_pipeline: RID
var _wind_shader: RDShaderFile = load("res://shaders/wind_field.glsl")
var _wind_shader_rid: RID
var _wind_pipeline: RID
var _moist_shader: RDShaderFile = load("res://shaders/cloud_moisture_couple.glsl")
var _moist_shader_rid: RID
var _moist_pipeline: RID
var _warned_gpu: bool = false
var _cloud_tex: Object = null
var _cloud_buf_a: RID
var _cloud_buf_b: RID
var _cloud_flip: bool = false
var _wind_gpu_valid: bool = false
var _seed_cache: int = -2147483648
var _gpu_manager_ref: Object = null
var _buffer_size: int = -1
var updates_paused: bool = false
var wind_update_interval_ticks: int = 1
var source_update_interval_ticks: int = 1
var advection_update_interval_ticks: int = 1
var moisture_update_interval_ticks: int = 1
var texture_update_interval_ticks: int = 1
var _tick_counter: int = 0
var _last_wind_tick: int = -1000000
var _last_source_tick: int = -1000000
var _last_advection_tick: int = -1000000
var _last_moisture_tick: int = -1000000
var _last_texture_tick: int = -1000000
var _force_resync: bool = true

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

func initialize(gen: Object, time_sys: Object = null) -> void:
	generator = gen
	time_system = time_sys
	cloud_compute = load("res://scripts/systems/CloudOverlayCompute.gd").new()
	_noise_u = FastNoiseLite.new()
	_noise_v = FastNoiseLite.new()
	_noise_curl = FastNoiseLite.new()
	_noise_curl2 = FastNoiseLite.new()
	# Preserve generated cloud state on startup; only reset local compute bindings.
	_sync_seed(false)
	_noise_u.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_v.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_u.frequency = 0.015
	_noise_v.frequency = 0.015
	_noise_curl.noise_type = FastNoiseLite.TYPE_CELLULAR
	_noise_curl.frequency = 0.02
	_noise_curl2.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_curl2.frequency = 0.08
	_cloud_tex = load("res://scripts/systems/CloudTextureCompute.gd").new()
	# Prepare advection shader if available
	var rd := RenderingServer.get_rendering_device()
	if _advec_shader != null:
		var spirv := _get_spirv(_advec_shader)
		if spirv != null:
			_advec_shader_rid = rd.shader_create_from_spirv(spirv)
			_advec_pipeline = rd.compute_pipeline_create(_advec_shader_rid)
	if _wind_shader != null:
		var spirv2 := _get_spirv(_wind_shader)
		if spirv2 != null:
			_wind_shader_rid = rd.shader_create_from_spirv(spirv2)
			_wind_pipeline = rd.compute_pipeline_create(_wind_shader_rid)
	if _moist_shader != null:
		var spirv3 := _get_spirv(_moist_shader)
		if spirv3 != null:
			_moist_shader_rid = rd.shader_create_from_spirv(spirv3)
			_moist_pipeline = rd.compute_pipeline_create(_moist_shader_rid)
	_force_resync = true
	_tick_counter = 0
	_last_wind_tick = -1000000
	_last_source_tick = -1000000
	_last_advection_tick = -1000000
	_last_moisture_tick = -1000000
	_last_texture_tick = -1000000

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null or world == null:
		return {}
	_sync_seed(false)
	var w: int = generator.config.width
	var h: int = generator.config.height
	_sync_gpu_manager(w, h)
	if generator.last_temperature.size() != w * h or generator.last_moisture.size() != w * h:
		return {}
	_tick_counter += 1
	if updates_paused:
		return {}
	if not _wind_pipeline.is_valid() or not _advec_pipeline.is_valid():
		# GPU-only mode: do not fall back to CPU if pipelines are missing
		return {}
	_ensure_buffers(w, h)
	var dirty_fields := PackedStringArray()
	var force_update: bool = _force_resync
	# 1) Update wind field (bands + eddies evolving with phase)
	# GPU-only: wind update via compute if pipeline is ready; else skip.
	var sim_days: float = float(world.simulation_time_days)
	var tod: float = fposmod(sim_days, 1.0)
	var days_per_year = time_system.get_days_per_year() if time_system and "get_days_per_year" in time_system else 365.0
	var doy: float = fposmod(sim_days / days_per_year, 1.0)
	var diurnal_factor: float = 0.5 - 0.5 * cos(6.28318 * tod) # 0 at midnight, 1 at midday
	var seasonal_factor: float = cos(6.28318 * doy)
	var do_wind_update: bool = force_update or ((_tick_counter - _last_wind_tick) >= max(1, wind_update_interval_ticks))
	if do_wind_update and _wind_pipeline.is_valid():
		_update_wind_field_gpu(world, w, h)
		_last_wind_tick = _tick_counter
		dirty_fields.append("wind")
	else:
		if not _wind_gpu_valid:
			return {}
	# 2) Build humidity-driven source field via GPU overlay compute
	# Keep phase bounded to avoid precision artifacts at very high time acceleration.
	var phase: float = fposmod(float(world.simulation_time_days) * cloud_phase_speed, 1024.0)
	var source_buf_override: RID = RID()
	var use_gpu_source: bool = (cloud_compute and "compute_clouds_to_buffer" in cloud_compute)
	var do_source_update: bool = force_update or ((_tick_counter - _last_source_tick) >= max(1, source_update_interval_ticks))
	if use_gpu_source and do_source_update:
		if "ensure_persistent_buffers" in generator:
			generator.ensure_persistent_buffers(false)
		var temp_buf: RID = generator.get_persistent_buffer("temperature") if "get_persistent_buffer" in generator else RID()
		var moist_buf: RID = generator.get_persistent_buffer("moisture") if "get_persistent_buffer" in generator else RID()
		var land_buf: RID = generator.get_persistent_buffer("is_land") if "get_persistent_buffer" in generator else RID()
		var light_buf: RID = generator.get_persistent_buffer("light") if "get_persistent_buffer" in generator else RID()
		var biome_buf: RID = generator.get_persistent_buffer("biome_id") if "get_persistent_buffer" in generator else RID()
		source_buf_override = generator.get_persistent_buffer("cloud_source") if "get_persistent_buffer" in generator else RID()
		var ok_src: bool = false
		if temp_buf.is_valid() and moist_buf.is_valid() and land_buf.is_valid() and light_buf.is_valid() and biome_buf.is_valid() and source_buf_override.is_valid():
			ok_src = cloud_compute.compute_clouds_to_buffer(
				w,
				h,
				temp_buf,
				moist_buf,
				land_buf,
				light_buf,
				biome_buf,
				phase,
				int(generator.config.rng_seed),
				source_buf_override
			)
		if not ok_src:
			source_buf_override = RID()
		else:
			_last_source_tick = _tick_counter
	else:
		source_buf_override = generator.get_persistent_buffer("cloud_source") if "get_persistent_buffer" in generator else RID()
	if not source_buf_override.is_valid():
		return {}
	# 3) Initialize clouds if missing; else advect previous field
	if generator.last_clouds.size() != w * h:
		generator.last_clouds.resize(w * h)
		generator.last_clouds.fill(0.0)
		_setup_cloud_buffers(w, h)
	var clouds_changed: bool = false
	var moisture_changed: bool = false
	# GPU-only advection; substep large dt for stability at high time acceleration.
	var do_advection: bool = force_update or ((_tick_counter - _last_advection_tick) >= max(1, advection_update_interval_ticks))
	if _advec_pipeline.is_valid() and do_advection:
		var adv_dt_input: float = max(0.0, dt_days)
		if force_update:
			# After high-speed skips, use a small guaranteed step to re-form cloud structure quickly.
			adv_dt_input = max(adv_dt_input, 0.08)
		var advec_steps: int = int(clamp(ceil(adv_dt_input / max(0.0001, max_cloud_step_days)), 1.0, float(max_substeps_per_tick)))
		var advec_dt: float = adv_dt_input / float(max(1, advec_steps))
		for _s in range(advec_steps):
			_advect_and_mix_clouds_gpu(advec_dt, w, h, PackedFloat32Array(), source_buf_override)
		_last_advection_tick = _tick_counter
		clouds_changed = true
		dirty_fields.append("clouds")
	else:
		if force_update:
			return {}
	# 4) Moisture coupling with diurnal/seasonal modulation
	var do_moisture: bool = force_update or ((_tick_counter - _last_moisture_tick) >= max(1, moisture_update_interval_ticks))
	if coupling_enabled and do_moisture and clouds_changed:
		var rain_mult: float = 1.0 + diurnal_mod_amp * (diurnal_factor - 0.5) * 0.6 + seasonal_mod_amp * seasonal_factor * 0.2
		var evap_mult: float = 1.0 - diurnal_mod_amp * (diurnal_factor - 0.5) * 0.3 - seasonal_mod_amp * seasonal_factor * 0.1
		rain_mult = clamp(rain_mult, 0.5, 1.6)
		evap_mult = clamp(evap_mult, 0.5, 1.6)
		if _moist_pipeline.is_valid():
			var moist_steps: int = int(clamp(ceil(dt_days / max(0.0001, max_moist_step_days)), 1.0, float(max_substeps_per_tick)))
			var moist_dt: float = dt_days / float(max(1, moist_steps))
			for _m in range(moist_steps):
				_apply_cloud_moisture_coupling_gpu(moist_dt, w, h, rain_mult, evap_mult)
			moisture_changed = true
			_last_moisture_tick = _tick_counter
			dirty_fields.append("moisture")
	var do_texture_update: bool = force_update or ((clouds_changed or moisture_changed) and ((_tick_counter - _last_texture_tick) >= max(1, texture_update_interval_ticks)))
	if do_texture_update:
		_update_cloud_texture_gpu(w, h)
		_last_texture_tick = _tick_counter
	_force_resync = false
	if dirty_fields.size() == 0:
		return {}
	return {"dirty_fields": dirty_fields }

func _apply_cloud_moisture_coupling(dt_days: float, w: int, h: int, rain_mult: float, evap_mult: float) -> void:
	if generator == null:
		return
	var _size: int = w * h
	if generator.last_moisture.size() != _size or generator.last_clouds.size() != _size or generator.last_temperature.size() != _size:
		return
	var rain_rate_land: float = base_rain_strength * rain_mult
	var rain_rate_ocean: float = base_rain_strength * 0.65 * rain_mult
	var evap_rate_ocean: float = base_evap_strength * evap_mult
	var evap_rate_land: float = base_evap_strength * 0.5 * evap_mult
	var m: PackedFloat32Array = generator.last_moisture
	var c: PackedFloat32Array = generator.last_clouds
	var is_land: PackedByteArray = generator.last_is_land
	var t: PackedFloat32Array = generator.last_temperature
	var l: PackedFloat32Array = generator.last_light if generator.last_light.size() == _size else PackedFloat32Array()
	if l.size() != _size:
		l.resize(_size)
		l.fill(0.75)
	var biomes: PackedInt32Array = generator.last_biomes
	var relax_rate: float = humidity_relax_rate_per_day + humidity_mix_rate_per_day
	for i in range(_size):
		var land: bool = (i < is_land.size()) and (is_land[i] != 0)
		var cloud_cov: float = clamp(c[i], 0.0, 1.0)
		var moist_val: float = clamp(m[i], 0.0, 1.0)
		var temp_val: float = clamp(t[i], 0.0, 1.0)
		var light_val: float = clamp(l[i], 0.0, 1.0)
		var day: float = _smoothstep(0.18, 0.90, light_val)
		var night: float = 1.0 - day
		var warm: float = _smoothstep(0.30, 0.90, temp_val)
		var veg: float = 0.0
		if land:
			var bid: int = biomes[i] if i < biomes.size() else 0
			veg = _biome_vegetation_factor(bid)
		var evap_rate: float = (evap_rate_land if land else evap_rate_ocean) * (0.45 + 1.05 * warm) * ((0.30 + 0.90 * day) if land else (0.55 + 0.60 * day)) * (1.0 - 0.30 * cloud_cov)
		var transp: float = (evap_rate_land * vegetation_evap_boost * veg * (0.30 + 0.70 * warm) * (0.25 + 0.75 * day) * (1.0 - 0.25 * cloud_cov)) if land else 0.0
		var target: float = clamp(0.28 + 0.20 * warm + 0.30 * veg + 0.12 * night, 0.0, 1.0) if land else clamp(0.60 + 0.28 * warm + 0.08 * night, 0.0, 1.0)
		var relax: float = relax_rate * (target - moist_val)
		var condense: float = condensation_rate_per_day * cloud_cov * (0.35 + 0.65 * night + max(0.0, moist_val - target) * 0.5)
		var rain_rate: float = rain_rate_land if land else rain_rate_ocean
		var precip: float = rain_rate * precipitation_rate_per_day * cloud_cov * cloud_cov * (0.40 + 0.60 * night)
		var delta: float = dt_days * (evap_rate + transp + relax - condense - precip)
		var moist_new: float = clamp(moist_val + delta, 0.0, 1.0)
		m[i] = moist_new
		var subsat: float = clamp(target - moist_new + 0.20, 0.0, 1.0)
		var rainout_loss: float = cloud_dissipation_rate_per_day * precip * (0.40 + 0.60 * night)
		var dry_loss: float = cloud_dissipation_rate_per_day * subsat * (0.25 + 0.75 * day)
		var loss: float = clamp(dt_days * (rainout_loss + dry_loss), 0.0, 1.0)
		c[i] = clamp(cloud_cov * (1.0 - loss), 0.0, 1.0)
	generator.last_moisture = m
	generator.last_clouds = c

func _apply_cloud_moisture_coupling_gpu(dt_days: float, w: int, h: int, rain_mult: float, evap_mult: float) -> void:
	if generator == null:
		return
	if not _moist_pipeline.is_valid():
		return
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)
	var cloud_buf := _cloud_buf_b if _cloud_flip else _cloud_buf_a
	var moist_buf: RID = generator.get_persistent_buffer("moisture") if "get_persistent_buffer" in generator else RID()
	var land_buf: RID = generator.get_persistent_buffer("is_land") if "get_persistent_buffer" in generator else RID()
	var temp_buf: RID = generator.get_persistent_buffer("temperature") if "get_persistent_buffer" in generator else RID()
	var light_buf: RID = generator.get_persistent_buffer("light") if "get_persistent_buffer" in generator else RID()
	var biome_buf: RID = generator.get_persistent_buffer("biome_id") if "get_persistent_buffer" in generator else RID()
	if not cloud_buf.is_valid() or not moist_buf.is_valid() or not land_buf.is_valid() or not temp_buf.is_valid() or not light_buf.is_valid() or not biome_buf.is_valid():
		return
	var rain_rate_land: float = base_rain_strength * rain_mult
	var rain_rate_ocean: float = base_rain_strength * 0.65 * rain_mult
	var evap_rate_ocean: float = base_evap_strength * evap_mult
	var evap_rate_land: float = base_evap_strength * 0.5 * evap_mult
	var dt_step: float = min(dt_days, max_moist_step_days)
	var rd := RenderingServer.get_rendering_device()
	var uniforms: Array = []
	var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u0.binding = 0; u0.add_id(cloud_buf); uniforms.append(u0)
	var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u1.binding = 1; u1.add_id(moist_buf); uniforms.append(u1)
	var u2 := RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u2.binding = 2; u2.add_id(land_buf); uniforms.append(u2)
	var u3 := RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u3.binding = 3; u3.add_id(temp_buf); uniforms.append(u3)
	var u4 := RDUniform.new(); u4.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u4.binding = 4; u4.add_id(light_buf); uniforms.append(u4)
	var u5 := RDUniform.new(); u5.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u5.binding = 5; u5.add_id(biome_buf); uniforms.append(u5)
	var u_set := rd.uniform_set_create(uniforms, _moist_shader_rid, 0)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([
		dt_step,
		rain_rate_land,
		rain_rate_ocean,
		evap_rate_land,
		evap_rate_ocean,
		humidity_mix_rate_per_day,
		humidity_relax_rate_per_day,
		condensation_rate_per_day,
		precipitation_rate_per_day,
		vegetation_evap_boost,
		cloud_dissipation_rate_per_day,
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _moist_pipeline)
	rd.compute_list_bind_uniform_set(cl, u_set, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, gx, gy, 1)
	rd.compute_list_end()
	rd.free_rid(u_set)

func _ensure_buffers(w: int, h: int) -> void:
	var size: int = w * h
	if wind_u.size() != size:
		wind_u.resize(size)
	if wind_v.size() != size:
		wind_v.resize(size)
	if _tmp_clouds.size() != size:
		_tmp_clouds.resize(size)
	
func _sync_seed(force_reset: bool) -> void:
	if generator == null or not ("config" in generator):
		return
	var cur_seed: int = int(generator.config.rng_seed)
	if not force_reset and cur_seed == _seed_cache:
		return
	_seed_cache = cur_seed
	_noise_u.seed = cur_seed ^ 0xC0FFEE
	_noise_v.seed = cur_seed ^ 0xBADC0DE
	_noise_curl.seed = cur_seed ^ 0x1FEED5
	_noise_curl2.seed = cur_seed ^ 0x5AC1D0
	# Rebind local resources on seed change; do not wipe generated cloud state.
	_cloud_buf_a = RID()
	_cloud_buf_b = RID()
	_cloud_flip = false
	_wind_gpu_valid = false
	_force_resync = true

func _sync_gpu_manager(w: int, h: int) -> void:
	var mgr: Object = generator.get_gpu_buffer_manager() if (generator and "get_gpu_buffer_manager" in generator) else null
	var size: int = w * h
	if mgr != _gpu_manager_ref or _buffer_size != size:
		_gpu_manager_ref = mgr
		_buffer_size = size
		_cloud_buf_a = RID()
		_cloud_buf_b = RID()
		_cloud_flip = false
		_wind_gpu_valid = false
		_force_resync = true

func _update_wind_field(world: Object, w: int, h: int) -> void:
	var _size: int = w * h
	var t: float = float(world.simulation_time_days)
	var phase: float = fposmod(t * 0.08, 1.0)
	for y in range(h):
		var lat01: float = float(y) / max(1.0, float(h) - 1.0)
		var lat_signed: float = (lat01 - 0.5) * 2.0
		# Meandering jets: jitter latitude by low-frequency noise
		var lat_jitter: float = 0.18 * _noise_u.get_noise_2d(float(y) * 0.02 + phase * 4.0, float(y) * 0.01 + phase * 1.7)
		lat_signed = clamp(lat_signed + lat_jitter, -1.0, 1.0)
		var abs_lat: float = abs(lat_signed)
		var hem_sign: float = 1.0 if lat_signed >= 0.0 else -1.0
		var mid: float = clamp(1.0 - abs(abs_lat - 0.45) / 0.35, 0.0, 1.0)
		mid = pow(mid, 1.2)
		var eq: float = clamp(1.0 - abs_lat / 0.25, 0.0, 1.0)
		eq = pow(eq, 1.15)
		var polar: float = clamp((abs_lat - 0.65) / 0.35, 0.0, 1.0)
		polar = pow(polar, 1.1)
		var band_strength: float = lerp(0.45, 1.2, mid) + 0.55 * eq
		var eq_dir: float = -1.0
		band_strength += polar_flow_strength * polar
		var band_u: float = hem_sign * band_strength * (1.0 - eq) * (1.0 - polar) + eq_dir * band_strength * eq + polar_flow_dir * band_strength * polar
		for x in range(w):
			var i: int = x + y * w
			# Eddy noise adds curl-like local variation
			var nx: float = float(x) * 0.05
			var ny: float = float(y) * 0.05
			var nu: float = 0.35 * _noise_u.get_noise_2d(nx + phase * 20.0, ny - phase * 10.0)
			var nv: float = 0.35 * _noise_v.get_noise_2d(nx - phase * 15.0, ny + phase * 18.0)
			var meander: float = 0.25 * _noise_u.get_noise_2d(float(x) * 0.01 + phase * 3.0, float(y) * 0.008 - phase * 1.5)
			var bg_u: float = 0.12 * sin(6.28318 * (lat01 * 0.8 + phase * 0.5))
			var bg_v: float = 0.08 * cos(6.28318 * (float(x) / max(1.0, float(w)) * 0.7 + phase * 0.4))
			# Curl noise swirl (cellular-based) to add whorley-like turbulence
			var curl_vec: Vector2 = _curl_noise(_noise_curl, float(x) * 0.5 + phase * 3.0, float(y) * 0.5 - phase * 2.0, 0.75)
			var curl_vec2: Vector2 = _curl_noise(_noise_curl2, float(x) * 1.2 + phase * 6.0, float(y) * 1.2 - phase * 4.0, 0.35)
			var curl_mult: float = (lerp(0.15, 0.45, mid) + polar * polar_curl_boost) * curl_strength
			# Seasonal/diurnal scaling of band strength
			var sim_days: float = float(world.simulation_time_days)
			var tod: float = fposmod(sim_days, 1.0)
			var days_per_year = time_system.get_days_per_year() if time_system and "get_days_per_year" in time_system else 365.0
			var doy: float = fposmod(sim_days / days_per_year, 1.0)
			var diurnal_factor: float = 0.5 - 0.5 * cos(6.28318 * tod)
			var seasonal_factor: float = cos(6.28318 * doy)
			var wind_mult: float = 1.0 + seasonal_mod_amp * seasonal_factor * 0.2 + diurnal_mod_amp * (diurnal_factor - 0.5) * 0.1
			var lat_mult: float = lerp(0.75, 1.4, mid) + polar * 0.3
			var turb_scale: float = 0.7
			var base_u: float = (band_u * wind_mult * lat_mult) + (nu + meander + bg_u + curl_vec.x * curl_mult + curl_vec2.x * 0.22) * turb_scale
			# Meridional component small; push toward equator
			var v_band: float = -0.22 * lat_signed * lat_mult
			var base_v: float = (v_band * wind_mult) + (nv * 0.6 + bg_v + curl_vec.y * curl_mult + curl_vec2.y * 0.22) * turb_scale
			# Rotate local wind to encourage vortices and avoid long streaking
			var angle: float = _noise_curl2.get_noise_2d(float(x) * 0.03 + phase * 1.2, float(y) * 0.03 - phase * 0.8) * 1.1
			var ca: float = cos(angle)
			var sa: float = sin(angle)
			var rot_u: float = base_u * ca - base_v * sa
			var rot_v: float = base_u * sa + base_v * ca
			wind_u[i] = lerp(base_u, rot_u, vortex_rotate_strength)
			wind_v[i] = lerp(base_v, rot_v, vortex_rotate_strength)
	_wind_gpu_valid = false

func _update_wind_field_gpu(world: Object, w: int, h: int) -> void:
	var rd := RenderingServer.get_rendering_device()
	if not _wind_pipeline.is_valid():
		return
	var size: int = w * h
	if wind_u.size() != size: wind_u.resize(size)
	if wind_v.size() != size: wind_v.resize(size)
	var use_persistent: bool = true
	var u_buf: RID
	var v_buf: RID
	if use_persistent and generator and "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)
		u_buf = generator.get_persistent_buffer("wind_u")
		v_buf = generator.get_persistent_buffer("wind_v")
	if not u_buf.is_valid() or not v_buf.is_valid():
		u_buf = rd.storage_buffer_create(wind_u.to_byte_array().size(), wind_u.to_byte_array())
		v_buf = rd.storage_buffer_create(wind_v.to_byte_array().size(), wind_v.to_byte_array())
		use_persistent = false
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(u_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(v_buf); uniforms.append(u)
	var u_set := rd.uniform_set_create(uniforms, _wind_shader_rid, 0)
	var phase: float = fposmod(float(world.simulation_time_days) * 0.08, 1.0)
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
	if not use_persistent:
		# GPU-only runtime: do not read back wind buffers to CPU.
		_wind_gpu_valid = false
		rd.free_rid(u_set)
		rd.free_rid(u_buf)
		rd.free_rid(v_buf)
		return
	_wind_gpu_valid = use_persistent
	rd.free_rid(u_set)

func _advect_and_mix_clouds(dt_days: float, w: int, h: int, source: PackedFloat32Array) -> void:
	var size: int = w * h
	var dt_cloud: float = dt_days * cloud_time_scale
	var adv_scale: float = min(max_adv_shift_cells, max(0.0, adv_cells_per_day) * dt_cloud)
	var diff_alpha: float = clamp(diffusion_rate_per_day * dt_cloud, 0.0, max_diff_alpha)
	var inj_alpha: float = injection_rate_per_day * dt_days * cloud_injection_scale
	inj_alpha = clamp(inj_alpha, cloud_injection_min, max_injection_alpha)
	var decay_alpha: float = clamp(cloud_decay_rate_per_day * dt_days, 0.0, max_decay_alpha)
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
			var nbr: float = (_tmp_clouds[l] + _tmp_clouds[r] + _tmp_clouds[t] + _tmp_clouds[b]) * 0.25
			var detail: float = abs(_tmp_clouds[i2] - nbr)
			var keep: float = _smoothstep(0.02, 0.18, detail) * clamp(detail_preserve, 0.0, 1.0)
			var local_diff: float = clamp(diff_alpha * (1.0 - keep), 0.0, 1.0)
			_tmp_clouds[i2] = lerp(_tmp_clouds[i2], nbr, local_diff)
	# Injection from humidity-driven source
	for i3 in range(size):
		var src: float = source[i3] if i3 < source.size() else 0.0
		var src_weight: float = _smoothstep(0.20, 0.90, src)
		var inj: float = clamp(inj_alpha * lerp(0.35, 1.0, src_weight), 0.0, 1.0)
		var c: float = clamp(_tmp_clouds[i3] * (1.0 - inj) + src * inj, 0.0, 1.0)
		c = max(c, src * source_pin_strength)
		var core_emphasis: float = _smoothstep(0.30, 0.78, c) * _smoothstep(0.20, 0.80, src_weight)
		var contrasted: float = clamp((c - cloud_floor) * cloud_contrast, 0.0, 1.0)
		var tonal: float = lerp(c, contrasted, core_emphasis)
		c = tonal
		var decay: float = clamp(decay_alpha * (0.35 + 0.65 * (1.0 - src_weight)), 0.0, 1.0)
		c *= (1.0 - decay)
		c = max(c, min_cloud_global)
		_tmp_clouds[i3] = c
	# Structure preservation: mild sharpening against neighbor mean
	if structure_sharpen > 0.0:
		for y3 in range(h):
			for x3 in range(w):
				var i4: int = x3 + y3 * w
				var l4: int = ((x3 - 1 + w) % w) + y3 * w
				var r4: int = ((x3 + 1) % w) + y3 * w
				var t4: int = x3 + max(0, y3 - 1) * w
				var b4: int = x3 + min(h - 1, y3 + 1) * w
				var nbr4: float = (_tmp_clouds[l4] + _tmp_clouds[r4] + _tmp_clouds[t4] + _tmp_clouds[b4]) * 0.25
				var core4: float = _smoothstep(0.30, 0.78, _tmp_clouds[i4])
				var sharp_k: float = structure_sharpen * core4
				var c4: float = _tmp_clouds[i4] + (_tmp_clouds[i4] - nbr4) * sharp_k
				_tmp_clouds[i4] = clamp(c4, 0.0, 1.0)
	generator.last_clouds = _tmp_clouds.duplicate()

func _advect_and_mix_clouds_gpu(dt_days: float, w: int, h: int, source: PackedFloat32Array, source_buf_override: RID = RID()) -> void:
	var rd := RenderingServer.get_rendering_device()
	if not _advec_pipeline.is_valid():
		return
	var size: int = w * h
	_setup_cloud_buffers(w, h)
	var in_buf := _cloud_buf_a if not _cloud_flip else _cloud_buf_b
	var out_buf := _cloud_buf_b if not _cloud_flip else _cloud_buf_a
	if not in_buf.is_valid() or not out_buf.is_valid():
		return
	# Update GPU input buffers for wind + source (unless precomputed on GPU)
	var src_buf: RID = source_buf_override
	if generator and "update_persistent_buffer" in generator:
		if not _wind_gpu_valid:
			generator.update_persistent_buffer("wind_u", wind_u.to_byte_array())
			generator.update_persistent_buffer("wind_v", wind_v.to_byte_array())
	var u_buf: RID = generator.get_persistent_buffer("wind_u") if generator else RID()
	var v_buf: RID = generator.get_persistent_buffer("wind_v") if generator else RID()
	if not src_buf.is_valid():
		src_buf = generator.get_persistent_buffer("cloud_source") if generator else RID()
	if not u_buf.is_valid() or not v_buf.is_valid() or not src_buf.is_valid():
		return
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(u_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(v_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(src_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(out_buf); uniforms.append(u)
	var u_set := rd.uniform_set_create(uniforms, _advec_shader_rid, 0)
	var dt_cloud: float = dt_days * cloud_time_scale
	var adv_scale: float = min(max_adv_shift_cells, max(0.0, adv_cells_per_day) * dt_cloud)
	var diff_alpha: float = clamp(diffusion_rate_per_day * dt_cloud, 0.0, max_diff_alpha)
	var inj_alpha: float = injection_rate_per_day * dt_days * cloud_injection_scale
	inj_alpha = clamp(inj_alpha, cloud_injection_min, max_injection_alpha)
	var decay_alpha: float = clamp(cloud_decay_rate_per_day * dt_days, 0.0, max_decay_alpha)
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([
		adv_scale,
		diff_alpha,
		inj_alpha,
		structure_sharpen,
		source_pin_strength,
		cloud_floor,
		cloud_contrast,
		min_cloud_global,
		detail_preserve,
		decay_alpha,
	])
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
	rd.free_rid(u_set)
	_cloud_flip = not _cloud_flip

func _setup_cloud_buffers(w: int, h: int) -> void:
	_sync_gpu_manager(w, h)
	if _cloud_buf_a.is_valid() and _cloud_buf_b.is_valid():
		return
	if generator and "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)
	if generator and "get_persistent_buffer" in generator:
		_cloud_buf_a = generator.get_persistent_buffer("clouds")
	if not _cloud_buf_a.is_valid():
		var rd := RenderingServer.get_rendering_device()
		var arr := PackedFloat32Array()
		if generator and "last_clouds" in generator and generator.last_clouds.size() == w * h:
			arr = generator.last_clouds
		else:
			arr.resize(w * h)
			arr.fill(0.0)
		_cloud_buf_a = rd.storage_buffer_create(arr.to_byte_array().size(), arr.to_byte_array())
	var rd2 := RenderingServer.get_rendering_device()
	if not _cloud_buf_b.is_valid():
		var arr2 := PackedFloat32Array(); arr2.resize(w * h)
		_cloud_buf_b = rd2.storage_buffer_create(arr2.to_byte_array().size(), arr2.to_byte_array())
	# Allocate wind/source buffers for compute if missing
	if generator and "ensure_gpu_storage_buffer" in generator:
		var size_bytes := w * h * 4
		if not generator.get_persistent_buffer("wind_u").is_valid():
			generator.ensure_gpu_storage_buffer("wind_u", size_bytes)
		if not generator.get_persistent_buffer("wind_v").is_valid():
			generator.ensure_gpu_storage_buffer("wind_v", size_bytes)
		if not generator.get_persistent_buffer("cloud_source").is_valid():
			generator.ensure_gpu_storage_buffer("cloud_source", size_bytes)

func _update_cloud_texture_gpu(w: int, h: int) -> void:
	if _cloud_tex == null:
		return
	var buf := _cloud_buf_b if _cloud_flip else _cloud_buf_a
	if not buf.is_valid():
		return
	var tex: Texture2D = _cloud_tex.update_from_buffer(w, h, buf)
	if tex and generator and "set_cloud_texture_override" in generator:
		generator.set_cloud_texture_override(tex)

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

func set_coupling_enabled(v: bool) -> void:
	coupling_enabled = v

func set_coupling(rain_strength: float, evap_strength: float) -> void:
	base_rain_strength = clamp(rain_strength, 0.0, 0.5)
	base_evap_strength = clamp(evap_strength, 0.0, 0.5)

func set_cycle_modulation(diurnal_amp: float, seasonal_amp: float) -> void:
	diurnal_mod_amp = clamp(diurnal_amp, 0.0, 2.0)
	seasonal_mod_amp = clamp(seasonal_amp, 0.0, 2.0)

func set_runtime_lod(paused: bool, wind_interval: int, source_interval: int, advection_interval: int, moisture_interval: int, texture_interval: int) -> void:
	updates_paused = paused
	wind_update_interval_ticks = max(1, int(wind_interval))
	source_update_interval_ticks = max(1, int(source_interval))
	advection_update_interval_ticks = max(1, int(advection_interval))
	moisture_update_interval_ticks = max(1, int(moisture_interval))
	texture_update_interval_ticks = max(1, int(texture_interval))
	if not updates_paused:
		_force_resync = true

func request_full_resync() -> void:
	_force_resync = true
