@tool
extends Control

@export_category("Tab Buttons")
@export var chat_button: Button
@export var history_button: Button
@export var settings_button: Button

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
@export var settings_menu: Control
@export var settings_save_button: Button
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
# Control.LayoutMode enum values (the enum itself is not exposed to scripts; verified on 4.6).
const LAYOUT_MODE_POSITION := 0
const LAYOUT_MODE_ANCHORS := 1

var current_chat: Dictionary = {}
var client: AiClient
var pending_ai_message: MessageBox
var _send_button_text := "Send"
var _send_button_tooltip := ""
var auto_execute := true # Phase 2: run validated calls immediately (until Approval UI gates them)

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
	client.system_prompt = "You are a helpful assistant inside the Godot editor. Node paths are relative to the edited scene root; use \".\" to target the root itself. Emit at most one action per response; if asked for several things, do the first and briefly say what remains."
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
	if settings_menu != null:
		settings_menu.visible = false


# Signal for user input in TextEdit
func _on_user_input_box_text_changed() -> void:
	_refresh_send_button()


# Cancel stays available while a reply is outstanding, even if the client
# is no longer busy (stuck bubble), so the UI is always recoverable.
func _can_cancel() -> bool:
	if client == null:
		return false
	return client.busy or pending_ai_message != null


# The send button doubles as a cancel button while a request is in flight.
func _refresh_send_button() -> void:
	if send_button == null or user_input_box == null:
		return
	if _can_cancel():
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
			if _can_cancel():
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
			and _can_cancel():
		var focus_owner := get_viewport().gui_get_focus_owner()
		if focus_owner == null or (focus_owner != self and not is_ancestor_of(focus_owner)):
			return
		get_viewport().set_input_as_handled()
		_on_cancel_requested()


# Signal to handle send button press
func _on_send_button_pressed() -> void:
	if _can_cancel():
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
	print("[GdAI] Sending: stream=%s tools=%d history=%d." % [client.streaming, client.tools.size(), history.size()])
	# Refresh send visibility/disabled now that a request is about to start.
	# client.send sets busy=true on success; update again after in case it failed fast.
	client.send(history)
	_on_user_input_box_text_changed()


