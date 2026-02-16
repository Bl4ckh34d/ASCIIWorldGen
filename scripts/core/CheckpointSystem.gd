# File: res://scripts/core/CheckpointSystem.gd
extends Node
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

# Periodic snapshot system for deterministic rewind/scrub.
# Minimal MVP: in-memory ring buffer; save/load core fields & config.

var generator: Object = null
var checkpoint_interval_days: float = 5.0
var max_checkpoints: int = 6
var last_checkpoint_time_days: float = -1.0
var last_loaded_time_days: float = -1.0
var checkpoints: Array = [] # Array of Dictionary snapshots

func initialize(gen: Object) -> void:
	generator = gen
	checkpoints.clear()
	last_checkpoint_time_days = -1.0

func set_interval_days(days: float) -> void:
	checkpoint_interval_days = max(0.001, float(days))

func set_max_checkpoints(n: int) -> void:
	max_checkpoints = max(1, n)
	# Trim if needed
	while checkpoints.size() > max_checkpoints:
		checkpoints.pop_front()

func maybe_checkpoint(sim_time_days: float) -> void:
	if generator == null:
		return
	if sim_time_days < 0.0:
		return
	if last_checkpoint_time_days < 0.0 or (sim_time_days - last_checkpoint_time_days) >= checkpoint_interval_days:
		save_checkpoint(sim_time_days)

func save_checkpoint(sim_time_days: float = -1.0) -> void:
	if generator == null:
		return
	if "sync_climate_cpu_mirror_from_gpu" in generator:
		generator.sync_climate_cpu_mirror_from_gpu()
	var t: float = sim_time_days
	if t < 0.0:
		if "_world_state" in generator and generator._world_state != null:
			t = float(generator._world_state.simulation_time_days)
		else:
			t = 0.0
	var w: int = (generator.config.width if "config" in generator else 0)
	var h: int = (generator.config.height if "config" in generator else 0)
	var size: int = max(0, w * h)
	var cp := {}
	cp["time_days"] = t
	cp["width"] = w
	cp["height"] = h
	cp["config"] = _capture_config()
	# Fields (deep copies)
	cp["height_field"] = _dup_f32(generator.last_height, size)
	cp["is_land"] = _dup_u8(generator.last_is_land, size)
	cp["temperature"] = _dup_f32(generator.last_temperature, size)
	cp["moisture"] = _dup_f32(generator.last_moisture, size)
	cp["biome_id"] = _dup_i32(generator.last_biomes, size)
	cp["lake"] = _dup_u8(generator.last_lake, size)
	cp["lake_id"] = _dup_i32(generator.last_lake_id, size)
	cp["flow_dir"] = _dup_i32(generator.last_flow_dir, size)
	cp["flow_accum"] = _dup_f32(generator.last_flow_accum, size)
	cp["river"] = _dup_u8(generator.last_river, size)
	cp["lava"] = _dup_u8(generator.last_lava, size)
	cp["cloud_cov"] = _dup_f32(generator.last_clouds, size)
	cp["coast_distance"] = _dup_f32(generator.last_water_distance, size)
	cp["turquoise_water"] = _dup_u8(generator.last_turquoise_water, size)
	cp["turquoise_strength"] = _dup_f32(generator.last_turquoise_strength, size)
	cp["beach"] = _dup_u8(generator.last_beach, size)
	cp["ocean_fraction"] = float(generator.last_ocean_fraction if "last_ocean_fraction" in generator else 0.0)
	# Commit to ring buffer
	checkpoints.append(cp)
	while checkpoints.size() > max_checkpoints:
		checkpoints.pop_front()
	last_checkpoint_time_days = t

func load_latest_before_or_equal(target_days: float) -> bool:
	if checkpoints.is_empty():
		return false
	var best_idx: int = -1
	var best_time: float = -1.0
	for i in range(checkpoints.size()):
		var t: float = float(checkpoints[i].get("time_days", -1.0))
		if t <= target_days and t >= 0.0 and t >= best_time:
			best_time = t
			best_idx = i
	if best_idx < 0:
		return false
	return _apply_checkpoint(checkpoints[best_idx])

