@tool
extends Control

@export_category("Tab Buttons")
@export var chat_button: Button
@export var history_button: Button

@export_category("Tab Menus")
@export var chat_menu: Control
@export var history_menu: Control

@export_category("User Input")
@export var chat_scroll: ScrollContainer
@export var message_list: VBoxContainer
@export var user_input_box: TextEdit
@export var send_button: Button

const MESSAGE_BOX_SCENE := preload("res://addons/GdAI/GdAiDock/MessageBox/MessageBox.tscn")
const BUBBLE_RATIO := 1.0
const SPACER_RATIO := 0.25
const MAX_LINES := 8

func _ready() -> void:
	# Tab button signals
	chat_button.pressed.connect(_on_chat_button_pressed)
	history_button.pressed.connect(_on_history_button_pressed)

	# User input section signals
	user_input_box.text_changed.connect(_on_user_input_box_text_changed)
	send_button.pressed.connect(_on_send_button_pressed)
	user_input_box.gui_input.connect(_on_input_gui_input)

	# Keep the view pinned to the most recent message
	var bar := chat_scroll.get_v_scroll_bar()
	bar.changed.connect(func(): chat_scroll.scroll_vertical = int(bar.max_value))


# Signal for chat button press
func _on_chat_button_pressed() -> void:
	chat_menu.visible = true
	history_menu.visible = false


# Signal for history button press
func _on_history_button_pressed() -> void:
	history_menu.visible = true
	chat_menu.visible = false


# Signal for user input in TextEdit
func _on_user_input_box_text_changed() -> void:
	send_button.visible = not user_input_box.text.strip_edges().is_empty()
	_update_input_height.call_deferred()


# Signal to detect keyboard input in TextEdit
func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey \
			and event.pressed and not event.echo \
			and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
		# Stop TextEdit from handling this key itself
		user_input_box.accept_event()
		
		if event.shift_pressed:
			# Shift+Enter inserts a new line
			user_input_box.insert_text_at_caret("\n")
		else:
			# Enter sends the message
			_on_send_button_pressed()


# Signal to handle send button press
func _on_send_button_pressed() -> void:
	var text := user_input_box.text.strip_edges()
	if text.is_empty():
		return

	# Show the user's message
	add_message(text, true)
	user_input_box.clear()
	_update_input_height.call_deferred()
	user_input_box.grab_focus()

	# Create an empty AI message to fill in as the response arrives
	var ai_message := add_message("", false)

	# API call goes here, appending to ai_message as chunks arrive:
	# ai_message.append_message_text(chunk)
	ai_message.set_message_text("AI response goes here")


# Helper function to create a message box
func add_message(text: String, is_user: bool) -> MessageBox:
	var message: MessageBox = MESSAGE_BOX_SCENE.instantiate()
	message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message.size_flags_stretch_ratio = BUBBLE_RATIO
	message.set_message_text(text)
	
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.size_flags_stretch_ratio = SPACER_RATIO
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 0)
	
	# User: spacer on the left pushes the bubble right. AI: the reverse.
	if is_user:
		row.add_child(spacer)
		row.add_child(message)
	else:
		row.add_child(message)
		row.add_child(spacer)
	
	message_list.add_child(row)
	return message # keep this to stream into it


func _update_input_height() -> void:
	var lines := clampi(user_input_box.get_total_visible_line_count(), 1, MAX_LINES)
	var padding := user_input_box.get_theme_stylebox("normal").get_minimum_size().y
	user_input_box.custom_minimum_size.y = lines * user_input_box.get_line_height() + padding