# Cancel the in-flight request at the user's request (cancel button or Esc).
# Also recovers a stuck bubble when no request is actually active.
func _on_cancel_requested() -> void:
	if client == null:
		return
	if client.busy:
		client.cancel()
	elif pending_ai_message == null:
		return
	else:
		print("[GdAI] Cleared stuck reply UI (no request was active).")
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
	lines.append("Planned actions:")
	for call in calls:
		if call is Dictionary:
			lines.append("• %s %s" % [str(call.get("name", "?")), JSON.stringify(call.get("arguments", {}))])
	if auto_execute and not calls.is_empty():
		lines.append("Results:")
		for result in execute_tool_calls(calls):
			var mark := "✓" if bool(result.get("ok", false)) else "✗"
			lines.append("%s %s: %s" % [mark, str(result.get("name", "?")), str(result.get("message", ""))])
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
	settings_menu.visible = false
	if settings_menu != null:
		settings_menu.visible = false
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
	lines.append("Paths are relative to the scene root; use \".\" for the root itself.")
	lines.append("Tree:")
	var shown_count := 0
	var truncated := false
	var saw_container := false
	var stack: Array = [[root, 0]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var node: Node = entry[0]
		var depth: int = entry[1]
		if depth > TREE_DEPTH_BUDGET or shown_count >= TREE_NODE_BUDGET:
			truncated = true
			continue
		var tag := ""
		if node is Container:
			tag = " [container]"
			saw_container = true
		lines.append("%s%s (%s)%s" % ["  ".repeat(depth), node.name, node.get_class(), tag])
		shown_count += 1
		var children := node.get_children()
		for i in range(children.size() - 1, -1, -1):
			stack.append([children[i], depth + 1])
	if truncated:
		lines.append("… (tree truncated to %d nodes, depth %d)" % [TREE_NODE_BUDGET, TREE_DEPTH_BUDGET])
	if saw_container:
		lines.append("[container] arranges its children itself: anchors/offsets are ignored — center children with size_flags_horizontal/vertical = 4 (SHRINK_CENTER).")
	return "\n".join(lines)


static func _find_unique_named(root: Node, node_name: String):
	var matches := root.find_children(node_name, "", true, true)
	if matches.size() == 1:
		return matches[0]
	return null


func _scene_rel_path(root: Node, node: Node) -> String:
	if node == root:
		return "."
	if root.is_ancestor_of(node):
		return str(root.get_path_to(node))
	return str(node.get_path())


const MODEL_OPTIONS := ["muse-spark-1.3", "muse-spark-1.3-contributor", "muse-spark-1.2", "muse-spark-1.1"]


# Set up settings UI
func _setup_settings_ui() -> void:
	if settings_button != null:
		settings_button.pressed.connect(_on_settings_button_pressed)
	else:
		push_warning("[GdAI] Settings button export is unassigned.")
	if model_picker != null and model_picker.item_count == 0:
		for option in MODEL_OPTIONS:
			model_picker.add_item(option)
	if settings_save_button != null:
		settings_save_button.pressed.connect(_on_settings_saved)
	else:
		push_warning("[GdAI] Settings save button export is unassigned.")
	if settings_menu == null:
		push_warning("[GdAI] Settings menu export is unassigned.")
	if api_key_field == null or endpoint_field == null or model_picker == null:
		push_warning("[GdAI] One or more settings field exports are unassigned.")
	_sync_settings_fields()


# Handle settings button press
func _on_settings_button_pressed() -> void:
	settings_menu.visible = true
	history_menu.visible = false
	chat_menu.visible = false
	
	if settings_menu == null:
		push_warning("[GdAI] Settings menu export is unassigned.")
		return
	settings_button.button_pressed = true
	settings_menu.visible = true
	chat_menu.visible = false
	history_menu.visible = false
	_sync_settings_fields()


# Sync setting fields
func _sync_settings_fields() -> void:
	if client == null:
		return
	if api_key_field != null:
		api_key_field.text = client.api_key
	if endpoint_field != null:
		endpoint_field.text = client.api_url
	_select_model(client.model)


# Select model
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


# Save settings
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


# Set title
# Phase 2 execution: runs validated tool calls through the Editor API so every
# change is a separate undoable action. Continues past failures.
# Returns per-call {"name", "ok", "message"} dicts.
func execute_tool_calls(calls: Array) -> Array:
	var results: Array = []
	for call in calls:
		if not call is Dictionary:
			results.append({"name": "?", "ok": false, "message": "call is not an object"})
			continue
		results.append(_execute_tool_call(call))
	return results


func _execute_tool_call(call: Dictionary) -> Dictionary:
	var fname := str(call.get("name", ""))
	var args = call.get("arguments", {})
	if client == null:
		return {"name": fname, "ok": false, "message": "client not ready"}
	if not args is Dictionary:
		return {"name": fname, "ok": false, "message": "arguments must be an object"}
	# Re-validate at execution time: never trust a stale or hand-built call.
	var problem := AiClient.validate_tool_call(client.tools, fname, args)
	if not problem.is_empty():
		return {"name": fname, "ok": false, "message": "invalid: " + problem}
	var outcome := {"ok": false, "message": "unknown action '%s'" % fname}
	match fname:
		"create_node":
			outcome = _op_create_node(args)
		"delete_node":
			outcome = _op_delete_node(args)
		"rename_node":
			outcome = _op_rename_node(args)
		"reparent_node":
			outcome = _op_reparent_node(args)
		"set_property":
			outcome = _op_set_property(args)
		"attach_script":
			outcome = _op_attach_script(args)
		"set_anchors_preset":
			outcome = _op_set_anchors_preset(args)
	return {"name": fname, "ok": bool(outcome.get("ok", false)), "message": str(outcome.get("message", ""))}


# Resolves a scene-relative (or absolute) path to a node in the edited scene.
# Returns {"node": Node or null, "error": String}.
func _resolve_scene_node(path_str: String) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"node": null, "error": "no scene is open"}
	var clean := path_str.strip_edges()
	if clean.is_empty() or clean == ".":
		return {"node": root, "error": ""}
	var node := root.get_node_or_null(NodePath(clean))
	if node == null and (clean == root.name or clean == root.scene_file_path.get_file().get_basename()):
		node = root
	if node == null and clean.find("/") == -1:
		node = _find_unique_named(root, clean)
	if node == null:
		return {"node": null, "error": "node not found: '%s'" % clean}
	if node != root and not root.is_ancestor_of(node):
		return {"node": null, "error": "node '%s' is outside the edited scene" % clean}
	return {"node": node, "error": ""}


