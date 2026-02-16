extends RefCounted
class_name WorldEventRng

# Deterministic "event RNG" keyed by world time + entity id.
# Use this for politics/economy/NPC simulation events so outcomes are reproducible across runs.


static func randf01(world_seed_hash: int, abs_day: int, entity_id: String, tag: String) -> float:
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
	abs_day = max(0, int(abs_day))
	entity_id = String(entity_id)
	tag = String(tag)
	var key: String = "evt|d=%d|id=%s|%s" % [abs_day, entity_id, tag]
	return DeterministicRng.randf01(world_seed_hash, key)

static func randi_range(world_seed_hash: int, abs_day: int, entity_id: String, tag: String, a: int, b: int) -> int:
	world_seed_hash = 1 if world_seed_hash == 0 else world_seed_hash
	abs_day = max(0, int(abs_day))
	entity_id = String(entity_id)
	tag = String(tag)
	var key: String = "evt|d=%d|id=%s|%s" % [abs_day, entity_id, tag]
	return DeterministicRng.randi_range(world_seed_hash, key, a, b)

