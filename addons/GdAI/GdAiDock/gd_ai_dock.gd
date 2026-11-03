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
@export var effort_picker: OptionButton # reasoning effort; items auto-fill from AiClient.REASONING_EFFORT_OPTIONS
@export var loop_cap_spin: SpinBox

@export_category("Settings Dirty Indicators")
@export var api_key_dirty_dot: Label
@export var endpoint_dirty_dot: Label
@export var model_dirty_dot: Label
@export var effort_dirty_dot: Label
@export var loop_cap_dirty_dot: Label

@export_category("Sign In")
@export var sign_in_popup : PanelContainer
@export var sign_in_button: Button
@export var session_status_label: Label
@export var sign_in_code_field: LineEdit
@export var sign_in_open_browser_button: Button
@export var sign_in_cancel_button: Button
@export var sign_out_button: Button # stacked with sign_in_button; visibility swaps by session

@export_category("Unsaved Changes Popup")
@export var unsaved_changes_container : PanelContainer
@export var save_changes_button : Button 
@export var exit_without_save_button : Button


const MESSAGE_BOX_SCENE := preload("res://addons/GdAI/GdAiDock/MessageBox/MessageBox.tscn")
const BUBBLE_RATIO := 1.0
const SPACER_RATIO := 0.25
const MAX_LINES := 8
const TREE_NODE_BUDGET := 60
const TREE_DEPTH_BUDGET := 8
const SELECTION_BUDGET := 8
const OPEN_SCRIPT_BUDGET := 1500 # open-script excerpt cap (chars); the model uses read_script past it
const SCRIPT_PREVIEW_LINES := 24 # max diff/content lines shown per script call in the plan
# Control.LayoutMode enum values (the enum itself is not exposed to scripts; verified on 4.6).
const LAYOUT_MODE_POSITION := 0
const LAYOUT_MODE_ANCHORS := 1
const DIRTY_DOT_TEXT := "●"
const DIRTY_DOT_COLOR := Color(1.0, 0.75, 0.25)

var current_chat: Dictionary = {}
var client: AiClient
var pending_ai_message: MessageBox
var _send_button_text := "Send"
var _send_button_tooltip := ""
var auto_execute := false # true runs every turn immediately (testing escape hatch); false gates destructive turns behind approval
var _pending_approval: Dictionary = {} # one outstanding approval card: calls, base text, message, row, buttons, history, preamble, cap, generation
const DEFAULT_MAX_LOOP_TURNS := 3
const SETTINGS_MAX_LOOP_TURNS := "plugins/gd_ai/max_loop_turns"
var max_loop_turns := DEFAULT_MAX_LOOP_TURNS # tool turns per message before the loop pauses; Settings-editable cost bound
const MAX_READ_CHARS := 8000 # read_script truncation cap (chars); protects the context window from huge files
var _loop_active := false
var _loop_transcript: Array = [] # request-scoped assistant tool pairs + tool results; never stored in chat history
var _loop_count := 0 # tool turns received this user message
var _loop_generation := 0 # user-message stamp; an approval from an older generation never continues the loop
var _continue_button = null # live Continue button, if a capped turn is resumable
var _continue_generation := -1 # user-message stamp the live Continue button belongs to
var _sign_in_uri := "" # verification URL for the in-flight device flow (step 2)
var _pending_tab := "" # tab waiting behind the unsaved-changes popup ("chat"/"history"); "" when none

## Initializes dock signals, client, settings, and input state on ready.
func _ready() -> void:
	if Engine.is_editor_hint() and get_tree() != null and get_tree().edited_scene_root == self:
		return # inert preview: this instance is the scene open for editing, not the live dock
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
	# History entry point; list saved chats behind the tab.
	_refresh_history_list()

	# Set up the AI client.
	client = AiClient.new()
	add_child(client)
	client.system_prompt = "You are a helpful assistant inside the Godot editor. Node paths are relative to the edited scene root; use \".\" to target the root itself. You may emit up to 3 actions per response, each fully specified; for longer tasks do the first steps and continue on the next turn. After each action I'll return its result; reply with the next actions until everything is done and verified in the results, then call finish with a short summary."
	client.response_received.connect(_on_ai_response)
	client.request_failed.connect(_on_ai_error)
	client.streaming = true
	client.stream_updated.connect(_on_ai_stream)
	client.retry_scheduled.connect(_on_ai_retry)
	# Declare the editor actions the model may invoke as structured calls.
	client.tools = AiClient.default_tools() # Set to [] to save tokens by disabling tools.
	client.tool_calls_received.connect(_on_ai_tool_calls)
	client.device_code_received.connect(_on_device_code_received)
	client.sign_in_succeeded.connect(_on_sign_in_succeeded)
	client.sign_in_failed.connect(_on_sign_in_failed)
	client.sign_in_cancelled.connect(_on_sign_in_cancelled)
	client.session_expired.connect(_on_session_expired)
	# Load saved config, then wire settings, auth, and attach UI.
	client.load_config()
	max_loop_turns = _load_loop_cap()
	_setup_settings_ui()
	_setup_dirty_dots()
	_setup_unsaved_popup()
	_setup_sign_in_ui()
	_setup_attach_ui()
	_update_session_status()
	if client.session_is_stale():
		client.refresh_session(true)

	# Remember the send button's scene appearance so cancel mode can restore it.
	_send_button_text = send_button.text
	_send_button_tooltip = send_button.tooltip_text

	# Initial input state: hide send until there is text.
	_on_user_input_box_text_changed()
	_update_input_height.call_deferred()


# Shows the chat tab unless unsaved settings block the switch.
func _on_chat_button_pressed() -> void:
	if not _confirm_leave_settings("chat"):
		return
	_show_chat_tab()


## Displays the chat menu and hides history and settings menus.
func _show_chat_tab() -> void:
	chat_button.button_pressed = true
	chat_menu.visible = true
	history_menu.visible = false
	if settings_menu != null:
		settings_menu.visible = false


# Refreshes the send button whenever the input text changes.
func _on_user_input_box_text_changed() -> void:
	_refresh_send_button()


## Reports whether a reply is outstanding, including a stuck bubble.
func _can_cancel() -> bool:
	if client == null:
		return false
	return client.busy or pending_ai_message != null


## Doubles the send button as cancel while a request is in flight.
func _refresh_send_button() -> void:
	if send_button == null or user_input_box == null:
		return
	# In-flight request turns the button into Cancel.
	if _can_cancel():
		send_button.visible = true
		send_button.disabled = false
		send_button.text = "Cancel"
		send_button.tooltip_text = "Cancel the in-flight request (Esc)"
	else:
		# Idle state restores the label and shows Send only with text.
		send_button.text = _send_button_text
		send_button.tooltip_text = _send_button_tooltip
		send_button.visible = not user_input_box.text.strip_edges().is_empty()
		send_button.disabled = false
	_update_input_height.call_deferred()


# Handles input-box keys for attach navigation, cancel, and sending.
func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey \
			and event.pressed and not event.echo:
		# Picker open: let it consume navigation and confirm keys first.
		if _attach_open and _handle_attach_key(event):
			user_input_box.accept_event()
			return
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


## Cancels in-flight requests on Escape pressed elsewhere in the dock.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE \
			and _can_cancel():
		# Only handle Esc when focus sits inside the dock.
		var focus_owner := get_viewport().gui_get_focus_owner()
		if focus_owner == null or (focus_owner != self and not is_ancestor_of(focus_owner)):
			return
		# Swallow the key and cancel the request.
		get_viewport().set_input_as_handled()
		_on_cancel_requested()


# Sends the typed message or cancels the in-flight request instead.
func _on_send_button_pressed() -> void:
	# Dismiss the picker so its selection can't leak into the send.
	_hide_attach_popup()
	if _can_cancel():
		# The button is in cancel mode while a request is in flight.
		_on_cancel_requested()
		return
	if client == null:
		return
	if user_input_box == null:
		return
	# Ignore empty input.
	var text := user_input_box.text.strip_edges()
	if text.is_empty():
		return

	# Lazily start a chat on the first send.
	if current_chat.is_empty():
		current_chat = ChatStore.new_chat()
	if current_chat.is_empty() or not current_chat.has("messages"):
		return
	var history: Array = current_chat["messages"]
	if not history is Array:
		return

	# Show the bubble, persist it, and reset the input.
	add_message(text, true)
	_record_message("user", text)
	user_input_box.clear()
	_on_user_input_box_text_changed()
	user_input_box.grab_focus()

	# Parse @-mentions before the input clears; each loop turn rebuilds contents from these paths.
	_pending_attach_paths = _parse_attach_paths(text)
	_launch_request(history)


## Starts a fresh loop turn on the given history with a pending bubble.
func _launch_request(history: Array) -> void:
	# Fresh editor snapshot for this request (never stored in history).
	client.context_prompt = _request_context()
	# Reset loop state and stamp this user message.
	_loop_active = true
	_loop_transcript = []
	_loop_count = 0
	_loop_generation += 1
	# Placeholder bubble streams the reply in place.
	pending_ai_message = add_message("Thinking...", false)
	print("[GdAI] Sending: stream=%s tools=%d history=%d." % [client.streaming, client.tools.size(), history.size()])
	# Refresh send state now and after send in case it failed fast.
	client.tool_choice = "auto" # first turn: the model may answer or act
	client.send(history)
	_on_user_input_box_text_changed()


# Cancels the active request or clears a stuck reply bubble.
func _on_cancel_requested() -> void:
	if client == null:
		return
	# Cancel the live request, or clear a stuck bubble.
	if client.busy:
		client.cancel()
	elif pending_ai_message == null:
		return
	else:
		print("[GdAI] Cleared stuck reply UI (no request was active).")
	# Mark the bubble cancelled before dropping it.
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text("Request cancelled.")
		pending_ai_message.set_copy_visible(true)
	pending_ai_message = null
	_end_loop()

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


# Finalizes the pending bubble with the completed response text.
func _on_ai_response(text: String) -> void:
	# Finalize the streaming bubble with the full text.
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text(text)
		pending_ai_message.set_copy_visible(true)
		_apply_turn_usage()
	pending_ai_message = null
	# Persist the reply and close the loop.
	if not current_chat.is_empty() and current_chat.has("messages"):
		_record_message("assistant", text)
	_end_loop() # plain-text reply: the model is done acting
	_on_user_input_box_text_changed()


## Stamps token usage onto the pending bubble before it is cleared.
func _apply_turn_usage() -> void:
	if pending_ai_message == null or not is_instance_valid(pending_ai_message):
		return
	if client == null or client.last_usage.is_empty():
		return
	pending_ai_message.set_usage(int(client.last_usage.get("prompt_tokens", 0)), int(client.last_usage.get("completion_tokens", 0)))


