extends RefCounted
class_name NpcSim

# Background daily NPC tick.
# Scaffolding only: important NPCs can accrue simple need drift and timestamps.

static func tick_day(_world_seed_hash: int, npc: NpcWorldStateModel, abs_day: int) -> void:
	if npc == null:
		return
	for nid in npc.important_npcs.keys():
		var v: Variant = npc.important_npcs.get(nid)
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var n: Dictionary = (v as Dictionary).duplicate(true)
		n["last_update_abs_day"] = abs_day
		# Very small deterministic drift placeholders.
		var needs: Dictionary = n.get("needs", {})
		if typeof(needs) != TYPE_DICTIONARY:
			needs = {}
		needs["hunger"] = clamp(float(needs.get("hunger", 0.0)) + 0.05, 0.0, 1.0)
		needs["thirst"] = clamp(float(needs.get("thirst", 0.0)) + 0.06, 0.0, 1.0)
		n["needs"] = needs
		npc.important_npcs[nid] = n