static func _sanitize_node_name(base: String) -> String:
	return base.strip_edges().replace("/", "_").replace(":", "_")


static func _unique_child_name(parent: Node, base: String) -> String:
	var clean := base.strip_edges()
	if clean.is_empty():
		clean = "Node"
	if not parent.has_node(clean):
		return clean
	var i := 2
	while parent.has_node("%s%d" % [clean, i]):
		i += 1
	return "%s%d" % [clean, i]


static func _has_property(node: Node, prop: String) -> bool:
	for p in node.get_property_list():
		if p is Dictionary and str(p.get("name", "")) == prop:
			return true
	return false


static func _short_value(value: Variant) -> String:
	var text := str(value)
	if value is String:
		text = "'%s'" % value
	if text.length() > 48:
		return text.left(47) + "…"
	return text


static func _to_float_array(value: Variant, count: int) -> Array:
	if not value is Array or value.size() != count:
		return []
	var out: Array = []
	for v in value:
		if v is float or (v is int and not (v is bool)):
			out.append(float(v))
		elif v is String and (v.strip_edges().is_valid_float() or v.strip_edges().is_valid_int()):
			out.append(float(v.strip_edges()))
		else:
			return []
	return out


# Coerces a JSON value to the type the property currently holds.
# Returns {"value": ..., "error": ""} (error non-empty on failure).
static func _coerce_to_like(current: Variant, value: Variant) -> Dictionary:
	if current == null or value == null:
		return {"value": value, "error": ""}
	if current is bool:
		if value is bool:
			return {"value": value, "error": ""}
		if value is String and value.strip_edges().to_lower() in ["true", "false"]:
			return {"value": value.strip_edges().to_lower() == "true", "error": ""}
		return {"value": null, "error": "must be a boolean"}
	if current is int and not (current is bool):
		if value is float or (value is int and not (value is bool)):
			return {"value": int(value), "error": ""}
		if value is String and value.strip_edges().is_valid_int():
			return {"value": int(value.strip_edges()), "error": ""}
		return {"value": null, "error": "must be a number"}
	if current is float:
		if value is float or value is int:
			return {"value": float(value), "error": ""}
		if value is String and (value.strip_edges().is_valid_float() or value.strip_edges().is_valid_int()):
			return {"value": float(value.strip_edges()), "error": ""}
		return {"value": null, "error": "must be a number"}
	if current is String:
		if value is String:
			return {"value": value, "error": ""}
		return {"value": null, "error": "must be a string"}
	if current is Object:
		return {"value": null, "error": "resource/object properties are not supported yet"}
	if current is Array and value is Array:
		return {"value": value, "error": ""}
	if current is Dictionary and value is Dictionary:
		return {"value": value, "error": ""}
	var want := ""
	var count := 0
	if current is Vector2:
		want = "Vector2"
		count = 2
	elif current is Vector2i:
		want = "Vector2i"
		count = 2
	elif current is Vector3:
		want = "Vector3"
		count = 3
	elif current is Vector3i:
		want = "Vector3i"
		count = 3
	elif current is Vector4:
		want = "Vector4"
		count = 4
	elif current is Vector4i:
		want = "Vector4i"
		count = 4
	elif current is Color:
		want = "Color"
		count = 3
		if value is Array and value.size() == 4:
			count = 4
	elif current is Rect2:
		want = "Rect2"
		count = 4
	if want.is_empty():
		return {"value": null, "error": "type %s is not supported" % type_string(typeof(current))}
	var nums := _to_float_array(value, count)
	if nums.is_empty():
		return {"value": null, "error": "must be an array of %d numbers" % count}
	match want:
		"Vector2":
			return {"value": Vector2(nums[0], nums[1]), "error": ""}
		"Vector2i":
			return {"value": Vector2i(int(nums[0]), int(nums[1])), "error": ""}
		"Vector3":
			return {"value": Vector3(nums[0], nums[1], nums[2]), "error": ""}
		"Vector3i":
			return {"value": Vector3i(int(nums[0]), int(nums[1]), int(nums[2])), "error": ""}
		"Vector4":
			return {"value": Vector4(nums[0], nums[1], nums[2], nums[3]), "error": ""}
		"Vector4i":
			return {"value": Vector4i(int(nums[0]), int(nums[1]), int(nums[2]), int(nums[3])), "error": ""}
		"Color":
			if count == 4:
				return {"value": Color(nums[0], nums[1], nums[2], nums[3]), "error": ""}
			return {"value": Color(nums[0], nums[1], nums[2]), "error": ""}
		_:
			return {"value": Rect2(nums[0], nums[1], nums[2], nums[3]), "error": ""}


