# File: res://scripts/rendering/WorldDataTextureManager.gd
class_name WorldDataTextureManager
extends RefCounted

# Manages GPU textures containing world data for ASCII rendering
# Efficiently packs multiple data channels into textures

# Load classes dynamically to avoid circular dependencies

# Texture data (RGBA channels packed efficiently)
var data_texture_1: ImageTexture  # height, temperature, moisture, light
var data_texture_2: ImageTexture  # biome_id, is_land, character_index, special_flags
var data_texture_3: ImageTexture  # turquoise_strength, shelf_noise, clouds, plate_boundary
var data_texture_4: ImageTexture  # lake, river, lava, lake_level_norm
var color_palette_texture: ImageTexture  # Pre-computed biome colors
var render_bedrock_view: bool = false

# Current data dimensions
var current_width: int = 0
var current_height: int = 0

# Character mapper instance
var character_mapper: Object

func _init():
	var AsciiCharacterMapperClass = load("res://scripts/rendering/AsciiCharacterMapper.gd")
	character_mapper = AsciiCharacterMapperClass.new()

func update_world_data(
	width: int,
	height: int,
	height_data: PackedFloat32Array,
	temperature_data: PackedFloat32Array,
	moisture_data: PackedFloat32Array,
	light_data: PackedFloat32Array,
	biome_data: PackedInt32Array,
	rock_data: PackedInt32Array,
	is_land_data: PackedByteArray,
	beach_mask: PackedByteArray,
	rng_seed: int,
	use_bedrock_view: bool = false,
	turquoise_strength: PackedFloat32Array = PackedFloat32Array(),
	shelf_noise: PackedFloat32Array = PackedFloat32Array(),
	clouds: PackedFloat32Array = PackedFloat32Array(),
	plate_boundary_mask: PackedByteArray = PackedByteArray(),
	lake_mask: PackedByteArray = PackedByteArray(),
	river_mask: PackedByteArray = PackedByteArray(),
	lava_mask: PackedByteArray = PackedByteArray(),
	pooled_lake_mask: PackedByteArray = PackedByteArray(),
	lake_id: PackedInt32Array = PackedInt32Array(),
	sea_level: float = 0.0,
	skip_base_textures: bool = false,
	skip_aux_textures: bool = false
) -> void:
	"""Update all world data textures"""
	
	# debug removed
	
	current_width = width
	current_height = height
	render_bedrock_view = use_bedrock_view
	
	# Update data textures
	if not skip_base_textures:
		_update_data_texture_1(width, height, height_data, temperature_data, moisture_data, light_data)
		_update_data_texture_2(width, height, biome_data, rock_data, is_land_data, beach_mask, rng_seed, use_bedrock_view)
	if not skip_aux_textures:
		_update_data_texture_3(width, height, turquoise_strength, shelf_noise, clouds, plate_boundary_mask)
		_update_data_texture_4(width, height, height_data, lake_mask, river_mask, lava_mask, pooled_lake_mask, lake_id, sea_level)
	_update_color_palette_texture(use_bedrock_view)

func update_clouds_only(
	width: int,
	height: int,
	turquoise_strength: PackedFloat32Array,
	shelf_noise: PackedFloat32Array,
	clouds: PackedFloat32Array,
	plate_boundary_mask: PackedByteArray
) -> void:
	"""Update only the clouds/turquoise/shelf texture (texture 3)."""
	current_width = width
	current_height = height
	_update_data_texture_3(width, height, turquoise_strength, shelf_noise, clouds, plate_boundary_mask)