func load_by_index(idx: int) -> bool:
	if idx < 0 or idx >= checkpoints.size():
		return false
	return _apply_checkpoint(checkpoints[idx])

func list_checkpoint_times() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(checkpoints.size())
	for i in range(checkpoints.size()):
		out[i] = float(checkpoints[i].get("time_days", 0.0))
	return out

func export_latest_to_file(path: String) -> bool:
	# Persist the most recent checkpoint to disk as a binary Godot Variant.
	if checkpoints.is_empty():
		return false
	var cp: Dictionary = checkpoints[checkpoints.size() - 1]
	return _write_checkpoint_to_file(cp, path)

func import_from_file(path: String) -> bool:
	# Load a checkpoint from disk and apply immediately.
	var cp: Dictionary = _read_checkpoint_from_file(path)
	if cp.is_empty():
		return false
	return _apply_checkpoint(cp)

func _write_checkpoint_to_file(cp: Dictionary, path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	# Wrap into a container with a small version header for future compatibility
	var container := {
		"version": 1,
		"checkpoint": cp,
	}
	f.store_var(container, true)
	f.flush()
	f.close()
	return true

func _read_checkpoint_from_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var container = f.get_var(true)
	f.close()
	if typeof(container) != TYPE_DICTIONARY:
		return {}
	var ver_any = container.get("version", 1)
	var ver: int = 1
	if typeof(ver_any) == TYPE_INT:
		ver = ver_any
	elif typeof(ver_any) == TYPE_FLOAT:
		var ver_f: float = ver_any
		ver = int(floor(ver_f))
	if ver != 1:
		# For now we only support version 1
		return {}
	return container.get("checkpoint", {})

func scrub_to(target_days: float, time_system: Node, simulation: Node, world: Object) -> bool:
	# Load the latest checkpoint at or before target_days, then deterministically
	# simulate forward in fixed ticks to reach target_days.
	if generator == null or time_system == null or simulation == null or world == null:
		return false
	var tgt: float = max(0.0, float(target_days))
	# Pause time while scrubbing
	var was_running: bool = false
	if "running" in time_system:
		was_running = VariantCastsUtil.to_bool(time_system.running)
	if "pause" in time_system:
		time_system.pause()
	# Load nearest checkpoint <= target
	var ok: bool = load_latest_before_or_equal(tgt)
	if not ok:
		return false
	# Determine tick size
	var dt_days: float = 1.0 / 1440.0
	if "tick_days" in time_system:
		dt_days = max(1e-6, float(time_system.tick_days))
	# Get loaded checkpoint time from state
	var start_t: float = float(last_loaded_time_days)
	if start_t < 0.0:
		start_t = 0.0
	# Temporarily relax budgets so all systems scheduled by cadence can run
	var prev_budget_time_mode: bool = true
	var prev_max_ms: float = 6.0
	var prev_max_count: int = 3
	if "budget_mode_time_ms" in simulation:
		prev_budget_time_mode = VariantCastsUtil.to_bool(simulation.budget_mode_time_ms)
	if "max_tick_time_ms" in simulation:
		prev_max_ms = float(simulation.max_tick_time_ms)
	if "max_systems_per_tick" in simulation:
		var prev_any = simulation.max_systems_per_tick
		if typeof(prev_any) == TYPE_INT:
			prev_max_count = prev_any
		elif typeof(prev_any) == TYPE_FLOAT:
			prev_max_count = int(floor(float(prev_any)))
	if "set_budget_mode_time" in simulation:
		simulation.set_budget_mode_time(true)
	if "set_max_tick_time_ms" in simulation:
		simulation.set_max_tick_time_ms(1e9)
	if "set_max_systems_per_tick" in simulation:
		simulation.set_max_systems_per_tick(1024)
	# Step forward in fixed increments until we reach or pass target
	if world != null and "simulation_time_days" in world:
		world.simulation_time_days = start_t
	var t: float = start_t
	var guard: int = 0
	var max_steps: int = int(ceil(max(0.0, tgt - start_t) / dt_days)) + 2
	while t + 1e-9 < tgt and guard < max_steps:
		# Advance time in world so systems read the correct phase
		if world != null and "simulation_time_days" in world:
			world.simulation_time_days = t
		# Execute one orchestrator tick deterministically
		if "on_tick" in simulation:
			simulation.on_tick(dt_days, world, {})
		t += dt_days
		guard += 1
	# Restore budgets
	if "set_budget_mode_time" in simulation:
		simulation.set_budget_mode_time(prev_budget_time_mode)
	if "set_max_tick_time_ms" in simulation:
		simulation.set_max_tick_time_ms(prev_max_ms)
	if "set_max_systems_per_tick" in simulation:
		simulation.set_max_systems_per_tick(prev_max_count)
	# Clamp final time to target (without running partial ticks)
	if world != null and "simulation_time_days" in world:
		world.simulation_time_days = tgt
	# Sync time system clock to target
	if "simulation_time_days" in time_system:
		time_system.simulation_time_days = tgt
	# Optionally resume
	if was_running and "start" in time_system:
		time_system.start()
	return true

func _apply_checkpoint(cp: Dictionary) -> bool:
	if generator == null:
		return false
	var w: int = cp.get("width", 0)
	var h: int = cp.get("height", 0)
	if w <= 0 or h <= 0:
		return false
	# Restore config
	var cfg: Dictionary = cp.get("config", {})
	if cfg.size() > 0 and "apply_config" in generator:
		generator.apply_config(cfg)
	# Restore fields (assign duplicates to keep checkpoints immutable)
	var f32: PackedFloat32Array
	var i32: PackedInt32Array
	var u8: PackedByteArray
	# Height field (support both new and legacy key)
	f32 = cp.get("height_field", PackedFloat32Array())
	if f32.is_empty():
		var legacy_h = cp.get("height", PackedFloat32Array())
		if typeof(legacy_h) == TYPE_PACKED_FLOAT32_ARRAY:
			f32 = legacy_h
	if f32.size() == w * h:
		# OPTIMIZED: Avoid duplication - checkpoint data is immutable
		generator.last_height = f32
	# is_land
	u8 = cp.get("is_land", PackedByteArray())
	if u8.size() == w * h:
		generator.last_is_land = u8
	# temperature
	f32 = cp.get("temperature", PackedFloat32Array())
	if f32.size() == w * h:
		generator.last_temperature = f32
	# moisture
	f32 = cp.get("moisture", PackedFloat32Array())
	if f32.size() == w * h:
		generator.last_moisture = f32
	# biome_id
	i32 = cp.get("biome_id", PackedInt32Array())
	if i32.size() == w * h:
		generator.last_biomes = i32
	# lake
	u8 = cp.get("lake", PackedByteArray())
	if u8.size() == w * h:
		generator.last_lake = u8
	# lake_id
	i32 = cp.get("lake_id", PackedInt32Array())
	if i32.size() == w * h:
		generator.last_lake_id = i32
	# flow_dir
	i32 = cp.get("flow_dir", PackedInt32Array())
	if i32.size() == w * h:
		generator.last_flow_dir = i32.duplicate()
	# flow_accum
	f32 = cp.get("flow_accum", PackedFloat32Array())
	if f32.size() == w * h:
		generator.last_flow_accum = f32.duplicate()
	# river
	u8 = cp.get("river", PackedByteArray())
	if u8.size() == w * h:
		generator.last_river = u8.duplicate()
	# lava
	u8 = cp.get("lava", PackedByteArray())
	if u8.size() == w * h:
		generator.last_lava = u8.duplicate()
	# cloud cover
	f32 = cp.get("cloud_cov", PackedFloat32Array())
	if f32.size() == w * h:
		generator.last_clouds = f32.duplicate()
	# coast distance
	f32 = cp.get("coast_distance", PackedFloat32Array())
	if f32.size() == w * h:
		generator.last_water_distance = f32.duplicate()
	# turquoise water
	u8 = cp.get("turquoise_water", PackedByteArray())
	if u8.size() == w * h:
		generator.last_turquoise_water = u8.duplicate()
	# turquoise strength
	f32 = cp.get("turquoise_strength", PackedFloat32Array())
	if f32.size() == w * h:
		generator.last_turquoise_strength = f32.duplicate()
	# beach
	u8 = cp.get("beach", PackedByteArray())
	if u8.size() == w * h:
		generator.last_beach = u8.duplicate()
	# Scalars
	if "last_ocean_fraction" in generator:
		generator.last_ocean_fraction = float(cp.get("ocean_fraction", 0.0))
	# Sync time metadata in world state if present
	var t: float = float(cp.get("time_days", 0.0))
	if "_world_state" in generator and generator._world_state != null:
		generator._world_state.simulation_time_days = t
	last_loaded_time_days = t
	return true

func _capture_config() -> Dictionary:
	var d := {}
	if generator == null or not ("config" in generator):
		return d
	var c = generator.config
	# Core seed/size
	d["rng_seed"] = c.rng_seed
	d["width"] = c.width
	d["height"] = c.height
	# Terrain
	d["octaves"] = c.octaves
	d["frequency"] = float(c.frequency)
	d["lacunarity"] = float(c.lacunarity)
	d["gain"] = float(c.gain)
	d["warp"] = float(c.warp)
	d["sea_level"] = float(c.sea_level)
	# Shores & meta
	d["shallow_threshold"] = float(c.shallow_threshold)
	d["shore_band"] = float(c.shore_band)
	d["shore_noise_mult"] = float(c.shore_noise_mult)
	d["height_scale_m"] = float(c.height_scale_m)
	# Climate
	d["temp_min_c"] = float(c.temp_min_c)
	d["temp_max_c"] = float(c.temp_max_c)
	d["lava_temp_threshold_c"] = float(c.lava_temp_threshold_c)
	d["temp_base_offset"] = float(c.temp_base_offset)
	d["temp_scale"] = float(c.temp_scale)
	d["moist_base_offset"] = float(c.moist_base_offset)
	d["moist_scale"] = float(c.moist_scale)
	d["continentality_scale"] = float(c.continentality_scale)
	# Seasonal
	d["season_phase"] = float(c.season_phase)
	d["season_amp_equator"] = float(c.season_amp_equator)
	d["season_amp_pole"] = float(c.season_amp_pole)
	d["season_ocean_damp"] = float(c.season_ocean_damp)
	# Toggles
	d["rivers_enabled"] = VariantCastsUtil.to_bool(c.rivers_enabled)
	d["lakes_enabled"] = VariantCastsUtil.to_bool(c.lakes_enabled)
	d["realistic_pooling_enabled"] = VariantCastsUtil.to_bool(c.realistic_pooling_enabled)
	# Hydro outflow
	d["max_forced_outflows"] = c.max_forced_outflows
	d["prob_outflow_0"] = float(c.prob_outflow_0)
	d["prob_outflow_1"] = float(c.prob_outflow_1)
	d["prob_outflow_2"] = float(c.prob_outflow_2)
	d["prob_outflow_3"] = float(c.prob_outflow_3)
	# Misc
	d["noise_x_scale"] = float(c.noise_x_scale)
	return d

func _dup_f32(src: PackedFloat32Array, size: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if src.size() == size:
		out = src.duplicate()
	return out

func _dup_u8(src: PackedByteArray, size: int) -> PackedByteArray:
	var out := PackedByteArray()
	if src.size() == size:
		out = src.duplicate()
	return out

func _dup_i32(src: PackedInt32Array, size: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if src.size() == size:
		out = src.duplicate()
	return out