# Auto-runs safe turns and parks destructive turns behind approval.
func _on_ai_tool_calls(calls: Array, preamble: String) -> void:
	# Collect the rendered bubble text line by line.
	var lines: Array[String] = []
	if not preamble.strip_edges().is_empty():
		lines.append(preamble.strip_edges())
		lines.append("") # blank line between the preamble and the turn body
	# Pure-finish turns skip the planned-actions section.
	var all_finish := not calls.is_empty() and calls.all(func(call): return call is Dictionary and str(call.get("name", "")) == "finish")
	if not all_finish:
		lines.append("Planned actions:")
		var planned_creates := _planned_script_creates(calls)
		for call in calls:
			if call is Dictionary:
				var fname := str(call.get("name", ""))
				if fname == "create_script" or fname == "edit_script":
					lines.append_array(_script_plan_lines(fname, call.get("arguments", {}), planned_creates))
				else:
					lines.append("• %s %s" % [fname, JSON.stringify(call.get("arguments", {}))])
	# Empty turn ends the loop immediately.
	if calls.is_empty():
		_end_loop() # nothing to approve or run; the turn is over
	# Count this turn against the loop cap.
	var capped := false
	if not calls.is_empty():
		_loop_count += 1
		capped = _loop_count > max_loop_turns
	var turn_results: Array = []
	# Safe turns run now; destructive turns wait for approval.
	var needs_approval := not auto_execute and not calls.is_empty() and _turn_needs_approval(calls)
	if not needs_approval and not calls.is_empty():
		turn_results = execute_tool_calls(calls)
		if all_finish:
			for result in turn_results:
				lines.append("✓ " + str(result.get("message", "")))
		else:
			lines.append("") # blank line between planned actions and results
			lines.append("Results:")
			for result in turn_results:
				var mark := "✓" if bool(result.get("ok", false)) else "✗"
				lines.append("%s %s: %s" % [mark, str(result.get("name", "?")), str(result.get("message", ""))])
		if capped:
			lines.append("(Loop limit reached — press Continue to go on.)")
		if _turn_has_finish(calls) and _turn_has_real_action(calls):
			lines.append("(The model called finish with other actions — press Continue if more work remains.)")
	# Approval needs an open scene to act on.
	if needs_approval:
		var scene_root := EditorInterface.get_edited_scene_root()
		if scene_root == null:
			lines.append("(No scene is open — open a scene and ask again to apply.)")
			needs_approval = false
			_end_loop() # nothing can execute or continue without a scene
		else:
			if str(scene_root.scene_file_path).strip_edges().is_empty():
				lines.append("Note: this scene has never been saved — approving modifies the open scene only; nothing is auto-saved.")
			lines.append("⏳ Awaiting approval.")
	# Render the bubble and stamp usage on it.
	var rendered := "\n".join(lines)
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text(rendered)
		if not needs_approval:
			pending_ai_message.set_copy_visible(true) # awaiting-approval resolves later
		_apply_turn_usage()
	# Persist the turn and keep a handle for the approval outcome.
	var history_ref = null
	if not current_chat.is_empty() and current_chat.has("messages"):
		_record_message("assistant", rendered)
		var msgs: Array = current_chat["messages"]
		if not msgs.is_empty() and msgs[msgs.size() - 1] is Dictionary:
			history_ref = msgs[msgs.size() - 1]
	if needs_approval and pending_ai_message != null and is_instance_valid(pending_ai_message):
		_show_approval_row(calls, rendered, history_ref, preamble, capped)
	pending_ai_message = null
	_on_user_input_box_text_changed()
	# Auto-run turns feed back into the loop; capped or finish turns offer Continue.
	if not needs_approval and not calls.is_empty():
		_after_tool_turn(preamble, calls, turn_results, capped)
	if (capped or _turn_has_finish(calls)) and not needs_approval and not calls.is_empty() and not _loop_transcript.is_empty():
		_show_continue_row()


## Reports whether a turn deletes a node or writes a script.
static func _turn_needs_approval(calls: Array) -> bool:
	for call in calls:
		if call is Dictionary and _is_destructive_action(str(call.get("name", ""))):
			return true
	return false


## Reports whether an action deletes nodes or writes scripts.
static func _is_destructive_action(fname: String) -> bool:
	return fname in ["delete_node", "create_script", "edit_script"]


## Maps same-turn script creates so edit previews resolve new files.
static func _planned_script_creates(calls: Array) -> Dictionary:
	# Map each valid new-file path to its planned content.
	var out := {}
	for call in calls:
		if not call is Dictionary or str(call.get("name", "")) != "create_script":
			continue
		var args = call.get("arguments", {})
		if not args is Dictionary:
			continue
		var checked := AiClient.validate_script_path(str(args.get("path", "")))
		if not bool(checked.get("ok", false)):
			continue
		var content := str(args.get("content", ""))
		if content.strip_edges().is_empty():
			continue
		var res_path: String = checked["path"]
		# Skip existing files and duplicate creates.
		if FileAccess.file_exists(res_path) or out.has(res_path):
			continue
		out[res_path] = content
	return out


## Builds advisory preview lines for a script write without executing.
static func _script_plan_lines(fname: String, args: Variant, planned_creates: Dictionary) -> Array[String]:
	if not args is Dictionary:
		return ["• %s (invalid arguments — execution will report the error)" % fname]
	if fname == "create_script":
		return _create_preview_lines(args, planned_creates)
	return _edit_preview_lines(args, planned_creates)


## Previews a planned script creation or explains why it would fail.
static func _create_preview_lines(args: Dictionary, planned_creates: Dictionary) -> Array[String]:
	# Validate the path before previewing.
	var checked := AiClient.validate_script_path(str(args.get("path", "")))
	if not bool(checked.get("ok", false)):
		return ["• create_script (bad path: %s)" % str(checked.get("error", "bad path"))]
	var res_path: String = checked["path"]
	var content := str(args.get("content", ""))
	if content.strip_edges().is_empty():
		return ["• create_script %s\n  ⚠ script content is empty" % res_path]
	if FileAccess.file_exists(res_path):
		return ["• create_script %s\n  ⚠ already exists (won't overwrite)" % res_path]
	if not planned_creates.has(res_path):
		return ["• create_script %s\n  ⚠ duplicate create in the same turn (later one fails)" % res_path]
	# List the new file plus its capped content lines.
	var out: Array[String] = ["• create_script %s (new file)" % res_path]
	var all_content := content.split("\n")
	var shown := 0
	for ln in all_content:
		if shown >= SCRIPT_PREVIEW_LINES:
			out.append("  … (%d more lines)" % (all_content.size() - shown))
			break
		out.append("  + " + _preview_clip(ln))
		shown += 1
	return out


## Previews a planned script edit with context or a failure warning.
static func _edit_preview_lines(args: Dictionary, planned_creates: Dictionary) -> Array[String]:
	# Validate the path before previewing.
	var checked := AiClient.validate_script_path(str(args.get("path", "")))
	if not bool(checked.get("ok", false)):
		return ["• edit_script (bad path: %s)" % str(checked.get("error", "bad path"))]
	var res_path: String = checked["path"]
	var find := str(args.get("find", ""))
	var replace := str(args.get("replace", ""))
	if find.is_empty():
		return ["• edit_script %s\n  ⚠ find text is empty" % res_path]
	if find == replace:
		return ["• edit_script %s\n  (no change: find and replace are identical)" % res_path]
	# Resolve the text to diff against: disk, open buffer, or planned file.
	var source := ""
	var planned_note := ""
	if FileAccess.file_exists(res_path):
		var buf := _open_buffer_for(res_path)
		source = str(buf.get("text", "")) if bool(buf.get("open", false)) else FileAccess.get_file_as_string(res_path)
	elif planned_creates.has(res_path):
		source = str(planned_creates[res_path])
		planned_note = " (against planned new file)"
	else:
		return ["• edit_script %s\n  ⚠ does not exist (use create_script first)" % res_path]
	# The find block must match exactly once.
	var hits := source.count(find)
	if hits == 0:
		return ["• edit_script %s\n  ⚠ find text not found in file%s" % [res_path, planned_note]]
	if hits > 1:
		return ["• edit_script %s\n  ⚠ find text matches %d blocks — include more surrounding lines" % [res_path, hits]]
	# Locate the match and check line alignment.
	var pos := source.find(find)
	var aligned := (pos == 0 or source[pos - 1] == "\n") \
		and (pos + find.length() >= source.length() or source[pos + find.length()] == "\n")
	var out: Array[String] = ["• edit_script %s%s" % [res_path, planned_note]]
	var find_lines := find.split("\n")
	var replace_lines := replace.split("\n")
	# Trim the split artifact from trailing newlines.
	if find_lines.size() > 0 and find_lines[find_lines.size() - 1].is_empty() and find.ends_with("\n"):
		find_lines.remove_at(find_lines.size() - 1)
	if replace.is_empty():
		replace_lines = PackedStringArray(["(delete — replace with nothing)"])
	elif replace_lines.size() > 0 and replace_lines[replace_lines.size() - 1].is_empty() and replace.ends_with("\n"):
		replace_lines.remove_at(replace_lines.size() - 1)
	if not aligned:
		out.append("  @@ line %d (partial-line match: %d line(s) → %d)" % [source.count("\n", 0, pos) + 1, find_lines.size(), replace_lines.size()])
		_append_capped_block(out, find_lines, "- ")
		_append_capped_block(out, replace_lines, "+ ")
		return out
	# Aligned match renders with surrounding context lines.
	var start_line := source.count("\n", 0, pos) + 1
	out.append("  @@ line %d (replace %d line(s) with %d)%s" % [start_line, find_lines.size(), replace_lines.size(), planned_note])
	var all_lines := source.split("\n")
	var first_idx := start_line - 1
	var from_idx := maxi(0, first_idx - 3)
	var to_idx := mini(all_lines.size(), first_idx + find_lines.size() + 3)
	var shown := 0
	for i in range(from_idx, first_idx):
		if shown >= SCRIPT_PREVIEW_LINES:
			break
		out.append("  " + _preview_clip(all_lines[i]))
		shown += 1
	for ln in find_lines:
		if shown >= SCRIPT_PREVIEW_LINES:
			break
		out.append("  - " + _preview_clip(ln))
		shown += 1
	for ln in replace_lines:
		if shown >= SCRIPT_PREVIEW_LINES:
			break
		out.append("  + " + _preview_clip(ln))
		shown += 1
	for i in range(first_idx + find_lines.size(), to_idx):
		if shown >= SCRIPT_PREVIEW_LINES:
			break
		out.append("  " + _preview_clip(all_lines[i]))
		shown += 1
	if shown >= SCRIPT_PREVIEW_LINES:
		out.append("  … (preview truncated)")
	return out


## Appends up to the preview cap with a prefix; stops silently when full.
static func _append_capped_block(out: Array[String], block_lines: PackedStringArray, prefix: String) -> void:
	# Count preview lines already used.
	var used := 0
	for l in out:
		if l.begins_with("  - ") or l.begins_with("  + ") or (l.begins_with("  ") and not l.begins_with("  @@")):
			used += 1
	# Append until the cap, then note truncation.
	for ln in block_lines:
		if used >= SCRIPT_PREVIEW_LINES:
			out.append("  … (preview truncated)")
			return
		out.append("  " + prefix + _preview_clip(ln))
		used += 1


## Clips a preview line to display width with an ellipsis.
static func _preview_clip(ln: String) -> String:
	var clean := ln.replace("\r", "")
	if clean.length() > 120:
		return clean.left(119) + "…"
	return clean


## Shows the single Approve/Reject card, superseding any pending one.
func _show_approval_row(calls: Array, base_text: String, history_ref, preamble: String, capped: bool) -> void:
	# Only one approval card lives at a time.
	_supersede_pending_approval()
	var approve_btn := Button.new()
	approve_btn.text = "Approve"
	approve_btn.tooltip_text = "Apply all %d action(s) to the edited scene" % calls.size()
	approve_btn.pressed.connect(_on_approve_pressed)
	var reject_btn := Button.new()
	reject_btn.text = "Reject"
	reject_btn.tooltip_text = "Discard without changing the scene"
	reject_btn.pressed.connect(_on_reject_pressed)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Assemble the button row under the bubble.
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(approve_btn)
	row.add_child(reject_btn)
	row.add_child(spacer)
	message_list.add_child(row)
	# Stash everything Approve/Reject needs.
	_pending_approval = {
		"calls": calls, "base_text": base_text, "message": pending_ai_message,
		"row": row, "approve": approve_btn, "reject": reject_btn, "history_ref": history_ref,
		"preamble": preamble, "capped": capped, "generation": _loop_generation,
	}


