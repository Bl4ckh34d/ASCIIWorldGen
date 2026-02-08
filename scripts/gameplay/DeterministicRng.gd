extends RefCounted
class_name DeterministicRng

static func key_hash(world_seed_hash: int, key: String) -> int:
	return key.hash() ^ world_seed_hash

static func randf01(world_seed_hash: int, key: String) -> float:
	var h: int = key_hash(world_seed_hash, key)
	var n: int = abs(h % 1000000)
	return float(n) / 1000000.0

static func randi_range(world_seed_hash: int, key: String, min_value: int, max_value: int) -> int:
	if max_value <= min_value:
		return min_value
	var span: int = max_value - min_value + 1
	var h: int = key_hash(world_seed_hash, key)
	var n: int = abs(h % span)
	return min_value + n
