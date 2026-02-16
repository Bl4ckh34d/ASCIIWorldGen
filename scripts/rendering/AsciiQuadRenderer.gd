# File: res://scripts/rendering/AsciiQuadRenderer.gd
extends Control
class_name AsciiQuadRenderer
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

# GPU-instanced quad renderer for ASCII map
# Replaces RichTextLabel with high-performance GPU rendering

# Load classes dynamically to avoid circular dependencies

# Rendering components
var viewport: SubViewport
var mesh_instance: MeshInstance2D
var quad_material: Material
var quad_mesh: QuadMesh
var display_rect: ColorRect
var cloud_rect: ColorRect
var cloud_material: Material
var cloud_texture_override: Texture2D
var light_texture_override: Texture2D
var river_texture_override: Texture2D
var biome_texture_override: Texture2D
var lava_texture_override: Texture2D
var society_overlay_texture_override: Texture2D
var world_data_1_override: Texture2D
var world_data_2_override: Texture2D
var _fallback_black_tex: Texture2D
var _fallback_white_tex: Texture2D
var _render_bedrock_view: bool = false
var _solar_day_of_year: float = 0.0
var _solar_time_of_day: float = 0.0
var _use_fixed_lonlat: bool = false
var _fixed_lon: float = 0.0
var _fixed_phi: float = 0.0
var _display_dimensions: Vector2 = Vector2.ZERO
var _display_origin: Vector2 = Vector2.ZERO
var _scroll_offset: Vector2 = Vector2.ZERO
var _display_window_explicit: bool = false

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
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	add_child(viewport)
	# Present the output via a ColorRect (shader-driven)
	display_rect = ColorRect.new()
	display_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	display_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display_rect.color = Color(1, 1, 1, 1)
	add_child(display_rect)
	# Cloud overlay (separate tile layer)
	cloud_rect = ColorRect.new()
	cloud_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cloud_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cloud_rect.color = Color(1, 1, 1, 1)
	cloud_rect.z_index = 50
	add_child(cloud_rect)
	
	# Create data managers
	var WorldDataTextureManagerClass = load("res://scripts/rendering/WorldDataTextureManager.gd")
	texture_manager = WorldDataTextureManagerClass.new()

func initialize_rendering(font: Font, font_size: int, width: int, height: int) -> void:
	"""Initialize the ASCII rendering system"""
	# debug removed
	
	map_width = width
	map_height = height
	_display_dimensions = Vector2(float(map_width), float(map_height))
	_display_origin = Vector2.ZERO
	_scroll_offset = Vector2.ZERO
	_display_window_explicit = false
	
	# Generate font atlas
	var FontAtlasGeneratorClass = load("res://scripts/rendering/FontAtlasGenerator.gd")
	font_atlas_generator = FontAtlasGeneratorClass.generate_ascii_atlas(font, font_size)
	
	# Update viewport size
	var viewport_width = width * cell_size.x
	var viewport_height = height * cell_size.y
	viewport.size = Vector2i(int(viewport_width), int(viewport_height))
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	# Create rendering components
	_create_quad_mesh()
	_create_material()
	_create_mesh_instance()
	
	is_initialized = true
	needs_mesh_update = true
	
	# display_rect is shader-driven; no texture binding needed
	
	# debug removed

func _create_quad_mesh() -> void:
	"""Create the base quad mesh"""
	quad_mesh = QuadMesh.new()
	quad_mesh.size = cell_size

func _build_solid_texture(color: Color) -> Texture2D:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(color)
	var tex := ImageTexture.new()
	tex.set_image(img)
	return tex

func _ensure_fallback_textures() -> void:
	if _fallback_black_tex == null:
		_fallback_black_tex = _build_solid_texture(Color(0, 0, 0, 1))
	if _fallback_white_tex == null:
		_fallback_white_tex = _build_solid_texture(Color(1, 1, 1, 1))

