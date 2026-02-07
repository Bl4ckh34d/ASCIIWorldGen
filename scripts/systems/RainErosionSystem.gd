# File: res://scripts/systems/RainErosionSystem.gd
extends RefCounted

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")
const RainErosionCompute = preload("res://scripts/systems/RainErosionCompute.gd")
const LandMaskCompute = preload("res://scripts/systems/LandMaskCompute.gd")

# Runtime rainfall-driven erosion.
# Strength is derived from humidity/moisture and runoff/flow accumulation.
# GPU-first implementation to avoid CPU bottlenecks.

var generator: Object = null
var _compute: Object = null
var _land_mask_compute: Object = null
var _step_counter: int = 0

const MAX_DT_DAYS: float = 6.0
const BASE_EROSION_RATE_PER_DAY: float = 0.000045
const MAX_EROSION_RATE_PER_DAY: float = 0.0009
const GLACIER_SMOOTHING_BIAS: float = 0.65
const CRYO_EROSION_RATE_SCALE: float = 1.25
const CRYO_EROSION_CAP_SCALE: float = 1.55
const CPU_SYNC_INTERVAL_STEPS: int = 90
const CPU_SYNC_MAX_CELLS: int = 250000

func initialize(gen: Object) -> void:
	generator = gen
	_step_counter = 0
	if _compute == null:
		_compute = RainErosionCompute.new()
	if _land_mask_compute == null:
		_land_mask_compute = LandMaskCompute.new()

func tick(dt_days: float, world: Object, _gpu_ctx: Dictionary) -> Dictionary:
	if generator == null:
		return {}
	var w: int = int(generator.config.width)
	var h: int = int(generator.config.height)
	var size: int = w * h
	if size <= 0:
		return {}

	var dt_eff: float = clamp(float(dt_days), 0.0, MAX_DT_DAYS)
	if dt_eff <= 0.0:
		return {}

	if "ensure_persistent_buffers" in generator:
		generator.ensure_persistent_buffers(false)

	var height_buf: RID = generator.get_persistent_buffer("height")
	var height_tmp: RID = generator.get_persistent_buffer("height_tmp")
	var moisture_buf: RID = generator.get_persistent_buffer("moisture")
	var flow_buf: RID = generator.get_persistent_buffer("flow_accum")
	var land_buf: RID = generator.get_persistent_buffer("is_land")
	var lake_buf: RID = generator.get_persistent_buffer("lake")
	var lava_buf: RID = generator.get_persistent_buffer("lava")
	var biome_buf: RID = generator.get_persistent_buffer("biome_id")
	var rock_buf: RID = generator.get_persistent_buffer("rock_type")
	if not height_buf.is_valid() or not height_tmp.is_valid():
		return {}
	if not moisture_buf.is_valid() or not flow_buf.is_valid():
		return {}
	if not land_buf.is_valid() or not lake_buf.is_valid() or not lava_buf.is_valid() or not biome_buf.is_valid() or not rock_buf.is_valid():
		return {}

	if _compute == null:
		_compute = RainErosionCompute.new()
	var noise_phase: float = float((_step_counter % 100000)) * 0.017
	var ok_gpu: bool = _compute.apply_gpu_buffers(
		w,
		h,
		height_buf,
		moisture_buf,
		flow_buf,
		land_buf,
		lake_buf,
		lava_buf,
		biome_buf,
		rock_buf,
		dt_eff,
		float(generator.config.sea_level),
		BASE_EROSION_RATE_PER_DAY,
		MAX_EROSION_RATE_PER_DAY,
		noise_phase,
		GLACIER_SMOOTHING_BIAS,
		CRYO_EROSION_RATE_SCALE,
		CRYO_EROSION_CAP_SCALE,
		int(BiomeClassifier.Biome.ICE_SHEET),
		int(BiomeClassifier.Biome.GLACIER),
		int(BiomeClassifier.Biome.DESERT_ICE),
		height_tmp
	)
	if not ok_gpu:
		return {}

	# Commit height_tmp -> height (bitwise copy as u32 words).
	if generator._flow_compute == null:
		generator._flow_compute = load("res://scripts/systems/FlowCompute.gd").new()
	if "_ensure" in generator._flow_compute:
		generator._flow_compute._ensure()
	generator._flow_compute._dispatch_copy_u32(height_tmp, height_buf, size)

	# Rebuild land mask from updated terrain on GPU.
	if _land_mask_compute == null:
		_land_mask_compute = LandMaskCompute.new()
	_land_mask_compute.update_from_height(w, h, height_buf, float(generator.config.sea_level), land_buf)

	_step_counter += 1
	var sync_interval: int = _cpu_sync_interval_for_world(world)
	if _step_counter % max(1, sync_interval) == 0:
		_sync_cpu_mirror(size)

	return {
		"dirty_fields": PackedStringArray(["height", "is_land"]),
		"consumed_days": dt_eff
	}

func _sync_cpu_mirror(size: int) -> void:
	if generator == null:
		return
	if size <= 0 or size > CPU_SYNC_MAX_CELLS:
		return
	if not ("read_persistent_buffer" in generator):
		return

	var h_bytes: PackedByteArray = generator.read_persistent_buffer("height")
	var h_vals: PackedFloat32Array = h_bytes.to_float32_array()
	if h_vals.size() == size:
		generator.last_height = h_vals
		generator.last_height_final = h_vals

	var l_bytes: PackedByteArray = generator.read_persistent_buffer("is_land")
	var l_vals: PackedInt32Array = l_bytes.to_int32_array()
	if l_vals.size() == size:
		var land := PackedByteArray()
		land.resize(size)
		var ocean_count: int = 0
		for i in range(size):
			var v: int = 1 if l_vals[i] != 0 else 0
			land[i] = v
			if v == 0:
				ocean_count += 1
		generator.last_is_land = land
		generator.last_ocean_fraction = float(ocean_count) / float(max(1, size))

func _cpu_sync_interval_for_world(world: Object) -> int:
	var ts: float = 1.0
	if world != null and "time_scale" in world:
		ts = max(1.0, float(world.time_scale))
	var interval: int = CPU_SYNC_INTERVAL_STEPS
	if ts >= 100000.0:
		interval *= 24
	elif ts >= 10000.0:
		interval *= 12
	elif ts >= 1000.0:
		interval *= 6
	elif ts >= 100.0:
		interval *= 3
	elif ts >= 10.0:
		interval *= 2
	return max(1, interval)
