extends RefCounted
class_name PartyMemberModel

const DEFAULT_BAG_COLS: int = 8
const DEFAULT_BAG_ROWS: int = 4

var member_id: String = "hero"
var display_name: String = "Hero"
var level: int = 1
var experience_points: int = 0
var max_hp: int = 42
var hp: int = 42
var max_mp: int = 12
var mp: int = 12
var strength: int = 8
var defense: int = 6
var agility: int = 7
var intellect: int = 6

# Per-member slot inventory (Valheim-like): equipment occupies slots too.
var bag_cols: int = DEFAULT_BAG_COLS
var bag_rows: int = DEFAULT_BAG_ROWS
var bag: Array = [] # Array[Dictionary] slots: {"name": String, "count": int, "equipped_slot": String?}

var equipment: Dictionary = {
	"weapon": "",
	"armor": "",
	"accessory": "",
}

func _init(id_value: String = "hero", name_value: String = "Hero") -> void:
	member_id = id_value
	display_name = name_value
	ensure_bag()

func ensure_bag() -> void:
	bag_cols = max(1, int(bag_cols))
	bag_rows = max(1, int(bag_rows))
	var want: int = bag_cols * bag_rows
	if bag.size() != want:
		bag.resize(want)
	for i in range(want):
		if typeof(bag[i]) != TYPE_DICTIONARY:
			bag[i] = {}

func is_bag_slot_empty(idx: int) -> bool:
	if idx < 0 or idx >= bag.size():
		return true
	var slot: Variant = bag[idx]
	if typeof(slot) != TYPE_DICTIONARY:
		return true
	var d: Dictionary = slot
	return String(d.get("name", "")).is_empty() or int(d.get("count", 0)) <= 0

func get_bag_slot(idx: int) -> Dictionary:
	if idx < 0 or idx >= bag.size():
		return {}
	var slot: Variant = bag[idx]
	if typeof(slot) != TYPE_DICTIONARY:
		return {}
	return Dictionary(slot)

func set_bag_slot(idx: int, slot: Dictionary) -> void:
	if idx < 0:
		return
	ensure_bag()
	if idx >= bag.size():
		return
	bag[idx] = slot.duplicate(true)

func gain_exp(amount: int) -> PackedStringArray:
	var logs: PackedStringArray = PackedStringArray()
	if amount <= 0:
		return logs
	experience_points += amount
	logs.append("%s gains %d EXP." % [display_name, amount])
	while experience_points >= _exp_to_next_level(level):
		experience_points -= _exp_to_next_level(level)
		level += 1
		max_hp += 4
		max_mp += 2
		strength += 1
		defense += 1
		agility += 1
		intellect += 1
		hp = max_hp
		mp = max_mp
		logs.append("%s reached level %d." % [display_name, level])
	return logs

func to_dict() -> Dictionary:
	return {
		"member_id": member_id,
		"display_name": display_name,
		"level": level,
		"exp": experience_points,
		"max_hp": max_hp,
		"hp": hp,
		"max_mp": max_mp,
		"mp": mp,
		"strength": strength,
		"defense": defense,
		"agility": agility,
		"intellect": intellect,
		"bag_cols": bag_cols,
		"bag_rows": bag_rows,
		"bag": bag.duplicate(true),
		"equipment": equipment.duplicate(true),
	}

static func from_dict(data: Dictionary) -> PartyMemberModel:
	var member := PartyMemberModel.new(
		String(data.get("member_id", "hero")),
		String(data.get("display_name", "Hero"))
	)
	member.level = max(1, int(data.get("level", 1)))
	member.experience_points = max(0, int(data.get("exp", 0)))
	member.max_hp = max(1, int(data.get("max_hp", 42)))
	member.hp = clamp(int(data.get("hp", member.max_hp)), 0, member.max_hp)
	member.max_mp = max(0, int(data.get("max_mp", 12)))
	member.mp = clamp(int(data.get("mp", member.max_mp)), 0, member.max_mp)
	member.strength = max(1, int(data.get("strength", 8)))
	member.defense = max(0, int(data.get("defense", 6)))
	member.agility = max(1, int(data.get("agility", 7)))
	member.intellect = max(1, int(data.get("intellect", 6)))
	member.bag_cols = max(1, int(data.get("bag_cols", DEFAULT_BAG_COLS)))
	member.bag_rows = max(1, int(data.get("bag_rows", DEFAULT_BAG_ROWS)))
	member.bag = data.get("bag", []).duplicate(true)
	member.ensure_bag()
	member.equipment = data.get("equipment", {}).duplicate(true)
	return member

func _exp_to_next_level(current_level: int) -> int:
	return 32 + current_level * 12