func _is_texture_bindable(tex: Texture2D) -> bool:
	if tex == null or not is_instance_valid(tex):
		return false
	# Texture2DRD wrappers can stay object-valid while their internal RID is invalid.
	if tex is Texture2DRD:
		if tex.has_method("get_texture_rd_rid"):
			var rid_v: Variant = tex.call("get_texture_rd_rid")
			if rid_v is RID:
				return (rid_v as RID).is_valid()
			return false
		if tex.has_method("get_texture_rd"):
			var rid_v2: Variant = tex.call("get_texture_rd")
			if rid_v2 is RID:
				return (rid_v2 as RID).is_valid()
			return false
	return true

func _safe_tex(tex: Texture2D, fallback: Texture2D) -> Texture2D:
	if _is_texture_bindable(tex):
		return tex
	return fallback

func _create_material() -> void:
	"""Create shader material for ASCII rendering"""
	# Try to load the ASCII rendering shader
	var shader = load("res://shaders/rendering/ascii_quad_render.gdshader")
	var cloud_shader = load("res://shaders/rendering/cloud_overlay.gdshader")
	_ensure_fallback_textures()
	
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
		quad_material.set_shader_parameter("display_dimensions", _display_dimensions)
		quad_material.set_shader_parameter("display_origin", _display_origin)
		quad_material.set_shader_parameter("scroll_offset", _scroll_offset)
		quad_material.set_shader_parameter("sea_level", 0.0)
		quad_material.set_shader_parameter("cloud_shadow_strength", 0.14)
		quad_material.set_shader_parameter("cloud_light_strength", 0.25)
		quad_material.set_shader_parameter("cloud_shadow_offset", Vector2(1.5, 1.0))
		quad_material.set_shader_parameter("day_of_year", _solar_day_of_year)
		quad_material.set_shader_parameter("time_of_day", _solar_time_of_day)
		quad_material.set_shader_parameter("use_fixed_lonlat", 0)
		quad_material.set_shader_parameter("fixed_lon", 0.0)
		quad_material.set_shader_parameter("fixed_phi", 0.0)
		quad_material.set_shader_parameter("use_glyphs", 0)
		quad_material.set_shader_parameter("bedrock_only_mode", 0)
		quad_material.set_shader_parameter("use_cloud_texture", 0)
		quad_material.set_shader_parameter("use_light_texture", 0)
		quad_material.set_shader_parameter("use_river_texture", 0)
		quad_material.set_shader_parameter("use_biome_texture", 0)
		quad_material.set_shader_parameter("use_lava_texture", 0)
		quad_material.set_shader_parameter("use_society_overlay", 0)

		# Provide safe default textures to avoid null sampler bindings.
		quad_material.set_shader_parameter("world_data_1", _fallback_black_tex)
		quad_material.set_shader_parameter("world_data_2", _fallback_black_tex)
		quad_material.set_shader_parameter("world_data_3", _fallback_black_tex)
		quad_material.set_shader_parameter("world_data_4", _fallback_black_tex)
		quad_material.set_shader_parameter("color_palette", _fallback_white_tex)
		quad_material.set_shader_parameter("cloud_texture", _fallback_black_tex)
		quad_material.set_shader_parameter("light_texture", _fallback_black_tex)
		quad_material.set_shader_parameter("river_texture", _fallback_black_tex)
		quad_material.set_shader_parameter("biome_texture", _fallback_black_tex)
		quad_material.set_shader_parameter("lava_texture", _fallback_black_tex)
		quad_material.set_shader_parameter("society_overlay", _fallback_black_tex)
		
		# Render directly on the display rect to avoid SubViewport black-screen issues
		if display_rect:
			display_rect.material = quad_material
			# Default to normal rendering
			if quad_material is ShaderMaterial:
				var shader_mat = quad_material as ShaderMaterial
				shader_mat.set_shader_parameter("debug_mode", 0)
		# Cloud overlay material
		if cloud_shader:
			cloud_material = ShaderMaterial.new()
			cloud_material.shader = cloud_shader
			if cloud_rect:
				cloud_rect.material = cloud_material
				cloud_rect.visible = true
			# Default uniforms to safe textures
			if cloud_material is ShaderMaterial:
				var cloud_mat := cloud_material as ShaderMaterial
				cloud_mat.set_shader_parameter("world_data_1", _fallback_black_tex)
				cloud_mat.set_shader_parameter("world_data_3", _fallback_black_tex)
				cloud_mat.set_shader_parameter("map_dimensions", Vector2(map_width, map_height))
				cloud_mat.set_shader_parameter("display_dimensions", _display_dimensions)
				cloud_mat.set_shader_parameter("display_origin", _display_origin)
				cloud_mat.set_shader_parameter("scroll_offset", _scroll_offset)
				cloud_mat.set_shader_parameter("cloud_opacity", 0.95)
				cloud_mat.set_shader_parameter("cloud_min", 0.18)
				cloud_mat.set_shader_parameter("cloud_levels", 10.0)
				cloud_mat.set_shader_parameter("cloud_power", 0.95)
				cloud_mat.set_shader_parameter("cloud_brightness", 1.0)
				cloud_mat.set_shader_parameter("cloud_night_alpha", 0.28)
				cloud_mat.set_shader_parameter("day_of_year", _solar_day_of_year)
				cloud_mat.set_shader_parameter("time_of_day", _solar_time_of_day)
				cloud_mat.set_shader_parameter("use_fixed_lonlat", 0)
				cloud_mat.set_shader_parameter("fixed_lon", 0.0)
				cloud_mat.set_shader_parameter("fixed_phi", 0.0)
				cloud_mat.set_shader_parameter("cloud_texture", _fallback_black_tex)
				cloud_mat.set_shader_parameter("light_texture", _fallback_black_tex)
				cloud_mat.set_shader_parameter("use_cloud_texture", 0)
				cloud_mat.set_shader_parameter("use_light_texture", 0)
		else:
			if cloud_rect:
				cloud_rect.visible = false
		
		pass
	else:
		# Fallback to simple material
		quad_material = CanvasItemMaterial.new()
		# debug removed

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
	"""Update world data for rendering"""
	
	if not is_initialized:
		# debug removed
		return
	
	# Always call into texture_manager so lightweight resources (notably the color
	# palette texture) stay valid in GPU-only mode when base/aux texture packing is skipped.
	_render_bedrock_view = use_bedrock_view
	texture_manager.update_world_data(
		map_width, map_height,
		height_data, temperature_data, moisture_data, light_data,
		biome_data, rock_data, is_land_data, beach_mask, rng_seed, use_bedrock_view,
		turquoise_strength, shelf_noise, clouds, plate_boundary_mask,
		lake_mask, river_mask, lava_mask, pooled_lake_mask, lake_id, sea_level,
		skip_base_textures, skip_aux_textures
	)
	
	# Update material uniforms
	_update_material_uniforms()
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat2 = quad_material as ShaderMaterial
		shader_mat2.set_shader_parameter("sea_level", sea_level)
	# Disable debug gradient once real data is bound
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat = quad_material as ShaderMaterial
		shader_mat.set_shader_parameter("debug_mode", 0)

