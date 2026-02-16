# File: res://scripts/systems/GPUBufferManager.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

# Manages persistent GPU buffers to reduce allocation/deallocation overhead
# Implements the persistent SSBO strategy from the performance refactor plan

const Log = preload("res://scripts/systems/Logger.gd")
const ComputeShaderBaseUtil = preload("res://scripts/systems/ComputeShaderBase.gd")
const _MIN_STORAGE_BUFFER_BYTES: int = 4

var _rd: RenderingDevice
var _buffers: Dictionary = {} # buffer_name -> { rid: RID, size: int, type: String }
var _staging_buffers: Dictionary = {} # for readback operations
var _clear_shader: RID = RID()
var _clear_pipeline: RID = RID()
var _copy_shader: RID = RID()
var _copy_pipeline: RID = RID()

var _alloc_count: int = 0
var _alloc_bytes: int = 0
var _readback_count: int = 0
var _readback_bytes: int = 0
var async_large_updates_enabled: bool = false
var async_large_update_threshold_bytes: int = 262144
var async_flush_on_readback: bool = true
var _pending_updates: Array[Dictionary] = []
var _pending_update_bytes: int = 0

func _init():
	_rd = RenderingServer.get_rendering_device()

func set_async_update_config(enabled: bool, threshold_bytes: int = 262144, flush_on_readback: bool = true) -> void:
	async_large_updates_enabled = VariantCastsUtil.to_bool(enabled)
	async_large_update_threshold_bytes = max(1024, int(threshold_bytes))
	async_flush_on_readback = VariantCastsUtil.to_bool(flush_on_readback)
	if not async_large_updates_enabled:
		flush_pending_updates()

func _apply_buffer_update(name: String, data: PackedByteArray, offset: int = 0) -> bool:
	if _rd == null:
		return false
	var buf = _buffers.get(name, {})
	if not buf.has("rid") or not buf.rid.is_valid():
		return false
	if offset + data.size() > buf.get("size", 0):
		push_error("GPUBufferManager: Update would exceed buffer size")
		return false
	_rd.buffer_update(buf.rid, offset, data.size(), data)
	return true

func _prune_pending_updates_for(name: String) -> void:
	if _pending_updates.is_empty():
		return
	var kept: Array[Dictionary] = []
	var dropped_bytes: int = 0
	for entry in _pending_updates:
		if String(entry.get("name", "")) == name:
			dropped_bytes += int((entry.get("data", PackedByteArray()) as PackedByteArray).size())
			continue
		kept.append(entry)
	_pending_updates = kept
	_pending_update_bytes = max(0, _pending_update_bytes - dropped_bytes)

func _ensure_clear_pipeline() -> bool:
	var state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_clear_shader,
		_clear_pipeline,
		"res://shaders/clear_u32.glsl",
		"gpu_buf_clear_u32"
	)
	_rd = state.get("rd", _rd)
	_clear_shader = state.get("shader", RID())
	_clear_pipeline = state.get("pipeline", RID())
	return VariantCastsUtil.to_bool(state.get("ok", false))

func _ensure_copy_pipeline() -> bool:
	var state: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_copy_shader,
		_copy_pipeline,
		"res://shaders/copy_u32.glsl",
		"gpu_buf_copy_u32"
	)
	_rd = state.get("rd", _rd)
	_copy_shader = state.get("shader", RID())
	_copy_pipeline = state.get("pipeline", RID())
	return VariantCastsUtil.to_bool(state.get("ok", false))