# Executes the pending turn and feeds results back into the loop.
func _on_approve_pressed() -> void:
	if _pending_approval.is_empty():
		return
	# Take the pending turn so re-clicks no-op.
	var pending: Dictionary = _pending_approval
	_pending_approval = {}
	_lock_approval_buttons(pending, true)
	# Stale approvals apply but never feed the new loop.
	var stale := int(pending.get("generation", -1)) != _loop_generation
	var turn_calls: Array = pending.get("calls", [])
	var lines: Array[String] = [str(pending.get("base_text", ""))]
	lines.append("Results:")
	# Execute and render one line per result.
	var turn_results := execute_tool_calls(turn_calls)
	for result in turn_results:
		var mark := "✓" if bool(result.get("ok", false)) else "✗"
		lines.append("%s %s: %s" % [mark, str(result.get("name", "?")), str(result.get("message", ""))])
	if stale:
		# Newer request arrived: apply, but never feed stale results into the new loop.
		lines.append("(Superseded by a newer request — not fed back.)")
	elif bool(pending.get("capped", false)):
		lines.append("(Loop limit reached — press Continue to go on.)")
	if _turn_has_finish(turn_calls) and _turn_has_real_action(turn_calls):
		lines.append("(The model called finish with other actions — press Continue if more work remains.)")
	# Save the outcome, then feed fresh results back into the loop.
	_update_pending_record(pending, "\n".join(lines))
	_on_user_input_box_text_changed()
	if not stale:
		_after_tool_turn(str(pending.get("preamble", "")), turn_calls, turn_results, bool(pending.get("capped", false)))
	if not stale and (bool(pending.get("capped", false)) or _turn_has_finish(turn_calls)) and not _loop_transcript.is_empty():
		_show_continue_row()


# Discards the pending turn without changing the scene.
func _on_reject_pressed() -> void:
	if _pending_approval.is_empty():
		return
	# Take the pending turn so re-clicks no-op.
	var pending: Dictionary = _pending_approval
	_pending_approval = {}
	_lock_approval_buttons(pending, false)
	_update_pending_record(pending, str(pending.get("base_text", "")) + "\nRejected — no changes applied.")
	_end_loop()
	_on_user_input_box_text_changed()


## Records tool results and re-sends so the loop continues or halts.
func _after_tool_turn(preamble: String, calls: Array, results: Array, capped: bool) -> void:
	if not _loop_active:
		return
	# Record the turn for the next model request.
	_append_loop_transcript(preamble, calls, results)
	if _turn_has_finish(calls) and not _turn_has_real_action(calls) and not capped:
		_end_loop() # pure finish within budget: clean done state
		return
	if _turn_has_finish(calls) or capped:
		_pause_loop() # ambiguous ending or cap: halted, but resumable via Continue
		return
	_continue_loop()


## Reports whether a turn contains a finish call.
static func _turn_has_finish(calls: Array) -> bool:
	for call in calls:
		if call is Dictionary and str(call.get("name", "")) == "finish":
			return true
	return false


## Reports whether a turn contains any non-finish action.
static func _turn_has_real_action(calls: Array) -> bool:
	for call in calls:
		if call is Dictionary and str(call.get("name", "")) != "finish":
			return true
	return false


## Appends assistant tool calls plus results to the loop transcript.
func _append_loop_transcript(preamble: String, calls: Array, results: Array) -> void:
	# Shape the calls into the API tool-call format.
	var tool_calls: Array = []
	for call in calls:
		if not call is Dictionary:
			continue
		tool_calls.append({
			"id": str(call.get("id", "")),
			"type": "function",
			"function": {
				"name": str(call.get("name", "")),
				"arguments": JSON.stringify(call.get("arguments", {})),
			},
		})
	if tool_calls.is_empty():
		return
	# Store the assistant turn, then one tool message per result.
	_loop_transcript.append({"role": "assistant", "content": preamble, "tool_calls": tool_calls})
	var pair_count: int = mini(calls.size(), results.size())
	for i in pair_count:
		var call = calls[i]
		var result = results[i]
		if not call is Dictionary or not result is Dictionary:
			continue
		var payload := {"ok": bool(result.get("ok", false)), "message": str(result.get("message", ""))}
		if result.has("detail"):
			payload["detail"] = result["detail"]
		_loop_transcript.append({
			"role": "tool",
			"tool_call_id": str(call.get("id", "")),
			"content": JSON.stringify(payload),
		})


## Re-sends history plus transcript to continue the tool loop.
func _continue_loop() -> void:
	if not _loop_active or client == null or client.busy:
		return
	if current_chat.is_empty() or not current_chat.has("messages"):
		_end_loop()
		return
	var history: Array = current_chat["messages"]
	if not history is Array:
		_end_loop()
		return
	# (send_followup selects required vs stepped-down auto.)
	# Fresh snapshot plus a new placeholder bubble for this turn.
	client.context_prompt = _request_context()
	pending_ai_message = add_message("Thinking…", false)
	# Send history plus transcript as the followup.
	var followup := history.duplicate()
	followup.append_array(_loop_transcript)
	client.send_followup(followup)
	_on_user_input_box_text_changed()


## Clears loop state and restores the default tool choice.
func _end_loop() -> void:
	_loop_active = false
	_loop_transcript = []
	_loop_count = 0
	if client != null:
		client.tool_choice = "auto"


## Halts auto-continuation while keeping the transcript for manual Continue.
func _pause_loop() -> void:
	_loop_active = false


## Offers a one-shot Continue button, retiring any older one.
func _show_continue_row() -> void:
	# Only one Continue button lives at a time.
	_retire_continue_button()
	var btn := Button.new()
	btn.text = "Continue"
	btn.tooltip_text = "Resume the loop for up to %d more tool turns" % max_loop_turns
	btn.pressed.connect(_on_continue_pressed)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Assemble the button row under the bubble.
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)
	row.add_child(spacer)
	message_list.add_child(row)
	_continue_button = btn
	_continue_generation = _loop_generation


## Disables and clears the live Continue button if present.
func _retire_continue_button() -> void:
	if _continue_button != null and is_instance_valid(_continue_button):
		_continue_button.disabled = true
		_continue_button.text = "Superseded"
	_continue_button = null


# Resumes a paused loop for another batch of tool turns.
func _on_continue_pressed() -> void:
	if _continue_button == null or not is_instance_valid(_continue_button):
		return
	# Older generations retire instead of resuming.
	if _continue_generation != _loop_generation:
		_retire_continue_button()
		return
	if client == null or client.busy:
		return
	var btn = _continue_button
	_continue_button = null
	btn.disabled = true
	btn.text = "Continuing…"
	# Reactivate the loop with a fresh turn budget.
	_loop_active = true
	_loop_count = 0
	_continue_loop()


## Treats the pending approval as rejected by a newer request.
func _supersede_pending_approval() -> void:
	if _pending_approval.is_empty():
		return
	# Take the pending turn so re-clicks no-op.
	var pending: Dictionary = _pending_approval
	_pending_approval = {}
	_lock_approval_buttons(pending, false)
	_update_pending_record(pending, str(pending.get("base_text", "")) + "\nSuperseded by a newer request — treated as rejected.")


## Disables approval buttons and labels the chosen outcome.
func _lock_approval_buttons(pending: Dictionary, approved: bool) -> void:
	# Freeze both buttons and label the chosen outcome.
	var approve_btn = pending.get("approve")
	if approve_btn != null and is_instance_valid(approve_btn):
		approve_btn.disabled = true
		if approved:
			approve_btn.text = "Approved ✓"
	var reject_btn = pending.get("reject")
	if reject_btn != null and is_instance_valid(reject_btn):
		reject_btn.disabled = true
		if not approved:
			reject_btn.text = "Rejected"


## Writes final approval text to the bubble and saved history.
func _update_pending_record(pending: Dictionary, full_text: String) -> void:
	# Rewrite the bubble with the final text.
	var message = pending.get("message")
	if message != null and is_instance_valid(message):
		message.set_message_text(full_text)
		message.set_copy_visible(true) # approve/reject/supersede are terminal
	# Mirror the outcome into saved history.
	var history_ref = pending.get("history_ref")
	if history_ref is Dictionary:
		history_ref["content"] = full_text
		if not current_chat.is_empty():
			ChatStore.save_chat(current_chat)


# Shows the failure message in the pending bubble and ends the loop.
func _on_ai_error(message: String) -> void:
	# Show the failure in the pending bubble.
	if pending_ai_message != null and is_instance_valid(pending_ai_message):
		pending_ai_message.set_message_text("Error: " + message)
		pending_ai_message.set_copy_visible(true)
	pending_ai_message = null
	_end_loop()

	# Keep the user's unanswered turn in history so it stays for context or retry.
	_on_user_input_box_text_changed()


## Creates a chat bubble row and wires its delete and retry signals.
func add_message(text: String, is_user: bool, copy_ready := false) -> MessageBox:
	var message: MessageBox = MESSAGE_BOX_SCENE.instantiate()
	message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message.set_flat(not is_user)
	# Copy appears only once the text is final (never for Thinking/streaming).
	message.set_copy_visible(copy_ready and not is_user)
	message.delete_requested.connect(_on_message_delete_requested)
	message.retry_requested.connect(_on_message_retry_requested)
	message.set_message_text(text)

	if not is_user:
		# AI replies flow full-width with no bubble offset (room for code blocks).
		message_list.add_child(message)
		_update_retry_visibility()
		return message # keep this to stream into it

	# User: spacer on the left pushes the bubble right.
	message.size_flags_stretch_ratio = BUBBLE_RATIO
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.size_flags_stretch_ratio = SPACER_RATIO
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 0)
	row.add_child(spacer)
	row.add_child(message)

	message_list.add_child(row)
	_update_retry_visibility()
	return message


# Deletes one bubble and its matching history entry by order.
func _on_message_delete_requested(message: MessageBox) -> void:
	# Locate the bubble before freeing its row.
	var idx := _message_ui_index(message)
	var parent := message.get_parent()
	if parent != null and parent != message_list and parent.get_parent() == message_list:
		message_list.remove_child(parent)
		parent.queue_free()
	elif parent == message_list:
		message_list.remove_child(message)
		message.queue_free()
	else:
		return
	# Drop the matching history entry and save.
	if idx < 0 or current_chat.is_empty():
		return
	var messages = current_chat.get("messages", [])
	if messages is Array and idx < messages.size():
		messages.remove_at(idx)
		ChatStore.save_chat(current_chat)
	_update_retry_visibility() # a delete can move the last-AI target


## Finds a bubble's history index, skipping approval and continue rows.
func _message_ui_index(message: MessageBox) -> int:
	# Walk display rows counting only message bubbles.
	var i := 0
	for child in message_list.get_children():
		var box: MessageBox = null
		if child is MessageBox:
			box = child
		elif child is HBoxContainer:
			for sub in child.get_children():
				if sub is MessageBox:
					box = sub
					break
		if box == null:
			continue # approval/continue rows carry no history entry
		if box == message:
			return i
		i += 1
	return -1