func update_light_data_only(_light_data: PackedFloat32Array) -> void:
	"""Fast update for just lighting (day-night cycle)"""
	if not is_initialized:
		return
	_update_light_uniform()

func update_clouds_only(
	_turquoise_strength: PackedFloat32Array,
	_shelf_noise: PackedFloat32Array,
	_clouds: PackedFloat32Array,
	_plate_boundary_mask: PackedByteArray
) -> void:
	"""Fast update for just clouds/shelf/turquoise data (texture 3)."""
	if not is_initialized:
		return
	_update_cloud_uniforms()

func set_hover_cell(x: int, y: int) -> void:
	"""Set the hovered tile coordinate for overlay rendering on the shader."""
	if not quad_material or not (quad_material is ShaderMaterial):
		return
	var shader_mat = quad_material as ShaderMaterial
	shader_mat.set_shader_parameter("hover_cell", Vector2(float(x), float(y)))

func clear_hover_cell() -> void:
	"""Disable hover overlay."""
	if not quad_material or not (quad_material is ShaderMaterial):
		return
	var shader_mat = quad_material as ShaderMaterial
	shader_mat.set_shader_parameter("hover_cell", Vector2(-1.0, -1.0))

func _update_material_uniforms() -> void:
	"""Update shader uniforms with current textures"""
	if not quad_material or not font_atlas_generator:
		return
	_ensure_fallback_textures()
	
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
		var t3 = texture_manager.get_data_texture_3()
		var t4 = texture_manager.get_data_texture_4()
		var pal = texture_manager.get_color_palette_texture()
		var tex_w1: Texture2D = _safe_tex(world_data_1_override, _safe_tex(t1, _fallback_black_tex))
		var tex_w2: Texture2D = _safe_tex(world_data_2_override, _safe_tex(t2, _fallback_black_tex))
		var tex_w3: Texture2D = _safe_tex(t3, _fallback_black_tex)
		var tex_w4: Texture2D = _safe_tex(t4, _fallback_black_tex)
		var tex_pal: Texture2D = _safe_tex(pal, _fallback_white_tex)
		shader_mat.set_shader_parameter("world_data_1", tex_w1)
		shader_mat.set_shader_parameter("world_data_2", tex_w2)
		shader_mat.set_shader_parameter("world_data_3", tex_w3)
		shader_mat.set_shader_parameter("world_data_4", tex_w4)
		shader_mat.set_shader_parameter("color_palette", tex_pal)
		
		# Set map dimensions
		shader_mat.set_shader_parameter("map_dimensions", Vector2(map_width, map_height))
		shader_mat.set_shader_parameter("display_dimensions", _display_dimensions)
		shader_mat.set_shader_parameter("display_origin", _display_origin)
		shader_mat.set_shader_parameter("scroll_offset", _scroll_offset)
		shader_mat.set_shader_parameter("cell_size", cell_size)
		shader_mat.set_shader_parameter("bedrock_only_mode", 1 if _render_bedrock_view else 0)
		shader_mat.set_shader_parameter("day_of_year", _solar_day_of_year)
		shader_mat.set_shader_parameter("time_of_day", _solar_time_of_day)
		shader_mat.set_shader_parameter("use_fixed_lonlat", 1 if _use_fixed_lonlat else 0)
		shader_mat.set_shader_parameter("fixed_lon", _fixed_lon)
		shader_mat.set_shader_parameter("fixed_phi", _fixed_phi)
		
		# Set atlas parameters
		var atlas_uv_size = font_atlas_generator.get_uv_dimensions()
		shader_mat.set_shader_parameter("atlas_uv_size", atlas_uv_size)
		var cloud_tex: Texture2D = _safe_tex(cloud_texture_override, _fallback_black_tex)
		var light_tex: Texture2D = _safe_tex(light_texture_override, _fallback_black_tex)
		var river_tex: Texture2D = _safe_tex(river_texture_override, _fallback_black_tex)
		var biome_tex: Texture2D = _safe_tex(biome_texture_override, _fallback_black_tex)
		var lava_tex: Texture2D = _safe_tex(lava_texture_override, _fallback_black_tex)
		var society_tex: Texture2D = _safe_tex(society_overlay_texture_override, _fallback_black_tex)
		shader_mat.set_shader_parameter("cloud_texture", cloud_tex)
		shader_mat.set_shader_parameter("use_cloud_texture", 1 if _is_texture_bindable(cloud_texture_override) else 0)
		shader_mat.set_shader_parameter("light_texture", light_tex)
		shader_mat.set_shader_parameter("use_light_texture", 1 if _is_texture_bindable(light_texture_override) else 0)
		shader_mat.set_shader_parameter("river_texture", river_tex)
		shader_mat.set_shader_parameter("use_river_texture", 1 if _is_texture_bindable(river_texture_override) else 0)
		shader_mat.set_shader_parameter("biome_texture", biome_tex)
		shader_mat.set_shader_parameter("use_biome_texture", 1 if _is_texture_bindable(biome_texture_override) else 0)
		shader_mat.set_shader_parameter("lava_texture", lava_tex)
		shader_mat.set_shader_parameter("use_lava_texture", 1 if _is_texture_bindable(lava_texture_override) else 0)
		shader_mat.set_shader_parameter("society_overlay", society_tex)
		shader_mat.set_shader_parameter("use_society_overlay", 1 if _is_texture_bindable(society_overlay_texture_override) else 0)
	else:
		pass
	_update_cloud_uniforms()

