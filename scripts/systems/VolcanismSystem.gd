# File: res://scripts/systems/VolcanismSystem.gd
extends RefCounted

# GPU volcanism system: spawns/decays lava using plate boundary mask + hotspots.

var generator: Object = null
var compute: Object = null
var time_system: Object = null

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
	# Boundary mask provided by PlateSystem when available
	var bnd_i32 := PackedInt32Array(); bnd_i32.resize(size)
	if "_plates_boundary_mask_i32" in generator and generator._plates_boundary_mask_i32 is PackedInt32Array and generator._plates_boundary_mask_i32.size() == size:
		bnd_i32 = generator._plates_boundary_mask_i32
	# Lava input as float field 0..1
	var lava_in := PackedFloat32Array(); lava_in.resize(size)
	for i in range(size):
		lava_in[i] = float(generator.last_lava[i] if i < generator.last_lava.size() else 0)
	var phase: float = 0.0
	if world != null and "simulation_time_days" in world:
		var days_per_year = time_system.get_days_per_year() if time_system and "get_days_per_year" in time_system else 365.0
		phase = fposmod(float(world.simulation_time_days) / days_per_year, 1.0)
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
