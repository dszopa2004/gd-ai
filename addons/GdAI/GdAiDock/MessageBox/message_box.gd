@tool
class_name MessageBox
extends PanelContainer

@export var label: RichTextLabel
@export var copy_button: BaseButton # Button or TextureButton

const COPY_TOOLTIP := "Copy response"
const COPY_MODULATE_NORMAL := Color.WHITE
const COPY_MODULATE_HOVER := Color(1.25, 1.25, 1.25)
const COPY_MODULATE_PRESSED := Color(0.75, 0.75, 0.75)

var _pending_text := ""
var _copy_visible := false
var _copy_hover := false
var _flat := false
var _flat_style := StyleBoxEmpty.new()


func _ready() -> void:
	label.text = _pending_text
	if copy_button != null:
		copy_button.tooltip_text = COPY_TOOLTIP
		copy_button.pressed.connect(_on_copy_pressed)
		copy_button.mouse_entered.connect(_on_copy_mouse_entered)
		copy_button.mouse_exited.connect(_on_copy_mouse_exited)
		copy_button.button_down.connect(_on_copy_button_down)
		copy_button.button_up.connect(_on_copy_button_up)
	_apply_flat() # set_flat may have run before exports resolved
	_apply_copy_visibility()


func set_message_text(text: String) -> void:
	_pending_text = text
	if label != null:
		label.text = text
	if copy_button != null:
		copy_button.tooltip_text = COPY_TOOLTIP


func append_message_text(chunk: String) -> void:
	_pending_text += chunk
	if label != null:
		label.append_text(chunk)


# Flat mode drops the bubble background (AI flow): the panel stylebox plus the
# label's own normal/focus backgrounds. The MarginContainer keeps text
# padding. Non-flat restores the themed bubble (user messages).
func set_flat(flat: bool) -> void:
	_flat = flat
	_apply_flat()


func _apply_flat() -> void:
	if _flat:
		add_theme_stylebox_override("panel", _flat_style)
		if label != null:
			label.add_theme_stylebox_override("normal", _flat_style)
			label.add_theme_stylebox_override("focus", _flat_style)
	else:
		remove_theme_stylebox_override("panel")
		if label != null:
			label.remove_theme_stylebox_override("normal")
			label.remove_theme_stylebox_override("focus")


func is_flat() -> bool:
	return _flat


# Copy button shows on AI responses only; null-safe until the scene wires it.
func set_copy_visible(v: bool) -> void:
	_copy_visible = v
	_apply_copy_visibility()


func _apply_copy_visibility() -> void:
	if copy_button == null:
		return
	copy_button.visible = _copy_visible


func is_copy_visible() -> bool:
	return _copy_visible


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(_pending_text)
	if copy_button != null:
		copy_button.tooltip_text = "Copied!"


# Hover/press feedback without extra textures: brighten on hover, dim while
# held. All four signals pass 0 args, matching these handlers.
func _on_copy_mouse_entered() -> void:
	_copy_hover = true
	_refresh_copy_modulate(false)


func _on_copy_mouse_exited() -> void:
	_copy_hover = false
	_refresh_copy_modulate(false)


func _on_copy_button_down() -> void:
	_refresh_copy_modulate(true)


func _on_copy_button_up() -> void:
	_refresh_copy_modulate(false)


func _refresh_copy_modulate(pressed: bool) -> void:
	if copy_button == null:
		return
	if pressed:
		copy_button.modulate = COPY_MODULATE_PRESSED
	elif _copy_hover:
		copy_button.modulate = COPY_MODULATE_HOVER
	else:
		copy_button.modulate = COPY_MODULATE_NORMAL
