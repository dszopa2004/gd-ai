extends Control

@onready var start_button: Button = $CenterContainer/VBoxContainer/StartButton
@onready var options_button: Button = $CenterContainer/VBoxContainer/OptionsButton


# Connect button signals when ready.
func _ready() -> void:
	start_button.pressed.connect(_on_start_button_pressed)
	options_button.pressed.connect(_on_options_button_pressed)


# Handle Start button press.
func _on_start_button_pressed() -> void:
	print("Starting game")


# Handle Options button press.
func _on_options_button_pressed() -> void:
	print("opening options")
