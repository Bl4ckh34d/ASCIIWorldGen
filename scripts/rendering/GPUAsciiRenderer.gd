# File: res://scripts/rendering/GPUAsciiRenderer.gd
class_name GPUAsciiRenderer
extends Control

# Integration layer for GPU-based ASCII rendering
# Replaces RichTextLabel-based rendering with high-performance GPU system

# Rendering components
var quad_renderer: Control
var is_gpu_rendering_enabled: bool = true
var fallback_label: RichTextLabel  # Fallback for compatibility

# Performance monitoring
var last_render_time_ms: float = 0.0
var frame_count: int = 0

# Removed unused signal gpu_rendering_failed

func _init():
	# Set up the control
	clip_contents = false
	mouse_filter = Control.MOUSE_FILTER_PASS

func initialize_gpu_rendering(font: Font, font_size: int, width: int, height: int) -> bool:
	"""Initialize GPU rendering system"""
	
	print("GPUAsciiRenderer: Initializing GPU rendering...")
	
	# Try to create GPU renderer
	if _create_gpu_renderer(font, font_size, width, height):
		print("GPUAsciiRenderer: GPU rendering enabled")
		is_gpu_rendering_enabled = true
		return true
	else:
		print("GPUAsciiRenderer: GPU rendering failed, falling back to RichTextLabel")
		_create_fallback_renderer()
		is_gpu_rendering_enabled = false
		return false

func _create_gpu_renderer(font: Font, font_size: int, width: int, height: int) -> bool:
	"""Create and initialize the GPU quad renderer"""
	
	# Load the AsciiQuadRenderer class dynamically to avoid circular dependencies
	var AsciiQuadRendererClass = load("res://scripts/rendering/AsciiQuadRenderer.gd")
	if not AsciiQuadRendererClass:
		print("GPUAsciiRenderer: Could not load AsciiQuadRenderer")
		return false
	
	quad_renderer = AsciiQuadRendererClass.new()
	if not quad_renderer:
		print("GPUAsciiRenderer: Could not create AsciiQuadRenderer instance")
		return false
	
	add_child(quad_renderer)
	
	# Initialize the renderer
	if not quad_renderer.has_method("initialize_rendering"):
		print("GPUAsciiRenderer: AsciiQuadRenderer missing initialize_rendering method")
		quad_renderer.queue_free()
		quad_renderer = null
		return false
	
	quad_renderer.initialize_rendering(font, font_size, width, height)
	
	# Set up viewport to fill this control and ensure it's behind overlays
	quad_renderer.size = size
	quad_renderer.anchors_preset = Control.PRESET_FULL_RECT
	quad_renderer.z_index = -1
	
	return true

func _create_fallback_renderer() -> void:
	"""Create fallback RichTextLabel renderer"""
	
	fallback_label = RichTextLabel.new()
	fallback_label.bbcode_enabled = true
	fallback_label.fit_content = false
	fallback_label.scroll_active = false
	fallback_label.anchors_preset = Control.PRESET_FULL_RECT
	add_child(fallback_label)

func update_ascii_display(
	_width: int,
	_height: int,
	height_data: PackedFloat32Array,
	temperature_data: PackedFloat32Array,
	moisture_data: PackedFloat32Array,
	light_data: PackedFloat32Array,
	biome_data: PackedInt32Array,
	is_land_data: PackedByteArray,
	beach_mask: PackedByteArray,
	rng_seed: int,
	fallback_ascii_string: String = ""
) -> void:
	"""Update the ASCII display using GPU or fallback rendering"""
	
	var start_time = Time.get_ticks_usec()
	
	if is_gpu_rendering_enabled and quad_renderer:
		# Use GPU rendering
		quad_renderer.update_world_data(
			height_data, temperature_data, moisture_data, light_data,
			biome_data, is_land_data, beach_mask, rng_seed
		)
		
	else:
		# Use fallback rendering
		if fallback_label and fallback_ascii_string.length() > 0:
			fallback_label.clear()
			fallback_label.append_text(fallback_ascii_string)
	
	# Update performance metrics
	var end_time = Time.get_ticks_usec()
	last_render_time_ms = float(end_time - start_time) / 1000.0
	frame_count += 1