func _update_cloud_uniforms() -> void:
	_ensure_fallback_textures()
	if cloud_material and cloud_material is ShaderMaterial:
		var cloud_mat := cloud_material as ShaderMaterial
		var t1 = world_data_1_override if world_data_1_override else texture_manager.get_data_texture_1()
		var t3 = texture_manager.get_data_texture_3()
		cloud_mat.set_shader_parameter("world_data_1", _safe_tex(t1, _fallback_black_tex))
		cloud_mat.set_shader_parameter("world_data_3", _safe_tex(t3, _fallback_black_tex))
		cloud_mat.set_shader_parameter("cloud_texture", _safe_tex(cloud_texture_override, _fallback_black_tex))
		cloud_mat.set_shader_parameter("use_cloud_texture", 1 if _is_texture_bindable(cloud_texture_override) else 0)
		cloud_mat.set_shader_parameter("light_texture", _safe_tex(light_texture_override, _fallback_black_tex))
		cloud_mat.set_shader_parameter("use_light_texture", 1 if _is_texture_bindable(light_texture_override) else 0)
		if cloud_rect:
			cloud_rect.visible = (t3 != null) or _is_texture_bindable(cloud_texture_override)
		cloud_mat.set_shader_parameter("map_dimensions", Vector2(map_width, map_height))
		cloud_mat.set_shader_parameter("display_dimensions", _display_dimensions)
		cloud_mat.set_shader_parameter("display_origin", _display_origin)
		cloud_mat.set_shader_parameter("scroll_offset", _scroll_offset)
		cloud_mat.set_shader_parameter("day_of_year", _solar_day_of_year)
		cloud_mat.set_shader_parameter("time_of_day", _solar_time_of_day)
		cloud_mat.set_shader_parameter("use_fixed_lonlat", 1 if _use_fixed_lonlat else 0)
		cloud_mat.set_shader_parameter("fixed_lon", _fixed_lon)
		cloud_mat.set_shader_parameter("fixed_phi", _fixed_phi)