## Lists AI message bubbles in display order, newest last.
func _ai_messages_in_order() -> Array:
	var boxes: Array = []
	if message_list == null:
		return boxes
	for child in message_list.get_children():
		if child is MessageBox:
			boxes.append(child)
	return boxes


## Offers retry only on the last AI message bubble.
func _update_retry_visibility() -> void:
	var boxes := _ai_messages_in_order()
	for i in boxes.size():
		(boxes[i] as MessageBox).set_retry_last(i == boxes.size() - 1)


# Regenerates the last response through the newest surviving user turn.
func _on_message_retry_requested(message: MessageBox) -> void:
	# Only retry when idle; mid-request has nothing final to redo.
	if client == null or client.busy or _loop_active:
		return # mid-request (incl. between tool turns): nothing final to redo
	if message.get_parent() != message_list:
		return
	if current_chat.is_empty() or not current_chat.has("messages"):
		return
	var history: Array = current_chat["messages"]
	if not history is Array:
		return
	# Target must be the last entry (assistant after user); older or stale targets no-op.
	var idx := _message_ui_index(message)
	if idx < 1 or idx != history.size() - 1:
		return
	var entry = history[idx]
	if not entry is Dictionary or str(entry.get("role", "")) != "assistant":
		return
	var prev = history[idx - 1]
	if not prev is Dictionary or str(prev.get("role", "")) != "user":
		return
	# Retry starts a new turn: retire live approval/continue first, like a superseding send.
	if not _pending_approval.is_empty():
		_supersede_pending_approval()
	_retire_continue_button()
	history.remove_at(idx)
	ChatStore.save_chat(current_chat)
	# Free the old bubble, then re-send from the surviving history.
	pending_ai_message = null
	message_list.remove_child(message)
	message.queue_free()
	_update_retry_visibility()
	_launch_request(history) # re-inits loop state, Thinking bubble, send


## Resizes the input box to its content up to the line cap.
func _update_input_height() -> void:
	if user_input_box == null:
		return
	# Size the box from its line count plus stylebox padding.
	var lines := clampi(user_input_box.get_total_visible_line_count(), 1, MAX_LINES)
	var line_h := user_input_box.get_line_height() \
		+ user_input_box.get_theme_constant("line_spacing")
	var padding := user_input_box.get_theme_stylebox("normal").get_minimum_size().y
	user_input_box.custom_minimum_size.y = lines * line_h + padding


# Shows the history tab unless unsaved settings block the switch.
func _on_history_button_pressed() -> void:
	if not _confirm_leave_settings("history"):
		return
	_show_history_tab()


## Displays the history menu and refreshes the saved chat list.
func _show_history_tab() -> void:
	history_button.button_pressed = true
	history_menu.visible = true
	chat_menu.visible = false
	settings_menu.visible = false
	if settings_menu != null:
		settings_menu.visible = false
	_refresh_history_list()


## Appends a message to the current chat and saves it.
func _record_message(role: String, content: String) -> void:
	if current_chat.is_empty() or not current_chat.has("messages"):
		return
	var messages = current_chat["messages"]
	if not messages is Array:
		return
	messages.append({"role": role, "content": content})
	# Title the chat from its first user message.
	if role == "user" and str(current_chat.get("title", "")) == "New chat":
		current_chat["title"] = _make_title(content)
	ChatStore.save_chat(current_chat)


## Snapshots the scene, selection, and script for the next request only.
func _build_editor_context() -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return "[Editor context]\nNo scene is currently open in the editor."
	# Collect the snapshot line by line.
	var lines: Array[String] = []
	lines.append("[Editor context]")
	var scene_path := root.scene_file_path
	if scene_path.is_empty():
		scene_path = "(unsaved scene)"
	lines.append("Scene: %s (root: %s, %s)" % [scene_path, root.name, root.get_class()])
	# Note multi-scene sessions and the capped selection list.
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
	# Depth-first walk of the tree within node and depth budgets.
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
	# Flag truncation and container layout rules.
	if truncated:
		lines.append("… (tree truncated to %d nodes, depth %d)" % [TREE_NODE_BUDGET, TREE_DEPTH_BUDGET])
	if saw_container:
		lines.append("[container] arranges its children itself: anchors/offsets are ignored — center children with size_flags_horizontal/vertical = 4 (SHRINK_CENTER).")
	var open_script := _open_script_block()
	if not open_script.is_empty():
		lines.append(open_script)
	return "\n".join(lines)


## Renders the live open-script buffer, capped, for request context.
static func _open_script_block() -> String:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return ""
	var sc: Script = script_editor.get_current_script()
	if sc == null:
		return ""
	# Prefer the live buffer so unsaved edits are included.
	var text := ""
	var ed = script_editor.get_current_editor()
	if ed != null and ed.has_method("get_base_editor"):
		var base = ed.get_base_editor()
		if base is TextEdit:
			text = (base as TextEdit).text
	if text.is_empty() and sc.has_method("get_source_code"):
		text = str(sc.get_source_code())
	var path := str(sc.resource_path)
	if path.is_empty():
		path = "(unsaved script)"
	# Cap the excerpt, pointing at read_script for the rest.
	var total_lines := text.split("\n").size() if not text.is_empty() else 0
	var shown := text
	var tail := ""
	if shown.length() > OPEN_SCRIPT_BUDGET:
		shown = shown.left(OPEN_SCRIPT_BUDGET)
		tail = "\n… (truncated to %d chars; use read_script for the full file)" % OPEN_SCRIPT_BUDGET
	return "[Open script] %s (%d lines):\n%s%s" % [path, total_lines, shown, tail]


# --- Manual context attach (@-mentions) ---
# Typing @ in the input opens a script/scene picker; picking inserts the full
# res:// path as text. On send, @res:// paths are parsed out and their
# contents appended to the request context (per-message scope: cached paths
# serve every loop turn of that message, and the next send re-parses).
const ATTACH_MAX_FILES := 3 # @-mentions honored per message; extras are dropped with a note
const ATTACH_SCAN_CAP := 500 # res:// files indexed for the picker per opening
const ATTACH_SHOWN_CAP := 100 # picker rows filled per keystroke
var _attach_popup: PopupPanel = null
var _attach_list: ItemList = null
var _attach_open := false # picker state (window-independent: popup visibility lies headless)
var _attach_cache: Array[String] = [] # res:// scan, valid only while the picker is open
var _pending_attach_paths: Array[String] = [] # parsed from the sent text; contents rebuilt every loop turn


## Combines fresh editor context with rebuilt attachment contents.
func _request_context() -> String:
	return _build_editor_context() + _attach_block_for(_pending_attach_paths)


## Builds the @-mention picker popup and wires its signals.
func _setup_attach_ui() -> void:
	if user_input_box == null:
		return
	# Build the floating picker popup and its layout.
	_attach_popup = PopupPanel.new()
	_attach_popup.size = Vector2i(440, 260)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_attach_popup.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)
	var hint := Label.new()
	hint.text = "Attach a script or scene (@)"
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.62))
	vbox.add_child(hint)
	# Candidate list fills the popup; wire pick and close signals.
	_attach_list = ItemList.new()
	_attach_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_attach_list)
	add_child(_attach_popup)
	_attach_list.item_selected.connect(_on_attach_item_chosen)
	_attach_list.item_activated.connect(_on_attach_item_chosen)
	_attach_popup.popup_hide.connect(_hide_attach_popup)
	user_input_box.text_changed.connect(_on_attach_text_changed)


# Opens or closes the attach picker as @-queries change.
func _on_attach_text_changed() -> void:
	if user_input_box == null or _attach_popup == null:
		return
	# Show the picker only while the caret sits on an @-query.
	var found: Array = _attach_query_at_caret()
	if int(found[0]) < 0:
		_hide_attach_popup()
		return
	_show_attach_popup(str(found[1]))


## Extracts the @-query under the caret, ignoring emails and spaces.
func _attach_query_at_caret() -> Array:
	# No input means no query.
	if user_input_box == null:
		return [-1, ""]
	var line := user_input_box.get_caret_line()
	var col := user_input_box.get_caret_column()
	if line < 0 or line >= user_input_box.get_line_count():
		return [-1, ""]
	var before := user_input_box.get_line(line).left(col)
	# Find the nearest @ and reject mid-word hits like emails.
	var at := before.rfind("@")
	if at < 0:
		return [-1, ""]
	if at > 0:
		var prev := before[at - 1]
		if prev != " " and prev != "\t":
			return [-1, ""]
	var query := before.substr(at + 1)
	if query.contains(" ") or query.contains("\t"):
		return [-1, ""]
	return [at, query]


## Shows filtered attach candidates above or below the input.
func _show_attach_popup(query: String) -> void:
	# Scan once per opening, then filter the cache per keystroke.
	if not _attach_open:
		_attach_cache = _scan_attach_files() # fresh scan per opening; filters reuse it
	# Filter the cache and fill the list up to the cap.
	var matches := _filter_attach_files(_attach_cache, query)
	_attach_list.clear()
	var shown := 0
	for f in matches:
		if shown >= ATTACH_SHOWN_CAP:
			break
		_attach_list.add_item(f)
		shown += 1
	if shown == 0:
		_hide_attach_popup() # no candidates: stay out of the way, plain-@ text still sends
		return
	_attach_list.set_block_signals(true) # programmatic select must not attach
	_attach_list.select(0)
	_attach_list.set_block_signals(false)
	# Anchor the popup above the input, or below when cramped.
	var r := user_input_box.get_global_rect()
	var size := Vector2i(440, 260)
	var pos := Vector2i(int(r.position.x), int(r.position.y) - size.y - 6)
	if pos.y < 0:
		pos.y = int(r.position.y + r.size.y + 6) # no room above: drop below
	_attach_open = true
	_attach_popup.popup(Rect2i(pos, size))


# Closes the attach picker and clears its cached scan.
func _hide_attach_popup() -> void:
	_attach_open = false
	_attach_cache = []
	if _attach_popup != null:
		_attach_popup.hide()


# Inserts the picked file path at the caret's @-word.
func _on_attach_item_chosen(index: int) -> void:
	if not _attach_open or _attach_list == null or user_input_box == null:
		return
	if index < 0 or index >= _attach_list.item_count:
		return
	_insert_attach_path(_attach_list.get_item_text(index))


## Replaces the @-word with the path plus a closing space.
func _insert_attach_path(path: String) -> void:
	var found: Array = _attach_query_at_caret()
	if int(found[0]) < 0:
		_hide_attach_popup()
		return
	# Swap the @-word for the picked path.
	var line := user_input_box.get_caret_line()
	var col := user_input_box.get_caret_column()
	user_input_box.remove_text(line, int(found[0]), line, col)
	user_input_box.set_caret_line(line)
	user_input_box.set_caret_column(int(found[0]))
	user_input_box.insert_text_at_caret("@" + path + " ")
	_hide_attach_popup()
	user_input_box.grab_focus()


## Consumes picker keys so Enter attaches instead of sending.
func _handle_attach_key(event: InputEventKey) -> bool:
	# Esc closes, Enter attaches, arrows move the selection.
	match event.keycode:
		KEY_ESCAPE:
			_hide_attach_popup()
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if _attach_list != null and _attach_list.item_count > 0:
				var sel := _attach_list.get_selected_items()
				_on_attach_item_chosen(sel[0] if not sel.is_empty() else 0)
			else:
				_hide_attach_popup()
			return true
		KEY_UP, KEY_DOWN:
			if _attach_list != null and _attach_list.item_count > 0:
				var sel2 := _attach_list.get_selected_items()
				var cur := int(sel2[0]) if not sel2.is_empty() else -1
				cur += 1 if event.keycode == KEY_DOWN else -1
				_attach_list.set_block_signals(true)
				_attach_list.select(clampi(cur, 0, _attach_list.item_count - 1))
				_attach_list.set_block_signals(false)
			return true
	return false


