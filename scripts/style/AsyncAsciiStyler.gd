# File: res://scripts/style/AsyncAsciiStyler.gd
extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const AsciiStyler = preload("res://scripts/style/AsciiStyler.gd")
const WorldConstants = preload("res://scripts/core/WorldConstants.gd")

signal ascii_generation_complete(ascii_text: String)
signal progress_update(percent: float)

var _is_processing: bool = false
var _should_cancel: bool = false
var _async_enabled: bool = VariantCasts.to_bool(WorldConstants.FEATURE_ASYNC_ASCII_STYLER)

func is_processing() -> bool:
	return _is_processing

func is_async_enabled() -> bool:
	return _async_enabled

func set_async_enabled(enabled: bool) -> void:
	_async_enabled = VariantCasts.to_bool(enabled)

func cancel_generation() -> void:
	_should_cancel = true

func build_ascii_async(
	w: int,
	h: int,
	height: PackedFloat32Array,
	is_land: PackedByteArray,
	turquoise_mask: PackedByteArray = PackedByteArray(),
	turquoise_strength: PackedFloat32Array = PackedFloat32Array(),
	beach_mask: PackedByteArray = PackedByteArray(),
	water_distance: PackedFloat32Array = PackedFloat32Array(),
	biomes: PackedInt32Array = PackedInt32Array(),
	sea_level: float = 0.0,
	rng_seed: int = 0,
	temperature: PackedFloat32Array = PackedFloat32Array(),
	temp_min_c: float = -20.0,
	temp_max_c: float = 40.0,
	shelf_noise: PackedFloat32Array = PackedFloat32Array(),
	lake_mask: PackedByteArray = PackedByteArray(),
	river_mask: PackedByteArray = PackedByteArray(),
	pooled_lake_mask: PackedByteArray = PackedByteArray(),
	lava_mask: PackedByteArray = PackedByteArray(),
	clouds: PackedFloat32Array = PackedFloat32Array(),
	lake_freeze: PackedByteArray = PackedByteArray(),
	light_field: PackedFloat32Array = PackedFloat32Array(),
	plate_boundary_mask: PackedByteArray = PackedByteArray()
) -> void:
	if _is_processing:
		push_warning("AsyncAsciiStyler: Already processing, ignoring new request")
		return
	_is_processing = true
	_should_cancel = false

	var styler := AsciiStyler.new()
	var total_cells: int = max(0, w * h)
	var sync_limit: int = int(WorldConstants.MAP_SIZE_SMALL)
	if (not _async_enabled) or total_cells <= sync_limit:
		var sync_result: String = styler.build_ascii(
			w,
			h,
			height,
			is_land,
			turquoise_mask,
			turquoise_strength,
			beach_mask,
			water_distance,
			biomes,
			sea_level,
			rng_seed,
			temperature,
			temp_min_c,
			temp_max_c,
			shelf_noise,
			lake_mask,
			river_mask,
			pooled_lake_mask,
			lava_mask,
			clouds,
			lake_freeze,
			light_field,
			plate_boundary_mask
		)
		_is_processing = false
		progress_update.emit(1.0)
		ascii_generation_complete.emit(sync_result)
		return

	_build_ascii_chunked.call_deferred(
		styler,
		w,
		h,
		height,
		is_land,
		turquoise_mask,
		turquoise_strength,
		beach_mask,
		water_distance,
		biomes,
		sea_level,
		rng_seed,
		temperature,
		temp_min_c,
		temp_max_c,
		shelf_noise,
		lake_mask,
		river_mask,
		pooled_lake_mask,
		lava_mask,
		clouds,
		lake_freeze,
		light_field,
		plate_boundary_mask
	)

func _build_ascii_chunked(
	styler: Object,
	w: int,
	h: int,
	height: PackedFloat32Array,
	is_land: PackedByteArray,
	turquoise_mask: PackedByteArray,
	turquoise_strength: PackedFloat32Array,
	beach_mask: PackedByteArray,
	water_distance: PackedFloat32Array,
	biomes: PackedInt32Array,
	sea_level: float,
	rng_seed: int,
	temperature: PackedFloat32Array,
	temp_min_c: float,
	temp_max_c: float,
	shelf_noise: PackedFloat32Array,
	lake_mask: PackedByteArray,
	river_mask: PackedByteArray,
	pooled_lake_mask: PackedByteArray,
	lava_mask: PackedByteArray,
	clouds: PackedFloat32Array,
	lake_freeze: PackedByteArray,
	light_field: PackedFloat32Array,
	plate_boundary_mask: PackedByteArray
) -> void:
	var chunk_cells: int = max(1, int(WorldConstants.ASYNC_ASCII_CHUNK_SIZE))
	var rows_per_chunk: int = max(1, int(floor(float(chunk_cells) / float(max(1, w)))))
	var chunks: PackedStringArray = PackedStringArray()

	for start_y in range(0, h, rows_per_chunk):
		if _should_cancel:
			_is_processing = false
			return
		var end_y: int = min(start_y + rows_per_chunk, h)
		var chunk_text: String = styler.build_ascii_rows(
			w,
			h,
			height,
			is_land,
			turquoise_mask,
			turquoise_strength,
			beach_mask,
			water_distance,
			biomes,
			sea_level,
			rng_seed,
			temperature,
			temp_min_c,
			temp_max_c,
			shelf_noise,
			lake_mask,
			river_mask,
			pooled_lake_mask,
			lava_mask,
			clouds,
			lake_freeze,
			light_field,
			plate_boundary_mask,
			start_y,
			end_y
		)
		chunks.append(chunk_text)
		progress_update.emit(float(end_y) / float(max(1, h)))
		await Engine.get_main_loop().process_frame

	if _should_cancel:
		_is_processing = false
		return
	_is_processing = false
	progress_update.emit(1.0)
	ascii_generation_complete.emit("".join(chunks))
