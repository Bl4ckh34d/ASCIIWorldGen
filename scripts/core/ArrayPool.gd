extends RefCounted
class_name ArrayPool

# CPU-side pool for large Packed*Array instances to reduce allocations between sim passes.
# v0 scaffolding: size-keyed buckets with explicit acquire/release.

var _f32_pool: Dictionary = {} # int size -> Array[PackedFloat32Array]
var _i32_pool: Dictionary = {} # int size -> Array[PackedInt32Array]
var _u8_pool: Dictionary = {}  # int size -> Array[PackedByteArray]

var _stats: Dictionary = {
	"acquire_f32": 0,
	"acquire_i32": 0,
	"acquire_u8": 0,
	"reuse_f32": 0,
	"reuse_i32": 0,
	"reuse_u8": 0,
	"release_f32": 0,
	"release_i32": 0,
	"release_u8": 0,
}

func clear() -> void:
	_f32_pool.clear()
	_i32_pool.clear()
	_u8_pool.clear()

func acquire_f32(size: int, zero_fill: bool = true) -> PackedFloat32Array:
	size = max(0, int(size))
	if size <= 0:
		return PackedFloat32Array()
	_stats["acquire_f32"] = int(_stats.get("acquire_f32", 0)) + 1
	var bucket: Array = _f32_pool.get(size, [])
	var arr := PackedFloat32Array()
	if not bucket.is_empty():
		arr = bucket.pop_back()
		_stats["reuse_f32"] = int(_stats.get("reuse_f32", 0)) + 1
		_f32_pool[size] = bucket
	else:
		arr.resize(size)
	if arr.size() != size:
		arr.resize(size)
	if zero_fill:
		arr.fill(0.0)
	return arr

func acquire_i32(size: int, fill_value: int = 0) -> PackedInt32Array:
	size = max(0, int(size))
	if size <= 0:
		return PackedInt32Array()
	_stats["acquire_i32"] = int(_stats.get("acquire_i32", 0)) + 1
	var bucket: Array = _i32_pool.get(size, [])
	var arr := PackedInt32Array()
	if not bucket.is_empty():
		arr = bucket.pop_back()
		_stats["reuse_i32"] = int(_stats.get("reuse_i32", 0)) + 1
		_i32_pool[size] = bucket
	else:
		arr.resize(size)
	if arr.size() != size:
		arr.resize(size)
	arr.fill(int(fill_value))
	return arr

func acquire_u8(size: int, fill_value: int = 0) -> PackedByteArray:
	size = max(0, int(size))
	if size <= 0:
		return PackedByteArray()
	_stats["acquire_u8"] = int(_stats.get("acquire_u8", 0)) + 1
	var bucket: Array = _u8_pool.get(size, [])
	var arr := PackedByteArray()
	if not bucket.is_empty():
		arr = bucket.pop_back()
		_stats["reuse_u8"] = int(_stats.get("reuse_u8", 0)) + 1
		_u8_pool[size] = bucket
	else:
		arr.resize(size)
	if arr.size() != size:
		arr.resize(size)
	if fill_value != 0:
		arr.fill(int(fill_value) & 255)
	elif arr.size() > 0:
		arr.fill(0)
	return arr

func release_f32(arr: PackedFloat32Array) -> void:
	var size: int = arr.size()
	if size <= 0:
		return
	var bucket: Array = _f32_pool.get(size, [])
	bucket.append(arr)
	_f32_pool[size] = bucket
	_stats["release_f32"] = int(_stats.get("release_f32", 0)) + 1

func release_i32(arr: PackedInt32Array) -> void:
	var size: int = arr.size()
	if size <= 0:
		return
	var bucket: Array = _i32_pool.get(size, [])
	bucket.append(arr)
	_i32_pool[size] = bucket
	_stats["release_i32"] = int(_stats.get("release_i32", 0)) + 1

func release_u8(arr: PackedByteArray) -> void:
	var size: int = arr.size()
	if size <= 0:
		return
	var bucket: Array = _u8_pool.get(size, [])
	bucket.append(arr)
	_u8_pool[size] = bucket
	_stats["release_u8"] = int(_stats.get("release_u8", 0)) + 1

func get_stats() -> Dictionary:
	var pooled_f32: int = 0
	var pooled_i32: int = 0
	var pooled_u8: int = 0
	for k in _f32_pool.keys():
		pooled_f32 += int(k) * int((_f32_pool.get(k, []) as Array).size())
	for k in _i32_pool.keys():
		pooled_i32 += int(k) * int((_i32_pool.get(k, []) as Array).size())
	for k in _u8_pool.keys():
		pooled_u8 += int(k) * int((_u8_pool.get(k, []) as Array).size())
	return {
		"f32_entries": pooled_f32,
		"i32_entries": pooled_i32,
		"u8_entries": pooled_u8,
		"bytes_estimate": pooled_f32 * 4 + pooled_i32 * 4 + pooled_u8,
		"ops": _stats.duplicate(true),
	}