func _update_light_uniform() -> void:
	"""Update only the light texture uniform"""
	_ensure_fallback_textures()
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat = quad_material as ShaderMaterial
		var t1 = world_data_1_override if world_data_1_override else texture_manager.get_data_texture_1()
		shader_mat.set_shader_parameter("world_data_1", _safe_tex(t1, _fallback_black_tex))
		shader_mat.set_shader_parameter("bedrock_only_mode", 1 if _render_bedrock_view else 0)
		shader_mat.set_shader_parameter("day_of_year", _solar_day_of_year)
		shader_mat.set_shader_parameter("time_of_day", _solar_time_of_day)
		shader_mat.set_shader_parameter("use_fixed_lonlat", 1 if _use_fixed_lonlat else 0)
		shader_mat.set_shader_parameter("fixed_lon", _fixed_lon)
		shader_mat.set_shader_parameter("fixed_phi", _fixed_phi)
		shader_mat.set_shader_parameter("display_dimensions", _display_dimensions)
		shader_mat.set_shader_parameter("display_origin", _display_origin)
		shader_mat.set_shader_parameter("scroll_offset", _scroll_offset)
		shader_mat.set_shader_parameter("light_texture", _safe_tex(light_texture_override, _fallback_black_tex))
		shader_mat.set_shader_parameter("use_light_texture", 1 if _is_texture_bindable(light_texture_override) else 0)
		shader_mat.set_shader_parameter("river_texture", _safe_tex(river_texture_override, _fallback_black_tex))
		shader_mat.set_shader_parameter("use_river_texture", 1 if _is_texture_bindable(river_texture_override) else 0)
		shader_mat.set_shader_parameter("biome_texture", _safe_tex(biome_texture_override, _fallback_black_tex))
		shader_mat.set_shader_parameter("use_biome_texture", 1 if _is_texture_bindable(biome_texture_override) else 0)
		shader_mat.set_shader_parameter("lava_texture", _safe_tex(lava_texture_override, _fallback_black_tex))
		shader_mat.set_shader_parameter("use_lava_texture", 1 if _is_texture_bindable(lava_texture_override) else 0)
	if cloud_material and cloud_material is ShaderMaterial:
		var cloud_mat := cloud_material as ShaderMaterial
		var t1c = world_data_1_override if world_data_1_override else texture_manager.get_data_texture_1()
		cloud_mat.set_shader_parameter("world_data_1", _safe_tex(t1c, _fallback_black_tex))
		cloud_mat.set_shader_parameter("day_of_year", _solar_day_of_year)
		cloud_mat.set_shader_parameter("time_of_day", _solar_time_of_day)
		cloud_mat.set_shader_parameter("use_fixed_lonlat", 1 if _use_fixed_lonlat else 0)
		cloud_mat.set_shader_parameter("fixed_lon", _fixed_lon)
		cloud_mat.set_shader_parameter("fixed_phi", _fixed_phi)
		cloud_mat.set_shader_parameter("display_dimensions", _display_dimensions)
		cloud_mat.set_shader_parameter("display_origin", _display_origin)
		cloud_mat.set_shader_parameter("scroll_offset", _scroll_offset)
		cloud_mat.set_shader_parameter("light_texture", _safe_tex(light_texture_override, _fallback_black_tex))
		cloud_mat.set_shader_parameter("use_light_texture", 1 if _is_texture_bindable(light_texture_override) else 0)
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat3 := quad_material as ShaderMaterial
		shader_mat3.set_shader_parameter("cloud_texture", _safe_tex(cloud_texture_override, _fallback_black_tex))
		shader_mat3.set_shader_parameter("use_cloud_texture", 1 if _is_texture_bindable(cloud_texture_override) else 0)