func _op_create_node(args: Dictionary) -> Dictionary:
	var node_type := str(args.get("node_type", "")).strip_edges()
	if node_type.is_empty():
		return {"ok": false, "message": "missing node_type"}
	if not ClassDB.class_exists(node_type) or not ClassDB.can_instantiate(node_type) or not ClassDB.is_parent_class(node_type, "Node"):
		return {"ok": false, "message": "unknown node type '%s'" % node_type}
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "message": "no scene is open"}
	var parent := root
	var parent_path := str(args.get("parent", "")).strip_edges()
	if not parent_path.is_empty() and parent_path != ".":
		var resolved := _resolve_scene_node(parent_path)
		if resolved["node"] == null:
			return {"ok": false, "message": "parent %s" % str(resolved["error"])}
		parent = resolved["node"]
	var base := str(args.get("name", "")).strip_edges()
	if base.is_empty():
		base = node_type
	var final_name := _unique_child_name(parent, _sanitize_node_name(base))
	var node := ClassDB.instantiate(node_type) as Node
	if node == null:
		return {"ok": false, "message": "could not instantiate '%s'" % node_type}
	node.name = final_name
	var is_control := node is Control
	var prev_layout := 0
	if is_control:
		prev_layout = int(node.get("layout_mode"))
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create %s" % node_type)
	undo_redo.add_do_method(parent, "add_child", node, true)
	undo_redo.add_do_method(node, "set_owner", root)
	if is_control:
		# Controls start in Anchors layout mode, matching the editor.
		undo_redo.add_do_property(node, "layout_mode", LAYOUT_MODE_ANCHORS)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(parent, "remove_child", node)
	if is_control:
		undo_redo.add_undo_property(node, "layout_mode", prev_layout)
	undo_redo.commit_action()
	return {"ok": true, "message": "created %s '%s' under '%s'" % [node_type, final_name, _scene_rel_path(root, parent)]}


func _op_delete_node(args: Dictionary) -> Dictionary:
	var resolved := _resolve_scene_node(str(args.get("node", "")))
	if resolved["node"] == null:
		return {"ok": false, "message": str(resolved["error"])}
	var node: Node = resolved["node"]
	var root := EditorInterface.get_edited_scene_root()
	if node == root:
		return {"ok": false, "message": "cannot delete the scene root"}
	var parent := node.get_parent()
	if parent == null:
		return {"ok": false, "message": "node has no parent"}
	var label := "%s '%s'" % [node.get_class(), node.name]
	var old_owner: Node = node.owner
	EditorInterface.get_selection().remove_node(node)
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Delete Node")
	undo_redo.add_do_method(parent, "remove_child", node)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(parent, "add_child", node)
	undo_redo.add_undo_method(node, "set_owner", old_owner)
	undo_redo.commit_action()
	return {"ok": true, "message": "deleted %s" % label}


func _op_rename_node(args: Dictionary) -> Dictionary:
	var resolved := _resolve_scene_node(str(args.get("node", "")))
	if resolved["node"] == null:
		return {"ok": false, "message": str(resolved["error"])}
	var node: Node = resolved["node"]
	var new_name := _sanitize_node_name(str(args.get("name", "")))
	if new_name.is_empty():
		return {"ok": false, "message": "new name is empty"}
	var parent := node.get_parent()
	if parent != null and parent.has_node(new_name) and parent.get_node(new_name) != node:
		return {"ok": false, "message": "sibling named '%s' already exists" % new_name}
	var old_name := node.name
	if old_name == new_name:
		return {"ok": true, "message": "already named '%s'" % new_name}
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Rename Node")
	undo_redo.add_do_property(node, "name", new_name)
	undo_redo.add_undo_property(node, "name", old_name)
	undo_redo.commit_action()
	return {"ok": true, "message": "renamed '%s' to '%s'" % [old_name, new_name]}


