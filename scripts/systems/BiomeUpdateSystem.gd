extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

# Biome updater: GPU-only classification and post, with optional cryosphere-only mode.

var generator: Object = null
var _biome_tex: Object = null
var _lava_tex: Object = null
var _blend: Object = null
var _biome_compute: Object = null
var _biome_post_compute: Object = null
var _lithology_compute: Object = null
var _fertility_compute: Object = null
var _transition_compute: Object = null
var biome_climate_tau_days: float = 3650.0 # ~10 years for macro-biome memory
var biome_transition_tau_days: float = 540.0
var cryosphere_transition_tau_days: float = 180.0
var cryosphere_climate_tau_days: float = 45.0
var biome_transition_max_step: float = 0.035
var cryosphere_transition_max_step: float = 0.06
var ocean_ice_base_thresh_c: float = -9.5
var ocean_ice_wiggle_amp_c: float = 1.1
var transition_seed_floor_general: float = 0.018
var transition_seed_floor_cryosphere: float = 0.002
var transition_front_q0: float = 0.10
var transition_front_q1: float = 0.72
var transition_front_gamma: float = 1.7
var transition_cryo_polar_seed_boost: float = 0.08
var _height_min_cache: float = 0.0
var _height_max_cache: float = 1.0
var _height_cache_size: int = -1
var _height_cache_refresh_counter: int = 0
var _transition_epoch: int = 0
const HEIGHT_MINMAX_REFRESH_INTERVAL: int = 24
const FERTILITY_WEATHERING_RATE: float = 0.012
const FERTILITY_HUMUS_RATE: float = 0.010
const FERTILITY_FLOW_SCALE: float = 64.0
const MAX_BIOME_EFFECTIVE_DT_DAYS: float = 0.25
const MAX_FERTILITY_EFFECTIVE_DT_DAYS: float = 0.10
const MAX_BIOME_TRANSITION_DT_DAYS: float = 3.0
const MAX_CRYOSPHERE_TRANSITION_DT_DAYS: float = 1.0

var run_full_biome: bool = true
var run_cryosphere: bool = true
var _warmup_enabled: bool = false
var _warmup_dt_cap_scale: float = 1.0
var _warmup_tau_scale: float = 1.0
var _warmup_step_scale: float = 1.0

func _cleanup_if_supported(obj: Variant) -> void:
	if obj == null:
		return
	if obj is Object:
		var o: Object = obj as Object
		if o.has_method("cleanup"):
			o.call("cleanup")

func initialize(gen: Object) -> void:
	generator = gen
	_biome_tex = load("res://scripts/systems/BiomeTextureCompute.gd").new()
	_lava_tex = load("res://scripts/systems/LavaTextureCompute.gd").new()
	_blend = load("res://scripts/systems/BiomeClimateBlendCompute.gd").new()
	_biome_compute = load("res://scripts/systems/BiomeCompute.gd").new()
	_biome_post_compute = load("res://scripts/systems/BiomePostCompute.gd").new()
	_lithology_compute = load("res://scripts/systems/LithologyCompute.gd").new()
	_fertility_compute = load("res://scripts/systems/FertilityLithologyCompute.gd").new()
	_transition_compute = load("res://scripts/systems/BiomeTransitionCompute.gd").new()

func set_update_modes(full_biome_enabled: bool, cryosphere_enabled: bool) -> void:
	run_full_biome = VariantCastsUtil.to_bool(full_biome_enabled)
	run_cryosphere = VariantCastsUtil.to_bool(cryosphere_enabled)

func set_warmup_mode(enabled: bool, dt_cap_scale: float = 1.0, tau_scale: float = 1.0, step_scale: float = 1.0) -> void:
	_warmup_enabled = VariantCastsUtil.to_bool(enabled)
	if _warmup_enabled:
		_warmup_dt_cap_scale = clamp(float(dt_cap_scale), 1.0, 64.0)
		_warmup_tau_scale = clamp(float(tau_scale), 0.04, 1.0)
		_warmup_step_scale = clamp(float(step_scale), 1.0, 16.0)
	else:
		_warmup_dt_cap_scale = 1.0
		_warmup_tau_scale = 1.0
		_warmup_step_scale = 1.0

