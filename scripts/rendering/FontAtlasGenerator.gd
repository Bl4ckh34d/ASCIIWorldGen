# File: res://scripts/rendering/FontAtlasGenerator.gd
class_name FontAtlasGenerator
extends RefCounted

# Generate texture atlas containing ASCII characters for GPU rendering
# Layout: 16x6 grid for 95 printable ASCII characters (32-126)

const ATLAS_SIZE: int = 512
const CHARS_PER_ROW: int = 16
const CHARS_PER_COL: int = 6
const TOTAL_CHARS: int = 95
const FIRST_CHAR: int = 32  # Space character
const LAST_CHAR: int = 126  # Tilde character

# Character dimensions in atlas
var char_width: int
var char_height: int
var char_uv_width: float
var char_uv_height: float

# Generated atlas data
var atlas_texture: ImageTexture
var character_uvs: PackedFloat32Array  # UV coordinates for each character

static func generate_ascii_atlas(font: Font, font_size: int, atlas_size: int = ATLAS_SIZE) -> FontAtlasGenerator:
	"""Generate ASCII font atlas texture and UV coordinates"""
	var generator = FontAtlasGenerator.new()
	generator._generate_atlas(font, font_size, atlas_size)
	return generator

func _generate_atlas(font: Font, font_size: int, atlas_size: int) -> void:
	"""Internal atlas generation"""
	print("FontAtlasGenerator: Generating ASCII atlas (size: %d, font_size: %d)" % [atlas_size, font_size])
	
	# Calculate character dimensions (use float division to avoid warnings)
	char_width = atlas_size / float(CHARS_PER_ROW)
	char_height = atlas_size / float(CHARS_PER_COL)
	char_uv_width = 1.0 / float(CHARS_PER_ROW)
	char_uv_height = 1.0 / float(CHARS_PER_COL)
	
	# Create atlas image
	var atlas_image = Image.create(atlas_size, atlas_size, false, Image.FORMAT_RGBA8)
	atlas_image.fill(Color(0, 0, 0, 0))  # Transparent background
	
	# Initialize UV array
	character_uvs = PackedFloat32Array()
	character_uvs.resize(TOTAL_CHARS * 4)  # 4 floats per character (u_min, v_min, u_max, v_max)
	
	# Render each ASCII character
	for i in range(TOTAL_CHARS):
		var char_code = FIRST_CHAR + i
		var char_string = char(char_code)
		
		# Calculate grid position
		var grid_x = i % CHARS_PER_ROW
		var grid_y = i / CHARS_PER_ROW
		
		# Calculate pixel position in atlas
		var pixel_x = grid_x * char_width
		var pixel_y = grid_y * char_height
		
		# Render character to atlas
		_render_character_to_atlas(atlas_image, font, font_size, char_string, pixel_x, pixel_y, char_width, char_height)
		
		# Calculate UV coordinates
		var u_min = float(grid_x) / float(CHARS_PER_ROW)
		var v_min = float(grid_y) / float(CHARS_PER_COL)
		var u_max = float(grid_x + 1) / float(CHARS_PER_ROW)
		var v_max = float(grid_y + 1) / float(CHARS_PER_COL)
		
		# Store UV coordinates
		var uv_index = i * 4
		character_uvs[uv_index + 0] = u_min
		character_uvs[uv_index + 1] = v_min
		character_uvs[uv_index + 2] = u_max
		character_uvs[uv_index + 3] = v_max
	
	# Create texture from image
	atlas_texture = ImageTexture.new()
	atlas_texture.set_image(atlas_image)
	
	print("FontAtlasGenerator: Atlas generated successfully (%dx%d characters)" % [CHARS_PER_ROW, CHARS_PER_COL])

