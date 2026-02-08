extends Control
class_name StatBar

# Lightweight HP/MP bar for menus (color changes by fullness).

@export var kind: String = "hp" # "hp" | "mp"
@export var value: int = 0
@export var max_value: int = 1

func _init() -> void:
	custom_minimum_size = Vector2(120, 10)

func set_values(new_value: int, new_max: int, new_kind: String = "") -> void:
	value = max(0, int(new_value))
	max_value = max(1, int(new_max))
	if not new_kind.is_empty():
		kind = String(new_kind)
	queue_redraw()

func _get_fill_color(ratio: float) -> Color:
	ratio = clamp(ratio, 0.0, 1.0)
	if kind == "mp":
		var full := Color(0.20, 0.55, 1.00, 1.0)
		var pale := Color(0.82, 0.90, 1.00, 1.0)
		return pale.lerp(full, ratio)
	# HP default: green -> yellow -> red as HP decreases.
	var green := Color(0.25, 0.90, 0.25, 1.0)
	var yellow := Color(0.95, 0.85, 0.25, 1.0)
	var red := Color(0.95, 0.25, 0.25, 1.0)
	if ratio >= 0.5:
		return yellow.lerp(green, (ratio - 0.5) / 0.5)
	return red.lerp(yellow, ratio / 0.5)

func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.10, 0.10, 0.10, 0.85), true)
	draw_rect(rect, Color(0.00, 0.00, 0.00, 1.0), false, 1.0)
	var ratio: float = float(value) / float(max_value) if max_value > 0 else 0.0
	var fill_w: float = rect.size.x * clamp(ratio, 0.0, 1.0)
	if fill_w <= 0.5:
		return
	var fill := Rect2(rect.position + Vector2(1, 1), Vector2(fill_w - 2.0, rect.size.y - 2.0))
	draw_rect(fill, _get_fill_color(ratio), true)

