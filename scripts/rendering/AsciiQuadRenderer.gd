# File: res://scripts/rendering/AsciiQuadRenderer.gd
class_name AsciiQuadRenderer
extends Control

# GPU-instanced quad renderer for ASCII map
# Replaces RichTextLabel with high-performance GPU rendering

# Load classes dynamically to avoid circular dependencies

# Rendering components
var viewport: SubViewport
var mesh_instance: MeshInstance2D
var quad_material: Material
var quad_mesh: QuadMesh
var display_rect: TextureRect

# Data managers
var font_atlas_generator: Object
var texture_manager: Object

# Map dimensions
var map_width: int = 0
var map_height: int = 0
var cell_size: Vector2 = Vector2(8.0, 12.0)  # Character cell size in pixels

# Rendering state
var is_initialized: bool = false
var needs_mesh_update: bool = false

# Removed unused signal rendering_complete

func _init():
	# Create and configure viewport
	viewport = SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	# Present the SubViewport via a TextureRect so it is visible in the scene
	display_rect = TextureRect.new()
	display_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	display_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(display_rect)
	
	# Create data managers
	var WorldDataTextureManagerClass = load("res://scripts/rendering/WorldDataTextureManager.gd")
	texture_manager = WorldDataTextureManagerClass.new()

func initialize_rendering(font: Font, font_size: int, width: int, height: int) -> void:
	"""Initialize the ASCII rendering system"""
	print("AsciiQuadRenderer: Initializing (%dx%d)" % [width, height])
	
	map_width = width
	map_height = height
	
	# Generate font atlas
	var FontAtlasGeneratorClass = load("res://scripts/rendering/FontAtlasGenerator.gd")
	font_atlas_generator = FontAtlasGeneratorClass.generate_ascii_atlas(font, font_size)
	
	# Update viewport size
	var viewport_width = width * cell_size.x
	var viewport_height = height * cell_size.y
	viewport.size = Vector2i(int(viewport_width), int(viewport_height))
	size = Vector2(viewport_width, viewport_height)
	
	# Create rendering components
	_create_quad_mesh()
	_create_material()
	_create_mesh_instance()
	
	is_initialized = true
	needs_mesh_update = true
	
	# Bind the viewport texture for display
	display_rect.texture = viewport.get_texture()
	
	print("AsciiQuadRenderer: Initialized successfully")

func _create_quad_mesh() -> void:
	"""Create the base quad mesh"""
	quad_mesh = QuadMesh.new()
	quad_mesh.size = cell_size

func _create_material() -> void:
	"""Create shader material for ASCII rendering"""
	# Try to load the ASCII rendering shader
	var shader = load("res://shaders/rendering/ascii_quad_render.gdshader")
	
	if shader:
		quad_material = ShaderMaterial.new()
		quad_material.shader = shader
		
		# Set up shader parameters
		if font_atlas_generator and "get_atlas_texture" in font_atlas_generator:
			var atlas_tex = font_atlas_generator.get_atlas_texture()
			if atlas_tex:
				quad_material.set_shader_parameter("font_atlas", atlas_tex)
		
		quad_material.set_shader_parameter("map_dimensions", Vector2(map_width, map_height))
		quad_material.set_shader_parameter("cell_size", cell_size)
		quad_material.set_shader_parameter("atlas_uv_size", Vector2(1.0/16.0, 1.0/6.0))

		# Provide safe default textures to avoid null uniforms before first update
		var black_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		black_img.fill(Color(0, 0, 0, 1))
		var white_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		white_img.fill(Color(1, 1, 1, 1))
		var tex_black := ImageTexture.new(); tex_black.set_image(black_img)
		var tex_white := ImageTexture.new(); tex_white.set_image(white_img)
		quad_material.set_shader_parameter("world_data_1", tex_black)
		quad_material.set_shader_parameter("world_data_2", tex_black)
		quad_material.set_shader_parameter("color_palette", tex_white)
		
		print("AsciiQuadRenderer: Using GPU shader material")
	else:
		# Fallback to simple material
		quad_material = CanvasItemMaterial.new()
		print("AsciiQuadRenderer: Using fallback material (shader not found)")

func _create_mesh_instance() -> void:
	"""Create mesh instance for rendering"""
	mesh_instance = MeshInstance2D.new()
	mesh_instance.mesh = quad_mesh
	mesh_instance.material = quad_material
	viewport.add_child(mesh_instance)

func update_world_data(
	height_data: PackedFloat32Array,
	temperature_data: PackedFloat32Array,
	moisture_data: PackedFloat32Array,
	light_data: PackedFloat32Array,
	biome_data: PackedInt32Array,
	is_land_data: PackedByteArray,
	beach_mask: PackedByteArray,
	rng_seed: int
) -> void:
	"""Update world data for rendering"""
	
	if not is_initialized:
		print("AsciiQuadRenderer: Not initialized, cannot update world data")
		return
	
	# Update texture manager
	texture_manager.update_world_data(
		map_width, map_height,
		height_data, temperature_data, moisture_data, light_data,
		biome_data, is_land_data, beach_mask, rng_seed
	)
	
	# Update material uniforms
	_update_material_uniforms()

