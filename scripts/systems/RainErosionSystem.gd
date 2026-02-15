# File: res://scripts/systems/RainErosionSystem.gd
extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

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

const MAX_DT_DAYS: float = 0.5
const BASE_EROSION_RATE_PER_DAY: float = 0.000010
const MAX_EROSION_RATE_PER_DAY: float = 0.00020
const GLACIER_SMOOTHING_BIAS: float = 0.65
const CRYO_EROSION_RATE_SCALE: float = 1.25
const CRYO_EROSION_CAP_SCALE: float = 1.55

func _cleanup_if_supported(obj: Variant) -> void:
	if obj == null:
		return
	if obj is Object:
		var o: Object = obj as Object
		if o.has_method("cleanup"):
			o.call("cleanup")

func initialize(gen: Object) -> void:
	generator = gen
	_step_counter = 0
	if _compute == null:
		_compute = RainErosionCompute.new()
	if _land_mask_compute == null:
		_land_mask_compute = LandMaskCompute.new()

func cleanup() -> void:
	_cleanup_if_supported(_compute)
	_cleanup_if_supported(_land_mask_compute)
	_compute = null
	_land_mask_compute = null
	_step_counter = 0
	generator = null

func tick(dt_days: float, _world: Object, _gpu_ctx: Dictionary) -> Dictionary:
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
	var flow_dir_buf: RID = generator.get_persistent_buffer("flow_dir")
	var land_buf: RID = generator.get_persistent_buffer("is_land")
	var lake_buf: RID = generator.get_persistent_buffer("lake")
	var lava_buf: RID = generator.get_persistent_buffer("lava")
	var biome_buf: RID = generator.get_persistent_buffer("biome_id")
	var rock_buf: RID = generator.get_persistent_buffer("rock_type")
	if not height_buf.is_valid() or not height_tmp.is_valid():
		return {}
	if not moisture_buf.is_valid() or not flow_buf.is_valid() or not flow_dir_buf.is_valid():
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
			flow_dir_buf,
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
	if "dispatch_copy_u32" in generator:
		if not VariantCasts.to_bool(generator.dispatch_copy_u32(height_tmp, height_buf, size)):
			return {}
	else:
		return {}

	# Rebuild land mask from updated terrain on GPU.
	if _land_mask_compute == null:
		_land_mask_compute = LandMaskCompute.new()
	_land_mask_compute.update_from_height(w, h, height_buf, float(generator.config.sea_level), land_buf)
	if "apply_ocean_connectivity_gate_runtime" in generator:
		generator.apply_ocean_connectivity_gate_runtime()

	_step_counter += 1

	return {
		"dirty_fields": PackedStringArray(["height", "is_land"]),
		"consumed_days": dt_eff
	}
