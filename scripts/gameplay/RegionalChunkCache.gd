extends RefCounted
class_name RegionalChunkCache

const RegionalChunkGenerator = preload("res://scripts/gameplay/RegionalChunkGenerator.gd")

var generator: RegionalChunkGenerator = null
var chunk_size: int = 32
var max_chunks: int = 256

var _tick: int = 0
var _chunks: Dictionary = {} # Vector2i -> { ground, obj, flags, last_used, chunk_size }

func configure(gen: RegionalChunkGenerator, chunk_size_value: int = 32, max_chunks_value: int = 256) -> void:
	generator = gen
	chunk_size = max(8, chunk_size_value)
	max_chunks = max(16, max_chunks_value)
	_tick = 0
	_chunks.clear()

func get_cell(gx: int, gy: int) -> Dictionary:
	if generator == null:
		return {"ground": 0, "obj": 0, "flags": 0}
	_tick += 1
	var cs: int = chunk_size
	var cx: int = int(gx / cs)
	var cy: int = int(gy / cs)
	var key := Vector2i(cx, cy)
	var chunk: Dictionary = _chunks.get(key, {})
	if chunk.is_empty():
		chunk = generator.generate_chunk(cx, cy, cs)
		chunk["last_used"] = _tick
		_chunks[key] = chunk
		_evict_if_needed()
	else:
		chunk["last_used"] = _tick
		_chunks[key] = chunk

	var lx: int = gx - cx * cs
	var ly: int = gy - cy * cs
	# Defensive clamp in case caller passed coords near clamp boundaries.
	lx = clamp(lx, 0, cs - 1)
	ly = clamp(ly, 0, cs - 1)
	var idx: int = lx + ly * cs
	var ground: PackedByteArray = chunk.get("ground", PackedByteArray())
	var obj: PackedByteArray = chunk.get("obj", PackedByteArray())
	var flags: PackedByteArray = chunk.get("flags", PackedByteArray())
	var height_raw: PackedFloat32Array = chunk.get("height_raw", PackedFloat32Array())
	var biome: PackedInt32Array = chunk.get("biome", PackedInt32Array())
	if idx < 0 or idx >= ground.size() or idx >= obj.size() or idx >= flags.size():
		return {"ground": 0, "obj": 0, "flags": 0}
	return {
		"ground": int(ground[idx]),
		"obj": int(obj[idx]),
		"flags": int(flags[idx]),
		"height_raw": float(height_raw[idx]) if idx >= 0 and idx < height_raw.size() else 0.0,
		"biome": int(biome[idx]) if idx >= 0 and idx < biome.size() else 7,
	}

func _evict_if_needed() -> void:
	if _chunks.size() <= max_chunks:
		return
	# Simple LRU eviction: drop the least recently used chunks until under budget.
	while _chunks.size() > max_chunks:
		var oldest_key: Variant = null
		var oldest_tick: int = 2147483647
		for k in _chunks.keys():
			var chunk: Dictionary = _chunks[k]
			var used: int = int(chunk.get("last_used", 0))
			if used < oldest_tick:
				oldest_tick = used
				oldest_key = k
		if oldest_key == null:
			break
		_chunks.erase(oldest_key)