## Lists attachable scripts and scenes under res://, sorted and capped.
func _scan_attach_files() -> Array[String]:
	# Walk res:// collecting scripts and scenes up to the cap.
	var out: Array[String] = []
	var stack: Array[String] = ["res://"]
	while not stack.is_empty() and out.size() < ATTACH_SCAN_CAP:
		var dir_path := stack.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry := dir.get_next()
		# Recurse into visible dirs; collect scripts and scenes.
		while entry != "" and out.size() < ATTACH_SCAN_CAP:
			var full: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				if not entry.begins_with("."):
					stack.append(full)
			else:
				var low := entry.to_lower()
				if low.ends_with(".gd") or low.ends_with(".tscn"):
					out.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	out.sort()
	return out


## Filters attach candidates by a case-insensitive query substring.
static func _filter_attach_files(files: Array[String], query: String) -> Array[String]:
	var q := query.strip_edges().to_lower()
	if q.is_empty():
		return files
	var out: Array[String] = []
	for f in files:
		if f.to_lower().contains(q):
			out.append(f)
	return out


## Extracts valid existing @res:// paths, skipping all other @-text.
static func _parse_attach_paths(text: String) -> Array[String]:
	# Find @res:// hits and trim trailing punctuation.
	var out: Array[String] = []
	var re := RegEx.new()
	re.compile("@(res://\\S+)")
	for m in re.search_all(text):
		var cand := str(m.get_string(1))
		while not cand.is_empty() and ".,;:!?)]\"'`".contains(cand.right(1)):
			cand = cand.left(cand.length() - 1)
		# Keep only valid, existing, deduplicated paths.
		var checked := AiClient.validate_attach_path(cand)
		if not bool(checked.get("ok", false)):
			continue
		var clean: String = checked["path"]
		if not FileAccess.file_exists(clean):
			print("[GdAI] attach skipped, not found: %s" % clean)
			continue
		if out.has(clean):
			continue
		out.append(clean)
	return out


## Formats attachments from live buffers, pointing at the open script.
func _attach_block_for(paths: Array[String]) -> String:
	if paths.is_empty():
		return ""
	# Skip re-sending the file already shown as the open script.
	var open_path := _current_script_path()
	var parts: Array[String] = ["", "[Attached files]"]
	var shown := 0
	for p in paths:
		if shown >= ATTACH_MAX_FILES:
			parts.append("(+%d more, over the %d-file attach limit)" % [paths.size() - shown, ATTACH_MAX_FILES])
			break
		if not open_path.is_empty() and p == open_path:
			parts.append("[Attached: %s — already included above as the open script]" % p)
			shown += 1
			continue
		if not FileAccess.file_exists(p):
			parts.append("[Attached: %s — file no longer exists, skipped]" % p)
			shown += 1
			continue
		var content := FileAccess.get_file_as_string(p)
		# Scripts prefer the live buffer so unsaved edits are included.
		var source := "disk"
		if p.to_lower().ends_with(".gd"):
			var buf := _open_buffer_for(p)
			if bool(buf.get("open", false)):
				content = str(buf.get("text", ""))
				source = "live buffer"
		# Cap content to the read budget.
		var lines := content.count("\n") + 1 if not content.is_empty() else 0
		var tail := ""
		if content.length() > MAX_READ_CHARS:
			content = content.left(MAX_READ_CHARS)
			tail = "\n… (truncated to %d chars)" % MAX_READ_CHARS
		parts.append("[Attached: %s (%d lines, %s)]:\n%s%s" % [p, lines, source, content, tail])
		shown += 1
	return "\n".join(parts)


## Returns the open script's path or empty when none.
static func _current_script_path() -> String:
	if not Engine.is_editor_hint():
		return ""
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return ""
	var cur: Script = script_editor.get_current_script()
	if cur == null:
		return ""
	return str(cur.resource_path)


## Finds a node by bare name only when uniquely matched.
static func _find_unique_named(root: Node, node_name: String):
	var matches := root.find_children(node_name, "", true, true)
	if matches.size() == 1:
		return matches[0]
	return null


## Formats a node path relative to the scene root.
func _scene_rel_path(root: Node, node: Node) -> String:
	if node == root:
		return "."
	if root.is_ancestor_of(node):
		return str(root.get_path_to(node))
	return str(node.get_path())


const MODEL_OPTIONS := ["muse-spark-1.3", "muse-spark-1.3-contributor", "muse-spark-1.2", "muse-spark-1.1"]


## Wires settings controls and fills model and effort options.
func _setup_settings_ui() -> void:
	# Wire the settings button, warning when the export is missing.
	if settings_button != null:
		settings_button.pressed.connect(_on_settings_button_pressed)
	else:
		push_warning("[GdAI] Settings button export is unassigned.")
	# Fill empty pickers from the built-in option lists.
	if model_picker != null and model_picker.item_count == 0:
		for option in MODEL_OPTIONS:
			model_picker.add_item(option)
	if effort_picker != null and effort_picker.item_count == 0:
		for option in AiClient.REASONING_EFFORT_OPTIONS:
			effort_picker.add_item(option)
	if settings_save_button != null:
		settings_save_button.pressed.connect(_on_settings_saved)
	else:
		push_warning("[GdAI] Settings save button export is unassigned.")
	if settings_menu == null:
		push_warning("[GdAI] Settings menu export is unassigned.")
	if api_key_field == null or endpoint_field == null or model_picker == null or effort_picker == null or loop_cap_spin == null:
		push_warning("[GdAI] One or more settings field exports are unassigned.")
	# Mask the key field, then show saved values.
	if api_key_field != null:
		api_key_field.secret = true
	_sync_settings_fields()


## Loads the saved loop cap, defaulting when unset or invalid.
static func _load_loop_cap() -> int:
	if not Engine.is_editor_hint():
		return DEFAULT_MAX_LOOP_TURNS
	var settings := EditorInterface.get_editor_settings()
	if settings != null and settings.has_setting(SETTINGS_MAX_LOOP_TURNS):
		return maxi(1, int(settings.get_setting(SETTINGS_MAX_LOOP_TURNS)))
	return DEFAULT_MAX_LOOP_TURNS


# Shows the settings tab while preserving any unsaved edits.
func _on_settings_button_pressed() -> void:
	_cancel_pending_tab() # staying on Settings answers the popup: drop any pending switch
	if settings_menu != null and settings_menu.visible:
		return # already viewing Settings: keep unsaved edits instead of re-syncing
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
	# Show the tab with saved values.
	_sync_settings_fields()


## Refreshes settings fields from saved values without exposing the key.
func _sync_settings_fields() -> void:
	if client == null:
		return
	# Key field never shows the real value, only a placeholder hint.
	if api_key_field != null:
		# Never mirror the real key here: @tool would persist it into an open .tscn on save.
		api_key_field.text = ""
		api_key_field.placeholder_text = "Key set (hidden) — type to replace" if not client.api_key.strip_edges().is_empty() else "Paste API key, sign in with Meta, or set MODEL_API_KEY"
	if endpoint_field != null:
		endpoint_field.text = client.api_url
	if loop_cap_spin != null:
		loop_cap_spin.value = max_loop_turns
	_select_model(client.model)
	_select_effort(client.reasoning_effort)
	_refresh_dirty_dots()


## Selects the saved model, adding unknown names as new rows.
func _select_model(model_name: String) -> void:
	if model_picker == null:
		return
	# Match the saved name against existing rows.
	var idx := -1
	for i in model_picker.item_count:
		if model_picker.get_item_text(i) == model_name:
			idx = i
			break
	# Unknown saved names join the list as new rows.
	if idx == -1 and not model_name.strip_edges().is_empty():
		model_picker.add_item(model_name.strip_edges())
		idx = model_picker.item_count - 1
	if idx != -1:
		model_picker.select(idx)


## Selects the saved effort, falling back on unknown values.
func _select_effort(effort: String) -> void:
	if effort_picker == null:
		return
	# Normalize the saved value, falling back on unknown text.
	var want := effort.strip_edges().to_lower()
	if not want in AiClient.REASONING_EFFORT_OPTIONS:
		want = AiClient.DEFAULT_REASONING_EFFORT
	for i in effort_picker.item_count:
		if effort_picker.get_item_text(i).strip_edges().to_lower() == want:
			effort_picker.select(i)
			return


# Saves settings fields and reloads the client configuration.
func _on_settings_saved() -> void:
	if client == null:
		return
	# Empty key field keeps the saved key; typed text replaces it.
	var typed_key := ""
	if api_key_field != null:
		typed_key = api_key_field.text.strip_edges()
	var switching := client.meta_session and not typed_key.is_empty() and typed_key != client.api_key.strip_edges()
	if not typed_key.is_empty():
		client.api_key = typed_key
	if endpoint_field != null:
		client.api_url = endpoint_field.text.strip_edges()
	# Apply the picked model and effort when valid.
	if model_picker != null and model_picker.selected >= 0:
		var picked := model_picker.get_item_text(model_picker.selected).strip_edges()
		if not picked.is_empty():
			client.model = picked
	if effort_picker != null and effort_picker.selected >= 0:
		var effort := effort_picker.get_item_text(effort_picker.selected).strip_edges().to_lower()
		if effort in AiClient.REASONING_EFFORT_OPTIONS:
			client.reasoning_effort = effort
	# Clamp the loop cap and persist it to editor settings.
	if loop_cap_spin != null:
		max_loop_turns = maxi(1, int(loop_cap_spin.value))
		if Engine.is_editor_hint():
			EditorInterface.get_editor_settings().set_setting(SETTINGS_MAX_LOOP_TURNS, max_loop_turns)
	if switching:
		client.clear_session() # typed key replaces the Meta session
	client.save_config()
	client.load_config()
	_update_session_status()
	_sync_settings_fields()


## Wires the unsaved-changes popup and its two buttons.
func _setup_unsaved_popup() -> void:
	if unsaved_changes_container != null:
		unsaved_changes_container.visible = false
	else:
		push_warning("[GdAI] Unsaved-changes popup export is unassigned.")
	if save_changes_button != null:
		save_changes_button.pressed.connect(_on_save_changes_pressed)
	else:
		push_warning("[GdAI] Save-changes button export is unassigned.")
	if exit_without_save_button != null:
		exit_without_save_button.pressed.connect(_on_exit_without_save_pressed)
	else:
		push_warning("[GdAI] Exit-without-save button export is unassigned.")


## Parks tab switches behind the popup when edits are unsaved.
func _confirm_leave_settings(target: String) -> bool:
	# Leave freely when Settings is hidden or clean.
	if settings_menu == null or not settings_menu.visible:
		return true
	if not _settings_have_unsaved_changes():
		return true
	if unsaved_changes_container == null:
		return true # no popup wired; let the switch through
	_pending_tab = target
	if settings_button != null:
		settings_button.button_pressed = true # stay visually on Settings while asking
	unsaved_changes_container.visible = true
	return false


## Reports whether any settings field differs from saved values.
func _settings_have_unsaved_changes() -> bool:
	return _api_key_dirty() or _endpoint_dirty() or _model_dirty() or _effort_dirty() or _loop_cap_dirty()


