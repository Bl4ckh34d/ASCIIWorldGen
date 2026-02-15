extends CanvasLayer
class_name HUD

# Minimal scene-based HUD scaffold for refactor plan M0/M4.

@onready var title_label: Label = %TitleLabel
@onready var metrics_label: Label = %MetricsLabel

func set_title(value: String) -> void:
	if title_label != null:
		title_label.text = value

func set_metrics(lines: PackedStringArray) -> void:
	if metrics_label == null:
		return
	metrics_label.text = "\n".join(lines)