func _update_data_texture_1(
	width: int,
	height: int, 
	height_data: PackedFloat32Array,
	temperature_data: PackedFloat32Array,
	moisture_data: PackedFloat32Array,
	light_data: PackedFloat32Array
) -> void:
	"""Update texture 1: height, temperature, moisture, light (RGBA32F)"""
	
	var image = Image.create(width, height, false, Image.FORMAT_RGBAF)
	
	var _total_pixels = width * height
	
	for y in range(height):
		for x in range(width):
			var i = x + y * width
			
			# Sample data arrays safely
			var height_val = height_data[i] if i < height_data.size() else 0.0
			var temp_val = temperature_data[i] if i < temperature_data.size() else 0.0
			var moisture_val = moisture_data[i] if i < moisture_data.size() else 0.0
			var light_val = light_data[i] if i < light_data.size() else 1.0
			
			# Normalize values to 0-1 range for texture storage
			var normalized_height = clamp(height_val * 0.5 + 0.5, 0.0, 1.0)  # Assume height in -1..1 range
			var normalized_temp = clamp(temp_val, 0.0, 1.0)
			var normalized_moisture = clamp(moisture_val, 0.0, 1.0)
			var normalized_light = clamp(light_val, 0.0, 1.0)
			
			image.set_pixel(x, y, Color(normalized_height, normalized_temp, normalized_moisture, normalized_light))
	
	# Create or update texture
	if data_texture_1 == null:
		data_texture_1 = ImageTexture.new()
	data_texture_1.set_image(image)

func _update_data_texture_2(
	width: int,
	height: int,
	biome_data: PackedInt32Array,
	rock_data: PackedInt32Array,
	is_land_data: PackedByteArray,
	beach_mask: PackedByteArray,
	rng_seed: int,
	use_bedrock_view: bool
) -> void:
	"""Update texture 2: biome_id, is_land, character_index, special_flags (RGBAF)"""
	
	# Use float format to avoid sRGB conversion and preserve exact values for indices/flags
	var image = Image.create(width, height, false, Image.FORMAT_RGBAF)
	
	for y in range(height):
		for x in range(width):
			var i = x + y * width
			
			# Sample data arrays safely
			var biome_id = biome_data[i] if i < biome_data.size() else 0
			var rock_id = rock_data[i] if i < rock_data.size() else 0
			var is_land = is_land_data[i] if i < is_land_data.size() else 0
			var is_beach = beach_mask[i] if i < beach_mask.size() else 0
			var surface_id: int = biome_id
			if use_bedrock_view and is_land != 0:
				surface_id = rock_id
			
			# Get character index for this cell
			var char_index = character_mapper.get_character_index(x, y, is_land == 1, surface_id, is_beach == 1, rng_seed, use_bedrock_view)
			
			# Pack data into RGBA channels (0..1 range)
			var biome_normalized = clamp(float(surface_id) / 255.0, 0.0, 1.0)
			var land_normalized = 1.0 if is_land != 0 else 0.0
			var char_normalized = clamp(float(char_index) / 255.0, 0.0, 1.0)
			var flags_normalized = 1.0 if (is_beach != 0 and not use_bedrock_view) else 0.0  # Could pack more flags here
			
			image.set_pixel(x, y, Color(biome_normalized, land_normalized, char_normalized, flags_normalized))
	
	# Create or update texture
	if data_texture_2 == null:
		data_texture_2 = ImageTexture.new()
	data_texture_2.set_image(image)

func _update_data_texture_3(
	width: int,
	height: int,
	turquoise_strength: PackedFloat32Array,
	shelf_noise: PackedFloat32Array,
	clouds: PackedFloat32Array,
	plate_boundary_mask: PackedByteArray
) -> void:
	"""Update texture 3: turquoise_strength, shelf_noise, clouds, plate_boundary (RGBA32F)"""
	var image = Image.create(width, height, false, Image.FORMAT_RGBAF)
	for y in range(height):
		for x in range(width):
			var i = x + y * width
			var turq = turquoise_strength[i] if i < turquoise_strength.size() else 0.0
			var shelf = shelf_noise[i] if i < shelf_noise.size() else 0.0
			var cloud = clouds[i] if i < clouds.size() else 0.0
			var boundary = 1.0 if (i < plate_boundary_mask.size() and plate_boundary_mask[i] != 0) else 0.0
			image.set_pixel(x, y, Color(clamp(turq, 0.0, 1.0), clamp(shelf, 0.0, 1.0), clamp(cloud, 0.0, 1.0), boundary))
	if data_texture_3 == null:
		data_texture_3 = ImageTexture.new()
	data_texture_3.set_image(image)

