# File: res://scripts/rendering/GPUAsciiRenderer.gd
extends Control
class_name GPUAsciiRenderer
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

# Integration layer for GPU-based ASCII rendering
# Replaces RichTextLabel-based rendering with high-performance GPU system
const Log = preload("res://scripts/systems/Logger.gd")

# Rendering components
var quad_renderer: Control
var is_gpu_rendering_enabled: bool = true

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
	if RenderingServer.get_rendering_device() == null:
		Log.event_kv(Log.LogLevel.ERROR, "render", "gpu_ascii_init", "rd_null")
		push_error("GPUAsciiRenderer: RenderingDevice unavailable (GPU-only mode).")
		is_gpu_rendering_enabled = false
		return false
	if font == null:
		Log.event_kv(Log.LogLevel.ERROR, "render", "gpu_ascii_init", "font_null")
		push_error("GPUAsciiRenderer: missing font for initialization.")
		is_gpu_rendering_enabled = false
		return false
	if width <= 0 or height <= 0:
		Log.event_kv(Log.LogLevel.ERROR, "render", "gpu_ascii_init", "invalid_size", -1, -1.0, {"w": width, "h": height})
		push_error("GPUAsciiRenderer: invalid map dimensions (%d x %d)." % [width, height])
		is_gpu_rendering_enabled = false
		return false
	if quad_renderer != null and is_instance_valid(quad_renderer):
		quad_renderer.queue_free()
		quad_renderer = null

	# Try to create GPU renderer
	if _create_gpu_renderer(font, font_size, width, height):
		Log.event_kv(Log.LogLevel.INFO, "render", "gpu_ascii_init", "ok", -1, -1.0, {"w": width, "h": height, "font_size": font_size})
		is_gpu_rendering_enabled = true
		return true
	else:
		Log.event_kv(Log.LogLevel.ERROR, "render", "gpu_ascii_init", "create_failed", -1, -1.0, {"w": width, "h": height, "font_size": font_size})
		push_error("GPU ASCII renderer initialization failed; CPU fallback renderer is disabled.")
		is_gpu_rendering_enabled = false
		return false

func _create_gpu_renderer(font: Font, font_size: int, width: int, height: int) -> bool:
	"""Create and initialize the GPU quad renderer"""
	
	# Load the AsciiQuadRenderer class dynamically to avoid circular dependencies
	var AsciiQuadRendererClass = load("res://scripts/rendering/AsciiQuadRenderer.gd")
	if not AsciiQuadRendererClass:
		return false
	
	quad_renderer = AsciiQuadRendererClass.new()
	if not quad_renderer:
		return false
	
	add_child(quad_renderer)
	
	# Initialize the renderer
	if not quad_renderer.has_method("initialize_rendering"):
		quad_renderer.queue_free()
		quad_renderer = null
		return false
	quad_renderer.call("initialize_rendering", font, font_size, width, height)
	if "is_initialized" in quad_renderer and not VariantCastsUtil.to_bool(quad_renderer.is_initialized):
		quad_renderer.queue_free()
		quad_renderer = null
		return false
	
	# Set up viewport to fill this control and ensure it's behind overlays
	quad_renderer.z_index = 0
	
	return true

func update_ascii_display(
	_width: int,
	_height: int,
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
	_fallback_ascii_string: String = "",
	skip_base_textures: bool = false,
	skip_aux_textures: bool = false
) -> void:
	"""Update the ASCII display using GPU rendering."""
	
	var start_time = Time.get_ticks_usec()
	
	if is_gpu_rendering_enabled and quad_renderer:
		if quad_renderer.map_width != _width or quad_renderer.map_height != _height:
			quad_renderer.resize_map(_width, _height)
		# Use GPU rendering
		quad_renderer.update_world_data(
			height_data, temperature_data, moisture_data, light_data,
			biome_data, rock_data, is_land_data, beach_mask, rng_seed, use_bedrock_view,
			turquoise_strength, shelf_noise, clouds, plate_boundary_mask,
			lake_mask, river_mask, lava_mask, pooled_lake_mask, lake_id, sea_level,
			skip_base_textures, skip_aux_textures
		)
		
	# Update performance metrics
	var end_time = Time.get_ticks_usec()
	last_render_time_ms = float(end_time - start_time) / 1000.0
	frame_count += 1

