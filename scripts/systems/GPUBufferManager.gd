# File: res://scripts/systems/GPUBufferManager.gd
extends RefCounted

# Manages persistent GPU buffers to reduce allocation/deallocation overhead
# Implements the persistent SSBO strategy from the performance refactor plan

var _rd: RenderingDevice
var _buffers: Dictionary = {} # buffer_name -> { rid: RID, size: int, type: String }
var _staging_buffers: Dictionary = {} # for readback operations

func _init():
	_rd = RenderingServer.get_rendering_device()

func ensure_buffer(name: String, size_bytes: int, initial_data: PackedByteArray = PackedByteArray()) -> RID:
	"""Ensure a persistent buffer exists with at least the specified size"""
	if _rd == null:
		return RID()
	var existing = _buffers.get(name, {})
	
	# If buffer exists and is large enough, reuse it
	if existing.has("rid") and existing.rid.is_valid() and existing.get("size", 0) >= size_bytes:
		# Optionally update with new data if provided
		if initial_data.size() > 0:
			_rd.buffer_update(existing.rid, 0, initial_data.size(), initial_data)
		return existing.rid
	
	# Create new buffer or resize existing
	if existing.has("rid") and existing.rid.is_valid():
		_rd.free_rid(existing.rid)
	var init_bytes: PackedByteArray = initial_data
	if init_bytes.size() == 0:
		init_bytes = PackedByteArray()
		init_bytes.resize(size_bytes)
		init_bytes.fill(0)
	var buffer_rid = _rd.storage_buffer_create(size_bytes, init_bytes)
	_buffers[name] = {
		"rid": buffer_rid,
		"size": size_bytes,
		"type": "storage"
	}
	
	return buffer_rid

func get_buffer(name: String) -> RID:
	"""Get an existing buffer RID by name"""
	var buf = _buffers.get(name, {})
	if buf.has("rid") and buf.rid.is_valid():
		return buf.rid
	return RID()

func update_buffer(name: String, data: PackedByteArray, offset: int = 0) -> bool:
	"""Update buffer contents"""
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

func read_buffer(name: String, staging_name: String = "") -> PackedByteArray:
	"""Read buffer contents back to CPU with optional staging buffer name"""
	if _rd == null:
		return PackedByteArray()
	var buf = _buffers.get(name, {})
	if not buf.has("rid") or not buf.rid.is_valid():
		return PackedByteArray()
	
	# Use staging buffer if specified to avoid frequent allocations
	if staging_name != "":
		var staging_key = "%s_staging" % staging_name
		var staging = _staging_buffers.get(staging_key, {})
		if not staging.has("rid") or not staging.rid.is_valid() or staging.get("size", 0) < buf.size:
			if staging.has("rid") and staging.rid.is_valid():
				_rd.free_rid(staging.rid)
			var staging_rid = _rd.storage_buffer_create(buf.size)
			_staging_buffers[staging_key] = {"rid": staging_rid, "size": buf.size}
		
		# Copy to staging then read (if needed for specific GPU architectures)
		# For now, direct read from source
	
	return _rd.buffer_get_data(buf.rid)

func read_buffer_region(name: String, offset_bytes: int, size_bytes: int) -> PackedByteArray:
	"""Read a byte range from a managed buffer."""
	if _rd == null:
		return PackedByteArray()
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
	return _rd.buffer_get_data(buf.rid, off, req)

func clear_buffer(name: String, clear_value: int = 0) -> bool:
	"""Clear buffer to specified value using GPU clear shader"""
	if _rd == null:
		return false
	var buf = _buffers.get(name, {})
	if not buf.has("rid") or not buf.rid.is_valid():
		return false
	
	# For now, just update with zeros - could use clear shader for efficiency
	var clear_data = PackedByteArray()
	clear_data.resize(buf.size)
	clear_data.fill(clear_value)
	_rd.buffer_update(buf.rid, 0, clear_data.size(), clear_data)
	return true

func free_buffer(name: String) -> void:
	"""Free a specific buffer"""
	if _rd == null:
		_buffers.erase(name)
		return
	var buf = _buffers.get(name, {})
	if buf.has("rid") and buf.rid.is_valid():
		_rd.free_rid(buf.rid)
	_buffers.erase(name)

func cleanup() -> void:
	"""Free all managed buffers"""
	if _rd == null:
		_buffers.clear()
		_staging_buffers.clear()
		return
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