## Reports whether a replacement API key awaits saving.
func _api_key_dirty() -> bool:
	if client == null or api_key_field == null:
		return false
	return not api_key_field.text.strip_edges().is_empty() # cleared on sync, so any text is unapplied


## Reports whether the endpoint field differs from the saved value.
func _endpoint_dirty() -> bool:
	if client == null or endpoint_field == null:
		return false
	return endpoint_field.text.strip_edges() != client.api_url.strip_edges()


## Reports whether the picked model differs from the saved value.
func _model_dirty() -> bool:
	if client == null or model_picker == null or model_picker.selected < 0:
		return false
	return model_picker.get_item_text(model_picker.selected).strip_edges() != client.model.strip_edges()


## Reports whether the picked effort differs from the saved value.
func _effort_dirty() -> bool:
	if client == null or effort_picker == null or effort_picker.selected < 0:
		return false
	return effort_picker.get_item_text(effort_picker.selected).strip_edges().to_lower() != client.reasoning_effort.strip_edges().to_lower()


## Reports whether the loop cap differs from the saved value.
func _loop_cap_dirty() -> bool:
	if loop_cap_spin == null:
		return false
	return maxi(1, int(loop_cap_spin.value)) != max_loop_turns


## Styles dirty dots and wires fields to refresh them.
func _setup_dirty_dots() -> void:
	# Style every indicator before wiring field signals.
	for dot in [api_key_dirty_dot, endpoint_dirty_dot, model_dirty_dot, effort_dirty_dot, loop_cap_dirty_dot]:
		_style_dot(dot)
	if api_key_dirty_dot == null or endpoint_dirty_dot == null or model_dirty_dot == null or effort_dirty_dot == null or loop_cap_dirty_dot == null:
		push_warning("[GdAI] One or more dirty-dot exports are unassigned.")
	if api_key_field != null:
		api_key_field.text_changed.connect(_refresh_dirty_dots)
	if endpoint_field != null:
		endpoint_field.text_changed.connect(_refresh_dirty_dots)
	if model_picker != null:
		model_picker.item_selected.connect(_refresh_dirty_dots)
	if effort_picker != null:
		effort_picker.item_selected.connect(_refresh_dirty_dots)
	if loop_cap_spin != null:
		loop_cap_spin.value_changed.connect(_refresh_dirty_dots)
	_refresh_dirty_dots()


## Styles one dirty indicator dot and hides it initially.
func _style_dot(dot: Label) -> void:
	if dot == null:
		return
	dot.text = DIRTY_DOT_TEXT
	dot.add_theme_color_override("font_color", DIRTY_DOT_COLOR)
	dot.tooltip_text = "Unsaved change"
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.visible = false


# Refreshes every dirty dot from current field values.
func _refresh_dirty_dots(_changed = null) -> void: # optional arg: field signals each pass 1
	_set_dot(api_key_dirty_dot, _api_key_dirty())
	_set_dot(endpoint_dirty_dot, _endpoint_dirty())
	_set_dot(model_dirty_dot, _model_dirty())
	_set_dot(effort_dirty_dot, _effort_dirty())
	_set_dot(loop_cap_dirty_dot, _loop_cap_dirty())


## Shows or hides one dirty dot by its dirty flag.
func _set_dot(dot: Label, dirty: bool) -> void:
	if dot == null:
		return
	dot.visible = dirty


# Saves settings, then opens the tab parked behind the popup.
func _on_save_changes_pressed() -> void:
	var target := _pending_tab
	_cancel_pending_tab()
	_on_settings_saved()
	_open_pending_tab(target)


# Discards settings edits, then opens the parked tab.
func _on_exit_without_save_pressed() -> void:
	var target := _pending_tab
	_cancel_pending_tab()
	_sync_settings_fields() # revert fields to saved values
	_open_pending_tab(target)


## Drops the parked tab switch and hides the popup.
func _cancel_pending_tab() -> void:
	_pending_tab = ""
	if unsaved_changes_container != null:
		unsaved_changes_container.visible = false


## Shows the chat or history tab parked behind the popup.
func _open_pending_tab(target: String) -> void:
	match target:
		"chat":
			_show_chat_tab()
		"history":
			_show_history_tab()


## Wires sign-in controls while tolerating unassigned scene nodes.
func _setup_sign_in_ui() -> void:
	if sign_in_button != null:
		sign_in_button.pressed.connect(_on_sign_in_button_pressed)
	else:
		push_warning("[GdAI] Sign-in button export is unassigned.")
	if session_status_label == null:
		push_warning("[GdAI] Session status label export is unassigned.")
	if sign_in_open_browser_button != null:
		sign_in_open_browser_button.pressed.connect(_on_sign_in_open_browser_pressed)
	else:
		push_warning("[GdAI] Sign-in browser button export is unassigned.")
	if sign_in_cancel_button != null:
		sign_in_cancel_button.pressed.connect(_on_sign_in_cancel_pressed)
	else:
		push_warning("[GdAI] Sign-in cancel button export is unassigned.")
	if sign_in_code_field == null:
		push_warning("[GdAI] Sign-in code field export is unassigned.")
	if sign_out_button != null:
		sign_out_button.pressed.connect(_on_sign_out_button_pressed)
	else:
		push_warning("[GdAI] Sign-out button export is unassigned.")
	_set_sign_in_flow_visible(false)


## Shows flow-only sign-in nodes during an active sign-in.
func _set_sign_in_flow_visible(v: bool) -> void:
	if sign_in_popup != null:
		sign_in_popup.visible = v
	if sign_in_code_field != null:
		sign_in_code_field.visible = v
		if not v:
			sign_in_code_field.text = ""
	if sign_in_open_browser_button != null:
		sign_in_open_browser_button.visible = v
	if sign_in_cancel_button != null:
		sign_in_cancel_button.visible = v


# Starts the device sign-in flow and awaits the code signal.
func _on_sign_in_button_pressed() -> void:
	if client == null or client.sign_in_active:
		return
	# Reset flow state and lock the button while contacting Meta.
	_sign_in_uri = ""
	_set_sign_in_flow_visible(false)
	if sign_in_button != null:
		sign_in_button.disabled = true
	if session_status_label != null:
		session_status_label.text = "Contacting Meta sign-in…"
	client.begin_device_sign_in()


# Displays the device code and verification instructions for approval.
func _on_device_code_received(user_code: String, verification_uri: String, verification_uri_complete: String, _expires_in: int) -> void:
	# Prefer the complete URL, then show the code for approval.
	_sign_in_uri = verification_uri_complete if not verification_uri_complete.is_empty() else verification_uri
	if sign_in_code_field != null:
		sign_in_code_field.text = user_code
		sign_in_code_field.editable = false
	_set_sign_in_flow_visible(true)
	if session_status_label != null:
		session_status_label.text = "Enter code %s at %s (or press Open browser), then approve." % [user_code, verification_uri]


# Opens the verification URL for the in-flight sign-in.
func _on_sign_in_open_browser_pressed() -> void:
	if not _sign_in_uri.is_empty():
		OS.shell_open(_sign_in_uri)


# Cancels the in-flight device sign-in flow on request.
func _on_sign_in_cancel_pressed() -> void:
	if client != null:
		client.cancel_device_sign_in()


# Restores auth UI after a successful Meta sign-in.
func _on_sign_in_succeeded() -> void:
	_sign_in_uri = ""
	_update_auth_buttons()
	_set_sign_in_flow_visible(false)
	if sign_in_button != null:
		sign_in_button.disabled = false
	if session_status_label != null:
		session_status_label.text = "Signed in with Meta."


# Restores auth UI and reports the sign-in failure reason.
func _on_sign_in_failed(message: String) -> void:
	_sign_in_uri = ""
	_set_sign_in_flow_visible(false)
	if sign_in_button != null:
		sign_in_button.disabled = false
	if session_status_label != null:
		session_status_label.text = "Sign-in failed: %s" % message


# Restores auth UI after the sign-in is cancelled.
func _on_sign_in_cancelled() -> void:
	_sign_in_uri = ""
	_set_sign_in_flow_visible(false)
	if sign_in_button != null:
		sign_in_button.disabled = false
	_update_session_status()


## Swaps the stacked sign-in and sign-out buttons by session.
func _update_auth_buttons() -> void:
	var signed_in := client != null and client.meta_session
	if sign_in_button != null:
		sign_in_button.visible = not signed_in
	if sign_out_button != null:
		sign_out_button.visible = signed_in


# Clears the session and credentials, then refreshes auth UI.
func _on_sign_out_button_pressed() -> void:
	if client == null:
		return
	# Stop any in-flight flow, then wipe session and key.
	if client.sign_in_active:
		client.cancel_device_sign_in()
	client.clear_session()
	client.api_key = ""
	client.save_config()
	_sync_settings_fields()
	_update_session_status()


# Refreshes auth UI and surfaces session expiry as an error.
func _on_session_expired() -> void:
	_update_session_status() # session already cleared; flips status + buttons
	_on_ai_error("Meta session expired — press Sign in to sign in again.")


## Renders session status and keeps auth buttons in sync.
func _update_session_status() -> void:
	_update_auth_buttons()
	if session_status_label == null:
		return
	# Report which credential source is active.
	if client == null or client.api_key.strip_edges().is_empty():
		session_status_label.text = "Signed out — no API key configured."
		return
	var env_key := OS.get_environment("MODEL_API_KEY").strip_edges()
	if client.meta_session and env_key.is_empty():
		session_status_label.text = "Signed in with Meta."
	elif not env_key.is_empty():
		session_status_label.text = "Using MODEL_API_KEY from the environment (dev)."
	else:
		session_status_label.text = "API key loaded from editor settings."


## Runs validated tool calls as undoable actions, continuing past failures.
func execute_tool_calls(calls: Array) -> Array:
	# Run each call in order, recording failures inline.
	var results: Array = []
	for call in calls:
		if not call is Dictionary:
			results.append({"name": "?", "ok": false, "message": "call is not an object"})
			continue
		results.append(_execute_tool_call(call))
	return results


## Re-validates one tool call, then dispatches it to its operation.
func _execute_tool_call(call: Dictionary) -> Dictionary:
	# Reject malformed calls before touching the scene.
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
	var editable_problem := _check_targets_editable(fname, args)
	if not editable_problem.is_empty():
		return {"name": fname, "ok": false, "message": editable_problem}
	# Dispatch to the matching operation.
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
		"create_script":
			outcome = _op_create_script(args)
		"read_script":
			outcome = _op_read_script(args)
		"edit_script":
			outcome = _op_edit_script(args)
		"finish":
			outcome = _op_finish(args)
	# Shape the outcome, carrying detail for the model transcript.
	var final := {"name": fname, "ok": bool(outcome.get("ok", false)), "message": str(outcome.get("message", ""))}
	if outcome is Dictionary and outcome.has("detail"):
		final["detail"] = outcome["detail"] # full payload for the model's tool transcript; chat shows message only
	return final


## Snapshots live selection for undo, always cleared first and restored last.
static func _selection_snapshot() -> Array:
	var out: Array = []
	for sel_node in EditorInterface.get_selection().get_selected_nodes():
		if is_instance_valid(sel_node):
			out.append(sel_node)
	return out


