@tool
extends PanelContainer

@export var _label : RichTextLabel

var _pending_text : String

func _ready() -> void:
  _label.text = _pending_text


func set_message_text(text : String) -> void:
  _pending_text = text
  if _label is not null:
    label.text = text

func append_message_text(chunk : String) -> void:
  _pending_text += chunk;
  if _label is not null:
    _label.append_text(chunk)
