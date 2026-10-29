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
var client: AiClient
var pending_ai_message: MessageBox
var _send_button_text := "Send"
var _send_button_tooltip := ""

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

	# Set up ai client
	client = AiClient.new()
	add_child(client)
	# Prefer an environment variable over hardcoding the key.
	var raw_key := OS.get_environment("MODEL_API_KEY")
	client.api_key = raw_key.strip_edges()
	client.system_prompt = "You are a helpful assistant inside the Godot editor."
	client.response_received.connect(_on_ai_response)
	client.request_failed.connect(_on_ai_error)
	client.streaming = true
	client.stream_updated.connect(_on_ai_stream)
	client.retry_scheduled.connect(_on_ai_retry)
	var custom_url := OS.get_environment("MODEL_API_URL").strip_edges()
	if not custom_url.is_empty():
		client.api_url = custom_url
	print("[GdAI] API endpoint: %s" % client.api_url)
	if client.api_key.is_empty():
		push_warning("[GdAI] MODEL_API_KEY is empty. Set it and fully relaunch the editor (Cmd+Q).")
	else:
		print("[GdAI] MODEL_API_KEY loaded (%s)." % AiClient.fingerprint(raw_key))

	# Remember the send button's scene appearance so cancel mode can restore it.
	_send_button_text = send_button.text
	_send_button_tooltip = send_button.tooltip_text

	# Initial input state: hide send until there is text.
	_on_user_input_box_text_changed()
	_update_input_height.call_deferred()


# Signal for chat button press
func _on_chat_button_pressed() -> void:
	chat_button.button_pressed = true
	chat_menu.visible = true
	history_menu.visible = false


# Signal for user input in TextEdit
func _on_user_input_box_text_changed() -> void:
	_refresh_send_button()


# The send button doubles as a cancel button while a request is in flight.
func _refresh_send_button() -> void:
	if send_button == null or user_input_box == null:
		return
	if client != null and client.busy:
		send_button.visible = true
		send_button.disabled = false
		send_button.text = "Cancel"
		send_button.tooltip_text = "Cancel the in-flight request (Esc)"
	else:
		send_button.text = _send_button_text
		send_button.tooltip_text = _send_button_tooltip
		send_button.visible = not user_input_box.text.strip_edges().is_empty()
		send_button.disabled = false
	_update_input_height.call_deferred()


# Signal to detect keyboard input in TextEdit
func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey \
			and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			# Esc cancels an in-flight request; otherwise let it propagate.
			if client != null and client.busy:
				user_input_box.accept_event()
				_on_cancel_requested()
			return
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			# Stop TextEdit from handling this key itself
			user_input_box.accept_event()

			if event.shift_pressed:
				# Shift+Enter inserts a new line
				user_input_box.insert_text_at_caret("\n")
			else:
				# Enter sends the message
				_on_send_button_pressed()


# Esc cancels an in-flight request when focus is anywhere else inside the dock.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE \
			and client != null and client.busy:
		var focus_owner := get_viewport().gui_get_focus_owner()
		if focus_owner == null or (focus_owner != self and not is_ancestor_of(focus_owner)):
			return
		get_viewport().set_input_as_handled()
		_on_cancel_requested()


# Signal to handle send button press
func _on_send_button_pressed() -> void:
	if client != null and client.busy:
		# The button is in cancel mode while a request is in flight.
		_on_cancel_requested()
		return
	if client == null:
		return
	if user_input_box == null:
		return
	var text := user_input_box.text.strip_edges()
	if text.is_empty():
		return

	if current_chat.is_empty():
		current_chat = ChatStore.new_chat()
	if current_chat.is_empty() or not current_chat.has("messages"):
		return
	var history: Array = current_chat["messages"]
	if not history is Array:
		return

	add_message(text, true)
	_record_message("user", text)
	user_input_box.clear()
	_on_user_input_box_text_changed()
	user_input_box.grab_focus()

	pending_ai_message = add_message("Thinking...", false)
	# Refresh send visibility/disabled now that a request is about to start.
	# client.send sets busy=true on success; update again after in case it failed fast.
	client.send(history)
	_on_user_input_box_text_changed()


# Cancel the in-flight request at the user's request (cancel button or Esc).
func _on_cancel_requested() -> void:
	if client == null or not client.busy:
		return
	client.cancel()
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text("Request cancelled.")
	pending_ai_message = null

	# Keep the user's unanswered turn in history so it stays for context or retry.
	_refresh_send_button()
	if user_input_box != null:
		user_input_box.grab_focus()