## Skips targets inside locked nodes or uneditable instances with a reason.
func _check_targets_editable(fname: String, args: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return "" # each op reports "no scene is open" itself
	# Collect the node paths this action would touch.
	var targets: Array[String] = []
	match fname:
		"create_node":
			var parent_path := str(args.get("parent", "")).strip_edges()
			targets.append(parent_path if not parent_path.is_empty() else ".")
		"reparent_node":
			targets.append(str(args.get("node", "")))
			targets.append(str(args.get("new_parent", "")))
		"delete_node", "rename_node", "set_property", "attach_script", "set_anchors_preset":
			targets.append(str(args.get("node", "")))
		_:
			return ""
	# Reject locked nodes and uneditable instance interiors.
	for target in targets:
		var resolved := _resolve_scene_node(target)
		if resolved["node"] == null:
			return "" # let the op report not-found itself
		var node: Node = resolved["node"]
		if node.has_meta("_edit_lock_"):
			return "skipped: '%s' is locked in the editor" % node.name
		var locked_ancestor := _enclosing_uneditable_instance(root, node)
		if locked_ancestor != null:
			return "skipped: '%s' is inside uneditable instance '%s' (enable Editable Children on it)" % [node.name, locked_ancestor.name]
	return ""


## Finds the nearest uneditable instance ancestor above a node.
static func _enclosing_uneditable_instance(root: Node, node: Node) -> Node:
	# Climb parents looking for a locked instance root.
	var at := node.get_parent()
	while at != null and root.is_ancestor_of(at):
		if not str(at.scene_file_path).strip_edges().is_empty() and not root.is_editable_instance(at):
			return at
		at = at.get_parent()
	return null


## Resolves a scene-relative path to its edited-scene node.
func _resolve_scene_node(path_str: String) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"node": null, "error": "no scene is open"}
	# Empty or dot addresses the scene root itself.
	var clean := path_str.strip_edges()
	if clean.is_empty() or clean == ".":
		return {"node": root, "error": ""}
	var node := root.get_node_or_null(NodePath(clean))
	# Fall back to root-name and unique bare-name matches.
	if node == null and (clean == root.name or clean == root.scene_file_path.get_file().get_basename()):
		node = root
	if node == null and clean.find("/") == -1:
		node = _find_unique_named(root, clean)
	if node == null:
		return {"node": null, "error": "node not found: '%s'" % clean}
	# Reject nodes outside the edited scene.
	if node != root and not root.is_ancestor_of(node):
		return {"node": null, "error": "node '%s' is outside the edited scene" % clean}
	return {"node": node, "error": ""}


## Strips unsafe characters from a proposed node name.
static func _sanitize_node_name(base: String) -> String:
	return base.strip_edges().replace("/", "_").replace(":", "_")


## Derives a sibling-unique child name from a base name.
static func _unique_child_name(parent: Node, base: String) -> String:
	# Default empty names, then suffix until free.
	var clean := base.strip_edges()
	if clean.is_empty():
		clean = "Node"
	if not parent.has_node(clean):
		return clean
	var i := 2
	while parent.has_node("%s%d" % [clean, i]):
		i += 1
	return "%s%d" % [clean, i]


## Reports whether a node exposes the named property.
static func _has_property(node: Node, prop: String) -> bool:
	for p in node.get_property_list():
		if p is Dictionary and str(p.get("name", "")) == prop:
			return true
	return false


## Formats a value briefly for result messages with clipping.
static func _short_value(value: Variant) -> String:
	var text := str(value)
	if value is String:
		text = "'%s'" % value
	if text.length() > 48:
		return text.left(47) + "…"
	return text


## Coerces a JSON value into a fixed-count float array.
static func _to_float_array(value: Variant, count: int) -> Array:
	if not value is Array or value.size() != count:
		return []
	# Coerce each element, bailing on the first non-number.
	var out: Array = []
	for v in value:
		if v is float or (v is int and not (v is bool)):
			out.append(float(v))
		elif v is String and (v.strip_edges().is_valid_float() or v.strip_edges().is_valid_int()):
			out.append(float(v.strip_edges()))
		else:
			return []
	return out


## Coerces a JSON value to match the current property type.
static func _coerce_to_like(current: Variant, value: Variant) -> Dictionary:
	if current == null or value == null:
		return {"value": value, "error": ""}
	# Booleans accept true/false strings too.
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
	# Objects can't round-trip through JSON values.
	if current is Object:
		return {"value": null, "error": "resource/object properties are not supported yet"}
	if current is Array and value is Array:
		return {"value": value, "error": ""}
	if current is Dictionary and value is Dictionary:
		return {"value": value, "error": ""}
	# Map math types to their expected component count.
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


## Creates a node under its parent as one undoable action.
func _op_create_node(args: Dictionary) -> Dictionary:
	# Reject unknown or non-Node types before touching the scene.
	var node_type := str(args.get("node_type", "")).strip_edges()
	if node_type.is_empty():
		return {"ok": false, "message": "missing node_type"}
	if not ClassDB.class_exists(node_type) or not ClassDB.can_instantiate(node_type) or not ClassDB.is_parent_class(node_type, "Node"):
		return {"ok": false, "message": "unknown node type '%s'" % node_type}
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "message": "no scene is open"}
	# Default to the root; resolve an explicit parent when given.
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
	# Build the undoable add with ownership and selection.
	node.name = final_name
	var is_control := node is Control
	var sel := EditorInterface.get_selection()
	var sel_before := _selection_snapshot()
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create %s" % node_type)
	undo_redo.add_do_method(parent, "add_child", node, true)
	undo_redo.add_do_method(node, "set_owner", root)
	if is_control:
		# Controls start in Anchors layout mode, matching the editor.
		undo_redo.add_do_property(node, "layout_mode", LAYOUT_MODE_ANCHORS)
	undo_redo.add_do_method(sel, "clear")
	undo_redo.add_do_method(sel, "add_node", node)
	undo_redo.add_do_reference(node)
	# Reseat selection onto live nodes before removal so no inspector view references the node on tree-exit.
	undo_redo.add_undo_method(sel, "clear")
	for sel_node in sel_before:
		undo_redo.add_undo_method(sel, "add_node", sel_node)
		undo_redo.add_undo_reference(sel_node)
	undo_redo.add_undo_method(parent, "remove_child", node)
	undo_redo.commit_action()
	# Verify the add applied before reporting success.
	if node.get_parent() != parent or not node.is_inside_tree():
		return {"ok": false, "message": "create failed to apply under '%s'" % _scene_rel_path(root, parent)}
	return {"ok": true, "message": "created %s '%s' under '%s'" % [node_type, final_name, _scene_rel_path(root, parent)]}


## Deletes a node as one undoable action preserving owners.
func _op_delete_node(args: Dictionary) -> Dictionary:
	# Resolve the target; the root itself is never deletable.
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
	# Snapshot owners so undo restores the subtree exactly.
	var label := "%s '%s'" % [node.get_class(), node.name]
	var old_owner: Node = node.owner
	var heal_owner: Node = old_owner if old_owner != null else root
	var sub_owners: Array = []
	for d: Node in node.find_children("*", "", true, false):
		var downer: Node = d.owner
		sub_owners.append([d, downer if downer != null else root])
	var sel := EditorInterface.get_selection()
	var sel_before := _selection_snapshot()
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Delete Node")
	# History anchor: lead with a scene object, or the global selection misroutes with "history mismatch".
	undo_redo.add_do_method(node, "set_owner", heal_owner)
	undo_redo.add_do_method(sel, "remove_node", node)
	undo_redo.add_do_method(parent, "remove_child", node)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(sel, "clear")
	undo_redo.add_undo_method(parent, "add_child", node)
	undo_redo.add_undo_method(node, "set_owner", heal_owner)
	for pair in sub_owners:
		undo_redo.add_undo_method(pair[0], "set_owner", pair[1])
		undo_redo.add_undo_reference(pair[0])
	for sel_node in sel_before:
		undo_redo.add_undo_method(sel, "add_node", sel_node)
		undo_redo.add_undo_reference(sel_node)
	undo_redo.commit_action()
	# Verify the removal applied before reporting success.
	if node.is_inside_tree() or node.get_parent() != null:
		return {"ok": false, "message": "delete failed to apply on '%s'" % node.name}
	return {"ok": true, "message": "deleted %s" % label}


## Renames a node as one undoable action unless duplicated.
func _op_rename_node(args: Dictionary) -> Dictionary:
	var resolved := _resolve_scene_node(str(args.get("node", "")))
	if resolved["node"] == null:
		return {"ok": false, "message": str(resolved["error"])}
	# Sanitize the name and reject sibling collisions.
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
	# Apply the rename as one undoable step.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Rename Node")
	undo_redo.add_do_property(node, "name", new_name)
	undo_redo.add_undo_property(node, "name", old_name)
	undo_redo.commit_action()
	return {"ok": true, "message": "renamed '%s' to '%s'" % [old_name, new_name]}


## Moves a node to a new parent as one undoable action.
func _op_reparent_node(args: Dictionary) -> Dictionary:
	# Resolve the node; the root itself can never move.
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
	# Reject cycles and no-op moves onto the same parent.
	var new_parent: Node = presolved["node"]
	if new_parent == node or node.is_ancestor_of(new_parent):
		return {"ok": false, "message": "cannot reparent inside itself"}
	var old_parent := node.get_parent()
	if old_parent == null:
		return {"ok": false, "message": "node has no parent"}
	if old_parent == new_parent:
		return {"ok": true, "message": "already under '%s'" % _scene_rel_path(root, new_parent)}
	# Snapshot owners so undo restores the subtree exactly.
	var old_owner: Node = node.owner
	var heal_owner: Node = old_owner if old_owner != null else root
	var sub_owners: Array = []
	for d: Node in node.find_children("*", "", true, false):
		var downer: Node = d.owner
		sub_owners.append([d, downer if downer != null else root])
	var sel := EditorInterface.get_selection()
	var sel_before := _selection_snapshot()
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Reparent Node")
	# History anchor: first method targets a scene object; post-add set_owner restores since remove_child nulls owner.
	undo_redo.add_do_method(node, "set_owner", heal_owner)
	undo_redo.add_do_method(sel, "clear")
	undo_redo.add_do_method(old_parent, "remove_child", node)
	undo_redo.add_do_method(new_parent, "add_child", node, true)
	undo_redo.add_do_method(node, "set_owner", heal_owner)
	for pair in sub_owners:
		undo_redo.add_do_method(pair[0], "set_owner", pair[1])
		undo_redo.add_do_reference(pair[0])
	undo_redo.add_do_method(sel, "add_node", node)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(sel, "clear")
	undo_redo.add_undo_method(new_parent, "remove_child", node)
	undo_redo.add_undo_method(old_parent, "add_child", node, true)
	undo_redo.add_undo_method(node, "set_owner", heal_owner)
	for pair in sub_owners:
		undo_redo.add_undo_method(pair[0], "set_owner", pair[1])
	for sel_node in sel_before:
		undo_redo.add_undo_method(sel, "add_node", sel_node)
		undo_redo.add_undo_reference(sel_node)
	undo_redo.commit_action()
	# Verify the move applied before reporting success.
	if node.get_parent() != new_parent or not node.is_inside_tree() or node.owner == null:
		return {"ok": false, "message": "reparent failed to apply under '%s'" % _scene_rel_path(root, new_parent)}
	return {"ok": true, "message": "moved '%s' under '%s'" % [node.name, _scene_rel_path(root, new_parent)]}


## Sets a coerced property value as one undoable action.
func _op_set_property(args: Dictionary) -> Dictionary:
	# Resolve the node and confirm the property exists.
	var resolved := _resolve_scene_node(str(args.get("node", "")))
	if resolved["node"] == null:
		return {"ok": false, "message": str(resolved["error"])}
	var node: Node = resolved["node"]
	var prop := str(args.get("property", "")).strip_edges()
	if prop.is_empty():
		return {"ok": false, "message": "property name is empty"}
	if not _has_property(node, prop):
		return {"ok": false, "message": "'%s' has no property '%s'" % [node.name, prop]}
	# Coerce the JSON value to the property's type.
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


