extends Node
class_name RenderController

# GPU ASCII renderer lifecycle scaffold for refactor plan M4.

const Log = preload("res://scripts/systems/Logger.gd")
const ShaderLoader = preload("res://scripts/systems/ShaderLoader.gd")

var _gpu_ascii_renderer: Control = null

func initialize_gpu_ascii_renderer(ascii_map: RichTextLabel, map_width: int, map_height: int) -> Control:
	if ascii_map == null:
		push_error("RenderController: ascii_map is null.")
		return null
	if _gpu_ascii_renderer != null and is_instance_valid(_gpu_ascii_renderer):
		return _gpu_ascii_renderer
	var caps: Dictionary = ShaderLoader.get_system_capabilities()
	if not VariantCasts.to_bool(caps.get("gpu_compute_available", false)):
		Log.event_kv(Log.LogLevel.ERROR, "render", "gpu_ascii_init", "capability_missing", -1, -1.0, caps)
		push_error("RenderController: GPU compute unavailable; renderer init aborted.")
		ascii_map.modulate.a = 0.0
		return null

	var renderer_script: Script = load("res://scripts/rendering/GPUAsciiRenderer.gd")
	if renderer_script == null:
		Log.event_kv(Log.LogLevel.ERROR, "render", "gpu_ascii_init", "script_missing")
		push_error("RenderController: failed to load GPUAsciiRenderer.gd.")
		ascii_map.modulate.a = 0.0
		return null

	var renderer: Control = renderer_script.new()
	renderer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	renderer.z_index = 0
	renderer.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var map_container: Node = ascii_map.get_parent()
	if map_container != null and map_container is Control:
		(map_container as Control).add_child(renderer)
		(map_container as Control).move_child(renderer, 0)

	var default_font: Font = ascii_map.get_theme_font("normal_font")
	if default_font == null:
		default_font = ascii_map.get_theme_default_font()
	var font_size: int = ascii_map.get_theme_font_size("normal_font_size")
	if font_size <= 0:
		font_size = ascii_map.get_theme_default_font_size()

	if not ("initialize_gpu_rendering" in renderer):
		push_error("RenderController: initialize_gpu_rendering() missing.")
		renderer.queue_free()
		ascii_map.modulate.a = 0.0
		return null

	var ok_v: Variant = renderer.call("initialize_gpu_rendering", default_font, font_size, int(map_width), int(map_height))
	var ok: bool = VariantCasts.to_bool(ok_v)
	if not ok:
		Log.event_kv(Log.LogLevel.ERROR, "render", "gpu_ascii_init", "init_failed")
		push_error("RenderController: GPU renderer initialization failed in GPU-only mode.")
		renderer.queue_free()
		ascii_map.modulate.a = 0.0
		return null

	if "is_using_gpu_rendering" in renderer and not VariantCasts.to_bool(renderer.call("is_using_gpu_rendering")):
		Log.event_kv(Log.LogLevel.ERROR, "render", "gpu_ascii_init", "cpu_path_rejected")
		push_error("RenderController: GPU renderer reported non-GPU path (disallowed).")
		renderer.queue_free()
		ascii_map.modulate.a = 0.0
		return null

	_gpu_ascii_renderer = renderer
	ascii_map.modulate.a = 0.0
	Log.event_kv(Log.LogLevel.INFO, "render", "gpu_ascii_init", "ok")
	return _gpu_ascii_renderer

func get_renderer() -> Control:
	if _gpu_ascii_renderer != null and is_instance_valid(_gpu_ascii_renderer):
		return _gpu_ascii_renderer
	return null

func cleanup_renderer() -> void:
	if _gpu_ascii_renderer != null and is_instance_valid(_gpu_ascii_renderer):
		if "cleanup_renderer_resources" in _gpu_ascii_renderer:
			_gpu_ascii_renderer.call("cleanup_renderer_resources")
		_gpu_ascii_renderer.free()
	_gpu_ascii_renderer = null
