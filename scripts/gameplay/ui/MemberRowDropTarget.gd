extends PanelContainer
class_name MemberRowDropTarget

signal item_dropped(target_member_id: String, drag_data: Dictionary)

var member_id: String = ""

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if member_id.is_empty():
		return false
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data
	return d.has("from_member_id") and d.has("from_idx")

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	emit_signal("item_dropped", member_id, data)