func update_light_only(light_data: PackedFloat32Array) -> void:
	"""Fast update for just lighting data (day-night cycle)"""
	
	if is_gpu_rendering_enabled and quad_renderer:
		quad_renderer.update_light_data_only(light_data)

func update_clouds_only(
	turquoise_strength: PackedFloat32Array,
	shelf_noise: PackedFloat32Array,
	clouds: PackedFloat32Array,
	plate_boundary_mask: PackedByteArray
) -> void:
	"""Fast update for just clouds/shelf/turquoise data."""
	if is_gpu_rendering_enabled and quad_renderer:
		quad_renderer.update_clouds_only(turquoise_strength, shelf_noise, clouds, plate_boundary_mask)

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

func is_ready() -> bool:
	"""Heuristic: returns true when GPU renderer has all required resources."""
	if not is_gpu_rendering_enabled or quad_renderer == null:
		return false
	if "is_initialized" in quad_renderer and not quad_renderer.is_initialized:
		return false
	# Ensure textures exist
	if quad_renderer and "texture_manager" in quad_renderer:
		if quad_renderer.texture_manager == null:
			return false
		if quad_renderer.texture_manager.get_data_texture_1() == null:
			return false
		if quad_renderer.texture_manager.get_data_texture_2() == null:
			return false
		if quad_renderer.texture_manager.get_data_texture_3() == null:
			return false
		if quad_renderer.texture_manager.get_data_texture_4() == null:
			return false
		if quad_renderer.texture_manager.get_color_palette_texture() == null:
			return false
	return true

func set_hover_cell(x: int, y: int) -> void:
	"""Forward hovered tile coordinate to the GPU shader."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_hover_cell"):
		quad_renderer.set_hover_cell(x, y)

func clear_hover_cell() -> void:
	"""Disable hover overlay in the GPU shader."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("clear_hover_cell"):
		quad_renderer.clear_hover_cell()

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

func get_cell_size() -> Vector2:
	"""Expose current cell size in pixels when GPU renderer is active."""
	if quad_renderer:
		return quad_renderer.cell_size
	return Vector2.ZERO

func get_map_dimensions() -> Vector2i:
	"""Expose current map dimensions (tiles)."""
	if quad_renderer:
		return Vector2i(quad_renderer.map_width, quad_renderer.map_height)
	return Vector2i.ZERO

func get_cell_size_screen() -> Vector2:
	"""Return the on-screen cell size (in pixels), accounting for any scaling.
	This uses this control's current size divided by the map tile dimensions.
	"""
	if quad_renderer and quad_renderer.map_width > 0 and quad_renderer.map_height > 0:
		return Vector2(
			float(size.x) / float(quad_renderer.map_width),
			float(size.y) / float(quad_renderer.map_height)
		)
	return Vector2.ZERO

func set_cloud_texture_override(tex: Texture2D) -> void:
	"""Provide a GPU-updated cloud texture (Texture2DRD) to the renderer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_cloud_texture_override"):
		quad_renderer.set_cloud_texture_override(tex)

func set_cloud_overlay_enabled(enabled: bool) -> void:
	"""Enable/disable the separate white cloud overlay layer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_cloud_overlay_enabled"):
		quad_renderer.set_cloud_overlay_enabled(enabled)

func set_cloud_rendering_params(shadow_strength: float, light_strength: float, shadow_offset: Vector2) -> void:
	"""Configure cloud shadow/light contribution in the terrain shader."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_cloud_rendering_params"):
		quad_renderer.set_cloud_rendering_params(shadow_strength, light_strength, shadow_offset)

func set_noise_world_origin(origin_x: float, origin_y: float) -> void:
	"""Set world-space cell origin used by shader noise hashing."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_noise_world_origin"):
		quad_renderer.set_noise_world_origin(origin_x, origin_y)

