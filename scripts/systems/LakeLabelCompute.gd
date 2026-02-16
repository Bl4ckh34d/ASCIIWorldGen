extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

const ComputeShaderBaseUtil = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")

const PROPAGATE_SHADER_PATH: String = "res://shaders/lake_label_propagate_flag.glsl"
const MARK_BOUNDARY_SHADER_PATH: String = "res://shaders/lake_mark_boundary.glsl"
const SEED_FROM_LAND_SHADER_PATH: String = "res://shaders/lake_label_seed_from_land.glsl"
const APPLY_BOUNDARY_SHADER_PATH: String = "res://shaders/lake_label_apply_boundary.glsl"
const CLEAR_U32_SHADER_PATH: String = "res://shaders/clear_u32.glsl"

var _rd: RenderingDevice = null
var _prop_shader: RID = RID()
var _prop_pipeline: RID = RID()
var _mark_shader: RID = RID()
var _mark_pipeline: RID = RID()
var _seed_shader: RID = RID()
var _seed_pipeline: RID = RID()
var _apply_shader: RID = RID()
var _apply_pipeline: RID = RID()
var _clear_shader: RID = RID()
var _clear_pipeline: RID = RID()

var _buf_mgr: GPUBufferManager = null
var _size_cells: int = 0
var _labels_buf: RID = RID()
var _boundary_buf: RID = RID()
var _changed_flag_buf: RID = RID()
var _last_label_stats: Dictionary = {
	"requested_max_iters": 0,
	"executed_iters": 0,
	"early_out": false,
	"check_every": 0,
	"size_cells": 0,
}

func _init() -> void:
	_buf_mgr = GPUBufferManager.new()

func _ensure() -> bool:
	var prop_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_prop_shader,
		_prop_pipeline,
		PROPAGATE_SHADER_PATH,
		"lake_label_propagate_flag"
	)
	_rd = prop_state.get("rd", null)
	_prop_shader = prop_state.get("shader", RID())
	_prop_pipeline = prop_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(prop_state.get("ok", false)):
		return false

	var mark_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_mark_shader,
		_mark_pipeline,
		MARK_BOUNDARY_SHADER_PATH,
		"lake_mark_boundary"
	)
	_mark_shader = mark_state.get("shader", RID())
	_mark_pipeline = mark_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(mark_state.get("ok", false)):
		return false

	var seed_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_seed_shader,
		_seed_pipeline,
		SEED_FROM_LAND_SHADER_PATH,
		"lake_label_seed_from_land"
	)
	_seed_shader = seed_state.get("shader", RID())
	_seed_pipeline = seed_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(seed_state.get("ok", false)):
		return false

	var apply_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_apply_shader,
		_apply_pipeline,
		APPLY_BOUNDARY_SHADER_PATH,
		"lake_label_apply_boundary"
	)
	_apply_shader = apply_state.get("shader", RID())
	_apply_pipeline = apply_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(apply_state.get("ok", false)):
		return false

	var clear_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_clear_shader,
		_clear_pipeline,
		CLEAR_U32_SHADER_PATH,
		"clear_u32"
	)
	_clear_shader = clear_state.get("shader", RID())
	_clear_pipeline = clear_state.get("pipeline", RID())
	return VariantCastsUtil.to_bool(clear_state.get("ok", false))

func _ensure_work_buffers(size_cells: int) -> bool:
	if size_cells <= 0:
		return false
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	if _size_cells == size_cells and _labels_buf.is_valid() and _boundary_buf.is_valid() and _changed_flag_buf.is_valid():
		return true
	_size_cells = size_cells
	_labels_buf = _buf_mgr.ensure_buffer("lake_labels", size_cells * 4)
	_boundary_buf = _buf_mgr.ensure_buffer("lake_boundary_flags", (size_cells + 1) * 4)
	_changed_flag_buf = _buf_mgr.ensure_buffer("lake_changed_flag", 4)
	return _labels_buf.is_valid() and _boundary_buf.is_valid() and _changed_flag_buf.is_valid()

