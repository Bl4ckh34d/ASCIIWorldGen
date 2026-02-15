# File: res://scripts/systems/VolcanismSystem.gd
extends RefCounted

# GPU volcanism system: spawns/decays lava using plate boundary mask + hotspots.
const Log = preload("res://scripts/systems/Logger.gd")

var generator: Object = null
var compute: Object = null
var time_system: Object = null
var _lava_tex: Object = null
var _warned_missing_buffers: bool = false

# Rates per simulated day
var decay_rate_per_day: float = 0.02
var spawn_boundary_rate_per_day: float = 0.01
var hotspot_rate_per_day: float = 0.002
var hotspot_threshold: float = 0.999
var boundary_spawn_threshold: float = 0.999

func initialize(gen: Object, time_sys: Object = null) -> void:
	generator = gen
	time_system = time_sys
	var script_v: Script = load("res://scripts/systems/VolcanismCompute.gd")
	if script_v == null:
		Log.event_kv(Log.LogLevel.ERROR, "volcanism", "init", "compute_script_missing")
		push_error("VolcanismSystem: failed to load VolcanismCompute.gd.")
		compute = null
		return
	compute = script_v.new()
	_warned_missing_buffers = false

func _is_ready() -> bool:
	return generator != null and compute != null and "config" in generator

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if not _is_ready():
		return {}
	var dt: float = max(0.0, float(dt_days))
	if dt <= 0.0:
		return {}
	var w: int = int(generator.config.width)
	var h: int = int(generator.config.height)
	var size: int = w * h
	if size <= 0:
		return {}
	var phase: float = 0.0
	if world != null and "simulation_time_days" in world:
		var days_per_year = time_system.get_days_per_year() if time_system and "get_days_per_year" in time_system else 365.0
		phase = fposmod(float(world.simulation_time_days) / days_per_year, 1.0)
	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)
	var lava_buf: RID = generator.get_persistent_buffer("lava") if "get_persistent_buffer" in generator else RID()
	var bnd_buf: RID = generator.get_persistent_buffer("plate_boundary") if "get_persistent_buffer" in generator else RID()
	# If boundary buffer isn't ready, try to seed it from CPU mask once
	if not bnd_buf.is_valid() and "ensure_plate_boundary_buffer_from_state" in generator:
		bnd_buf = generator.ensure_plate_boundary_buffer_from_state(size)
	if not lava_buf.is_valid() or not bnd_buf.is_valid():
		if not _warned_missing_buffers:
			Log.event_kv(Log.LogLevel.WARNING, "volcanism", "tick", "buffers_missing", -1, -1.0, {
				"lava_valid": lava_buf.is_valid(),
				"boundary_valid": bnd_buf.is_valid(),
			})
			_warned_missing_buffers = true
		return {}
	_warned_missing_buffers = false

	var ok_gpu: bool = compute.step_gpu_buffers(w, h, bnd_buf, lava_buf, dt, {
		"decay_rate_per_day": decay_rate_per_day,
		"spawn_boundary_rate_per_day": spawn_boundary_rate_per_day,
		"hotspot_rate_per_day": hotspot_rate_per_day,
		"hotspot_threshold": hotspot_threshold,
		"boundary_spawn_threshold": boundary_spawn_threshold,
	}, phase, int(generator.config.rng_seed))
	if not ok_gpu:
		Log.event_kv(Log.LogLevel.WARNING, "volcanism", "tick", "compute_failed")
		return {}
	if _lava_tex == null:
		var tex_script: Script = load("res://scripts/systems/LavaTextureCompute.gd")
		if tex_script != null:
			_lava_tex = tex_script.new()
	if _lava_tex != null and "update_from_buffer" in _lava_tex:
		var tex: Texture2D = _lava_tex.update_from_buffer(w, h, lava_buf)
		if tex != null and "set_lava_texture_override" in generator:
			generator.set_lava_texture_override(tex)
		elif "set_lava_texture_override" in generator:
			generator.set_lava_texture_override(null)
	return {"dirty_fields": PackedStringArray(["lava"]) }

func cleanup() -> void:
	if compute != null and "cleanup" in compute:
		compute.cleanup()
	if _lava_tex != null and "cleanup" in _lava_tex:
		_lava_tex.cleanup()
	compute = null
	_lava_tex = null
	time_system = null
	generator = null
	_warned_missing_buffers = false
