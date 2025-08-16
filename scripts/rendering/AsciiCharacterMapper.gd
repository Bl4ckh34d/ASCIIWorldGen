# File: res://scripts/rendering/AsciiCharacterMapper.gd
class_name AsciiCharacterMapper
extends RefCounted

# Maps world data to ASCII characters for GPU rendering
# Ported from AsciiStyler.gd glyph selection logic

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

# Character constants (ASCII codes)
const CHAR_SPACE: int = 32       # " "
const CHAR_OCEAN: int = 8776     # "≈" (will map to closest ASCII)
const CHAR_ICE: int = 9617       # "░" 
const CHAR_DESERT: int = 58      # ":"
const CHAR_WASTELAND: int = 59   # ";"
const CHAR_GRASSLAND: int = 44   # ","
const CHAR_SAVANNA: int = 96     # "`"
const CHAR_STEPPE: int = 39      # "'"
const CHAR_SWAMP: int = 126      # "~"
const CHAR_FOREST: int = 89      # "Y"
const CHAR_RAINFOREST: int = 82  # "R"
const CHAR_HILLS: int = 43       # "+"
const CHAR_MOUNTAINS: int = 77   # "M"
const CHAR_ALPINE: int = 94      # "^"
const CHAR_BEACH: int = 46       # "."
const CHAR_DEFAULT: int = 35     # "#"

# Character variation tables for randomization
var tree_variants: PackedInt32Array = PackedInt32Array([89, 84, 35, 124])  # Y, T, #, |
var mountain_variants: PackedInt32Array = PackedInt32Array([77, 94, 35, 65])  # M, ^, #, A
var hill_variants: PackedInt32Array = PackedInt32Array([43, 126, 126, 61])  # +, ~, ~, =
var desert_variants: PackedInt32Array = PackedInt32Array([58, 46, 111, 46])  # :, ., o, .
var grass_variants: PackedInt32Array = PackedInt32Array([44, 39, 96, 46])  # ,, ', `, .

func get_character_index(x: int, y: int, is_land: bool, biome_id: int, is_beach: bool, rng_seed: int) -> int:
	"""Get character index (0-94) for atlas lookup"""
	
	if not is_land:
		return _ascii_to_atlas_index(CHAR_OCEAN)
	
	# Beach override
	if is_beach:
		return _ascii_to_atlas_index(CHAR_BEACH)
	
	# Get base character for biome
	var base_char = _get_base_character_for_biome(biome_id)
	
	# Add randomization for certain biomes
	var final_char = _apply_character_variation(base_char, biome_id, x, y, rng_seed)
	
	return _ascii_to_atlas_index(final_char)

func _get_base_character_for_biome(biome_id: int) -> int:
	"""Get base ASCII character for biome type"""
	match biome_id:
		BiomeClassifier.Biome.OCEAN:
			return CHAR_OCEAN
		BiomeClassifier.Biome.ICE_SHEET:
			return CHAR_ICE
		BiomeClassifier.Biome.DESERT_SAND:
			return CHAR_DESERT
		BiomeClassifier.Biome.WASTELAND:
			return CHAR_WASTELAND
		BiomeClassifier.Biome.GRASSLAND:
			return CHAR_GRASSLAND
		BiomeClassifier.Biome.SAVANNA:
			return CHAR_SAVANNA
		BiomeClassifier.Biome.STEPPE:
			return CHAR_STEPPE
		BiomeClassifier.Biome.SWAMP:
			return CHAR_SWAMP
		BiomeClassifier.Biome.TEMPERATE_FOREST, BiomeClassifier.Biome.BOREAL_FOREST:
			return CHAR_FOREST
		BiomeClassifier.Biome.RAINFOREST:
			return CHAR_RAINFOREST
		BiomeClassifier.Biome.HILLS:
			return CHAR_HILLS
		BiomeClassifier.Biome.MOUNTAINS:
			return CHAR_MOUNTAINS
		BiomeClassifier.Biome.ALPINE:
			return CHAR_ALPINE
		_:
			return CHAR_DEFAULT

func _apply_character_variation(base_char: int, biome_id: int, x: int, y: int, rng_seed: int) -> int:
	"""Apply character variations based on position and biome"""
	var glyph_hash = _hash2(x, y, rng_seed)
	
	match biome_id:
		BiomeClassifier.Biome.TEMPERATE_FOREST, BiomeClassifier.Biome.BOREAL_FOREST:
			return tree_variants[glyph_hash % tree_variants.size()]
		BiomeClassifier.Biome.MOUNTAINS:
			return mountain_variants[glyph_hash % mountain_variants.size()]
		BiomeClassifier.Biome.HILLS:
			return hill_variants[glyph_hash % hill_variants.size()]
		BiomeClassifier.Biome.DESERT_SAND:
			return desert_variants[glyph_hash % desert_variants.size()]
		BiomeClassifier.Biome.GRASSLAND:
			return grass_variants[glyph_hash % grass_variants.size()]
		_:
			return base_char

func _ascii_to_atlas_index(ascii_code: int) -> int:
	"""Convert ASCII code to atlas index (0-94)"""
	# Handle special characters that aren't in basic ASCII range
	if ascii_code == 8776:  # ≈ (ocean)
		return _ascii_to_atlas_index(126)  # Use ~ instead
	elif ascii_code == 9617:  # ░ (ice)
		return _ascii_to_atlas_index(35)   # Use # instead
	
	# Clamp to printable ASCII range (32-126)
	if ascii_code < 32:
		ascii_code = 32  # Space
	elif ascii_code > 126:
		ascii_code = 126  # Tilde
	
	return ascii_code - 32  # Convert to 0-94 range

func _hash2(x: int, y: int, rng_seed: int) -> int:
	"""Deterministic hash for character variation"""
	var h: int = rng_seed ^ (x * 374761393) ^ (y * 668265263)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return h & 0x7fffffff

# Utility functions for creating character index textures

func create_character_index_array(
	width: int, 
	height: int,
	is_land: PackedByteArray,
	biomes: PackedInt32Array,
	beach_mask: PackedByteArray,
	rng_seed: int
) -> PackedByteArray:
	"""Create array of character indices for entire map"""
	
	var result = PackedByteArray()
	result.resize(width * height)
	
	for y in range(height):
		for x in range(width):
			var i = x + y * width
			
			var land = is_land[i] if i < is_land.size() else 0
			var biome = biomes[i] if i < biomes.size() else 0
			var beach = beach_mask[i] if i < beach_mask.size() else 0
			
			var char_index = get_character_index(x, y, land == 1, biome, beach == 1, rng_seed)
			result[i] = char_index

	return result

func create_character_index_texture(
	width: int,
	height: int, 
	is_land: PackedByteArray,
	biomes: PackedInt32Array,
	beach_mask: PackedByteArray,
	rng_seed: int
) -> ImageTexture:
	"""Create texture containing character indices"""
	
	var char_indices = create_character_index_array(width, height, is_land, biomes, beach_mask, rng_seed)
	
	# Create image from character indices
	var image = Image.create(width, height, false, Image.FORMAT_R8)
	
	for y in range(height):
		for x in range(width):
			var i = x + y * width
			var char_index = char_indices[i]
			# Store character index in red channel
			image.set_pixel(x, y, Color(float(char_index) / 255.0, 0, 0, 1))
	
	# Create texture
	var texture = ImageTexture.new()
	texture.set_image(image)
	
	return texture