func set_cloud_texture_override(tex: Texture2D) -> void:
	cloud_texture_override = tex
	_update_cloud_uniforms()

func set_light_texture_override(tex: Texture2D) -> void:
	light_texture_override = tex
	_update_light_uniform()

func set_solar_params(day_of_year: float, time_of_day: float) -> void:
	_solar_day_of_year = fposmod(day_of_year, 1.0)
	_solar_time_of_day = fposmod(time_of_day, 1.0)
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat := quad_material as ShaderMaterial
		shader_mat.set_shader_parameter("day_of_year", _solar_day_of_year)
		shader_mat.set_shader_parameter("time_of_day", _solar_time_of_day)
	if cloud_material and cloud_material is ShaderMaterial:
		var cloud_mat := cloud_material as ShaderMaterial
		cloud_mat.set_shader_parameter("day_of_year", _solar_day_of_year)
		cloud_mat.set_shader_parameter("time_of_day", _solar_time_of_day)

func set_fixed_lonlat(enabled: bool, lon_rad: float, phi_rad: float) -> void:
	_use_fixed_lonlat = VariantCastsUtil.to_bool(enabled)
	_fixed_lon = float(lon_rad)
	_fixed_phi = float(phi_rad)
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat := quad_material as ShaderMaterial
		shader_mat.set_shader_parameter("use_fixed_lonlat", 1 if _use_fixed_lonlat else 0)
		shader_mat.set_shader_parameter("fixed_lon", _fixed_lon)
		shader_mat.set_shader_parameter("fixed_phi", _fixed_phi)
		shader_mat.set_shader_parameter("display_dimensions", _display_dimensions)
		shader_mat.set_shader_parameter("display_origin", _display_origin)
		shader_mat.set_shader_parameter("scroll_offset", _scroll_offset)
	if cloud_material and cloud_material is ShaderMaterial:
		var cloud_mat := cloud_material as ShaderMaterial
		cloud_mat.set_shader_parameter("use_fixed_lonlat", 1 if _use_fixed_lonlat else 0)
		cloud_mat.set_shader_parameter("fixed_lon", _fixed_lon)
		cloud_mat.set_shader_parameter("fixed_phi", _fixed_phi)
		cloud_mat.set_shader_parameter("display_dimensions", _display_dimensions)
		cloud_mat.set_shader_parameter("display_origin", _display_origin)
		cloud_mat.set_shader_parameter("scroll_offset", _scroll_offset)