func update_light_only(light_data: PackedFloat32Array) -> void:
	"""Fast update for just lighting data (day-night cycle)"""
	
	if is_gpu_rendering_enabled and quad_renderer:
		quad_renderer.update_light_data_only(light_data)

func resize_display(new_width: int, new_height: int) -> void:
	"""Resize the display for new map dimensions"""
	
	if is_gpu_rendering_enabled and quad_renderer:
		quad_renderer.resize_map(new_width, new_height)

func get_render_texture() -> Texture2D:
	"""Get the rendered texture (for GPU rendering)"""
	
	if is_gpu_rendering_enabled and quad_renderer:
		return quad_renderer.get_render_texture()
	
	return null

func is_using_gpu_rendering() -> bool:
	"""Check if GPU rendering is active"""
	return is_gpu_rendering_enabled

func get_performance_stats() -> Dictionary:
	"""Get rendering performance statistics"""
	
	var stats = {
		"gpu_rendering_enabled": is_gpu_rendering_enabled,
		"last_render_time_ms": last_render_time_ms,
		"frame_count": frame_count,
		"average_fps": 0.0
	}
	
	if is_gpu_rendering_enabled and quad_renderer:
		var gpu_stats = quad_renderer.get_performance_stats()
		stats.merge(gpu_stats)
	
	return stats

func force_fallback_rendering() -> void:
	"""Force switch to fallback rendering"""
	
	if is_gpu_rendering_enabled:
		print("GPUAsciiRenderer: Forcing fallback to RichTextLabel rendering")
		
		if quad_renderer:
			quad_renderer.queue_free()
			quad_renderer = null
		
		_create_fallback_renderer()
		is_gpu_rendering_enabled = false

func toggle_rendering_mode() -> void:
	"""Toggle between GPU and fallback rendering (for testing)"""
	
	if is_gpu_rendering_enabled:
		force_fallback_rendering()
	else:
		# Try to re-enable GPU rendering
		# Note: Would need to store initialization parameters
		print("GPUAsciiRenderer: Re-enabling GPU rendering not implemented")

func save_debug_data(prefix: String) -> void:
	"""Save debug data for troubleshooting"""
	
	if is_gpu_rendering_enabled and quad_renderer:
		quad_renderer.save_debug_image(prefix + "_gpu_render.png")
		
		# Save texture manager debug data
		if quad_renderer.texture_manager:
			quad_renderer.texture_manager.save_debug_textures(prefix)

func _on_resized() -> void:
	"""Handle control resize"""
	
	if quad_renderer:
		quad_renderer.size = size

func _ready() -> void:
	# Connect resize signal
	resized.connect(_on_resized)

# Mouse interaction support (for future features)

func _gui_input(event: InputEvent) -> void:
	"""Handle mouse input for map interaction"""
	
	if event is InputEventMouse:
		var mouse_pos = event.position
		var _world_pos = _screen_to_world(mouse_pos)
		
		# TODO: Implement mouse picking and interaction
		# This could be used for tile inspection, selection, etc.

func _screen_to_world(screen_pos: Vector2) -> Vector2:
	"""Convert screen coordinates to world coordinates"""
	
	if is_gpu_rendering_enabled and quad_renderer:
		return quad_renderer.screen_to_world(screen_pos)
	
	# Fallback calculation
	return Vector2.ZERO

# Cleanup

func _exit_tree() -> void:
	"""Clean up resources"""
	
	if quad_renderer:
		quad_renderer.queue_free()
		quad_renderer = null
	
	if fallback_label:
		fallback_label.queue_free()
		fallback_label = null