func _render_character_to_atlas(atlas_image: Image, font: Font, font_size: int, char_string: String, x: int, y: int, width: int, height: int) -> void:
	"""Render a single character to the atlas at specified position"""
	
	# Create temporary image for character rendering
	var char_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	char_image.fill(Color(0, 0, 0, 0))
	
	# Get character metrics
	var char_size = font.get_string_size(char_string, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	
	# Center character in cell
	var char_x = (width - char_size.x) / 2.0
	var char_y = (height - char_size.y) / 2.0 + font.get_ascent(font_size)
	
	# Render character (we'll use a simple approach - create a texture and copy pixels)
	# Note: This is a simplified version - in practice you might want to use CanvasItem for better text rendering
	_draw_character_pixels(char_image, font, font_size, char_string, char_x, char_y)
	
	# Copy character image to atlas
	atlas_image.blit_rect(char_image, Rect2i(0, 0, width, height), Vector2i(x, y))

func _draw_character_pixels(image: Image, _font: Font, _font_size: int, char_string: String, x: int, y: int) -> void:
	"""Simple character rendering - creates recognizable character shapes"""
	
	# For now, use a simple approach that creates recognizable shapes for each character
	# This avoids the complexity of proper font rendering while still being functional
	
	var char_code = char_string.unicode_at(0)
	var pattern = _get_character_pattern(char_code)
	
	# Draw 8x8 pixel pattern
	var pattern_size = 8
	var start_x = x + (char_width - pattern_size) / 2.0
	var start_y = y + (char_height - pattern_size) / 2.0
	
	for py in range(pattern_size):
		for px in range(pattern_size):
			var bit_index = py * pattern_size + px
			if bit_index < pattern.size() and pattern[bit_index]:
				var pixel_x = start_x + px
				var pixel_y = start_y + py
				if pixel_x >= 0 and pixel_y >= 0 and pixel_x < image.get_width() and pixel_y < image.get_height():
					image.set_pixel(pixel_x, pixel_y, Color.WHITE)

func _get_character_pattern(char_code: int) -> Array:
	"""Get 8x8 bit pattern for character (simplified font)"""
	
	# Simple 8x8 patterns for common characters
	match char_code:
		32: # Space
			return [false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false]
		35: # #
			return [false,true,false,true,false,false,false,false,
					false,true,false,true,false,false,false,false,
					true,true,true,true,true,false,false,false,
					false,true,false,true,false,false,false,false,
					true,true,true,true,true,false,false,false,
					false,true,false,true,false,false,false,false,
					false,true,false,true,false,false,false,false,
					false,false,false,false,false,false,false,false]
		43: # +
			return [false,false,false,false,false,false,false,false,
					false,false,true,false,false,false,false,false,
					false,false,true,false,false,false,false,false,
					true,true,true,true,true,false,false,false,
					false,false,true,false,false,false,false,false,
					false,false,true,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false]
		77: # M
			return [true,false,false,false,true,false,false,false,
					true,true,false,true,true,false,false,false,
					true,false,true,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					false,false,false,false,false,false,false,false]
		89: # Y
			return [true,false,false,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					false,true,false,true,false,false,false,false,
					false,false,true,false,false,false,false,false,
					false,false,true,false,false,false,false,false,
					false,false,true,false,false,false,false,false,
					false,false,true,false,false,false,false,false,
					false,false,false,false,false,false,false,false]
		126: # ~
			return [false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,true,true,false,false,true,false,false,
					true,false,false,true,true,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false,
					false,false,false,false,false,false,false,false]
		_: # Default rectangle
			return [true,true,true,true,true,false,false,false,
					true,false,false,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					true,false,false,false,true,false,false,false,
					true,true,true,true,true,false,false,false,
					false,false,false,false,false,false,false,false]

func get_character_uv(char_code: int) -> Vector4:
	"""Get UV coordinates for a character (u_min, v_min, u_max, v_max)"""
	if char_code < FIRST_CHAR or char_code > LAST_CHAR:
		char_code = FIRST_CHAR  # Default to space
	
	var char_index = char_code - FIRST_CHAR
	var uv_index = char_index * 4
	
	return Vector4(
		character_uvs[uv_index + 0],  # u_min
		character_uvs[uv_index + 1],  # v_min
		character_uvs[uv_index + 2],  # u_max
		character_uvs[uv_index + 3]   # v_max
	)

func get_character_index(char_code: int) -> int:
	"""Get character index in atlas (0-94)"""
	if char_code < FIRST_CHAR or char_code > LAST_CHAR:
		return 0  # Default to space
	return char_code - FIRST_CHAR

func save_atlas_to_file(file_path: String) -> void:
	"""Save atlas texture to file for debugging"""
	if atlas_texture and atlas_texture.get_image():
		atlas_texture.get_image().save_png(file_path)
		print("FontAtlasGenerator: Atlas saved to %s" % file_path)

func get_atlas_texture() -> ImageTexture:
	"""Get the generated atlas texture"""
	return atlas_texture

func get_character_dimensions() -> Vector2i:
	"""Get character dimensions in pixels"""
	return Vector2i(char_width, char_height)

func get_uv_dimensions() -> Vector2:
	"""Get character UV dimensions"""
	return Vector2(char_uv_width, char_uv_height)
