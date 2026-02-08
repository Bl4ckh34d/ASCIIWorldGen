extends Button
class_name InventorySlotButton

signal slot_selected(member_id: String, slot_idx: int)
signal context_requested(member_id: String, slot_idx: int, global_pos: Vector2)

var member_id: String = ""
var slot_idx: int = -1
var slot_data: Dictionary = {}

func configure(new_member_id: String, new_slot_idx: int, new_slot_data: Dictionary) -> void:
	member_id = String(new_member_id)
	slot_idx = int(new_slot_idx)
	slot_data = new_slot_data.duplicate(true)
	_update_visual()

func _ready() -> void:
	toggle_mode = true
	clip_text = true
	custom_minimum_size = Vector2(64, 64)

func _pressed() -> void:
	emit_signal("slot_selected", member_id, slot_idx)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		emit_signal("context_requested", member_id, slot_idx, get_global_mouse_position())
		var vp: Viewport = get_viewport()
		if vp:
			vp.set_input_as_handled()

func _update_visual() -> void:
	var name: String = String(slot_data.get("name", ""))
	var count: int = int(slot_data.get("count", 0))
	var eq: String = String(slot_data.get("equipped_slot", ""))
	if name.is_empty() or count <= 0:
		text = ""
		tooltip_text = ""
		modulate = Color(1, 1, 1, 0.85)
		return
	var short_name: String = name
	if short_name.length() > 12:
		short_name = short_name.substr(0, 11) + "."
	var bottom: String = ""
	if count > 1:
		bottom = "x%d" % count
	elif not eq.is_empty():
		bottom = eq.left(1).to_upper()
	text = short_name if bottom.is_empty() else ("%s\n%s" % [short_name, bottom])
	tooltip_text = "%s%s" % [name, (" (Equipped: %s)" % eq) if not eq.is_empty() else ""]
	modulate = Color(1.0, 0.98, 0.85, 1.0) if not eq.is_empty() else Color(1, 1, 1, 1)

func _get_drag_data(_at_position: Vector2) -> Variant:
	var name: String = String(slot_data.get("name", ""))
	var count: int = int(slot_data.get("count", 0))
	if name.is_empty() or count <= 0:
		return null
	var preview := Label.new()
	preview.text = name
	preview.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	set_drag_preview(preview)
	return {
		"from_member_id": member_id,
		"from_idx": slot_idx,
	}

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data
	return d.has("from_member_id") and d.has("from_idx")

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var d: Dictionary = data
	var from_id: String = String(d.get("from_member_id", ""))
	var from_idx: int = int(d.get("from_idx", -1))
	var gs: Node = get_node_or_null("/root/GameState")
	if gs == null or not gs.has_method("move_bag_item"):
		return
	gs.move_bag_item(from_id, from_idx, member_id, slot_idx)