func _op_reparent_node(args: Dictionary) -> Dictionary:
	var resolved := _resolve_scene_node(str(args.get("node", "")))
	if resolved["node"] == null:
		return {"ok": false, "message": str(resolved["error"])}
	var node: Node = resolved["node"]
	var root := EditorInterface.get_edited_scene_root()
	if node == root:
		return {"ok": false, "message": "cannot reparent the scene root"}
	var presolved := _resolve_scene_node(str(args.get("new_parent", "")))
	if presolved["node"] == null:
		return {"ok": false, "message": "new parent %s" % str(presolved["error"])}
	var new_parent: Node = presolved["node"]
	if new_parent == node or node.is_ancestor_of(new_parent):
		return {"ok": false, "message": "cannot reparent inside itself"}
	var old_parent := node.get_parent()
	if old_parent == null:
		return {"ok": false, "message": "node has no parent"}
	if old_parent == new_parent:
		return {"ok": true, "message": "already under '%s'" % _scene_rel_path(root, new_parent)}
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Reparent Node")
	undo_redo.add_do_method(old_parent, "remove_child", node)
	undo_redo.add_do_method(new_parent, "add_child", node, true)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(new_parent, "remove_child", node)
	undo_redo.add_undo_method(old_parent, "add_child", node, true)
	undo_redo.commit_action()
	return {"ok": true, "message": "moved '%s' under '%s'" % [node.name, _scene_rel_path(root, new_parent)]}


func _op_set_property(args: Dictionary) -> Dictionary:
	var resolved := _resolve_scene_node(str(args.get("node", "")))
	if resolved["node"] == null:
		return {"ok": false, "message": str(resolved["error"])}
	var node: Node = resolved["node"]
	var prop := str(args.get("property", "")).strip_edges()
	if prop.is_empty():
		return {"ok": false, "message": "property name is empty"}
	if not _has_property(node, prop):
		return {"ok": false, "message": "'%s' has no property '%s'" % [node.name, prop]}
	var coerced := _coerce_to_like(node.get(prop), args.get("value"))
	if not str(coerced.get("error", "")).is_empty():
		return {"ok": false, "message": "property '%s' %s" % [prop, str(coerced["error"])]}
	var old_value = node.get(prop)
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Set %s" % prop)
	undo_redo.add_do_property(node, prop, coerced["value"])
	undo_redo.add_undo_property(node, prop, old_value)
	undo_redo.commit_action()
	return {"ok": true, "message": "set %s.%s = %s" % [node.name, prop, _short_value(coerced["value"])]}


func _op_attach_script(args: Dictionary) -> Dictionary:
	var resolved := _resolve_scene_node(str(args.get("node", "")))
	if resolved["node"] == null:
		return {"ok": false, "message": str(resolved["error"])}
	var node: Node = resolved["node"]
	var script_path := str(args.get("script_path", "")).strip_edges()
	if script_path.is_empty():
		return {"ok": false, "message": "script path is empty"}
	if node.get_script() != null:
		return {"ok": false, "message": "'%s' already has a script" % node.name}
	if not ResourceLoader.exists(script_path):
		return {"ok": false, "message": "script not found: '%s'" % script_path}
	var script = load(script_path)
	if not script is Script:
		return {"ok": false, "message": "'%s' is not a script" % script_path}
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Attach Script")
	undo_redo.add_do_method(node, "set_script", script)
	undo_redo.add_do_reference(script)
	undo_redo.add_undo_method(node, "set_script", null)
	undo_redo.commit_action()
	return {"ok": true, "message": "attached '%s' to '%s'" % [script_path, node.name]}


static func _anchors_preset_value(preset_name: String) -> int:
	var presets := {
		"top_left": Control.PRESET_TOP_LEFT,
		"top_right": Control.PRESET_TOP_RIGHT,
		"bottom_left": Control.PRESET_BOTTOM_LEFT,
		"bottom_right": Control.PRESET_BOTTOM_RIGHT,
		"center_left": Control.PRESET_CENTER_LEFT,
		"center_top": Control.PRESET_CENTER_TOP,
		"center_right": Control.PRESET_CENTER_RIGHT,
		"center_bottom": Control.PRESET_CENTER_BOTTOM,
		"center": Control.PRESET_CENTER,
		"left_wide": Control.PRESET_LEFT_WIDE,
		"top_wide": Control.PRESET_TOP_WIDE,
		"bottom_wide": Control.PRESET_BOTTOM_WIDE,
		"right_wide": Control.PRESET_RIGHT_WIDE,
		"vcenter_wide": Control.PRESET_VCENTER_WIDE,
		"hcenter_wide": Control.PRESET_HCENTER_WIDE,
		"full_rect": Control.PRESET_FULL_RECT,
	}
	return int(presets.get(preset_name.to_lower(), -1))


