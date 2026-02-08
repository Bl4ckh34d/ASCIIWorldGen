extends RefCounted
class_name PartyStateModel

const PartyMemberModel = preload("res://scripts/gameplay/models/PartyMember.gd")
const ItemCatalog = preload("res://scripts/gameplay/catalog/ItemCatalog.gd")

var members: Array[PartyMemberModel] = []

# Compatibility view used by battle/menu snapshots.
# Source of truth is now per-member `PartyMemberModel.bag` slot inventories.
var inventory: Dictionary = {}
var gold: int = 0

func reset_default_party() -> void:
	members.clear()
	members.append(PartyMemberModel.new("hero", "Hero"))
	members.append(PartyMemberModel.new("mage", "Mage"))
	members[1].max_hp = 32
	members[1].hp = 32
	members[1].max_mp = 24
	members[1].mp = 24
	members[1].intellect = 9
	members.append(PartyMemberModel.new("rogue", "Rogue"))
	members[2].agility = 10
	members[2].strength = 7
	ensure_bags()
	_clear_all_bags()
	add_item("Potion", 3)
	add_item("Herb", 2)
	add_item("Bronze Sword", 1)
	add_item("Leather Armor", 1)
	gold = 120

func total_power() -> int:
	var power: int = 0
	for member in members:
		var bonus: Dictionary = _sum_equipment_bonuses(member)
		power += member.level * 2 + (member.strength + int(bonus.get("strength", 0))) + (member.intellect + int(bonus.get("intellect", 0))) + (member.agility + int(bonus.get("agility", 0)))
	return max(6, power)

func add_item(item_name: String, count: int = 1) -> void:
	add_item_auto(item_name, count)

func add_item_auto(item_name: String, count: int = 1) -> int:
	item_name = String(item_name)
	if item_name.is_empty() or count <= 0:
		return count
	ensure_bags()
	var item: Dictionary = ItemCatalog.get_item(item_name)
	var stackable: bool = bool(item.get("stackable", true))
	var remaining: int = count
	# Fill existing stack first.
	if stackable:
		for member in members:
			if member == null:
				continue
			member.ensure_bag()
			for i in range(member.bag.size()):
				var slot: Dictionary = member.get_bag_slot(i)
				if String(slot.get("name", "")) != item_name:
					continue
				var cur_count: int = max(0, int(slot.get("count", 0)))
				slot["count"] = cur_count + remaining
				member.set_bag_slot(i, slot)
				remaining = 0
				break
			if remaining <= 0:
				break
	# Use empty slots.
	while remaining > 0:
		var placed: bool = false
		for member in members:
			if member == null:
				continue
			member.ensure_bag()
			for i in range(member.bag.size()):
				if not member.is_bag_slot_empty(i):
					continue
				var put: int = remaining if stackable else 1
				member.set_bag_slot(i, {"name": item_name, "count": put})
				remaining -= put
				placed = true
				break
			if placed:
				break
		if not placed:
			break
	_rebuild_inventory_dict()
	return remaining

func remove_item(item_name: String, count: int = 1, allow_remove_equipped: bool = false) -> bool:
	item_name = String(item_name)
	if item_name.is_empty() or count <= 0:
		return false
	ensure_bags()
	var need: int = count
	for member in members:
		if member == null:
			continue
		member.ensure_bag()
		for i in range(member.bag.size()):
			var slot: Dictionary = member.get_bag_slot(i)
			if String(slot.get("name", "")) != item_name:
				continue
			if not allow_remove_equipped and not String(slot.get("equipped_slot", "")).is_empty():
				continue
			var have: int = max(0, int(slot.get("count", 0)))
			if have <= 0:
				continue
			var take: int = min(have, need)
			have -= take
			need -= take
			if have <= 0:
				member.set_bag_slot(i, {})
			else:
				slot["count"] = have
				member.set_bag_slot(i, slot)
			if need <= 0:
				_rebuild_inventory_dict()
				return true
	_rebuild_inventory_dict()
	return false

