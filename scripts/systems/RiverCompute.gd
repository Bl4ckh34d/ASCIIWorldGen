# File: res://scripts/systems/RiverCompute.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

const ComputeShaderBaseUtil = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")

const SEED_SHADER_PATH: String = "res://shaders/river_seed_nms.glsl"
const TRACE_SHADER_PATH: String = "res://shaders/river_trace.glsl"
const CLEAR_U32_SHADER_PATH: String = "res://shaders/clear_u32.glsl"

var _rd: RenderingDevice
var _seed_shader: RID
var _seed_pipeline: RID
var _trace_shader: RID
var _trace_pipeline: RID
var _clear_shader: RID
var _clear_pipeline: RID
var _seeds_buf: RID
var _front_a_buf: RID
var _front_b_buf: RID
var _active_flag_buf: RID
var _buf_size: int = 0
var _buf_mgr: GPUBufferManager = null
var _last_trace_stats: Dictionary = {
	"requested_max_iters": 0,
	"executed_iters": 0,
	"early_out": false,
	"size_cells": 0,
	"seed_threshold": 0.0,
	"min_len": 0,
}

func _init() -> void:
	_buf_mgr = GPUBufferManager.new()

func _river_max_iters(w: int, h: int, min_len: int) -> int:
	# Gameplay-oriented cap: shorter traces keep runtime predictable.
	# This intentionally sacrifices long-tail realism for performance.
	var cap: int = min(w + h, 96)
	return max(min_len, cap)

func _ensure() -> bool:
	var seed_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_seed_shader,
		_seed_pipeline,
		SEED_SHADER_PATH,
		"river_seed_nms"
	)
	_rd = seed_state.get("rd", null)
	_seed_shader = seed_state.get("shader", RID())
	_seed_pipeline = seed_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(seed_state.get("ok", false)):
		return false

	var trace_state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_trace_shader,
		_trace_pipeline,
		TRACE_SHADER_PATH,
		"river_trace"
	)
	_trace_shader = trace_state.get("shader", RID())
	_trace_pipeline = trace_state.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(trace_state.get("ok", false)):
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

func _ensure_frontier_buffers(size: int) -> void:
	if _buf_size == size and _seeds_buf.is_valid() and _front_a_buf.is_valid() and _front_b_buf.is_valid() and _active_flag_buf.is_valid():
		return
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	_buf_size = size
	var bytes: int = size * 4
	_seeds_buf = _buf_mgr.ensure_buffer("river_frontier_seeds", bytes)
	_front_a_buf = _buf_mgr.ensure_buffer("river_frontier_a", bytes)
	_front_b_buf = _buf_mgr.ensure_buffer("river_frontier_b", bytes)
	_active_flag_buf = _buf_mgr.ensure_buffer("river_frontier_active", 4)

func _read_active_flag() -> int:
	if _rd == null or not _active_flag_buf.is_valid():
		return 1
	var bytes: PackedByteArray = _rd.buffer_get_data(_active_flag_buf, 0, 4)
	if bytes.size() < 4:
		return 1
	var ints: PackedInt32Array = bytes.to_int32_array()
	if ints.size() <= 0:
		return 1
	return int(ints[0])

func get_last_trace_stats() -> Dictionary:
	return _last_trace_stats.duplicate(true)

