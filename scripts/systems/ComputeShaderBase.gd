# File: res://scripts/systems/ComputeShaderBase.gd
extends RefCounted
class_name ComputeShaderBase

# Lightweight shared helpers for compute wrappers.
# We keep this static/composable so existing wrappers can adopt it incrementally.

const VariantCasts = preload("res://scripts/core/VariantCasts.gd")
const ShaderLoader = preload("res://scripts/systems/ShaderLoader.gd")
const Log = preload("res://scripts/systems/Logger.gd")

static func ensure_rd_and_pipeline(
	rd: RenderingDevice,
	shader: RID,
	pipeline: RID,
	shader_path: String,
	shader_name: String
) -> Dictionary:
	var out: Dictionary = {
		"ok": false,
		"rd": rd,
		"shader": shader,
		"pipeline": pipeline,
	}

	if out["rd"] == null:
		out["rd"] = RenderingServer.get_rendering_device()
	if out["rd"] == null:
		Log.event_kv(Log.LogLevel.ERROR, "shader", "rd_acquire", "rd_null", -1, -1.0, {"name": shader_name, "path": shader_path})
		push_error("%s: RenderingDevice unavailable (GPU-only sim)." % shader_name)
		return out

	if not (out["shader"] is RID and (out["shader"] as RID).is_valid()) or not (out["pipeline"] is RID and (out["pipeline"] as RID).is_valid()):
		var file: RDShaderFile = ShaderLoader.load_shader_safe(shader_path)
		if file == null:
			return out
		var built: Dictionary = ShaderLoader.create_shader_and_pipeline(out["rd"], file, shader_name)
		out["shader"] = built.get("shader", RID())
		out["pipeline"] = built.get("pipeline", RID())
		if not ((out["shader"] as RID).is_valid() and (out["pipeline"] as RID).is_valid()):
			return out

	out["ok"] = true
	return out

static func validate_push_constant_size(pc: PackedByteArray, expected_size: int, label: String) -> bool:
	var got: int = pc.size()
	if got != int(expected_size):
		Log.event_kv(Log.LogLevel.ERROR, "compute", "push_constant_size", "mismatch", -1, -1.0, {
			"label": label,
			"expected_bytes": int(expected_size),
			"actual_bytes": int(got),
		})
		push_error("%s: push constants size mismatch (%d != %d)." % [label, got, int(expected_size)])
		return false
	return true

static func free_rids(rd: RenderingDevice, rids: Array) -> void:
	if rd == null:
		return
	for rv in rids:
		if rv is RID and (rv as RID).is_valid():
			rd.free_rid(rv as RID)

static func uniform_set_is_alive(rd: RenderingDevice, uniform_set: RID) -> bool:
	if rd == null:
		return false
	if not (uniform_set is RID and uniform_set.is_valid()):
		return false
	if rd.has_method("uniform_set_is_valid"):
		return VariantCasts.to_bool(rd.uniform_set_is_valid(uniform_set))
	return true

static func free_uniform_set_if_alive(rd: RenderingDevice, uniform_set: RID) -> void:
	if not uniform_set_is_alive(rd, uniform_set):
		return
	rd.free_rid(uniform_set)

static func is_main_rendering_device(rd: RenderingDevice) -> bool:
	if rd == null:
		return false
	var main_rd: RenderingDevice = RenderingServer.get_rendering_device()
	return main_rd != null and rd == main_rd

static func submit_if_local(rd: RenderingDevice) -> void:
	if rd == null:
		return
	# In Godot 4.6, submit/sync are valid only for local RenderingDevice instances.
	if is_main_rendering_device(rd):
		return
	rd.submit()
