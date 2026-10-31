extends Control

func _ready() -> void:
	$"Test Button".pressed.connect(_on_test_button_pressed)

func _on_test_button_pressed() -> void:
	print("Hello World!")