# Show backoff status in the pending bubble until the next attempt streams in.
func _on_ai_retry(next_attempt: int, total_attempts: int, delay_sec: float) -> void:
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text("Retrying… (%d/%d, in %.1fs)" % [next_attempt, total_attempts, delay_sec])


# Append streamed chunks into the pending bubble as they arrive.
func _on_ai_stream(full_text: String) -> void:
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text(full_text)


# Set ai response message
func _on_ai_response(text: String) -> void:
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text(text)
	pending_ai_message = null
	if not current_chat.is_empty() and current_chat.has("messages"):
		_record_message("assistant", text)
	_on_user_input_box_text_changed()


# Handle error on ai message
func _on_ai_error(message: String) -> void:
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text("Error: " + message)
	pending_ai_message = null

	# Keep the user's unanswered turn in history so it stays for context or retry.
	_on_user_input_box_text_changed()


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
	if user_input_box == null:
		return
	var lines := clampi(user_input_box.get_total_visible_line_count(), 1, MAX_LINES)
	var line_h := user_input_box.get_line_height() \
		+ user_input_box.get_theme_constant("line_spacing")
	var padding := user_input_box.get_theme_stylebox("normal").get_minimum_size().y
	user_input_box.custom_minimum_size.y = lines * line_h + padding


# Signal for history button press
func _on_history_button_pressed() -> void:
	history_menu.visible = true
	chat_menu.visible = false
	_refresh_history_list()


# Append to the current chat and write it to disk
func _record_message(role: String, content: String) -> void:
	if current_chat.is_empty() or not current_chat.has("messages"):
		return
	var messages = current_chat["messages"]
	if not messages is Array:
		return
	messages.append({"role": role, "content": content})
	if role == "user" and str(current_chat.get("title", "")) == "New chat":
		current_chat["title"] = _make_title(content)
	ChatStore.save_chat(current_chat)


# Make title for chat in history
func _make_title(text: String) -> String:
	var line := text.split("\n")[0].strip_edges()
	return line if line.length() <= 40 else line.substr(0, 40) + "…"


# Clear message list
func _clear_message_list() -> void:
	for child in message_list.get_children():
		message_list.remove_child(child)
		child.queue_free()


func _cancel_pending_request() -> void:
	if client != null and client.busy:
		client.cancel()
	pending_ai_message = null


# Create a new chat
func _on_new_chat_button_pressed() -> void:
	_cancel_pending_request()
	current_chat = {}
	_clear_message_list()
	_on_chat_button_pressed()
	_on_user_input_box_text_changed()
	user_input_box.grab_focus()


# Open the chat from the message history
func _open_chat(id: String) -> void:
	_cancel_pending_request()
	var chat := ChatStore.load_chat(id)
	if chat.is_empty():
		return
	current_chat = chat
	_clear_message_list()
	var messages = chat.get("messages", [])
	if messages is Array:
		for msg in messages:
			if msg is Dictionary:
				add_message(str(msg.get("content", "")), str(msg.get("role", "")) == "user")
	_on_chat_button_pressed()


# Delete chat
func _delete_chat(id: String) -> void:
	ChatStore.delete_chat(id)
	if str(current_chat.get("id", "")) == id:
		_cancel_pending_request()
		current_chat = {}
		_clear_message_list()
	_refresh_history_list()


# Refresh the histor list
func _refresh_history_list() -> void:
	# Iterate through history list and remove children
	for child in history_list.get_children():
		history_list.remove_child(child)
		child.queue_free()

	# Restore chats, update displayed text if no chats found
	var chats := ChatStore.list_chats()
	if chats.is_empty():
		var empty := Label.new()
		empty.text = "No saved chats yet"
		history_list.add_child(empty)
		return

	# Iterate through chats and add them back to the list
	for chat in chats:
		history_list.add_child(_make_history_row(chat))


# Makes the history row node
func _make_history_row(chat: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new() # Create row to store chat button and delete button

	# Create button to open chat
	var open_button := Button.new()
	open_button.text = str(chat.get("title", "Untitled"))
	open_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	open_button.clip_text = true
	open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_button.pressed.connect(_open_chat.bind(str(chat.get("id", ""))))

	# Create delete button
	var delete_button := Button.new()
	delete_button.text = "✕"
	delete_button.pressed.connect(_delete_chat.bind(str(chat.get("id", ""))))

	# Add buttons to row and return row node
	row.add_child(open_button)
	row.add_child(delete_button)
	return row