func _update_data_texture_4(
	width: int,
	height: int,
	height_data: PackedFloat32Array,
	lake_mask: PackedByteArray,
	river_mask: PackedByteArray,
	lava_mask: PackedByteArray,
	pooled_lake_mask: PackedByteArray,
	lake_id: PackedInt32Array,
	sea_level: float
) -> void:
	"""Update texture 4: lake, river, lava, lake_level_norm (RGBA32F)"""
	var size: int = width * height
	var has_lake_id: bool = lake_id.size() == size
	var has_height: bool = height_data.size() == size
	var lake_level: PackedFloat32Array = PackedFloat32Array()
	if has_lake_id and has_height:
		var max_id: int = 0
		for i0 in range(size):
			var lid: int = lake_id[i0]
			if lid > max_id:
				max_id = lid
		if max_id > 0:
			lake_level.resize(max_id + 1)
			var fallback_level: PackedFloat32Array = PackedFloat32Array()
			fallback_level.resize(max_id + 1)
			for j in range(max_id + 1):
				lake_level[j] = -999.0
				fallback_level[j] = -999.0
			var neighbor_dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
			# Prefer rim heights (lake cells adjacent to non-lake) to approximate spill level.
			for y in range(height):
				for x in range(width):
					var i1: int = x + y * width
					var lid2: int = lake_id[i1]
					if lid2 <= 0:
						continue
					var is_lake: bool = (i1 < lake_mask.size() and lake_mask[i1] != 0) or (i1 < pooled_lake_mask.size() and pooled_lake_mask[i1] != 0)
					if not is_lake:
						continue
					var h: float = height_data[i1]
					if h > fallback_level[lid2]:
						fallback_level[lid2] = h
					var edge: bool = false
					for dir in neighbor_dirs:
						var nx: int = x + dir.x
						var ny: int = y + dir.y
						if ny < 0 or ny >= height:
							edge = true
							break
						if nx < 0:
							nx += width
						elif nx >= width:
							nx -= width
						var ni: int = nx + ny * width
						var n_is_lake: bool = (ni < lake_mask.size() and lake_mask[ni] != 0) or (ni < pooled_lake_mask.size() and pooled_lake_mask[ni] != 0)
						if not n_is_lake:
							edge = true
							break
					if edge and h > lake_level[lid2]:
						lake_level[lid2] = h
			for lid in range(max_id + 1):
				if lake_level[lid] < -900.0 and fallback_level[lid] > -900.0:
					lake_level[lid] = fallback_level[lid]
	var image = Image.create(width, height, false, Image.FORMAT_RGBAF)
	for y in range(height):
		for x in range(width):
			var i = x + y * width
			var lake_val = 0.0
			if i < lake_mask.size() and lake_mask[i] != 0:
				lake_val = 1.0
			elif i < pooled_lake_mask.size() and pooled_lake_mask[i] != 0:
				lake_val = 1.0
			var river_val = 1.0 if (i < river_mask.size() and river_mask[i] != 0) else 0.0
			var lava_val = 1.0 if (i < lava_mask.size() and lava_mask[i] != 0) else 0.0
			var level_val: float = sea_level
			if lake_val > 0.5 and has_lake_id and has_height:
				var lid3: int = lake_id[i]
				if lid3 > 0 and lid3 < lake_level.size() and lake_level[lid3] > -900.0:
					level_val = lake_level[lid3]
			var level_norm: float = clamp(level_val * 0.5 + 0.5, 0.0, 1.0)
			image.set_pixel(x, y, Color(lake_val, river_val, lava_val, level_norm))
	if data_texture_4 == null:
		data_texture_4 = ImageTexture.new()
	data_texture_4.set_image(image)

func _update_color_palette_texture(use_bedrock_view: bool = false) -> void:
	"""Create color palette texture for biome colors"""
	
	# Create palette with 256 colors (one row)
	var palette_size = 256
	var image = Image.create(palette_size, 1, false, Image.FORMAT_RGB8)
	
	var BiomePaletteClass = load("res://scripts/style/BiomePalette.gd")
	var biome_palette = BiomePaletteClass.new()
	var RockPaletteClass = load("res://scripts/style/RockPalette.gd")
	var rock_palette = RockPaletteClass.new()
	
	# Generate colors for each biome ID
	for biome_id in range(palette_size):
		var color = biome_palette.color_for_biome(biome_id, false)
		if use_bedrock_view:
			color = rock_palette.color_for_rock(biome_id, false)
		image.set_pixel(biome_id, 0, color)
	
	# Create texture
	if color_palette_texture == null:
		color_palette_texture = ImageTexture.new()
	color_palette_texture.set_image(image)