## Attaches a script to a scriptless node as one undoable action.
func _op_attach_script(args: Dictionary) -> Dictionary:
	# Resolve the node and confirm the script loads.
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


## Maps a preset name to its Control anchor constant.
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


## Maps a preset name to its horizontal and vertical grow directions.
static func _preset_grow_directions(preset_name: String) -> Array:
	# Grow = overflow direction from the anchor (verified on 4.6); overflow always extends into the parent.
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


## Creates a new script file without overwriting existing files.
func _op_create_script(args: Dictionary) -> Dictionary:
	# Validate the path and reject empty or existing files.
	var checked := AiClient.validate_script_path(str(args.get("path", "")))
	if not bool(checked.get("ok", false)):
		return {"ok": false, "message": str(checked.get("error", "bad path"))}
	var res_path: String = checked["path"]
	var content := str(args.get("content", ""))
	if content.strip_edges().is_empty():
		return {"ok": false, "message": "script content is empty"}
	if FileAccess.file_exists(res_path):
		return {"ok": false, "message": "'%s' already exists (won't overwrite)" % res_path}
	# Ensure the folder exists, then write and verify the file.
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(res_path.get_base_dir()))
	if dir_err != OK:
		return {"ok": false, "message": "could not create folder '%s' (error %d)" % [res_path.get_base_dir(), dir_err]}
	var f := FileAccess.open(res_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "message": "could not write '%s' (%s)" % [res_path, error_string(FileAccess.get_open_error())]}
	f.store_string(content)
	var write_err := f.get_error()
	f.close()
	if write_err != OK:
		return {"ok": false, "message": "failed writing '%s' (error %d)" % [res_path, write_err]}
	if not FileAccess.file_exists(res_path):
		return {"ok": false, "message": "write could not be verified on disk for '%s'" % res_path}
	# Rescan so the new file appears in the editor.
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	return {"ok": true, "message": "created script '%s' (%d bytes; verified on disk, not undoable)" % [res_path, content.to_utf8_buffer().size()]}


## Reads a script for the model, preferring its live buffer.
func _op_read_script(args: Dictionary) -> Dictionary:
	# Validate the path and confirm the file exists.
	var checked := AiClient.validate_script_path(str(args.get("path", "")))
	if not bool(checked.get("ok", false)):
		return {"ok": false, "message": str(checked.get("error", "bad path"))}
	var res_path: String = checked["path"]
	if not FileAccess.file_exists(res_path):
		return {"ok": false, "message": "'%s' does not exist" % res_path}
	# Prefer the live buffer, then truncate to the read cap.
	var content := FileAccess.get_file_as_string(res_path)
	var notes: Array[String] = []
	var buf := _open_buffer_for(res_path)
	if bool(buf.get("open", false)):
		content = str(buf.get("text", ""))
		notes.append("live buffer, unsaved changes included")
	if content.length() > MAX_READ_CHARS:
		notes.append("truncated, %d total chars" % content.length())
		content = content.left(MAX_READ_CHARS)
	var note := ""
	if not notes.is_empty():
		note = " (%s)" % "; ".join(notes)
	var line_count := 0
	if not content.is_empty():
		line_count = content.count("\n") + 1
	return {"ok": true, "message": "read '%s' (%d bytes, %d lines%s; content sent to model)" % [res_path, content.to_utf8_buffer().size(), line_count, note], "detail": content}


## Replaces one matched block in a script and verifies disk.
func _op_edit_script(args: Dictionary) -> Dictionary:
	# Validate the path and confirm the file exists.
	var checked := AiClient.validate_script_path(str(args.get("path", "")))
	if not bool(checked.get("ok", false)):
		return {"ok": false, "message": str(checked.get("error", "bad path"))}
	var res_path: String = checked["path"]
	if not FileAccess.file_exists(res_path):
		return {"ok": false, "message": "'%s' does not exist (use create_script first)" % res_path}
	# Edit from the live buffer when open, else from disk.
	var buf := _open_buffer_for(res_path)
	var buf_open := bool(buf.get("open", false))
	var source_text := str(buf.get("text", "")) if buf_open else FileAccess.get_file_as_string(res_path)
	var edited := AiClient.apply_script_edit(source_text, str(args.get("find", "")), str(args.get("replace", "")))
	if not bool(edited.get("ok", false)):
		return {"ok": false, "message": str(edited.get("error", "edit failed"))}
	if bool(edited.get("noop", false)):
		return {"ok": true, "message": "no change: find and replace are identical"}
	var f := FileAccess.open(res_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "message": "could not write '%s' (%s)" % [res_path, error_string(FileAccess.get_open_error())]}
	f.store_string(str(edited.get("content", "")))
	var write_err := f.get_error()
	f.close()
	if write_err != OK:
		return {"ok": false, "message": "failed writing '%s' (error %d)" % [res_path, write_err]}
	if FileAccess.get_file_as_string(res_path) != str(edited.get("content", "")):
		return {"ok": false, "message": "write could not be verified on disk for '%s'" % res_path}
	# Sync the open editor, then report success.
	_reload_script_in_editor(res_path, str(edited.get("content", "")))
	var src_note := " from live buffer" if buf_open else ""
	return {"ok": true, "message": "edited '%s' (1 block replaced%s; verified on disk, not undoable)" % [res_path, src_note]}


## Refreshes open editor views after a script disk write.
static func _reload_script_in_editor(res_path: String, new_text: String) -> void:
	# Push the new text into the open editor and filesystem cache.
	if Engine.is_editor_hint():
		var script_editor := EditorInterface.get_script_editor()
		if script_editor != null:
			var cur: Script = script_editor.get_current_script()
			if cur != null and cur.resource_path == res_path:
				var ed = script_editor.get_current_editor()
				if ed != null and ed.has_method("get_base_editor"):
					var base = ed.get_base_editor()
					if base is TextEdit:
						(base as TextEdit).text = new_text
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null and fs.has_method("update_file"):
			fs.call("update_file", res_path)
	# Reload the resource so runtime state matches disk.
	if ResourceLoader.exists(res_path):
		var res := ResourceLoader.load(res_path)
		if res != null and res.has_method("reload"):
			res.call("reload")


## Reads live buffer text when a script is open in the editor.
static func _open_buffer_for(res_path: String) -> Dictionary:
	# Default to closed; only the current script can match.
	var out := {"open": false, "text": ""}
	if not Engine.is_editor_hint():
		return out
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return out
	var cur: Script = script_editor.get_current_script()
	if cur == null or cur.resource_path != res_path:
		return out
	var ed = script_editor.get_current_editor()
	if ed != null and ed.has_method("get_base_editor"):
		var base = ed.get_base_editor()
		if base is TextEdit:
			out["open"] = true
			out["text"] = (base as TextEdit).text
	return out


## Returns the model's summary as the turn's final result.
func _op_finish(args: Dictionary) -> Dictionary:
	var summary := str(args.get("summary", "")).strip_edges()
	if summary.is_empty():
		summary = "Done."
	return {"ok": true, "message": summary}


## Applies an anchors preset to a Control as one undoable action.
func _op_set_anchors_preset(args: Dictionary) -> Dictionary:
	# Resolve the node and confirm it is a Control.
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
	# Warn when the parent overrides or starves anchors.
	var note := ""
	var layout_parent := node.get_parent()
	if layout_parent != null and layout_parent is Container:
		note = " (parent %s is a Container and overrides anchors; use size_flags instead)" % layout_parent.name
	elif layout_parent is Control:
		var psize: Vector2 = layout_parent.size
		if psize.x < 1.0 or psize.y < 1.0:
			note = " (parent '%s' is %dx%d — anchors are relative to it, so size the parent first, e.g. full_rect on the parent, then re-run)" % [layout_parent.name, int(psize.x), int(psize.y)]
	# Apply preset plus grow directions as one undoable step.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Set Anchors Preset")
	undo_redo.add_do_property(node, "layout_mode", LAYOUT_MODE_ANCHORS)
	# Probe-verified (4.6.3): plain set_anchors_preset misplaces center/full_rect; KEEP_SIZE matches the editor Layout menu.
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


## Derives a short chat title from the first message line.
func _make_title(text: String) -> String:
	var line := text.split("\n")[0].strip_edges()
	return line if line.length() <= 40 else line.substr(0, 40) + "…"


## Frees all message rows and dismisses any pending approval.
func _clear_message_list() -> void:
	_continue_button = null # rows (and the button) are freed below
	# Dismiss any pending approval without applying.
	if not _pending_approval.is_empty():
		var pending: Dictionary = _pending_approval
		_pending_approval = {}
		_update_pending_record(pending, str(pending.get("base_text", "")) + "\nDismissed (chat cleared) — no changes applied.")
	# Free every message row.
	for child in message_list.get_children():
		message_list.remove_child(child)
		child.queue_free()


## Cancels any active request and clears loop state.
func _cancel_pending_request() -> void:
	if client != null and client.busy:
		client.cancel()
	pending_ai_message = null
	_end_loop()


# Discards the current view and starts a fresh empty chat.
func _on_new_chat_button_pressed() -> void:
	_cancel_pending_request()
	current_chat = {}
	_clear_message_list()
	_on_chat_button_pressed()
	_on_user_input_box_text_changed()
	user_input_box.grab_focus()


# Open the chat from the message history.
func _open_chat(id: String) -> void:
	_cancel_pending_request()
	var chat := ChatStore.load_chat(id)
	if chat.is_empty():
		return
	# Swap in the loaded chat and rebuild its bubbles.
	current_chat = chat
	_clear_message_list()
	var messages = chat.get("messages", [])
	if messages is Array:
		for msg in messages:
			if msg is Dictionary:
				var is_user := str(msg.get("role", "")) == "user"
				add_message(str(msg.get("content", "")), is_user, not is_user) # restored AI text is final
	_on_chat_button_pressed()


# Deletes a saved chat, clearing the view when current.
func _delete_chat(id: String) -> void:
	ChatStore.delete_chat(id)
	# Clear the view when the open chat was deleted.
	if str(current_chat.get("id", "")) == id:
		_cancel_pending_request()
		current_chat = {}
		_clear_message_list()
	_refresh_history_list()


## Rebuilds the history list rows from saved chats.
func _refresh_history_list() -> void:
	# Remove all history rows.
	for child in history_list.get_children():
		history_list.remove_child(child)
		child.queue_free()

	# Show a placeholder when no chats are saved.
	var chats := ChatStore.list_chats()
	if chats.is_empty():
		var empty := Label.new()
		empty.text = "No saved chats yet"
		history_list.add_child(empty)
		return

	# Add one row per saved chat.
	for chat in chats:
		history_list.add_child(_make_history_row(chat))


## Builds one history row with open and delete buttons.
func _make_history_row(chat: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new() # Row holding the open and delete buttons.

	# Open-chat button.
	var open_button := Button.new()
	open_button.text = str(chat.get("title", "Untitled"))
	open_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	open_button.clip_text = true
	open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_button.pressed.connect(_open_chat.bind(str(chat.get("id", ""))))

	# Delete-chat button.
	var delete_button := Button.new()
	delete_button.text = "✕"
	delete_button.pressed.connect(_delete_chat.bind(str(chat.get("id", ""))))

	# Assemble and return the row.
	row.add_child(open_button)
	row.add_child(delete_button)
	return row