func set_display_window(display_w: int, display_h: int, origin_x: float = 0.0, origin_y: float = 0.0) -> void:
	# Control which sub-rectangle of the data textures is shown on screen.
	_display_dimensions = Vector2(float(max(0, display_w)), float(max(0, display_h)))
	_display_origin = Vector2(origin_x, origin_y)
	_display_window_explicit = true
	_apply_view_window_uniforms()

func set_scroll_offset(offset_x: float, offset_y: float) -> void:
	# Smooth camera scroll (fractional cells).
	_scroll_offset = Vector2(offset_x, offset_y)
	_apply_view_window_uniforms()

func _apply_view_window_uniforms() -> void:
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat := quad_material as ShaderMaterial
		shader_mat.set_shader_parameter("display_dimensions", _display_dimensions)
		shader_mat.set_shader_parameter("display_origin", _display_origin)
		shader_mat.set_shader_parameter("scroll_offset", _scroll_offset)
	if cloud_material and cloud_material is ShaderMaterial:
		var cloud_mat := cloud_material as ShaderMaterial
		cloud_mat.set_shader_parameter("display_dimensions", _display_dimensions)
		cloud_mat.set_shader_parameter("display_origin", _display_origin)
		cloud_mat.set_shader_parameter("scroll_offset", _scroll_offset)

func set_river_texture_override(tex: Texture2D) -> void:
	river_texture_override = tex
	_update_light_uniform()

func set_biome_texture_override(tex: Texture2D) -> void:
	biome_texture_override = tex
	_update_light_uniform()

func set_lava_texture_override(tex: Texture2D) -> void:
	lava_texture_override = tex
	_update_light_uniform()

func set_society_overlay_texture_override(tex: Texture2D) -> void:
	society_overlay_texture_override = tex
	_update_light_uniform()

func set_world_data_1_override(tex: Texture2D) -> void:
	world_data_1_override = tex
	_update_material_uniforms()

func set_world_data_2_override(tex: Texture2D) -> void:
	world_data_2_override = tex
	_update_material_uniforms()

func cleanup() -> void:
	# Detach materials first so no sampler uniforms remain bound during shutdown.
	if display_rect != null and is_instance_valid(display_rect):
		display_rect.material = null
	if cloud_rect != null and is_instance_valid(cloud_rect):
		cloud_rect.material = null
	quad_material = null
	cloud_material = null
	cloud_texture_override = null
	light_texture_override = null
	river_texture_override = null
	biome_texture_override = null
	lava_texture_override = null
	society_overlay_texture_override = null
	world_data_1_override = null
	world_data_2_override = null
	_fallback_black_tex = null
	_fallback_white_tex = null

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
		# debug removed

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
	if not _display_window_explicit:
		_display_dimensions = Vector2(float(map_width), float(map_height))
		_display_origin = Vector2.ZERO
	
	# Update viewport size
	var viewport_width = new_width * cell_size.x
	var viewport_height = new_height * cell_size.y
	if viewport:
		viewport.size = Vector2i(int(viewport_width), int(viewport_height))
	
	# Update material uniforms
	if quad_material and quad_material is ShaderMaterial:
		var shader_mat = quad_material as ShaderMaterial
		shader_mat.set_shader_parameter("map_dimensions", Vector2(map_width, map_height))
	if cloud_material and cloud_material is ShaderMaterial:
		var cloud_mat := cloud_material as ShaderMaterial
		cloud_mat.set_shader_parameter("map_dimensions", Vector2(map_width, map_height))
	_apply_view_window_uniforms()
	
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