func cleanup() -> void:
	_cleanup_if_supported(_biome_tex)
	_cleanup_if_supported(_lava_tex)
	_cleanup_if_supported(_blend)
	_cleanup_if_supported(_biome_compute)
	_cleanup_if_supported(_biome_post_compute)
	_cleanup_if_supported(_lithology_compute)
	_cleanup_if_supported(_fertility_compute)
	_cleanup_if_supported(_transition_compute)
	_biome_tex = null
	_lava_tex = null
	_blend = null
	_biome_compute = null
	_biome_post_compute = null
	_lithology_compute = null
	_fertility_compute = null
	_transition_compute = null
	_height_cache_size = -1
	_height_cache_refresh_counter = 0
	_transition_epoch = 0
	_warmup_enabled = false
	_warmup_dt_cap_scale = 1.0
	_warmup_tau_scale = 1.0
	_warmup_step_scale = 1.0
	generator = null

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	if not run_full_biome and not run_cryosphere:
		return {}
	var w: int = generator.config.width
	var h: int = generator.config.height
	var size: int = w * h
	if generator.last_height.size() != size or generator.last_is_land.size() != size:
		return {}
	if generator.last_temperature.size() != size or generator.last_moisture.size() != size:
		return {}
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)

	var height_buf: RID = generator.get_persistent_buffer("height")
	var land_buf: RID = generator.get_persistent_buffer("is_land")
	var temp_now_buf: RID = generator.get_persistent_buffer("temperature")
	var moist_now_buf: RID = generator.get_persistent_buffer("moisture")
	var slow_temp_buf: RID = generator.get_persistent_buffer("biome_temp")
	var slow_moist_buf: RID = generator.get_persistent_buffer("biome_moist")
	var cryo_temp_buf: RID = generator.get_persistent_buffer("cryo_temp")
	var cryo_moist_buf: RID = generator.get_persistent_buffer("cryo_moist")
	var beach_buf: RID = generator.get_persistent_buffer("beach")
	var desert_buf: RID = generator.get_persistent_buffer("desert_noise")
	var biome_noise_buf: RID = generator.get_persistent_buffer("shore_noise")
	var rock_buf: RID = generator.get_persistent_buffer("rock_type")
	var flow_buf: RID = generator.get_persistent_buffer("flow_accum")
	var fertility_buf: RID = generator.get_persistent_buffer("fertility")
	var biome_buf: RID = generator.get_persistent_buffer("biome_id")
	var biome_prev_buf: RID = generator.get_persistent_buffer("biome_prev")
	var biome_tmp: RID = generator.get_persistent_buffer("biome_tmp")
	var lake_buf: RID = generator.get_persistent_buffer("lake")
	var lava_buf: RID = generator.get_persistent_buffer("lava")
	if not height_buf.is_valid() or not land_buf.is_valid():
		return {}
	if not biome_buf.is_valid() or not biome_prev_buf.is_valid() or not biome_tmp.is_valid():
		return {}
	if not temp_now_buf.is_valid() or not moist_now_buf.is_valid():
		return {}
	if _biome_compute == null:
		_biome_compute = load("res://scripts/systems/BiomeCompute.gd").new()
	if _biome_post_compute == null:
		_biome_post_compute = load("res://scripts/systems/BiomePostCompute.gd").new()
	if _lithology_compute == null:
		_lithology_compute = load("res://scripts/systems/LithologyCompute.gd").new()
	if _fertility_compute == null:
		_fertility_compute = load("res://scripts/systems/FertilityLithologyCompute.gd").new()
	if _transition_compute == null:
		_transition_compute = load("res://scripts/systems/BiomeTransitionCompute.gd").new()

	var dt_sim: float = _compute_sim_dt(world, dt_days)
	var dt_cap_scale: float = _warmup_dt_cap_scale if _warmup_enabled else 1.0
	var tau_scale: float = _warmup_tau_scale if _warmup_enabled else 1.0
	var step_scale: float = _warmup_step_scale if _warmup_enabled else 1.0
	var dt_biome: float = min(dt_sim, MAX_BIOME_EFFECTIVE_DT_DAYS * dt_cap_scale)
	var dt_fertility: float = min(dt_sim, MAX_FERTILITY_EFFECTIVE_DT_DAYS * dt_cap_scale)
	var dt_transition_biome: float = min(dt_sim, MAX_BIOME_TRANSITION_DT_DAYS * dt_cap_scale)
	var dt_transition_cryo: float = min(dt_sim, MAX_CRYOSPHERE_TRANSITION_DT_DAYS * dt_cap_scale)
	var biome_transition_tau_eff: float = max(0.001, biome_transition_tau_days * tau_scale)
	var cryosphere_transition_tau_eff: float = max(0.001, cryosphere_transition_tau_days * tau_scale)
	var biome_step_max_eff: float = clamp(biome_transition_max_step * step_scale, 0.0, 1.0)
	var cryosphere_step_max_eff: float = clamp(cryosphere_transition_max_step * step_scale, 0.0, 1.0)
	var biome_step: float = _compute_transition_fraction(dt_transition_biome, biome_transition_tau_eff, biome_step_max_eff)
	var cryosphere_step: float = _compute_transition_fraction(dt_transition_cryo, cryosphere_transition_tau_eff, cryosphere_step_max_eff)

	var biome_changed: bool = false
	var lava_changed: bool = false
	var lithology_changed: bool = false
	var fertility_changed: bool = false
	var temp_for_cryosphere: RID = temp_now_buf
	var moist_for_cryosphere: RID = moist_now_buf
	# Always keep a smoothed cryosphere climate signal available, even when this
	# instance is running in full-biome mode only. This prevents full biome passes
	# from stripping ice/glacier states between dedicated cryosphere ticks.
	if _blend and cryo_temp_buf.is_valid() and cryo_moist_buf.is_valid():
		var alpha_cryo: float = 0.0
		var cryosphere_climate_tau_eff: float = max(0.001, cryosphere_climate_tau_days * tau_scale)
		if dt_biome > 0.0 and cryosphere_climate_tau_eff > 0.0:
			alpha_cryo = 1.0 - exp(-dt_biome / cryosphere_climate_tau_eff)
		alpha_cryo = clamp(alpha_cryo, 0.0, 1.0)
		if _blend.apply(w, h, temp_now_buf, moist_now_buf, cryo_temp_buf, cryo_moist_buf, alpha_cryo):
			temp_for_cryosphere = cryo_temp_buf
			moist_for_cryosphere = cryo_moist_buf

	if run_full_biome:
		if not _copy_u32_buffer(biome_buf, biome_prev_buf, size):
			return {}
		var params := {
			"width": w,
			"height": h,
			"seed": generator.config.rng_seed,
			"freeze_temp_threshold": 0.16,
			"height_scale_m": generator.config.height_scale_m,
			"lapse_c_per_km": 5.5,
			"noise_x_scale": generator.config.noise_x_scale,
			"temp_min_c": generator.config.temp_min_c,
			"temp_max_c": generator.config.temp_max_c,
		}
		params["biome_noise_strength_c"] = 0.28
		params["biome_moist_jitter"] = 0.012
		params["biome_smoothing_enabled"] = true
		params["biome_smoothing_passes"] = 1
		# Keep biome noise phase stable across ticks to avoid large reclassification jumps.
		params["biome_phase"] = generator.biome_phase if ("biome_phase" in generator) else 0.0
		params["biome_moist_jitter2"] = 0.008
		params["biome_moist_islands"] = 0.16
		params["biome_moist_elev_dry"] = 0.14

		var alpha: float = 0.0
		var biome_climate_tau_eff: float = max(0.001, biome_climate_tau_days * tau_scale)
		if dt_biome > 0.0 and biome_climate_tau_eff > 0.0:
			alpha = 1.0 - exp(-dt_biome / biome_climate_tau_eff)
		alpha = clamp(alpha, 0.0, 1.0)
		var temp_for_classify: RID = temp_now_buf
		var moist_for_classify: RID = moist_now_buf
		if _blend and slow_temp_buf.is_valid() and slow_moist_buf.is_valid():
			if _blend.apply(w, h, temp_now_buf, moist_now_buf, slow_temp_buf, slow_moist_buf, alpha):
				temp_for_classify = slow_temp_buf
				moist_for_classify = slow_moist_buf

		_height_cache_refresh_counter += 1
		if _height_cache_size != size or _height_cache_refresh_counter >= HEIGHT_MINMAX_REFRESH_INTERVAL:
			var metrics: Dictionary = {}
			if "get_world_state_metrics_snapshot" in generator:
				metrics = generator.get_world_state_metrics_snapshot()
			if metrics.is_empty():
				var min_h := 1e9
				var max_h := -1e9
				for hv in generator.last_height:
					if hv < min_h:
						min_h = hv
					if hv > max_h:
						max_h = hv
				_height_min_cache = min_h
				_height_max_cache = max_h
			else:
				_height_min_cache = float(metrics.get("min_h", _height_min_cache))
				_height_max_cache = float(metrics.get("max_h", _height_max_cache))
				params["world_state_metrics"] = metrics
			_height_cache_size = size
			_height_cache_refresh_counter = 0
		params["min_h"] = _height_min_cache
		params["max_h"] = _height_max_cache
		if not params.has("world_state_metrics") and "get_world_state_metrics_snapshot" in generator:
			var metrics_now: Dictionary = generator.get_world_state_metrics_snapshot()
			if not metrics_now.is_empty():
				params["world_state_metrics"] = metrics_now

		if rock_buf.is_valid() and biome_tmp.is_valid() and flow_buf.is_valid() and fertility_buf.is_valid() and lava_buf.is_valid():
			var lith_params := {
				"seed": generator.config.rng_seed,
				"noise_x_scale": generator.config.noise_x_scale,
				"min_h": _height_min_cache,
				"max_h": _height_max_cache,
			}
			var ok_lith: bool = _lithology_compute.classify_to_buffer(
				w,
				h,
				height_buf,
				land_buf,
				temp_for_classify,
				moist_for_classify,
				lava_buf,
				desert_buf,
				lith_params,
				biome_tmp
			)
			if ok_lith:
				var ok_fert: bool = _fertility_compute.update_gpu_buffers(
					w,
					h,
					rock_buf,
					biome_tmp,
					biome_buf,
					land_buf,
					moist_for_classify,
					flow_buf,
					lava_buf,
					fertility_buf,
					dt_fertility,
					FERTILITY_WEATHERING_RATE,
					FERTILITY_HUMUS_RATE,
					FERTILITY_FLOW_SCALE
				)
				if ok_fert:
					lithology_changed = true
					fertility_changed = true

		var ok_classify: bool = _biome_compute.classify_to_buffer(
			w,
			h,
			height_buf,
			land_buf,
			temp_for_classify,
			moist_for_classify,
			beach_buf,
			desert_buf,
			fertility_buf,
			params,
			biome_buf,
			biome_noise_buf
		)
		if not ok_classify:
			return {}
		if not lake_buf.is_valid() or not lava_buf.is_valid() or not rock_buf.is_valid():
			return {}
		var ok_post: bool = _biome_post_compute.apply_overrides_and_lava_gpu(
			w,
			h,
			land_buf,
			temp_for_classify,
			moist_for_classify,
			biome_buf,
			lake_buf,
			rock_buf,
			biome_tmp,
			lava_buf,
			generator.config.temp_min_c,
			generator.config.temp_max_c,
			generator.config.lava_temp_threshold_c,
			0.0
		)
		if not ok_post:
			return {}
		lava_changed = true
		# Reapply cryosphere masks after every full-biome pass to avoid
		# periodic ice/glacier popping from cadence mismatch between systems.
		var ok_reapply: bool = _reapply_cryosphere(
			w,
			h,
			biome_tmp,
			biome_buf,
			land_buf,
			height_buf,
			temp_for_cryosphere,
			moist_for_cryosphere
		)
		if not ok_reapply:
			if not _copy_u32_buffer(biome_tmp, biome_buf, size):
				return {}
		biome_changed = _apply_temporal_transition_gpu(
			w,
			h,
			size,
			biome_prev_buf,
			biome_buf,
			biome_tmp,
			biome_step,
			cryosphere_step
		)
	elif run_cryosphere:
		if not _copy_u32_buffer(biome_buf, biome_prev_buf, size):
			return {}
		# Cryosphere-only path: reapply seasonal ice/glacier masks to current biomes.
		if not _copy_u32_buffer(biome_buf, biome_tmp, size):
			return {}
		var ok_reapply_only: bool = _reapply_cryosphere(
			w,
			h,
			biome_tmp,
			biome_buf,
			land_buf,
			height_buf,
			temp_for_cryosphere,
			moist_for_cryosphere
		)
		if not ok_reapply_only:
			if not _copy_u32_buffer(biome_tmp, biome_buf, size):
				return {}
		biome_changed = _apply_temporal_transition_gpu(
			w,
			h,
			size,
			biome_prev_buf,
			biome_buf,
			biome_tmp,
			0.0,
			cryosphere_step
		)

	if biome_changed and _biome_tex:
		var btex: Texture2D = _biome_tex.update_from_buffer(w, h, biome_buf)
		if btex and "set_biome_texture_override" in generator:
			generator.set_biome_texture_override(btex)
		elif "set_biome_texture_override" in generator:
			generator.set_biome_texture_override(null)
	if lava_changed and _lava_tex:
		var ltex: Texture2D = _lava_tex.update_from_buffer(w, h, lava_buf)
		if ltex and "set_lava_texture_override" in generator:
			generator.set_lava_texture_override(ltex)
		elif "set_lava_texture_override" in generator:
			generator.set_lava_texture_override(null)
	var dirty := PackedStringArray()
	if biome_changed:
		dirty.append("biome")
	if lava_changed:
		dirty.append("lava")
	if lithology_changed:
		dirty.append("rock_type")
	if fertility_changed:
		dirty.append("fertility")
	var out := {"consumed_days": dt_sim}
	if dirty.size() > 0:
		out["dirty_fields"] = dirty
	return out