func grant_rewards(rewards: Dictionary) -> PackedStringArray:
	var logs: PackedStringArray = PackedStringArray()
	var exp_amount: int = max(0, int(rewards.get("exp", 0)))
	var gold_amount: int = max(0, int(rewards.get("gold", 0)))
	if exp_amount > 0:
		for member in members:
			var member_logs: PackedStringArray = member.gain_exp(exp_amount)
			for line in member_logs:
				logs.append(line)
	if gold_amount > 0:
		gold += gold_amount
		logs.append("Party found %d gold." % gold_amount)
	var items: Array = rewards.get("items", [])
	for entry in items:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var item_name: String = String(entry.get("name", ""))
		var amount: int = max(1, int(entry.get("count", 1)))
		if item_name.is_empty():
			continue
		var leftover: int = add_item_auto(item_name, amount)
		var got: int = amount - leftover
		if got <= 0:
			logs.append("Could not carry %s x%d." % [item_name, amount])
		elif leftover > 0:
			logs.append("Obtained %s x%d (no space for x%d)." % [item_name, got, leftover])
		else:
			logs.append("Obtained %s x%d." % [item_name, amount])
	return logs

func to_dict() -> Dictionary:
	var out_members: Array = []
	for member in members:
		out_members.append(member.to_dict())
	_rebuild_inventory_dict()
	return {
		"members": out_members,
		"inventory": inventory.duplicate(true),
		"gold": gold,
	}

static func from_dict(data: Dictionary) -> PartyStateModel:
	var state := PartyStateModel.new()
	state.gold = max(0, int(data.get("gold", 0)))
	var legacy_inventory: Dictionary = data.get("inventory", {}).duplicate(true)
	var incoming_members: Array = data.get("members", [])
	for entry in incoming_members:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		state.members.append(PartyMemberModel.from_dict(entry))
	if state.members.is_empty():
		state.reset_default_party()
		return state
	state.ensure_bags()
	state._migrate_legacy_inventory_and_equipment_if_needed(legacy_inventory)
	return state

func ensure_bags() -> void:
	for member in members:
		if member != null:
			member.ensure_bag()

func rebuild_inventory_view() -> void:
	# Public hook for systems that mutate bag slots directly (UI, scripting).
	_rebuild_inventory_dict()

func _clear_all_bags() -> void:
	ensure_bags()
	for member in members:
		if member == null:
			continue
		for i in range(member.bag.size()):
			member.bag[i] = {}

func _has_any_bag_items() -> bool:
	ensure_bags()
	for member in members:
		if member == null:
			continue
		for slot_v in member.bag:
			if typeof(slot_v) != TYPE_DICTIONARY:
				continue
			var slot: Dictionary = slot_v
			if not String(slot.get("name", "")).is_empty() and int(slot.get("count", 0)) > 0:
				return true
	return false

func _migrate_legacy_inventory_and_equipment_if_needed(legacy_inventory: Dictionary) -> void:
	# New saves store items in per-member bags; old saves only had `inventory` dict and equipment items were not in inventory.
	var has_bag_items: bool = _has_any_bag_items()
	if has_bag_items:
		# Ensure equipment items exist in bag and are flagged equipped.
		_ensure_equipment_items_in_bags()
		_rebuild_inventory_dict()
		return
	# Legacy: distribute inventory into bags.
	if typeof(legacy_inventory) == TYPE_DICTIONARY and not legacy_inventory.is_empty():
		for key in legacy_inventory.keys():
			var item_name: String = String(key)
			var count: int = max(0, int(legacy_inventory.get(key, 0)))
			if item_name.is_empty() or count <= 0:
				continue
			add_item_auto(item_name, count)
	# Also migrate currently equipped items (they used to be "out of inventory").
	_ensure_equipment_items_in_bags()
	_rebuild_inventory_dict()

func _ensure_equipment_items_in_bags() -> void:
	ensure_bags()
	for member in members:
		if member == null:
			continue
		var eq: Dictionary = member.equipment
		for slot in ["weapon", "armor", "accessory"]:
			var item_name: String = String(eq.get(slot, ""))
			if item_name.is_empty():
				# Clear any stale bag flags for this slot.
				_clear_equipped_flag_in_bag(member, slot)
				continue
			var found: int = _find_bag_slot_with_item(member, item_name)
			if found < 0:
				found = _find_first_empty_bag_slot(member)
				if found >= 0:
					member.set_bag_slot(found, {"name": item_name, "count": 1, "equipped_slot": slot})
			else:
				var slot_data: Dictionary = member.get_bag_slot(found)
				slot_data["equipped_slot"] = slot
				member.set_bag_slot(found, slot_data)

