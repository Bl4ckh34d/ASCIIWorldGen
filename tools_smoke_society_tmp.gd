extends SceneTree
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")
const ShaderLoader = preload("res://scripts/systems/ShaderLoader.gd")
func _initialize() -> void:
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	if rd == null:
		printerr("SMOKE_FAIL: rd null")
		quit(2)
		return
	var paths: Array[String] = [
		"res://shaders/society/economy_tick.glsl",
		"res://shaders/society/politics_tick.glsl",
		"res://shaders/society/npc_tick.glsl",
		"res://shaders/society/pop_migrate.glsl",
		"res://shaders/society/trade_flow_tick.glsl",
		"res://shaders/society/civilization_tick.glsl",
		"res://shaders/society/wildlife_tick.glsl",
		"res://shaders/society/society_overlay_pack.glsl",
	]
	for p in paths:
		var f: RDShaderFile = ShaderLoader.load_shader_safe(p)
		if f == null:
			printerr("SMOKE_FAIL: load ", p)
			quit(2)
			return
		var out: Dictionary = ShaderLoader.create_shader_and_pipeline(rd, f, p)
		if not VariantCasts.to_bool(out.get("success", false)):
			printerr("SMOKE_FAIL: pipeline ", p)
			quit(2)
			return
		var pr: RID = out.get("pipeline", RID())
		var sh: RID = out.get("shader", RID())
		if pr.is_valid():
			rd.free_rid(pr)
		if sh.is_valid():
			rd.free_rid(sh)
	print("SMOKE_OK")
	quit(0)