func _dispatch_clear_u32(buf_rid: RID, total_u32: int) -> bool:
	if _rd == null or not buf_rid.is_valid() or total_u32 <= 0:
		return false
	if not _ensure_clear_pipeline():
		return false
	var uniforms: Array = []
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(buf_rid)
	uniforms.append(u0)
	var u_set: RID = _rd.uniform_set_create(uniforms, _clear_shader, 0)
	if not u_set.is_valid():
		return false
	var pc := PackedByteArray()
	pc.append_array(PackedInt32Array([int(total_u32)]).to_byte_array())
	var pad: int = (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 16, "GPUBufferManager.clear_u32"):
		_rd.free_rid(u_set)
		return false
	var g1d: int = int(ceil(float(total_u32) / 256.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _clear_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func _dispatch_copy_u32(src_rid: RID, dst_rid: RID, total_u32: int) -> bool:
	if _rd == null or not src_rid.is_valid() or not dst_rid.is_valid() or total_u32 <= 0:
		return false
	if not _ensure_copy_pipeline():
		return false
	var uniforms: Array = []
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(src_rid)
	uniforms.append(u0)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(dst_rid)
	uniforms.append(u1)
	var u_set: RID = _rd.uniform_set_create(uniforms, _copy_shader, 0)
	if not u_set.is_valid():
		return false
	var pc := PackedByteArray()
	pc.append_array(PackedInt32Array([int(total_u32)]).to_byte_array())
	var pad: int = (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray()
		zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 16, "GPUBufferManager.copy_u32"):
		_rd.free_rid(u_set)
		return false
	var g1d: int = int(ceil(float(total_u32) / 256.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _copy_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, g1d, 1, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func ensure_buffer(name: String, size_bytes: int, initial_data: PackedByteArray = PackedByteArray(), usage: int = 0) -> RID:
	"""Ensure a persistent buffer exists with at least the specified size"""
	if _rd == null:
		Log.event_kv(Log.LogLevel.ERROR, "gpu_buf", "ensure_buffer", "rd_null", size_bytes)
		return RID()
	if _pending_updates.size() > 0:
		flush_pending_updates()
	var existing = _buffers.get(name, {})
	var requested_size: int = max(0, int(size_bytes))
	var alloc_size: int = max(requested_size, int(initial_data.size()))
	if alloc_size <= 0:
		# Keep a tiny valid SSBO for zero-entity systems that still need a bound uniform set.
		alloc_size = _MIN_STORAGE_BUFFER_BYTES
	
	# If buffer exists and is large enough, reuse it
	if existing.has("rid") and existing.rid.is_valid() and existing.get("size", 0) >= alloc_size:
		# Optionally update with new data if provided
		if initial_data.size() > 0:
			_apply_buffer_update(name, initial_data, 0)
		return existing.rid
	
	# Create new buffer or resize existing
	if existing.has("rid") and existing.rid.is_valid():
		_rd.free_rid(existing.rid)
	_prune_pending_updates_for(name)
	var init_bytes: PackedByteArray = initial_data
	if init_bytes.size() == 0:
		init_bytes = PackedByteArray()
		init_bytes.resize(alloc_size)
		init_bytes.fill(0)
	elif init_bytes.size() < alloc_size:
		var padded := PackedByteArray()
		padded.resize(alloc_size)
		padded.fill(0)
		for i in range(init_bytes.size()):
			padded[i] = init_bytes[i]
		init_bytes = padded
	var buffer_rid = _rd.storage_buffer_create(alloc_size, init_bytes)
	_alloc_count += 1
	_alloc_bytes += int(alloc_size)
	_buffers[name] = {
		"rid": buffer_rid,
		"size": alloc_size,
		"type": "storage",
		"usage": int(usage),
	}
	Log.event_kv(Log.LogLevel.INFO, "gpu_buf", "alloc", "ok", alloc_size, -1.0, {"name": name})
	
	return buffer_rid

func get_buffer(name: String) -> RID:
	"""Get an existing buffer RID by name"""
	var buf = _buffers.get(name, {})
	if buf.has("rid") and buf.rid.is_valid():
		return buf.rid
	return RID()

func update_buffer(name: String, data: PackedByteArray, offset: int = 0, force_sync: bool = false) -> bool:
	"""Update buffer contents"""
	if _rd == null:
		return false
	if data.size() <= 0:
		return true
	if not force_sync and async_large_updates_enabled and data.size() >= async_large_update_threshold_bytes:
		return queue_buffer_update(name, data, offset)
	return _apply_buffer_update(name, data, offset)

func queue_buffer_update(name: String, data: PackedByteArray, offset: int = 0) -> bool:
	"""Queue a large update for deferred flush. Falls back to sync if async is disabled."""
	if _rd == null:
		return false
	if data.size() <= 0:
		return true
	var buf = _buffers.get(name, {})
	if not buf.has("rid") or not buf.rid.is_valid():
		return false
	if offset + data.size() > int(buf.get("size", 0)):
		push_error("GPUBufferManager: Queued update would exceed buffer size")
		return false
	if not async_large_updates_enabled:
		return _apply_buffer_update(name, data, offset)
	_pending_updates.append({
		"name": name,
		"offset": int(offset),
		"data": data,
	})
	_pending_update_bytes += int(data.size())
	return true

func flush_pending_updates(max_ops: int = -1, max_bytes: int = -1) -> int:
	"""Apply queued async updates immediately. Returns number of applied updates."""
	if _rd == null:
		_pending_updates.clear()
		_pending_update_bytes = 0
		return 0
	if _pending_updates.is_empty():
		return 0
	var applied: int = 0
	var used_bytes: int = 0
	var remaining: Array[Dictionary] = []
	for entry in _pending_updates:
		var e_bytes: int = int((entry.get("data", PackedByteArray()) as PackedByteArray).size())
		if (max_ops >= 0 and applied >= max_ops) or (max_bytes >= 0 and (used_bytes + e_bytes) > max_bytes):
			remaining.append(entry)
			continue
		var ok: bool = _apply_buffer_update(
			String(entry.get("name", "")),
			entry.get("data", PackedByteArray()) as PackedByteArray,
			int(entry.get("offset", 0))
		)
		if ok:
			applied += 1
			used_bytes += e_bytes
		else:
			# Keep failed entries queued for retry unless buffer was deleted.
			remaining.append(entry)
	_pending_updates = remaining
	_pending_update_bytes = 0
	for entry in _pending_updates:
		_pending_update_bytes += int((entry.get("data", PackedByteArray()) as PackedByteArray).size())
	return applied

func read_buffer(name: String, staging_name: String = "") -> PackedByteArray:
	"""Read buffer contents back to CPU with optional staging buffer name"""
	if _rd == null:
		return PackedByteArray()
	if async_flush_on_readback and _pending_updates.size() > 0:
		flush_pending_updates()
	var buf = _buffers.get(name, {})
	if not buf.has("rid") or not buf.rid.is_valid():
		return PackedByteArray()

	var buf_size: int = int(buf.get("size", 0))
	_readback_count += 1
	_readback_bytes += max(0, buf_size)
	
	# Use staging buffer if specified to avoid frequent allocations
	if staging_name != "":
		var staging_key = "%s_staging" % staging_name
		var staging = _staging_buffers.get(staging_key, {})
		if not staging.has("rid") or not staging.rid.is_valid() or int(staging.get("size", 0)) < buf_size:
			if staging.has("rid") and staging.rid.is_valid():
				_rd.free_rid(staging.rid)
			var staging_rid = _rd.storage_buffer_create(buf_size)
			_alloc_count += 1
			_alloc_bytes += int(buf_size)
			_staging_buffers[staging_key] = {"rid": staging_rid, "size": buf_size}
		var staging_rid_use: RID = (_staging_buffers.get(staging_key, {}) as Dictionary).get("rid", RID())
		if staging_rid_use.is_valid() and (buf_size % 4 == 0):
			var word_count: int = buf_size >> 2
			var copied: bool = _dispatch_copy_u32(buf.rid, staging_rid_use, word_count)
			if copied:
				return _rd.buffer_get_data(staging_rid_use)
	return _rd.buffer_get_data(buf.rid)

func read_buffer_region(name: String, offset_bytes: int, size_bytes: int) -> PackedByteArray:
	"""Read a byte range from a managed buffer."""
	if _rd == null:
		return PackedByteArray()
	if async_flush_on_readback and _pending_updates.size() > 0:
		flush_pending_updates()
	var buf = _buffers.get(name, {})
	if not buf.has("rid") or not buf.rid.is_valid():
		return PackedByteArray()
	var total_size: int = int(buf.get("size", 0))
	if total_size <= 0:
		return PackedByteArray()
	var off: int = clamp(int(offset_bytes), 0, total_size)
	var max_len: int = max(0, total_size - off)
	var req: int = clamp(int(size_bytes), 0, max_len)
	if req <= 0:
		return PackedByteArray()
	_readback_count += 1
	_readback_bytes += int(req)
	return _rd.buffer_get_data(buf.rid, off, req)

func clear_buffer(name: String, clear_value: int = 0) -> bool:
	"""Clear buffer to specified value using GPU clear shader"""
	if _rd == null:
		return false
	var buf = _buffers.get(name, {})
	if not buf.has("rid") or not buf.rid.is_valid():
		return false
	var buf_size: int = int(buf.get("size", 0))
	if clear_value == 0 and buf_size > 0 and (buf_size % 4 == 0):
		var word_count: int = buf_size >> 2
		if _dispatch_clear_u32(buf.rid, word_count):
			return true
	# Fallback for non-u32-aligned sizes or non-zero clears.
	var clear_data := PackedByteArray()
	clear_data.resize(buf_size)
	clear_data.fill(int(clear_value) & 255)
	_rd.buffer_update(buf.rid, 0, clear_data.size(), clear_data)
	return true

func free_buffer(name: String) -> void:
	"""Free a specific buffer"""
	if _rd == null:
		_prune_pending_updates_for(name)
		_buffers.erase(name)
		return
	flush_pending_updates()
	var buf = _buffers.get(name, {})
	if buf.has("rid") and buf.rid.is_valid():
		_rd.free_rid(buf.rid)
	_prune_pending_updates_for(name)
	_buffers.erase(name)

func cleanup() -> void:
	"""Free all managed buffers"""
	if _rd == null:
		_buffers.clear()
		_staging_buffers.clear()
		_pending_updates.clear()
		_pending_update_bytes = 0
		return
	flush_pending_updates()
	for name in _buffers.keys():
		var buf = _buffers[name]
		if buf.has("rid") and buf.rid.is_valid():
			_rd.free_rid(buf.rid)
	_buffers.clear()
	
	for name in _staging_buffers.keys():
		var buf = _staging_buffers[name]
		if buf.has("rid") and buf.rid.is_valid():
			_rd.free_rid(buf.rid)
	_staging_buffers.clear()
	ComputeShaderBaseUtil.free_rids(_rd, [_clear_pipeline, _clear_shader, _copy_pipeline, _copy_shader])
	_clear_pipeline = RID()
	_clear_shader = RID()
	_copy_pipeline = RID()
	_copy_shader = RID()
	_pending_updates.clear()
	_pending_update_bytes = 0

func get_buffer_stats() -> Dictionary:
	"""Get memory usage statistics"""
	var total_bytes = 0
	var active_buffers = 0
	
	for buf in _buffers.values():
		if buf.has("rid") and buf.rid.is_valid():
			total_bytes += buf.get("size", 0)
			active_buffers += 1
	
	return {
		"active_buffers": active_buffers,
		"total_bytes": total_bytes,
		"total_mb": float(total_bytes) / (1024.0 * 1024.0)
	}

func get_io_stats() -> Dictionary:
	return {
		"alloc_count": _alloc_count,
		"alloc_bytes": _alloc_bytes,
		"alloc_mb": float(_alloc_bytes) / (1024.0 * 1024.0),
		"readback_count": _readback_count,
		"readback_bytes": _readback_bytes,
		"readback_mb": float(_readback_bytes) / (1024.0 * 1024.0),
		"pending_updates": _pending_updates.size(),
		"pending_update_bytes": _pending_update_bytes,
		"pending_update_mb": float(_pending_update_bytes) / (1024.0 * 1024.0),
	}