func _compute_sim_dt(_world: Object, dt_days: float) -> float:
	return max(0.0, dt_days)

func _compute_transition_fraction(dt_sim: float, tau_days: float, max_step: float) -> float:
	if dt_sim <= 0.0:
		return 0.0
	if tau_days <= 0.0:
		return clamp(max_step, 0.0, 1.0)
	var raw: float = 1.0 - exp(-dt_sim / max(0.001, tau_days))
	return clamp(raw, 0.0, clamp(max_step, 0.0, 1.0))

func _apply_temporal_transition_gpu(
		w: int,
		h: int,
		size: int,
		old_biome_buf: RID,
		new_biome_buf: RID,
		scratch_out_buf: RID,
		biome_step: float,
		cryosphere_step: float
	) -> bool:
	if size <= 0:
		return false
	if not old_biome_buf.is_valid() or not new_biome_buf.is_valid() or not scratch_out_buf.is_valid():
		return false
	var step_b: float = clamp(biome_step, 0.0, 1.0)
	var step_c: float = clamp(cryosphere_step, 0.0, 1.0)
	if step_b <= 0.0 and step_c <= 0.0:
		if not _copy_u32_buffer(old_biome_buf, new_biome_buf, size):
			return false
		return false
	if step_b >= 0.999 and step_c >= 0.999:
		return true
	if _transition_compute == null:
		_transition_compute = load("res://scripts/systems/BiomeTransitionCompute.gd").new()
	if _transition_compute == null:
		return true
	_transition_epoch += 1
	var ok: bool = _transition_compute.blend_to_buffer(
		w,
		h,
		old_biome_buf,
		new_biome_buf,
		scratch_out_buf,
		step_b,
		step_c,
		int(generator.config.rng_seed),
		_transition_epoch,
		transition_seed_floor_general,
		transition_seed_floor_cryosphere,
		transition_front_q0,
		transition_front_q1,
		transition_front_gamma,
		transition_cryo_polar_seed_boost
	)
	if not ok:
		return true
	if not _copy_u32_buffer(scratch_out_buf, new_biome_buf, size):
		return true
	return true

func _reapply_cryosphere(
		w: int,
		h: int,
		biome_in_buf: RID,
		biome_out_buf: RID,
		land_buf: RID,
		height_buf: RID,
		temp_buf: RID,
		moist_buf: RID
	) -> bool:
	if _biome_compute == null:
		return false
	if not ("reapply_cryosphere_to_buffer" in _biome_compute):
		return false
	return _biome_compute.reapply_cryosphere_to_buffer(
		w,
		h,
		biome_in_buf,
		biome_out_buf,
		land_buf,
		height_buf,
		temp_buf,
		moist_buf,
		generator.config.temp_min_c,
		generator.config.temp_max_c,
		generator.config.height_scale_m,
		5.5,
		ocean_ice_base_thresh_c,
		ocean_ice_wiggle_amp_c
	)

func _copy_u32_buffer(src: RID, dst: RID, count: int) -> bool:
	if not src.is_valid() or not dst.is_valid() or count <= 0:
		return false
	if "dispatch_copy_u32" in generator:
		return VariantCastsUtil.to_bool(generator.dispatch_copy_u32(src, dst, count))
	return false