func _clear_equipped_flag_in_bag(member: PartyMemberModel, equip_slot: String) -> void:
	if member == null:
		return
	for i in range(member.bag.size()):
		var slot_data: Dictionary = member.get_bag_slot(i)
		if String(slot_data.get("equipped_slot", "")) == equip_slot:
			slot_data.erase("equipped_slot")
			member.set_bag_slot(i, slot_data)

func _find_bag_slot_with_item(member: PartyMemberModel, item_name: String) -> int:
	if member == null:
		return -1
	for i in range(member.bag.size()):
		var slot_data: Dictionary = member.get_bag_slot(i)
		if String(slot_data.get("name", "")) == item_name and int(slot_data.get("count", 0)) > 0:
			return i
	return -1

func _find_first_empty_bag_slot(member: PartyMemberModel) -> int:
	if member == null:
		return -1
	for i in range(member.bag.size()):
		if member.is_bag_slot_empty(i):
			return i
	return -1

func _rebuild_inventory_dict() -> void:
	inventory.clear()
	ensure_bags()
	for member in members:
		if member == null:
			continue
		for slot_v in member.bag:
			if typeof(slot_v) != TYPE_DICTIONARY:
				continue
			var slot: Dictionary = slot_v
			var item_name: String = String(slot.get("name", ""))
			var count: int = int(slot.get("count", 0))
			if item_name.is_empty() or count <= 0:
				continue
			inventory[item_name] = int(inventory.get(item_name, 0)) + count

func summary_lines(max_members: int = 4) -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	for i in range(min(max_members, members.size())):
		var member: PartyMemberModel = members[i]
		lines.append("%s Lv%d HP %d/%d MP %d/%d" % [member.display_name, member.level, member.hp, member.max_hp, member.mp, member.max_mp])
	lines.append("Gold: %d" % gold)
	return lines

func equipment_lines(max_members: int = 4) -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	for i in range(min(max_members, members.size())):
		var member: PartyMemberModel = members[i]
		var weapon: String = String(member.equipment.get("weapon", "None"))
		if weapon.is_empty():
			weapon = "None"
		var armor: String = String(member.equipment.get("armor", "None"))
		if armor.is_empty():
			armor = "None"
		var accessory: String = String(member.equipment.get("accessory", "None"))
		if accessory.is_empty():
			accessory = "None"
		lines.append("%s: Wpn %s | Arm %s | Acc %s" % [member.display_name, weapon, armor, accessory])
	if lines.is_empty():
		lines.append("No party members.")
	return lines

func stat_lines(max_members: int = 4) -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	for i in range(min(max_members, members.size())):
		var member: PartyMemberModel = members[i]
		var bonus: Dictionary = _sum_equipment_bonuses(member)
		var b_str: int = int(bonus.get("strength", 0))
		var b_def: int = int(bonus.get("defense", 0))
		var b_agi: int = int(bonus.get("agility", 0))
		var b_int: int = int(bonus.get("intellect", 0))
		lines.append("%s: STR %s DEF %s AGI %s INT %s" % [
			member.display_name,
			_fmt_stat(member.strength, b_str),
			_fmt_stat(member.defense, b_def),
			_fmt_stat(member.agility, b_agi),
			_fmt_stat(member.intellect, b_int),
		])
	if lines.is_empty():
		lines.append("No party members.")
	return lines

func _fmt_stat(base: int, bonus: int) -> String:
	if bonus == 0:
		return str(base)
	var total: int = base + bonus
	var sign: String = "+" if bonus > 0 else ""
	return "%d(%s%d)" % [total, sign, bonus]

func _sum_equipment_bonuses(member: PartyMemberModel) -> Dictionary:
	var bonus: Dictionary = {
		"strength": 0,
		"defense": 0,
		"agility": 0,
		"intellect": 0,
	}
	if member == null:
		return bonus
	var eq: Dictionary = member.equipment
	for slot in ["weapon", "armor", "accessory"]:
		var item_name: String = String(eq.get(slot, ""))
		if item_name.is_empty():
			continue
		var item_data: Dictionary = ItemCatalog.get_item(item_name)
		var stats: Dictionary = item_data.get("stat_bonuses", {})
		for k in stats.keys():
			var key: String = String(k)
			if bonus.has(key):
				bonus[key] = int(bonus.get(key, 0)) + int(stats.get(k, 0))
	return bonus