func set_light_texture_override(tex: Texture2D) -> void:
	"""Provide a GPU-updated light texture (Texture2DRD) to the renderer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_light_texture_override"):
		quad_renderer.set_light_texture_override(tex)

func set_solar_params(day_of_year: float, time_of_day: float) -> void:
	"""Provide solar cycle params for sun-angle-aware cloud shadows."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_solar_params"):
		quad_renderer.set_solar_params(day_of_year, time_of_day)

func set_fixed_lonlat(enabled: bool, lon_rad: float, phi_rad: float) -> void:
	"""Override lon/lat mapping for solar geometry (regional/local map views)."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_fixed_lonlat"):
		quad_renderer.set_fixed_lonlat(enabled, lon_rad, phi_rad)

func set_display_window(display_w: int, display_h: int, origin_x: float = 0.0, origin_y: float = 0.0) -> void:
	"""Display only a sub-rectangle of the data textures (for padded views)."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_display_window"):
		quad_renderer.set_display_window(display_w, display_h, origin_x, origin_y)

func set_scroll_offset_cells(offset_x: float, offset_y: float) -> void:
	"""Smooth camera scroll (fractional cell offset)."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_scroll_offset"):
		quad_renderer.set_scroll_offset(offset_x, offset_y)

func set_river_texture_override(tex: Texture2D) -> void:
	"""Provide a GPU-updated river texture (Texture2DRD) to the renderer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_river_texture_override"):
		quad_renderer.set_river_texture_override(tex)

func set_biome_texture_override(tex: Texture2D) -> void:
	"""Provide a GPU-updated biome texture (Texture2DRD) to the renderer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_biome_texture_override"):
		quad_renderer.set_biome_texture_override(tex)

func set_lava_texture_override(tex: Texture2D) -> void:
	"""Provide a GPU-updated lava texture (Texture2DRD) to the renderer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_lava_texture_override"):
		quad_renderer.set_lava_texture_override(tex)

func set_society_overlay_texture_override(tex: Texture2D) -> void:
	"""Provide a GPU-packed society overlay texture (human/wildlife) to the renderer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_society_overlay_texture_override"):
		quad_renderer.set_society_overlay_texture_override(tex)

func set_world_data_1_override(tex: Texture2D) -> void:
	"""Provide a GPU-packed world_data_1 texture to the renderer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_world_data_1_override"):
		quad_renderer.set_world_data_1_override(tex)

func set_world_data_2_override(tex: Texture2D) -> void:
	"""Provide a GPU-packed world_data_2 texture to the renderer."""
	if is_gpu_rendering_enabled and quad_renderer and quad_renderer.has_method("set_world_data_2_override"):
		quad_renderer.set_world_data_2_override(tex)

func force_fallback_rendering() -> void:
	"""GPU-only mode: explicit fallback switching is disabled."""
	push_warning("force_fallback_rendering() ignored: CPU fallback renderer is disabled.")

func toggle_rendering_mode() -> void:
	"""GPU-only mode: keep GPU path active."""
	push_warning("toggle_rendering_mode() ignored: CPU fallback renderer is disabled.")

func save_debug_data(prefix: String) -> void:
	"""Save debug data for troubleshooting"""
	
	if is_gpu_rendering_enabled and quad_renderer:
		quad_renderer.save_debug_image(prefix + "_gpu_render.png")
		
		# Save texture manager debug data
		if quad_renderer.texture_manager:
			quad_renderer.texture_manager.save_debug_textures(prefix)

func _on_resized() -> void:
	"""Handle control resize"""
	
	if quad_renderer and size.x > 0.0 and size.y > 0.0:
		# Full-rect anchors already drive sizing; forcing size here causes anchor warnings.
		quad_renderer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

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

func cleanup_renderer_resources() -> void:
	if quad_renderer != null and is_instance_valid(quad_renderer):
		if quad_renderer.has_method("cleanup"):
			quad_renderer.call("cleanup")
		quad_renderer.free()
	quad_renderer = null

func _exit_tree() -> void:
	"""Clean up resources"""
	cleanup_renderer_resources()
