extends Node
class_name SettingsPanelController

# Manages world settings panel visibility and the floating "Show Settings" button.

var _owner_control: Control = null
var _bottom_panel: PanelContainer = null
var _settings_button: Button = null
var _hide_button: Button = null
var _floating_show_button: Button = null
var _panel_hidden: bool = false

func initialize(owner_control: Control, bottom_panel: PanelContainer, settings_button: Button, hide_button: Button) -> void:
	_owner_control = owner_control
	_bottom_panel = bottom_panel
	_settings_button = settings_button
	_hide_button = hide_button
	_panel_hidden = _bottom_panel != null and not _bottom_panel.visible
	_apply_visibility_state()

func cleanup() -> void:
	_remove_floating_show_button()
	_owner_control = null
	_bottom_panel = null
	_settings_button = null
	_hide_button = null

func is_panel_hidden() -> bool:
	return _panel_hidden

func set_panel_hidden(hidden: bool) -> void:
	var next_hidden: bool = hidden
	if next_hidden == _panel_hidden:
		# Keep labels/buttons coherent even when state is unchanged.
		_apply_visibility_state()
		return
	_panel_hidden = next_hidden
	_apply_visibility_state()

func toggle_panel() -> void:
	set_panel_hidden(not _panel_hidden)

func on_viewport_resized() -> void:
	if _floating_show_button != null and _floating_show_button.visible:
		_position_floating_button()

func _apply_visibility_state() -> void:
	if _bottom_panel != null:
		if _panel_hidden:
			_bottom_panel.hide()
		else:
			_bottom_panel.show()

	if _hide_button != null:
		_hide_button.text = "Show Panel" if _panel_hidden else "Hide Panel"
	if _settings_button != null:
		_settings_button.text = "Show Settings" if _panel_hidden else "Hide Settings"

	if _panel_hidden:
		_create_floating_show_button()
	else:
		_remove_floating_show_button()

func _create_floating_show_button() -> void:
	if _owner_control == null or _floating_show_button != null:
		return
	_floating_show_button = Button.new()
	_floating_show_button.text = "Show Settings"
	_floating_show_button.z_index = 100
	_floating_show_button.pressed.connect(_on_floating_show_pressed)
	_owner_control.add_child(_floating_show_button)
	_position_floating_button()

func _remove_floating_show_button() -> void:
	if _floating_show_button == null:
		return
	_floating_show_button.queue_free()
	_floating_show_button = null

func _position_floating_button() -> void:
	if _floating_show_button == null:
		return
	var viewport_size: Vector2 = _owner_control.get_viewport().get_visible_rect().size if _owner_control != null else Vector2.ZERO
	var button_size: Vector2 = _floating_show_button.size
	if button_size == Vector2.ZERO:
		button_size = _floating_show_button.get_combined_minimum_size()
	if button_size == Vector2.ZERO:
		button_size = Vector2(120.0, 30.0)
	_floating_show_button.position = Vector2(
		viewport_size.x - button_size.x - 10.0,
		viewport_size.y - button_size.y - 10.0
	)

func _on_floating_show_pressed() -> void:
	toggle_panel()