func _clear_u32_buffer(buf: RID, total_u32: int) -> bool:
	if not buf.is_valid() or total_u32 <= 0:
		return false
	var clear_uniforms: Array = []
	var cu := RDUniform.new()
	cu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	cu.binding = 0
	cu.add_id(buf)
	clear_uniforms.append(cu)
	var clear_set: RID = _rd.uniform_set_create(clear_uniforms, _clear_shader, 0)
	var clear_pc := PackedByteArray()
	clear_pc.append_array(PackedInt32Array([total_u32, 0, 0, 0]).to_byte_array())
	if not ComputeShaderBaseUtil.validate_push_constant_size(clear_pc, 16, "LakeLabelCompute.clear_u32"):
		_rd.free_rid(clear_set)
		return false
	var g1d: int = int(ceil(float(total_u32) / 256.0))
	var clear_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(clear_list, _clear_pipeline)
	_rd.compute_list_bind_uniform_set(clear_list, clear_set, 0)
	_rd.compute_list_set_push_constant(clear_list, clear_pc, clear_pc.size())
	_rd.compute_list_dispatch(clear_list, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(clear_set)
	return true

func _dispatch_seed(w: int, h: int, land_buf: RID) -> bool:
	var seed_uniforms: Array = []
	var su: RDUniform
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 0; su.add_id(land_buf); seed_uniforms.append(su)
	su = RDUniform.new(); su.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; su.binding = 1; su.add_id(_labels_buf); seed_uniforms.append(su)
	var seed_set: RID = _rd.uniform_set_create(seed_uniforms, _seed_shader, 0)
	var seed_pc := PackedByteArray()
	seed_pc.append_array(PackedInt32Array([w, h, 0, 0]).to_byte_array())
	if not ComputeShaderBaseUtil.validate_push_constant_size(seed_pc, 16, "LakeLabelCompute.seed"):
		_rd.free_rid(seed_set)
		return false
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var seed_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(seed_list, _seed_pipeline)
	_rd.compute_list_bind_uniform_set(seed_list, seed_set, 0)
	_rd.compute_list_set_push_constant(seed_list, seed_pc, seed_pc.size())
	_rd.compute_list_dispatch(seed_list, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(seed_set)
	return true

func _dispatch_propagate(w: int, h: int, land_buf: RID, wrap_x: bool) -> bool:
	var prop_uniforms: Array = []
	var pu: RDUniform
	pu = RDUniform.new(); pu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; pu.binding = 0; pu.add_id(land_buf); prop_uniforms.append(pu)
	pu = RDUniform.new(); pu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; pu.binding = 1; pu.add_id(_labels_buf); prop_uniforms.append(pu)
	pu = RDUniform.new(); pu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; pu.binding = 2; pu.add_id(_changed_flag_buf); prop_uniforms.append(pu)
	var prop_set: RID = _rd.uniform_set_create(prop_uniforms, _prop_shader, 0)
	var prop_pc := PackedByteArray()
	prop_pc.append_array(PackedInt32Array([w, h, (1 if wrap_x else 0), 0]).to_byte_array())
	if not ComputeShaderBaseUtil.validate_push_constant_size(prop_pc, 16, "LakeLabelCompute.propagate"):
		_rd.free_rid(prop_set)
		return false
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _prop_pipeline)
	_rd.compute_list_bind_uniform_set(cl, prop_set, 0)
	_rd.compute_list_set_push_constant(cl, prop_pc, prop_pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(prop_set)
	return true

func _read_changed_flag() -> int:
	if not _changed_flag_buf.is_valid():
		return 1
	var bytes: PackedByteArray = _rd.buffer_get_data(_changed_flag_buf, 0, 4)
	if bytes.size() < 4:
		return 1
	var ints: PackedInt32Array = bytes.to_int32_array()
	if ints.size() <= 0:
		return 1
	return int(ints[0])

func get_last_label_stats() -> Dictionary:
	return _last_label_stats.duplicate(true)

func _dispatch_mark_boundary(w: int, h: int) -> bool:
	var mark_uniforms: Array = []
	var mu: RDUniform
	mu = RDUniform.new(); mu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; mu.binding = 0; mu.add_id(_labels_buf); mark_uniforms.append(mu)
	mu = RDUniform.new(); mu.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; mu.binding = 1; mu.add_id(_boundary_buf); mark_uniforms.append(mu)
	var mark_set: RID = _rd.uniform_set_create(mark_uniforms, _mark_shader, 0)
	var mark_pc := PackedByteArray()
	mark_pc.append_array(PackedInt32Array([w, h, 0, 0]).to_byte_array())
	if not ComputeShaderBaseUtil.validate_push_constant_size(mark_pc, 16, "LakeLabelCompute.mark_boundary"):
		_rd.free_rid(mark_set)
		return false
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var mark_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(mark_list, _mark_pipeline)
	_rd.compute_list_bind_uniform_set(mark_list, mark_set, 0)
	_rd.compute_list_set_push_constant(mark_list, mark_pc, mark_pc.size())
	_rd.compute_list_dispatch(mark_list, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(mark_set)
	return true

func _dispatch_apply(size: int, out_lake_buf: RID, out_lake_id_buf: RID) -> bool:
	var apply_uniforms: Array = []
	var au: RDUniform
	au = RDUniform.new(); au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; au.binding = 0; au.add_id(_labels_buf); apply_uniforms.append(au)
	au = RDUniform.new(); au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; au.binding = 1; au.add_id(_boundary_buf); apply_uniforms.append(au)
	au = RDUniform.new(); au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; au.binding = 2; au.add_id(out_lake_buf); apply_uniforms.append(au)
	au = RDUniform.new(); au.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; au.binding = 3; au.add_id(out_lake_id_buf); apply_uniforms.append(au)
	var apply_set: RID = _rd.uniform_set_create(apply_uniforms, _apply_shader, 0)
	var apply_pc := PackedByteArray()
	apply_pc.append_array(PackedInt32Array([size, 0, 0, 0]).to_byte_array())
	if not ComputeShaderBaseUtil.validate_push_constant_size(apply_pc, 16, "LakeLabelCompute.apply_boundary"):
		_rd.free_rid(apply_set)
		return false
	var g1d: int = int(ceil(float(size) / 256.0))
	var apply_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(apply_list, _apply_pipeline)
	_rd.compute_list_bind_uniform_set(apply_list, apply_set, 0)
	_rd.compute_list_set_push_constant(apply_list, apply_pc, apply_pc.size())
	_rd.compute_list_dispatch(apply_list, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(apply_set)
	return true

func label_lakes_gpu_buffers(
		w: int,
		h: int,
		land_buf: RID,
		wrap_x: bool,
		out_lake_buf: RID,
		out_lake_id_buf: RID,
		iterations: int = 0
	) -> bool:
	if not _ensure():
		return false
	if w <= 0 or h <= 0:
		return false
	if not land_buf.is_valid() or not out_lake_buf.is_valid() or not out_lake_id_buf.is_valid():
		return false
	var size: int = w * h
	if not _ensure_work_buffers(size):
		return false
	if not _dispatch_seed(w, h, land_buf):
		return false

	var max_iters: int = max(1, iterations if iterations > 0 else max(w, h))
	var check_every: int = 8
	var executed_iters: int = 0
	var early_out: bool = false
	for it in range(max_iters):
		executed_iters = it + 1
		if not _clear_u32_buffer(_changed_flag_buf, 1):
			return false
		if not _dispatch_propagate(w, h, land_buf, wrap_x):
			return false
		if (it % check_every) == (check_every - 1):
			var changed: int = _read_changed_flag()
			if changed == 0:
				early_out = true
				break

	if not _clear_u32_buffer(_boundary_buf, size + 1):
		return false
	if not _dispatch_mark_boundary(w, h):
		return false
	var applied_ok: bool = _dispatch_apply(size, out_lake_buf, out_lake_id_buf)
	if applied_ok:
		_last_label_stats = {
			"requested_max_iters": max_iters,
			"executed_iters": executed_iters,
			"early_out": early_out,
			"check_every": check_every,
			"size_cells": size,
		}
	return applied_ok

func cleanup() -> void:
	if _buf_mgr != null:
		_buf_mgr.cleanup()
	ComputeShaderBaseUtil.free_rids(_rd, [
		_prop_pipeline,
		_prop_shader,
		_mark_pipeline,
		_mark_shader,
		_seed_pipeline,
		_seed_shader,
		_apply_pipeline,
		_apply_shader,
		_clear_pipeline,
		_clear_shader,
	])
	_prop_pipeline = RID()
	_prop_shader = RID()
	_mark_pipeline = RID()
	_mark_shader = RID()
	_seed_pipeline = RID()
	_seed_shader = RID()
	_apply_pipeline = RID()
	_apply_shader = RID()
	_clear_pipeline = RID()
	_clear_shader = RID()
	_labels_buf = RID()
	_boundary_buf = RID()
	_changed_flag_buf = RID()
	_size_cells = 0
