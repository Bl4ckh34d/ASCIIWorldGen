extends RefCounted
class_name QuestStateModel

enum QuestStatus {
	ACTIVE,
	COMPLETED,
	FAILED,
}

var quests: Dictionary = {}

func reset_defaults() -> void:
	quests.clear()
	quests["quest_first_steps"] = {
		"title": "First Steps",
		"status": QuestStatus.ACTIVE,
		"notes": "Explore the surrounding region and survive a battle.",
	}

func ensure_default_quests() -> void:
	if quests.is_empty():
		reset_defaults()

func set_status(quest_id: String, status_value: int) -> void:
	if not quests.has(quest_id):
		return
	var q: Dictionary = quests[quest_id]
	q["status"] = clamp(int(status_value), QuestStatus.ACTIVE, QuestStatus.FAILED)
	quests[quest_id] = q

func add_or_update_quest(quest_id: String, title: String, notes: String, status_value: int = QuestStatus.ACTIVE) -> void:
	if quest_id.is_empty():
		return
	quests[quest_id] = {
		"title": title,
		"notes": notes,
		"status": clamp(int(status_value), QuestStatus.ACTIVE, QuestStatus.FAILED),
	}

func to_dict() -> Dictionary:
	return {
		"quests": quests.duplicate(true),
	}

static func from_dict(data: Dictionary) -> QuestStateModel:
	var out := QuestStateModel.new()
	out.quests = data.get("quests", {}).duplicate(true)
	out.ensure_default_quests()
	return out

func summary_lines(max_lines: int = 12) -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	for quest_id in quests.keys():
		var q: Dictionary = quests[quest_id]
		var status_text: String = _status_to_text(int(q.get("status", QuestStatus.ACTIVE)))
		lines.append("[%s] %s" % [status_text, String(q.get("title", quest_id))])
		if lines.size() >= max_lines:
			break
	if lines.is_empty():
		lines.append("No quests.")
	return lines

func _status_to_text(v: int) -> String:
	match v:
		QuestStatus.ACTIVE:
			return "Active"
		QuestStatus.COMPLETED:
			return "Done"
		QuestStatus.FAILED:
			return "Failed"
		_:
			return "Unknown"
