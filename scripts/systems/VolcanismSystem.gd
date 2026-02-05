# File: res://scripts/systems/VolcanismSystem.gd
extends RefCounted

# GPU volcanism system: spawns/decays lava using plate boundary mask + hotspots.

var generator: Object = null
var compute: Object = null
var time_system: Object = null
var _lava_tex: Object = null

# Rates per simulated day
var decay_rate_per_day: float = 0.02
var spawn_boundary_rate_per_day: float = 0.01
var hotspot_rate_per_day: float = 0.002
var hotspot_threshold: float = 0.999
var boundary_spawn_threshold: float = 0.999

func initialize(gen: Object, time_sys: Object = null) -> void:
	generator = gen
	time_system = time_sys
	compute = load("res://scripts/systems/VolcanismCompute.gd").new()

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null or compute == null:
		return {}
	var w: int = generator.config.width
	var h: int = generator.config.height
	var size: int = w * h
	if size <= 0:
		return {}
	var use_gpu_only: bool = ("config" in generator and generator.config.use_gpu_all)
	var phase: float = 0.0
	if world != null and "simulation_time_days" in world:
		var days_per_year = time_system.get_days_per_year() if time_system and "get_days_per_year" in time_system else 365.0
		phase = fposmod(float(world.simulation_time_days) / days_per_year, 1.0)
	if use_gpu_only:
		if "ensure_persistent_buffers" in generator:
			generator.ensure_persistent_buffers(false)
		var lava_buf: RID = generator.get_persistent_buffer("lava") if "get_persistent_buffer" in generator else RID()
		var bnd_buf: RID = generator.get_persistent_buffer("plate_boundary") if "get_persistent_buffer" in generator else RID()
		# If boundary buffer isn't ready, try to seed it from CPU mask once
		if not bnd_buf.is_valid() and "_gpu_buffer_manager" in generator and generator._gpu_buffer_manager != null:
			if "_plates_boundary_mask_i32" in generator and generator._plates_boundary_mask_i32 is PackedInt32Array and generator._plates_boundary_mask_i32.size() == size:
				generator._gpu_buffer_manager.ensure_buffer("plate_boundary", size * 4, generator._plates_boundary_mask_i32.to_byte_array())
				bnd_buf = generator.get_persistent_buffer("plate_boundary")
		if lava_buf.is_valid() and bnd_buf.is_valid():
			var ok_gpu: bool = compute.step_gpu_buffers(w, h, bnd_buf, lava_buf, dt_days, {
				"decay_rate_per_day": decay_rate_per_day,
				"spawn_boundary_rate_per_day": spawn_boundary_rate_per_day,
				"hotspot_rate_per_day": hotspot_rate_per_day,
				"hotspot_threshold": hotspot_threshold,
				"boundary_spawn_threshold": boundary_spawn_threshold,
			}, phase, int(generator.config.rng_seed))
			if ok_gpu:
				if _lava_tex == null:
					_lava_tex = load("res://scripts/systems/LavaTextureCompute.gd").new()
				if _lava_tex:
					var tex: Texture2D = _lava_tex.update_from_buffer(w, h, lava_buf)
					if tex and "set_lava_texture_override" in generator:
						generator.set_lava_texture_override(tex)
				return {"dirty_fields": PackedStringArray(["lava"]) }
		# GPU-only: do not fall back to CPU volcanism
		return {}
	# Boundary mask provided by PlateSystem when available
	var bnd_i32 := PackedInt32Array(); bnd_i32.resize(size)
	if "_plates_boundary_mask_i32" in generator and generator._plates_boundary_mask_i32 is PackedInt32Array and generator._plates_boundary_mask_i32.size() == size:
		bnd_i32 = generator._plates_boundary_mask_i32
	# Lava input as float field 0..1
	var lava_in := PackedFloat32Array(); lava_in.resize(size)
	for i in range(size):
		lava_in[i] = float(generator.last_lava[i] if i < generator.last_lava.size() else 0)
	var out: PackedFloat32Array = compute.step(w, h, bnd_i32, lava_in, dt_days, {
		"decay_rate_per_day": decay_rate_per_day,
		"spawn_boundary_rate_per_day": spawn_boundary_rate_per_day,
		"hotspot_rate_per_day": hotspot_rate_per_day,
		"hotspot_threshold": hotspot_threshold,
		"boundary_spawn_threshold": boundary_spawn_threshold,
	}, phase, int(generator.config.rng_seed))
	if out.size() == size:
		generator.last_lava.resize(size)
		var lava_count = 0
		for k in range(size):
			var lava_val = (1 if out[k] > 0.5 else 0)
			generator.last_lava[k] = lava_val
			if lava_val == 1: lava_count += 1
		
		# Store volcanic activity stats
		if "volcanic_stats" not in generator:
			generator.volcanic_stats = {}
		generator.volcanic_stats["active_lava_cells"] = lava_count
		generator.volcanic_stats["boundary_cells_available"] = bnd_i32.count(1)
		generator.volcanic_stats["eruption_potential"] = float(lava_count) / float(max(1, size)) * 100.0
		
		return {"dirty_fields": PackedStringArray(["lava"]), "lava_count": lava_count}
	return {}
