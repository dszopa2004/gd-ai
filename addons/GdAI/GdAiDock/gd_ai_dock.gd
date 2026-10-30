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

@export_category("Settings")
@export var settings_button: Button
@export var settings_dialog: AcceptDialog
@export var api_key_field: LineEdit
@export var endpoint_field: LineEdit
@export var model_picker: OptionButton


const MESSAGE_BOX_SCENE := preload("res://addons/GdAI/GdAiDock/MessageBox/MessageBox.tscn")
const BUBBLE_RATIO := 1.0
const SPACER_RATIO := 0.25
const MAX_LINES := 8
const TREE_NODE_BUDGET := 60
const TREE_DEPTH_BUDGET := 8
const SELECTION_BUDGET := 8

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
	client.system_prompt = "You are a helpful assistant inside the Godot editor."
	client.response_received.connect(_on_ai_response)
	client.request_failed.connect(_on_ai_error)
	client.streaming = true
	client.stream_updated.connect(_on_ai_stream)
	client.retry_scheduled.connect(_on_ai_retry)
	# Declare editor actions; the model may answer with structured calls,
	# rendered as text until Phase 2 executes them.
	client.tools = AiClient.default_tools() # Set to [] to use less tokens by not using tools
	client.tool_calls_received.connect(_on_ai_tool_calls)
	client.load_config()
	_setup_settings_ui()

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

	# Fresh editor snapshot for this request (never stored in history).
	client.context_prompt = _build_editor_context()
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


# Render structured actions as text until Phase 2 executes them.
func _on_ai_tool_calls(calls: Array, preamble: String) -> void:
	var lines: Array[String] = []
	if not preamble.strip_edges().is_empty():
		lines.append(preamble.strip_edges())
	lines.append("Planned actions (not executed yet):")
	for call in calls:
		if call is Dictionary:
			lines.append("• %s %s" % [str(call.get("name", "?")), JSON.stringify(call.get("arguments", {}))])
	var rendered := "\n".join(lines)
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text(rendered)
	pending_ai_message = null
	if not current_chat.is_empty() and current_chat.has("messages"):
		_record_message("assistant", rendered)
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
# Snapshot of editor state for the next request. Never stored in chat history.
func _build_editor_context() -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return "[Editor context]\nNo scene is currently open in the editor."
	var lines: Array[String] = []
	lines.append("[Editor context]")
	var scene_path := root.scene_file_path
	if scene_path.is_empty():
		scene_path = "(unsaved scene)"
	lines.append("Scene: %s (root: %s, %s)" % [scene_path, root.name, root.get_class()])
	var open_scenes = EditorInterface.get_open_scenes()
	if open_scenes.size() > 1:
		lines.append("Open scenes: %d" % open_scenes.size())
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if not selected.is_empty():
		var shown: Array[String] = []
		for i in mini(selected.size(), SELECTION_BUDGET):
			var node: Node = selected[i]
			shown.append("%s (%s)" % [_scene_rel_path(root, node), node.get_class()])
		var extra := selected.size() - shown.size()
		if extra > 0:
			shown.append("+%d more" % extra)
		lines.append("Selected: %s" % ", ".join(shown))
	lines.append("Tree:")
	var shown_count := 0
	var truncated := false
	var stack: Array = [[root, 0]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var node: Node = entry[0]
		var depth: int = entry[1]
		if depth > TREE_DEPTH_BUDGET or shown_count >= TREE_NODE_BUDGET:
			truncated = true
			continue
		lines.append("%s%s (%s)" % ["  ".repeat(depth), node.name, node.get_class()])
		shown_count += 1
		var children := node.get_children()
		for i in range(children.size() - 1, -1, -1):
			stack.append([children[i], depth + 1])
	if truncated:
		lines.append("… (tree truncated to %d nodes, depth %d)" % [TREE_NODE_BUDGET, TREE_DEPTH_BUDGET])
	return "\n".join(lines)


func _scene_rel_path(root: Node, node: Node) -> String:
	if node == root:
		return "."
	if root.is_ancestor_of(node):
		return str(root.get_path_to(node))
	return str(node.get_path())


const MODEL_OPTIONS := ["muse-spark-1.3", "muse-spark-1.3-contributor", "muse-spark-1.2", "muse-spark-1.1"]


func _setup_settings_ui() -> void:
	if settings_button != null:
		settings_button.pressed.connect(_on_settings_opened)
	else:
		push_warning("[GdAI] Settings button export is unassigned.")
	if model_picker != null and model_picker.item_count == 0:
		for option in MODEL_OPTIONS:
			model_picker.add_item(option)
	if settings_dialog != null:
		settings_dialog.confirmed.connect(_on_settings_saved)
	else:
		push_warning("[GdAI] Settings dialog export is unassigned.")
	if api_key_field == null or endpoint_field == null or model_picker == null:
		push_warning("[GdAI] One or more settings field exports are unassigned.")


func _on_settings_opened() -> void:
	if settings_dialog == null or client == null:
		return
	if api_key_field != null:
		api_key_field.text = client.api_key
	if endpoint_field != null:
		endpoint_field.text = client.api_url
	_select_model(client.model)
	settings_dialog.popup_centered()


func _select_model(model_name: String) -> void:
	if model_picker == null:
		return
	var idx := -1
	for i in model_picker.item_count:
		if model_picker.get_item_text(i) == model_name:
			idx = i
			break
	if idx == -1 and not model_name.strip_edges().is_empty():
		model_picker.add_item(model_name.strip_edges())
		idx = model_picker.item_count - 1
	if idx != -1:
		model_picker.select(idx)


func _on_settings_saved() -> void:
	if client == null:
		return
	if api_key_field != null:
		client.api_key = api_key_field.text.strip_edges()
	if endpoint_field != null:
		client.api_url = endpoint_field.text.strip_edges()
	if model_picker != null and model_picker.selected >= 0:
		var picked := model_picker.get_item_text(model_picker.selected).strip_edges()
		if not picked.is_empty():
			client.model = picked
	client.save_config()
	client.load_config()


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