func get_data_texture_1() -> ImageTexture:
	"""Get data texture 1 (height, temperature, moisture, light)"""
	return data_texture_1

func get_data_texture_2() -> ImageTexture:
	"""Get data texture 2 (biome_id, is_land, character_index, flags)"""
	return data_texture_2

func get_data_texture_3() -> ImageTexture:
	"""Get data texture 3 (turquoise, shelf, clouds, boundary)"""
	return data_texture_3

func get_data_texture_4() -> ImageTexture:
	"""Get data texture 4 (lake, river, lava, reserved)"""
	return data_texture_4

func get_color_palette_texture() -> ImageTexture:
	"""Get color palette texture"""
	return color_palette_texture

func get_dimensions() -> Vector2i:
	"""Get current texture dimensions"""
	return Vector2i(current_width, current_height)

# Optimized update functions for individual data components

func update_light_data_only(light_data: PackedFloat32Array) -> void:
	"""Fast update for just light data (day-night cycle)"""
	if data_texture_1 == null or current_width == 0 or current_height == 0:
		return
	
	var image = data_texture_1.get_image()
	if image == null:
		return
	
	# Update only the alpha channel (light data)
	for y in range(current_height):
		for x in range(current_width):
			var i = x + y * current_width
			
			if i < light_data.size():
				var existing_color = image.get_pixel(x, y)
				var new_light = clamp(light_data[i], 0.0, 1.0)
				image.set_pixel(x, y, Color(existing_color.r, existing_color.g, existing_color.b, new_light))
	
	# Update texture
	data_texture_1.set_image(image)

func update_temperature_data_only(temperature_data: PackedFloat32Array) -> void:
	"""Fast update for just temperature data (climate changes)"""
	if data_texture_1 == null or current_width == 0 or current_height == 0:
		return
	
	var image = data_texture_1.get_image()
	if image == null:
		return
	
	# Update only the green channel (temperature data)
	for y in range(current_height):
		for x in range(current_width):
			var i = x + y * current_width
			
			if i < temperature_data.size():
				var existing_color = image.get_pixel(x, y)
				var new_temp = clamp(temperature_data[i], 0.0, 1.0)
				image.set_pixel(x, y, Color(existing_color.r, new_temp, existing_color.b, existing_color.a))
	
	# Update texture
	data_texture_1.set_image(image)

func save_debug_textures(prefix: String) -> void:
	"""Save textures to files for debugging"""
	if data_texture_1 and data_texture_1.get_image():
		data_texture_1.get_image().save_png(prefix + "_data1.png")
		# debug removed
	
	if data_texture_2 and data_texture_2.get_image():
		data_texture_2.get_image().save_png(prefix + "_data2.png")
		# debug removed

	if data_texture_3 and data_texture_3.get_image():
		data_texture_3.get_image().save_png(prefix + "_data3.png")
		# debug removed

	if data_texture_4 and data_texture_4.get_image():
		data_texture_4.get_image().save_png(prefix + "_data4.png")
		# debug removed
	
	if color_palette_texture and color_palette_texture.get_image():
		color_palette_texture.get_image().save_png(prefix + "_palette.png")
		# debug removed

func get_memory_usage_mb() -> float:
	"""Estimate GPU memory usage in MB"""
	var usage = 0.0
	
	if data_texture_1:
		usage += current_width * current_height * 16  # RGBA32F = 16 bytes per pixel
	
	if data_texture_2:
		usage += current_width * current_height * 16  # RGBA32F = 16 bytes per pixel

	if data_texture_3:
		usage += current_width * current_height * 16  # RGBA32F = 16 bytes per pixel

	if data_texture_4:
		usage += current_width * current_height * 16  # RGBA32F = 16 bytes per pixel
	
	if color_palette_texture:
		usage += 256 * 1 * 3  # RGB8 = 3 bytes per pixel
	
	return usage / (1024.0 * 1024.0)  # Convert to MB
