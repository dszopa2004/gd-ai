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

@export_category("History")
@export var history_list: VBoxContainer
@export var new_chat_button: Button


const MESSAGE_BOX_SCENE := preload("res://addons/GdAI/GdAiDock/MessageBox/MessageBox.tscn")
const BUBBLE_RATIO := 1.0
const SPACER_RATIO := 0.25
const MAX_LINES := 8

var current_chat: Dictionary = {}

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

	new_chat_button.pressed.connect(_on_new_chat_button_pressed)
	_refresh_history_list()


# Signal for chat button press
func _on_chat_button_pressed() -> void:
	chat_button.button_pressed = true
	chat_menu.visible = true
	history_menu.visible = false


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
	
	if current_chat.is_empty():
		current_chat = ChatStore.new_chat()
	
	add_message(text, true)
	_record_message("user", text)
	user_input_box.clear()
	user_input_box.grab_focus()
	
	var ai_message := add_message("", false)

	# Placeholder until the API is hooked up. When the real response finishes,
	# call _record_message("assistant", full_text) once.
	var reply := "AI response goes here"
	ai_message.set_message_text(reply)
	_record_message("assistant", reply)


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


# Signal for history button press
func _on_history_button_pressed() -> void:
	history_menu.visible = true
	chat_menu.visible = false
	_refresh_history_list()


# Append to the current chat and write it to disk
func _record_message(role: String, content: String) -> void:
	current_chat["messages"].append({"role": role, "content": content})
	if role == "user" and current_chat["title"] == "New chat":
		current_chat["title"] = _make_title(content)
	ChatStore.save_chat(current_chat)


func _make_title(text: String) -> String:
	var line := text.split("\n")[0].strip_edges()
	return line if line.length() <= 40 else line.substr(0, 40) + "…"


func _clear_message_list() -> void:
	for child in message_list.get_children():
		message_list.remove_child(child)
		child.queue_free()


func _on_new_chat_button_pressed() -> void:
	current_chat = {}
	_clear_message_list()
	_on_chat_button_pressed()
	user_input_box.grab_focus()


func _open_chat(id: String) -> void:
	var chat := ChatStore.load_chat(id)
	if chat.is_empty():
		return
	current_chat = chat
	_clear_message_list()
	for msg in chat["messages"]:
		add_message(msg["content"], msg["role"] == "user")
	_on_chat_button_pressed()


func _delete_chat(id: String) -> void:
	ChatStore.delete_chat(id)
	if current_chat.get("id", "") == id:
		current_chat = {}
		_clear_message_list()
	_refresh_history_list()


func _refresh_history_list() -> void:
	for child in history_list.get_children():
		history_list.remove_child(child)
		child.queue_free()

	var chats := ChatStore.list_chats()
	if chats.is_empty():
		var empty := Label.new()
		empty.text = "No saved chats yet"
		history_list.add_child(empty)
		return

	for chat in chats:
		history_list.add_child(_make_history_row(chat))


func _make_history_row(chat: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()

	var open_button := Button.new()
	open_button.text = chat["title"]
	open_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	open_button.clip_text = true
	open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_button.pressed.connect(_open_chat.bind(chat["id"]))

	var delete_button := Button.new()
	delete_button.text = "✕"
	delete_button.pressed.connect(_delete_chat.bind(chat["id"]))

	row.add_child(open_button)
	row.add_child(delete_button)
	return row
