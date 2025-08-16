# File: res://scripts/style/AsyncAsciiStyler.gd
extends RefCounted

# Asynchronous ASCII styler to prevent main thread blocking
# Processes large maps in chunks to maintain UI responsiveness

const AsciiStyler = preload("res://scripts/style/AsciiStyler.gd")

signal ascii_generation_complete(ascii_text: String)
signal progress_update(percent: float)

var _is_processing: bool = false
var _should_cancel: bool = false

func is_processing() -> bool:
	return _is_processing

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
	
	# For small maps, use synchronous generation
	var total_cells = w * h
	if total_cells <= 5000:  # ~70x70 or smaller
		var styler = AsciiStyler.new()
		var result = styler.build_ascii(w, h, height, is_land, turquoise_mask, turquoise_strength, beach_mask, water_distance, biomes, sea_level, rng_seed, temperature, temp_min_c, temp_max_c, shelf_noise, lake_mask, river_mask, pooled_lake_mask, lava_mask, clouds, lake_freeze, light_field, plate_boundary_mask)
		_is_processing = false
		ascii_generation_complete.emit(result)
		return
	
	# For large maps, use chunked processing
	_build_ascii_chunked.call_deferred(w, h, height, is_land, turquoise_mask, turquoise_strength, beach_mask, water_distance, biomes, sea_level, rng_seed, temperature, temp_min_c, temp_max_c, shelf_noise, lake_mask, river_mask, pooled_lake_mask, lava_mask, clouds, lake_freeze, light_field, plate_boundary_mask)

func _build_ascii_chunked(
	w: int, h: int,
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
	
	var styler = AsciiStyler.new()
	var sb: PackedStringArray = PackedStringArray()
	var use_light: bool = light_field.size() == w * h
	var total: int = w * h
	
	# Pre-calculate data availability flags
	var flags = _calculate_data_flags(w, h, height, is_land, biomes, beach_mask, turquoise_mask, turquoise_strength, water_distance, shelf_noise, lake_mask, river_mask, pooled_lake_mask, lava_mask, clouds, lake_freeze, temperature, plate_boundary_mask)
	
	# Process in chunks to avoid blocking
	var chunk_size = 500  # Process ~22x22 tile chunks at a time
	var processed_rows = 0
	
	for start_y in range(0, h, chunk_size):
		if _should_cancel:
			_is_processing = false
			return
		
		var end_y = min(start_y + chunk_size, h)
		var chunk_lines: PackedStringArray = []
		
		# Process chunk
		for y in range(start_y, end_y):
			var line_parts: PackedStringArray = []
			for x in range(w):
				var i: int = x + y * w
				var result = _process_cell(x, y, i, w, h, styler, rng_seed, flags, height, is_land, biomes, beach_mask, turquoise_mask, turquoise_strength, water_distance, shelf_noise, lake_mask, river_mask, pooled_lake_mask, lava_mask, clouds, lake_freeze, temperature, temp_min_c, temp_max_c, sea_level, use_light, light_field, plate_boundary_mask)
				line_parts.append(result)
			line_parts.append("\\n")
			chunk_lines.append("".join(line_parts))
		
		sb.append_array(chunk_lines)
		processed_rows = end_y
		
		# Emit progress and yield control
		var progress = float(processed_rows) / float(h)
		progress_update.emit(progress)
		
		# Yield control to prevent UI freezing
		await Engine.get_main_loop().process_frame
	
	if not _should_cancel:
		var final_result = "".join(sb)
		_is_processing = false
		ascii_generation_complete.emit(final_result)
	else:
		_is_processing = false

func _calculate_data_flags(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, biomes: PackedInt32Array, beach_mask: PackedByteArray, turquoise_mask: PackedByteArray, turquoise_strength: PackedFloat32Array, water_distance: PackedFloat32Array, shelf_noise: PackedFloat32Array, lake_mask: PackedByteArray, river_mask: PackedByteArray, pooled_lake_mask: PackedByteArray, lava_mask: PackedByteArray, clouds: PackedFloat32Array, lake_freeze: PackedByteArray, temperature: PackedFloat32Array, plate_boundary_mask: PackedByteArray) -> Dictionary:
	var total = w * h
	return {
		"have_height": height.size() == total,
		"have_land": is_land.size() == total,
		"have_biome": biomes.size() == total,
		"have_beach": beach_mask.size() == total,
		"have_turq": turquoise_mask.size() == total,
		"have_turq_strength": turquoise_strength.size() == total,
		"have_water_dist": water_distance.size() == total,
		"have_shelf": shelf_noise.size() == total,
		"have_lake": lake_mask.size() == total,
		"have_river": river_mask.size() == total,
		"have_pool": pooled_lake_mask.size() == total,
		"have_lava": lava_mask.size() == total,
		"have_clouds": clouds.size() == total,
		"have_freeze": lake_freeze.size() == total,
		"have_temp": temperature.size() == total,
		"have_boundaries": plate_boundary_mask.size() == total
	}

func _process_cell(x: int, y: int, i: int, w: int, h: int, styler: Object, rng_seed: int, flags: Dictionary, height: PackedFloat32Array, is_land: PackedByteArray, biomes: PackedInt32Array, beach_mask: PackedByteArray, turquoise_mask: PackedByteArray, turquoise_strength: PackedFloat32Array, water_distance: PackedFloat32Array, shelf_noise: PackedFloat32Array, lake_mask: PackedByteArray, river_mask: PackedByteArray, pooled_lake_mask: PackedByteArray, lava_mask: PackedByteArray, clouds: PackedFloat32Array, lake_freeze: PackedByteArray, temperature: PackedFloat32Array, temp_min_c: float, temp_max_c: float, sea_level: float, use_light: bool, light_field: PackedFloat32Array, plate_boundary_mask: PackedByteArray) -> String:
	# This is a simplified version - for full implementation, we'd need to replicate
	# the entire cell processing logic from AsciiStyler.build_ascii()
	# For now, delegate to the original styler for individual cells
	
	# Default values
	var glyph: String = " "
	var col: Color = Color(1,1,1,1)
	
	if flags.have_land and flags.have_height:
		if is_land[i] == 1:
			var biome_id: int = (biomes[i] if flags.have_biome else 0)
			var is_beach: bool = flags.have_beach and beach_mask[i] == 1
			# Use styler for glyph generation
			glyph = styler.glyph_for(x, y, true, biome_id, is_beach, rng_seed)
			# Simplified color (would need full logic from original)
			col = Color(0.5, 0.8, 0.3) if not is_beach else Color(0.9, 0.8, 0.6)
		else:
			glyph = "≈"
			col = Color(0.2, 0.4, 0.8)
	
	# Apply light field if available
	if use_light and light_field.size() > i:
		var b: float = clamp(light_field[i], 0.0, 1.0)
		col = Color(col.r * b, col.g * b, col.b * b, col.a)
	
	return "[color=%s]%s[/color]" % [col.to_html(true), glyph]