func trace_rivers_gpu_buffers(
		w: int, h: int,
		land_buf: RID,
		lake_buf: RID,
		flow_dir_buf: RID,
		flow_accum_buf: RID,
		threshold: float,
		min_len: int,
		roi: Rect2i,
		out_river_buf: RID,
		clear_output: bool = true
	) -> bool:
	if not _ensure():
		_last_trace_stats = {"requested_max_iters": 0, "executed_iters": 0, "early_out": false, "size_cells": 0, "seed_threshold": float(threshold), "min_len": int(min_len)}
		return false
	if not _seed_pipeline.is_valid() or not _trace_pipeline.is_valid() or not _clear_pipeline.is_valid():
		return false
	if not land_buf.is_valid() or not lake_buf.is_valid() or not flow_dir_buf.is_valid() or not flow_accum_buf.is_valid() or not out_river_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	_ensure_frontier_buffers(size)
	var g1d2 := int(ceil(float(size) / 256.0))
	var uniforms_c: Array = []
	var u_set_c: RID
	var pc_c := PackedByteArray()
	var ints_c := PackedInt32Array([size])
	pc_c.append_array(ints_c.to_byte_array())
	var pad_clear := (16 - (pc_c.size() % 16)) % 16
	if pad_clear > 0:
		var z_clear := PackedByteArray()
		z_clear.resize(pad_clear)
		pc_c.append_array(z_clear)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc_c, 16, "RiverCompute.clear"):
		return false
	# Clear river output only when requested by caller (tile scheduler controls this).
	if clear_output:
		uniforms_c.clear()
		var uc := RDUniform.new()
		uc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uc.binding = 0
		uc.add_id(out_river_buf)
		uniforms_c.append(uc)
		u_set_c = _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
		var clear_output_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clear_output_list, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clear_output_list, u_set_c, 0)
		_rd.compute_list_set_push_constant(clear_output_list, pc_c, pc_c.size())
		_rd.compute_list_dispatch(clear_output_list, g1d2, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set_c)
	# Seed pass
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(flow_accum_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(flow_dir_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(_seeds_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _seed_shader, 0)
	var rx0: int = 0; var ry0: int = 0; var rx1: int = w; var ry1: int = h
	if roi.size.x > 0 and roi.size.y > 0:
		rx0 = clamp(roi.position.x, 0, max(0, w))
		ry0 = clamp(roi.position.y, 0, max(0, h))
		rx1 = clamp(roi.position.x + roi.size.x, 0, max(0, w))
		ry1 = clamp(roi.position.y + roi.size.y, 0, max(0, h))
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h])
	var floats := PackedFloat32Array([threshold])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var roi_ints := PackedInt32Array([rx0, ry0, rx1, ry1])
	pc.append_array(roi_ints.to_byte_array())
	var pad_seed := (16 - (pc.size() % 16)) % 16
	if pad_seed > 0:
		var z_seed := PackedByteArray(); z_seed.resize(pad_seed)
		pc.append_array(z_seed)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 32, "RiverCompute.seed"):
		_rd.free_rid(u_set)
		return false
	var gx: int = int(ceil(float(w) / 16.0)); var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _seed_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	# Trace pass
	var buf_front_in := _seeds_buf
	var buf_front_out := _front_a_buf
	# Clear frontier out
	uniforms_c.clear()
	var uc2 := RDUniform.new(); uc2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; uc2.binding = 0; uc2.add_id(buf_front_out); uniforms_c.append(uc2)
	u_set_c = _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
	var clear_frontier_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(clear_frontier_list, _clear_pipeline)
	_rd.compute_list_bind_uniform_set(clear_frontier_list, u_set_c, 0)
	_rd.compute_list_set_push_constant(clear_frontier_list, pc_c, pc_c.size())
	_rd.compute_list_dispatch(clear_frontier_list, g1d2, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set_c)
	var max_iters: int = _river_max_iters(w, h, min_len)
	var executed_iters: int = 0
	var early_out: bool = false
	for _iter in range(max_iters):
		executed_iters = _iter + 1
		uniforms.clear()
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(flow_dir_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(land_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(lake_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_front_in); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_front_out); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(out_river_buf); uniforms.append(u)
		u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(_active_flag_buf); uniforms.append(u)
		u_set = _rd.uniform_set_create(uniforms, _trace_shader, 0)
		# Reset "frontier has work" flag before this trace step.
		uniforms_c.clear()
		var uc_flag := RDUniform.new()
		uc_flag.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uc_flag.binding = 0
		uc_flag.add_id(_active_flag_buf)
		uniforms_c.append(uc_flag)
		u_set_c = _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
		var pc_flag := PackedByteArray()
		pc_flag.append_array(PackedInt32Array([1]).to_byte_array())
		var pad_flag := (16 - (pc_flag.size() % 16)) % 16
		if pad_flag > 0:
			var z_flag := PackedByteArray()
			z_flag.resize(pad_flag)
			pc_flag.append_array(z_flag)
		if not ComputeShaderBaseUtil.validate_push_constant_size(pc_flag, 16, "RiverCompute.active_flag_clear"):
			_rd.free_rid(u_set_c)
			_rd.free_rid(u_set)
			return false
		var clear_flag_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clear_flag_list, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clear_flag_list, u_set_c, 0)
		_rd.compute_list_set_push_constant(clear_flag_list, pc_flag, pc_flag.size())
		_rd.compute_list_dispatch(clear_flag_list, 1, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set_c)
		pc = PackedByteArray(); var total_arr := PackedInt32Array([size]); pc.append_array(total_arr.to_byte_array())
		var pad_trace := (16 - (pc.size() % 16)) % 16
		if pad_trace > 0:
			var z_trace := PackedByteArray(); z_trace.resize(pad_trace)
			pc.append_array(z_trace)
		if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 16, "RiverCompute.trace"):
			_rd.free_rid(u_set)
			return false
		var g1d := int(ceil(float(size) / 256.0))
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _trace_pipeline)
		_rd.compute_list_bind_uniform_set(cl, u_set, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, g1d, 1, 1)
		_rd.compute_list_end()
		var active: int = _read_active_flag()
		# swap frontiers
		var tmp := buf_front_in
		buf_front_in = buf_front_out
		buf_front_out = tmp
		# clear new out
		uniforms_c.clear()
		uc2 = RDUniform.new(); uc2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; uc2.binding = 0; uc2.add_id(buf_front_out); uniforms_c.append(uc2)
		u_set_c = _rd.uniform_set_create(uniforms_c, _clear_shader, 0)
		pc_c = PackedByteArray(); ints_c = PackedInt32Array([size]); pc_c.append_array(ints_c.to_byte_array())
		pad_clear = (16 - (pc_c.size() % 16)) % 16
		if pad_clear > 0:
			var z_clear3 := PackedByteArray(); z_clear3.resize(pad_clear)
			pc_c.append_array(z_clear3)
		if not ComputeShaderBaseUtil.validate_push_constant_size(pc_c, 16, "RiverCompute.frontier_clear"):
			_rd.free_rid(u_set_c)
			_rd.free_rid(u_set)
			return false
		clear_frontier_list = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(clear_frontier_list, _clear_pipeline)
		_rd.compute_list_bind_uniform_set(clear_frontier_list, u_set_c, 0)
		_rd.compute_list_set_push_constant(clear_frontier_list, pc_c, pc_c.size())
		_rd.compute_list_dispatch(clear_frontier_list, g1d2, 1, 1)
		_rd.compute_list_end()
		_rd.free_rid(u_set_c)
		_rd.free_rid(u_set)
		if active == 0:
			early_out = true
			break
	_last_trace_stats = {
		"requested_max_iters": max_iters,
		"executed_iters": executed_iters,
		"early_out": early_out,
		"size_cells": size,
		"seed_threshold": float(threshold),
		"min_len": int(min_len),
	}
	# GPU-only: skip CPU pruning in this path
	return true

func cleanup() -> void:
	if _buf_mgr != null:
		_buf_mgr.cleanup()
	ComputeShaderBaseUtil.free_rids(_rd, [
		_seed_pipeline,
		_seed_shader,
		_trace_pipeline,
		_trace_shader,
		_clear_pipeline,
		_clear_shader,
	])
	_seed_pipeline = RID()
	_seed_shader = RID()
	_trace_pipeline = RID()
	_trace_shader = RID()
	_clear_pipeline = RID()
	_clear_shader = RID()
	_seeds_buf = RID()
	_front_a_buf = RID()
	_front_b_buf = RID()
	_active_flag_buf = RID()
	_buf_size = 0
