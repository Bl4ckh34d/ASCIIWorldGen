# File: res://scripts/SettingsDialog.gd
extends AcceptDialog
class_name SettingsDialog

signal apply_requested(patch: Dictionary)
signal cancel_requested

@export var encounter_slider_path: NodePath = NodePath("Root/EncounterSlider")
@export var encounter_value_label_path: NodePath = NodePath("Root/EncounterValue")
@export var text_speed_slider_path: NodePath = NodePath("Root/TextSpeedSlider")
@export var text_speed_value_label_path: NodePath = NodePath("Root/TextSpeedValue")
@export var auto_battle_check_path: NodePath = NodePath("Root/AutoBattleCheck")
@export var apply_button_path: NodePath = NodePath("Root/ApplyButton")

const ENCOUNTER_MIN: float = 0.10
const ENCOUNTER_MAX: float = 2.00
const TEXT_SPEED_MIN: float = 0.50
const TEXT_SPEED_MAX: float = 2.00

var _encounter_slider: HSlider = null
var _encounter_value_label: Label = null
var _text_speed_slider: HSlider = null
var _text_speed_value_label: Label = null
var _auto_battle_check: CheckBox = null
var _apply_button: Button = null

func _ready() -> void:
	_encounter_slider = _resolve_hslider(encounter_slider_path, "encounter_slider")
	_encounter_value_label = _resolve_label(encounter_value_label_path, "encounter_value_label")
	_text_speed_slider = _resolve_hslider(text_speed_slider_path, "text_speed_slider")
	_text_speed_value_label = _resolve_label(text_speed_value_label_path, "text_speed_value_label")
	_auto_battle_check = _resolve_checkbox(auto_battle_check_path, "auto_battle_check")
	_apply_button = _resolve_button(apply_button_path, "apply_button")

	_configure_slider_bounds()
	_wire_signals()
	_refresh_value_labels()

func set_settings(data: Dictionary) -> void:
	_set_slider_value(_encounter_slider, _sanitize_encounter(float(data.get("encounter_rate_multiplier", 1.0))))
	_set_slider_value(_text_speed_slider, _sanitize_text_speed(float(data.get("text_speed", 1.0))))
	if _auto_battle_check != null:
		_auto_battle_check.button_pressed = VariantCasts.to_bool(data.get("auto_battle_enabled", false))
	_refresh_value_labels()

func build_patch() -> Dictionary:
	return {
		"encounter_rate_multiplier": _sanitize_encounter(_slider_value(_encounter_slider, 1.0)),
		"text_speed": _sanitize_text_speed(_slider_value(_text_speed_slider, 1.0)),
		"auto_battle_enabled": _auto_battle_check.button_pressed if _auto_battle_check != null else false,
	}

func _wire_signals() -> void:
	if _encounter_slider != null and not _encounter_slider.value_changed.is_connected(_on_slider_changed):
		_encounter_slider.value_changed.connect(_on_slider_changed)
	if _text_speed_slider != null and not _text_speed_slider.value_changed.is_connected(_on_slider_changed):
		_text_speed_slider.value_changed.connect(_on_slider_changed)
	if _apply_button != null and not _apply_button.pressed.is_connected(_on_apply_pressed):
		_apply_button.pressed.connect(_on_apply_pressed)
	if not confirmed.is_connected(_on_confirmed):
		confirmed.connect(_on_confirmed)
	if not canceled.is_connected(_on_canceled):
		canceled.connect(_on_canceled)

func _configure_slider_bounds() -> void:
	if _encounter_slider != null:
		_encounter_slider.min_value = ENCOUNTER_MIN
		_encounter_slider.max_value = ENCOUNTER_MAX
		_encounter_slider.step = 0.01
	if _text_speed_slider != null:
		_text_speed_slider.min_value = TEXT_SPEED_MIN
		_text_speed_slider.max_value = TEXT_SPEED_MAX
		_text_speed_slider.step = 0.01

func _on_slider_changed(_value: float) -> void:
	_refresh_value_labels()

func _refresh_value_labels() -> void:
	if _encounter_value_label != null:
		_encounter_value_label.text = "x%.2f" % _sanitize_encounter(_slider_value(_encounter_slider, 1.0))
	if _text_speed_value_label != null:
		_text_speed_value_label.text = "x%.2f" % _sanitize_text_speed(_slider_value(_text_speed_slider, 1.0))

func _on_apply_pressed() -> void:
	_on_confirmed()

func _on_confirmed() -> void:
	emit_signal("apply_requested", build_patch())

func _on_canceled() -> void:
	emit_signal("cancel_requested")

func _sanitize_encounter(v: float) -> float:
	if is_nan(v) or is_inf(v):
		return 1.0
	return clamp(v, ENCOUNTER_MIN, ENCOUNTER_MAX)

func _sanitize_text_speed(v: float) -> float:
	if is_nan(v) or is_inf(v):
		return 1.0
	return clamp(v, TEXT_SPEED_MIN, TEXT_SPEED_MAX)

func _slider_value(slider: HSlider, fallback: float) -> float:
	if slider == null:
		return fallback
	return float(slider.value)

func _set_slider_value(slider: HSlider, value: float) -> void:
	if slider == null:
		return
	slider.set_block_signals(true)
	slider.value = value
	slider.set_block_signals(false)

func _resolve_hslider(path: NodePath, id: String) -> HSlider:
	var node: Node = get_node_or_null(path)
	if node == null:
		push_warning("SettingsDialog: Missing node for %s at path '%s'." % [id, str(path)])
		return null
	if node is HSlider:
		return node as HSlider
	push_warning("SettingsDialog: Node '%s' is not an HSlider." % id)
	return null

func _resolve_label(path: NodePath, id: String) -> Label:
	var node: Node = get_node_or_null(path)
	if node == null:
		push_warning("SettingsDialog: Missing node for %s at path '%s'." % [id, str(path)])
		return null
	if node is Label:
		return node as Label
	push_warning("SettingsDialog: Node '%s' is not a Label." % id)
	return null

func _resolve_checkbox(path: NodePath, id: String) -> CheckBox:
	var node: Node = get_node_or_null(path)
	if node == null:
		push_warning("SettingsDialog: Missing node for %s at path '%s'." % [id, str(path)])
		return null
	if node is CheckBox:
		return node as CheckBox
	push_warning("SettingsDialog: Node '%s' is not a CheckBox." % id)
	return null

func _resolve_button(path: NodePath, id: String) -> Button:
	var node: Node = get_node_or_null(path)
	if node == null:
		push_warning("SettingsDialog: Missing node for %s at path '%s'." % [id, str(path)])
		return null
	if node is Button:
		return node as Button
	push_warning("SettingsDialog: Node '%s' is not a Button." % id)
	return null
