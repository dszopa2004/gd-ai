extends Control

func _ready() -> void:
	$MenuContainer/VBox/StartButton.pressed.connect(_on_start_button_pressed)
	$MenuContainer/VBox/OptionsButton.pressed.connect(_on_options_button_pressed)

func _on_start_button_pressed() -> void:
	print("Starting game")

func _on_options_button_pressed() -> void:
	print("opening options")