func update_light_data_only(light_data: PackedFloat32Array) -> void:
	"""Fast update for just lighting (day-night cycle)"""
	if not is_initialized:
		return
	
	texture_manager.update_light_data_only(light_data)
	_update_light_uniform()

func _update_material_uniforms() -> void:
	"""Update shader uniforms with current textures"""
	if not quad_material or not font_atlas_generator:
		return
	
	# Only set shader parameters if using ShaderMaterial
	if quad_material is ShaderMaterial:
		var shader_mat = quad_material as ShaderMaterial
		
		# Set font atlas (guard null)
		var atlas_tex2 = font_atlas_generator.get_atlas_texture()
		if atlas_tex2:
			shader_mat.set_shader_parameter("font_atlas", atlas_tex2)
		
		# Set world data textures
		var t1 = texture_manager.get_data_texture_1()
		var t2 = texture_manager.get_data_texture_2()
		var pal = texture_manager.get_color_palette_texture()
		if t1:
			shader_mat.set_shader_parameter("world_data_1", t1)
		if t2:
			shader_mat.set_shader_parameter("world_data_2", t2)
		if pal:
			shader_mat.set_shader_parameter("color_palette", pal)
		
		# Set map dimensions
		shader_mat.set_shader_parameter("map_dimensions", Vector2(map_width, map_height))
		shader_mat.set_shader_parameter("cell_size", cell_size)
		
		# Set atlas parameters
		var atlas_uv_size = font_atlas_generator.get_uv_dimensions()
		shader_mat.set_shader_parameter("atlas_uv_size", atlas_uv_size)
	else:
		print("AsciiQuadRenderer: Using fallback material - shader parameters not available")

func _update_light_uniform() -> void:
	"""Update only the light texture uniform"""
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat = quad_material as ShaderMaterial
		shader_mat.set_shader_parameter("world_data_1", texture_manager.get_data_texture_1())

func _ready() -> void:
	if needs_mesh_update:
		_setup_instanced_rendering()

func _setup_instanced_rendering() -> void:
	"""Setup GPU instancing for rendering all map cells"""
	if not is_initialized:
		return
	
	# For now, we'll use a simpler approach with a large quad
	# In the future, this could be optimized with actual GPU instancing
	
	# Scale the quad to cover the entire map
	var scale_x = float(map_width)
	var scale_y = float(map_height)
	mesh_instance.scale = Vector2(scale_x, scale_y)
	
	# Center the quad
	mesh_instance.position = Vector2(map_width * cell_size.x * 0.5, map_height * cell_size.y * 0.5)
	
	needs_mesh_update = false

func get_render_texture() -> ViewportTexture:
	"""Get the rendered texture for display"""
	return viewport.get_texture()

func save_debug_image(file_path: String) -> void:
	"""Save rendered image for debugging"""
	var image = viewport.get_texture().get_image()
	if image:
		image.save_png(file_path)
		print("AsciiQuadRenderer: Debug image saved to %s" % file_path)

func get_memory_usage_mb() -> float:
	"""Get estimated memory usage"""
	var usage = 0.0
	
	# Viewport texture
	if viewport:
		usage += viewport.size.x * viewport.size.y * 4  # RGBA8 = 4 bytes per pixel
	
	# Add texture manager usage
	if texture_manager:
		usage += texture_manager.get_memory_usage_mb() * 1024.0 * 1024.0
	
	# Font atlas
	if font_atlas_generator:
		usage += 512 * 512 * 4  # RGBA8 atlas
	
	return usage / (1024.0 * 1024.0)

func resize_map(new_width: int, new_height: int) -> void:
	"""Resize the map and update rendering"""
	if new_width == map_width and new_height == map_height:
		return
	
	map_width = new_width
	map_height = new_height
	
	# Update viewport size
	var viewport_width = new_width * cell_size.x
	var viewport_height = new_height * cell_size.y
	if viewport:
		viewport.size = Vector2i(int(viewport_width), int(viewport_height))
	size = Vector2(viewport_width, viewport_height)
	
	# Update material uniforms
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat = quad_material as ShaderMaterial
		shader_mat.set_shader_parameter("map_dimensions", Vector2(map_width, map_height))
	
	needs_mesh_update = true

# Camera control functions (for future implementation)

func set_camera_position(_pos: Vector2) -> void:
	"""Set camera position for panning"""
	# TODO: Implement camera controls
	pass

func set_camera_zoom(_zoom: float) -> void:
	"""Set camera zoom level"""
	# TODO: Implement zoom controls
	pass

func world_to_screen(world_pos: Vector2) -> Vector2:
	"""Convert world coordinates to screen coordinates"""
	return world_pos * cell_size

func screen_to_world(screen_pos: Vector2) -> Vector2:
	"""Convert screen coordinates to world coordinates"""
	return screen_pos / cell_size

# Performance monitoring

func get_performance_stats() -> Dictionary:
	"""Get rendering performance statistics"""
	return {
		"memory_usage_mb": get_memory_usage_mb(),
		"map_dimensions": Vector2(map_width, map_height),
		"total_cells": map_width * map_height,
		"viewport_size": viewport.size if viewport else Vector2i.ZERO,
		"is_initialized": is_initialized
	}
