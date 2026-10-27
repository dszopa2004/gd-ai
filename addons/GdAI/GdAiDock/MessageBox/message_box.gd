@tool
class_name MessageBox
extends PanelContainer

@export var label: RichTextLabel

var _pending_text := ""


func _ready() -> void:
	label.text = _pending_text


func set_message_text(text: String) -> void:
	_pending_text = text
	if label != null:
		label.text = text


func append_message_text(chunk: String) -> void:
	_pending_text += chunk
	if label != null:
		label.append_text(chunk)
