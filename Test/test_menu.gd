extends Control

@onready var start_button: Button = $CenterContainer/VBoxContainer/StartButton
@onready var options_button: Button = $CenterContainer/VBoxContainer/OptionsButton


# Called when the menu scene is ready. Connects button signals to their handlers.
func _ready() -> void:
	start_button.pressed.connect(_on_start_button_pressed)
	options_button.pressed.connect(_on_options_button_pressed)


# Handles the Start button press. Starts the game.
func _on_start_button_pressed() -> void:
	print("Starting game")


# Handles the Options button press. Opens the options menu.
func _on_options_button_pressed() -> void:
	print("opening options")
