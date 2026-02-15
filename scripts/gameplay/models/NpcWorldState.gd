extends RefCounted
class_name NpcWorldStateModel

# NPC world state:
# - "important" NPCs are persisted individually (rulers, shopkeepers, quest givers).
# - Bulk populations remain aggregated until later.
# This file is scaffolding for persistence + deterministic ticking.

const CURRENT_VERSION: int = 1

var version: int = CURRENT_VERSION

# npc_id -> Dictionary (profile, role, home, needs, personality, disposition, flags)
var important_npcs: Dictionary = {}

# npc_id -> Array[Dictionary] recent dialogue summary / memory hooks (optional, small)
var npc_memories: Dictionary = {}

var last_tick_abs_day: int = -1

func reset_defaults() -> void:
	version = CURRENT_VERSION
	important_npcs.clear()
	npc_memories.clear()
	last_tick_abs_day = -1

func ensure_important_npc(npc_id: String, patch: Dictionary = {}) -> Dictionary:
	npc_id = String(npc_id)
	if npc_id.is_empty():
		return {}
	var v: Variant = important_npcs.get(npc_id, {})
	var st: Dictionary = {}
	if typeof(v) == TYPE_DICTIONARY:
		st = (v as Dictionary).duplicate(true)
	st["id"] = npc_id
	for k in patch.keys():
		st[k] = patch[k]
	important_npcs[npc_id] = st
	return st.duplicate(true)

func to_dict() -> Dictionary:
	return {
		"version": version,
		"important_npcs": important_npcs.duplicate(true),
		"npc_memories": npc_memories.duplicate(true),
		"last_tick_abs_day": last_tick_abs_day,
	}

static func from_dict(data: Dictionary) -> NpcWorldStateModel:
	var out := NpcWorldStateModel.new()
	out.version = max(1, int(data.get("version", CURRENT_VERSION)))
	out.important_npcs = data.get("important_npcs", {}).duplicate(true)
	out.npc_memories = data.get("npc_memories", {}).duplicate(true)
	out.last_tick_abs_day = int(data.get("last_tick_abs_day", -1))
	return out
