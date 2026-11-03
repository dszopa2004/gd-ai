@tool
class_name MessageBox
extends PanelContainer

@export var label: RichTextLabel

var _pending_text := ""
var _flat := false
var _flat_style := StyleBoxEmpty.new()


func _ready() -> void:
	label.text = _pending_text
	_apply_flat() # set_flat may have run before label resolved


func set_message_text(text: String) -> void:
	_pending_text = text
	if label != null:
		label.text = text


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
