# File: res://scripts/core/CheckpointSystem.gd
extends Node

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
	max_checkpoints = max(1, int(n))
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
	var t: float = sim_time_days
	if t < 0.0:
		if "_world_state" in generator and generator._world_state != null:
			t = float(generator._world_state.simulation_time_days)
		else:
			t = 0.0
	var w: int = int(generator.config.width if "config" in generator else 0)
	var h: int = int(generator.config.height if "config" in generator else 0)
	var size: int = max(0, w * h)
	var cp := {}
	cp["time_days"] = t
	cp["width"] = w
	cp["height"] = h
	cp["config"] = _capture_config()
	# Fields (deep copies)
	cp["height"] = _dup_f32(generator.last_height, size)
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

func _apply_checkpoint(cp: Dictionary) -> bool:
	if generator == null:
		return false
	var w: int = int(cp.get("width", 0))
	var h: int = int(cp.get("height", 0))
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
	f32 = cp.get("height", PackedFloat32Array()); if f32.size() == w * h: generator.last_height = f32.duplicate()
	u8 = cp.get("is_land", PackedByteArray()); if u8.size() == w * h: generator.last_is_land = u8.duplicate()
	f32 = cp.get("temperature", PackedFloat32Array()); if f32.size() == w * h: generator.last_temperature = f32.duplicate()
	f32 = cp.get("moisture", PackedFloat32Array()); if f32.size() == w * h: generator.last_moisture = f32.duplicate()
	i32 = cp.get("biome_id", PackedInt32Array()); if i32.size() == w * h: generator.last_biomes = i32.duplicate()
	u8 = cp.get("lake", PackedByteArray()); if u8.size() == w * h: generator.last_lake = u8.duplicate()
	i32 = cp.get("lake_id", PackedInt32Array()); if i32.size() == w * h: generator.last_lake_id = i32.duplicate()
	i32 = cp.get("flow_dir", PackedInt32Array()); if i32.size() == w * h: generator.last_flow_dir = i32.duplicate()
	f32 = cp.get("flow_accum", PackedFloat32Array()); if f32.size() == w * h: generator.last_flow_accum = f32.duplicate()
	u8 = cp.get("river", PackedByteArray()); if u8.size() == w * h: generator.last_river = u8.duplicate()
	u8 = cp.get("lava", PackedByteArray()); if u8.size() == w * h: generator.last_lava = u8.duplicate()
	f32 = cp.get("cloud_cov", PackedFloat32Array()); if f32.size() == w * h: generator.last_clouds = f32.duplicate()
	f32 = cp.get("coast_distance", PackedFloat32Array()); if f32.size() == w * h: generator.last_water_distance = f32.duplicate()
	u8 = cp.get("turquoise_water", PackedByteArray()); if u8.size() == w * h: generator.last_turquoise_water = u8.duplicate()
	f32 = cp.get("turquoise_strength", PackedFloat32Array()); if f32.size() == w * h: generator.last_turquoise_strength = f32.duplicate()
	u8 = cp.get("beach", PackedByteArray()); if u8.size() == w * h: generator.last_beach = u8.duplicate()
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
	d["rng_seed"] = int(c.rng_seed)
	d["width"] = int(c.width)
	d["height"] = int(c.height)
	# Terrain
	d["octaves"] = int(c.octaves)
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
	d["use_gpu_all"] = bool(c.use_gpu_all)
	d["use_gpu_clouds"] = bool(c.use_gpu_clouds)
	d["rivers_enabled"] = bool(c.rivers_enabled)
	d["lakes_enabled"] = bool(c.lakes_enabled)
	d["realistic_pooling_enabled"] = bool(c.realistic_pooling_enabled)
	d["use_gpu_pooling"] = bool(c.use_gpu_pooling)
	# Hydro outflow
	d["max_forced_outflows"] = int(c.max_forced_outflows)
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