static func _preset_grow_directions(preset_name: String) -> Array:
	# Verified empirically on 4.6: grow = direction the rect extends from its
	# anchor position on min-size overflow, so overflow always extends into
	# the parent (fresh-control defaults END,END are the top_left case).
	var growers := {
		"top_left": [Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_END],
		"top_right": [Control.GROW_DIRECTION_BEGIN, Control.GROW_DIRECTION_END],
		"bottom_left": [Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_BEGIN],
		"bottom_right": [Control.GROW_DIRECTION_BEGIN, Control.GROW_DIRECTION_BEGIN],
		"center_left": [Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_BOTH],
		"center_top": [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_END],
		"center_right": [Control.GROW_DIRECTION_BEGIN, Control.GROW_DIRECTION_BOTH],
		"center_bottom": [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BEGIN],
		"center": [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BOTH],
		"left_wide": [Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_BOTH],
		"top_wide": [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_END],
		"bottom_wide": [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BEGIN],
		"right_wide": [Control.GROW_DIRECTION_BEGIN, Control.GROW_DIRECTION_BOTH],
		"vcenter_wide": [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BOTH],
		"hcenter_wide": [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BOTH],
		"full_rect": [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BOTH],
	}
	return growers.get(preset_name.to_lower(), [Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BOTH])


func _op_set_anchors_preset(args: Dictionary) -> Dictionary:
	var resolved := _resolve_scene_node(str(args.get("node", "")))
	if resolved["node"] == null:
		return {"ok": false, "message": str(resolved["error"])}
	var node: Node = resolved["node"]
	if not node is Control:
		return {"ok": false, "message": "'%s' is not a Control" % node.name}
	var preset_name := str(args.get("preset", "")).strip_edges().to_lower()
	var preset := _anchors_preset_value(preset_name)
	if preset < 0:
		return {"ok": false, "message": "unknown anchors preset '%s'" % preset_name}
	var keep_offsets := bool(args.get("keep_offsets", false))
	var grow: Array = _preset_grow_directions(preset_name)
	var note := ""
	var layout_parent := node.get_parent()
	if layout_parent != null and layout_parent is Container:
		note = " (parent %s is a Container and overrides anchors; use size_flags instead)" % layout_parent.name
	elif layout_parent is Control:
		var psize: Vector2 = layout_parent.size
		if psize.x < 1.0 or psize.y < 1.0:
			note = " (parent '%s' is %dx%d — anchors are relative to it, so size the parent first, e.g. full_rect on the parent, then re-run)" % [layout_parent.name, int(psize.x), int(psize.y)]
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Set Anchors Preset")
	undo_redo.add_do_property(node, "layout_mode", LAYOUT_MODE_ANCHORS)
	# Probe-verified (4.6.3): plain set_anchors_preset leaves offsets numerically,
	# so center lands the top-left corner at parent-center and full_rect overflows
	# the parent. set_anchors_and_offsets_preset KEEP_SIZE matches the editor
	# Layout menu exactly (true center keeping size, true fill for full_rect).
	if keep_offsets:
		undo_redo.add_do_method(node, "set_anchors_preset", preset, true)
	else:
		undo_redo.add_do_method(node, "set_anchors_and_offsets_preset", preset, Control.PRESET_MODE_KEEP_SIZE)
	undo_redo.add_do_property(node, "grow_horizontal", grow[0])
	undo_redo.add_do_property(node, "grow_vertical", grow[1])
	for prop in ["anchor_left", "anchor_top", "anchor_right", "anchor_bottom", "offset_left", "offset_top", "offset_right", "offset_bottom", "grow_horizontal", "grow_vertical", "layout_mode"]:
		undo_redo.add_undo_property(node, prop, node.get(prop))
	undo_redo.commit_action()
	return {"ok": true, "message": "set anchors preset '%s' on '%s'%s" % [preset_name, node.name, note]}


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
