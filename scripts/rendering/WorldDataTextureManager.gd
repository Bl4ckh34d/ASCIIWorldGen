# File: res://scripts/rendering/WorldDataTextureManager.gd
class_name WorldDataTextureManager
extends RefCounted

# Manages GPU textures containing world data for ASCII rendering
# Efficiently packs multiple data channels into textures

# Load classes dynamically to avoid circular dependencies

# Texture data (RGBA channels packed efficiently)
var data_texture_1: ImageTexture  # height, temperature, moisture, light
var data_texture_2: ImageTexture  # biome_id, is_land, character_index, special_flags
var color_palette_texture: ImageTexture  # Pre-computed biome colors

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
	is_land_data: PackedByteArray,
	beach_mask: PackedByteArray,
	rng_seed: int
) -> void:
	"""Update all world data textures"""
	
	print("WorldDataTextureManager: Updating textures (%dx%d)" % [width, height])
	
	current_width = width
	current_height = height
	
	# Update data textures
	_update_data_texture_1(width, height, height_data, temperature_data, moisture_data, light_data)
	_update_data_texture_2(width, height, biome_data, is_land_data, beach_mask, rng_seed)
	_update_color_palette_texture()

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
	is_land_data: PackedByteArray,
	beach_mask: PackedByteArray,
	rng_seed: int
) -> void:
	"""Update texture 2: biome_id, is_land, character_index, special_flags (RGBA8)"""
	
	var image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	for y in range(height):
		for x in range(width):
			var i = x + y * width
			
			# Sample data arrays safely
			var biome_id = biome_data[i] if i < biome_data.size() else 0
			var is_land = is_land_data[i] if i < is_land_data.size() else 0
			var is_beach = beach_mask[i] if i < beach_mask.size() else 0
			
			# Get character index for this cell
			var char_index = character_mapper.get_character_index(x, y, is_land == 1, biome_id, is_beach == 1, rng_seed)
			
			# Pack data into RGBA channels (0-255 range)
			var biome_normalized = clamp(float(biome_id) / 255.0, 0.0, 1.0)
			var land_normalized = float(is_land) / 255.0
			var char_normalized = float(char_index) / 255.0
			var flags_normalized = float(is_beach) / 255.0  # Could pack more flags here
			
			image.set_pixel(x, y, Color(biome_normalized, land_normalized, char_normalized, flags_normalized))
	
	# Create or update texture
	if data_texture_2 == null:
		data_texture_2 = ImageTexture.new()
	data_texture_2.set_image(image)

func _update_color_palette_texture() -> void:
	"""Create color palette texture for biome colors"""
	
	# Create palette with 256 colors (one row)
	var palette_size = 256
	var image = Image.create(palette_size, 1, false, Image.FORMAT_RGB8)
	
	var BiomePaletteClass = load("res://scripts/style/BiomePalette.gd")
	var biome_palette = BiomePaletteClass.new()
	
	# Generate colors for each biome ID
	for biome_id in range(palette_size):
		var color = biome_palette.color_for_biome(biome_id, false)
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
		print("Saved debug texture: %s_data1.png" % prefix)
	
	if data_texture_2 and data_texture_2.get_image():
		data_texture_2.get_image().save_png(prefix + "_data2.png")
		print("Saved debug texture: %s_data2.png" % prefix)
	
	if color_palette_texture and color_palette_texture.get_image():
		color_palette_texture.get_image().save_png(prefix + "_palette.png")
		print("Saved debug texture: %s_palette.png" % prefix)

func get_memory_usage_mb() -> float:
	"""Estimate GPU memory usage in MB"""
	var usage = 0.0
	
	if data_texture_1:
		usage += current_width * current_height * 16  # RGBA32F = 16 bytes per pixel
	
	if data_texture_2:
		usage += current_width * current_height * 4   # RGBA8 = 4 bytes per pixel
	
	if color_palette_texture:
		usage += 256 * 1 * 3  # RGB8 = 3 bytes per pixel
	
	return usage / (1024.0 * 1024.0)  # Convert to MB
