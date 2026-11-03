@tool
class_name MessageBox
extends Container # BoxContainer root once reworked; PanelContainer root still works

signal delete_requested(message: MessageBox)

@export var label: RichTextLabel
@export var copy_button: BaseButton # Button or TextureButton
@export var delete_button : BaseButton
@export var bubble: PanelContainer # inner bubble in the reworked scene; null in the legacy scene
@export var segments: VBoxContainer # segment host; null until the scene adds it (legacy label path meanwhile)
@export var usage_label: Label

static var _bubble_warned := false
static var _re_cache := {}

const COPY_TOOLTIP := "Copy response"
const DELETE_TOOLTIP := "Delete message"
const ACTION_MODULATE_NORMAL := Color.WHITE
const ACTION_MODULATE_HOVER := Color(1.25, 1.25, 1.25)
const ACTION_MODULATE_PRESSED := Color(0.75, 0.75, 0.75)
const HOVER_SLOP_PX := 1.0 # forgiveness for landings exactly on a rect edge
const CODE_BG := "#1f1f24"
const CODE_BG_COLOR := Color(0.122, 0.122, 0.141)
const CODE_FG_COLOR := Color(0.87, 0.87, 0.88)
const CODE_RADIUS := 6
const CODE_BORDER := Color(1, 1, 1, 0.09)

var _pending_text := ""
var _usage: Dictionary = {}
var _copy_visible := false
var _copy_hover := false
var _hover := false
var _copy_shown := false
var _delete_hover := false
var _delete_shown := false
var _flat := false
var _flat_style := StyleBoxEmpty.new()
var _mono_font: Font = null


func _ready() -> void:
	if segments != null:
		if label != null:
			if label.get_parent() == segments:
				segments.remove_child(label)
				label.queue_free()
			else:
				label.visible = false
			label = null # legacy path retired; never dangles
		_render_segments(_pending_text)
	elif label != null:
		label.text = render_markdown(_pending_text)
	if bubble == null and get_class() != "PanelContainer" and not _bubble_warned:
		_bubble_warned = true
		push_warning("[GdAI] MessageBox bubble export is unassigned.")
	if copy_button != null:
		copy_button.tooltip_text = COPY_TOOLTIP
		copy_button.pressed.connect(_on_copy_pressed)
		copy_button.mouse_entered.connect(_on_copy_mouse_entered)
		copy_button.mouse_exited.connect(_on_copy_mouse_exited)
		copy_button.button_down.connect(_on_copy_button_down)
		copy_button.button_up.connect(_on_copy_button_up)
	if delete_button != null:
		delete_button.tooltip_text = DELETE_TOOLTIP
		delete_button.pressed.connect(_on_delete_pressed)
		delete_button.mouse_entered.connect(_on_delete_mouse_entered)
		delete_button.mouse_exited.connect(_on_delete_mouse_exited)
		delete_button.button_down.connect(_on_delete_button_down)
		delete_button.button_up.connect(_on_delete_button_up)
	# Hover funnel: the engine notifies whichever child is under the cursor,
	# so every hoverable part recomputes from geometry (order-independent).
	mouse_entered.connect(_queue_hover_refresh)
	mouse_exited.connect(_queue_hover_refresh)
	if bubble != null:
		bubble.mouse_entered.connect(_queue_hover_refresh)
		bubble.mouse_exited.connect(_queue_hover_refresh)
	if label != null:
		label.mouse_entered.connect(_queue_hover_refresh)
		label.mouse_exited.connect(_queue_hover_refresh)
	_apply_flat() # set_flat may have run before exports resolved
	_apply_copy_visibility()
	_apply_delete_visibility()
	_apply_usage()


func set_message_text(text: String) -> void:
	_pending_text = text # raw markdown: clipboard and history keep this
	if segments != null:
		_render_segments(text)
	elif label != null:
		label.text = render_markdown(text)
	if copy_button != null:
		copy_button.tooltip_text = COPY_TOOLTIP


# Split raw text into [{code: bool, text: String, lang: String}] on ```
# fences. Empty parts are dropped; an unclosed fence (mid-stream) runs to
# the end.
static func split_markdown(text: String) -> Array:
	var parts: Array = []
	var buf: Array[String] = []
	var in_code := false
	var lang := ""
	for line in text.split("\n"):
		if line.strip_edges().begins_with("```"):
			_flush_part(parts, buf, in_code, lang)
			if not in_code:
				lang = line.strip_edges().substr(3).strip_edges()
			in_code = not in_code
		else:
			buf.append(line)
	_flush_part(parts, buf, in_code, lang)
	return parts


static func _flush_part(parts: Array, buf: Array[String], was_code: bool, lang: String) -> void:
	if buf.is_empty():
		return
	parts.append({"code": was_code, "text": "\n".join(buf), "lang": lang if was_code else ""})
	buf.clear()


static func _escape_bbcode(s: String) -> String:
	return s.replace("[", "\\[").replace("]", "\\]")


# Legacy single-label path: fences to BBCode (prose markdown-lite, code escaped).
static func render_markdown(text: String) -> String:
	if not text.contains("```"):
		return markdown_lite(text)
	var out: Array[String] = []
	for part in split_markdown(text):
		var d: Dictionary = part
		if bool(d.get("code", false)):
			out.append("[bgcolor=" + CODE_BG + "][code]" + _escape_bbcode(str(d.get("text", ""))) + "[/code][/bgcolor]")
		else:
			out.append(markdown_lite(str(d.get("text", ""))))
	return "\n".join(out)


# Markdown-lite for prose: headers, lists, links, bold, italic, inline code.
# Single-underscore and double-underscore marks are deliberately unsupported
# (snake_case and __dunder__ names must survive). No tables/quotes/hr (yet).
static func markdown_lite(text: String) -> String:
	var out: Array[String] = []
	var block_re := _re("^([ \\t]*)(#{1,6}|[-*]|\\d+\\.)[ \\t]+(.*)$")
	for line in text.split("\n"):
		var m := block_re.search(line)
		if m == null:
			out.append(_md_inline(line))
			continue
		var indent: String = m.get_string(1)
		var marker: String = m.get_string(2)
		var content := _md_inline(m.get_string(3))
		if marker.begins_with("#"):
			var level := marker.length()
			if level <= 3:
				var size: int = [22, 19, 17][level - 1]
				out.append("[font_size=%d][b]%s[/b][/font_size]" % [size, content])
			else:
				out.append("[b]%s[/b]" % content)
		elif marker == "-" or marker == "*":
			out.append("\t".repeat(1 + mini(indent.length() / 2, 4)) + "• " + content)
		else:
			out.append("\t".repeat(1 + mini(indent.length() / 2, 4)) + marker + " " + content)
	return "\n".join(out)


static func _md_inline(line: String) -> String:
	# Code spans first, stashed behind private-use placeholders so their
	# contents (and their brackets) survive the passes below untouched.
	var mark := String.chr(0xE000)
	var spans: Array[String] = []
	var code_re := _re("`([^`\n]+)`")
	var out := line
	var m := code_re.search(out)
	while m != null:
		spans.append(m.get_string(1))
		out = out.substr(0, m.get_start()) + mark + str(spans.size() - 1) + mark + out.substr(m.get_end())
		m = code_re.search(out)
	out = _re("\\[([^\\[\\]]+)\\]\\(([^)\\s]+)\\)").sub(out, "[url=$2]$1[/url]", true)
	out = _re("\\*\\*\\*(.+?)\\*\\*\\*").sub(out, "[b][i]$1[/i][/b]", true)
	out = _re("\\*\\*(.+?)\\*\\*").sub(out, "[b]$1[/b]", true)
	out = _re("\\*([^\\*\\n]+)\\*").sub(out, "[i]$1[/i]", true)
	for i in spans.size():
		out = out.replace(mark + str(i) + mark, "[code]" + _escape_bbcode(spans[i]) + "[/code]")
	return out


static func _re(pattern: String) -> RegEx:
	if not _re_cache.has(pattern):
		var r := RegEx.new()
		r.compile(pattern)
		_re_cache[pattern] = r
	return _re_cache[pattern]


# Segmented path: prose labels plus real PanelContainers for code.
func _render_segments(raw: String) -> void:
	for c in segments.get_children():
		segments.remove_child(c)
		c.queue_free()
	for part in split_markdown(raw):
		var d: Dictionary = part
		if bool(d.get("code", false)):
			segments.add_child(_make_code_block(str(d.get("text", "")), str(d.get("lang", ""))))
		else:
			segments.add_child(_make_prose_label(str(d.get("text", ""))))


func _make_prose_label(prose: String) -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.text = markdown_lite(prose)
	l.fit_content = true
	l.scroll_active = false
	l.selection_enabled = true
	l.focus_mode = Control.FOCUS_CLICK
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _flat:
		l.add_theme_stylebox_override("normal", _flat_style)
		l.add_theme_stylebox_override("focus", _flat_style)
	l.mouse_entered.connect(_queue_hover_refresh)
	l.mouse_exited.connect(_queue_hover_refresh)
	return l


func _make_code_block(code_text: String, lang: String) -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = CODE_BG_COLOR
	sb.set_corner_radius_all(CODE_RADIUS)
	sb.set_border_width_all(1)
	sb.border_color = CODE_BORDER
	panel.add_theme_stylebox_override("panel", sb)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	var vbox := VBoxContainer.new()
	var header := HBoxContainer.new()
	if not lang.is_empty():
		var lang_label := Label.new()
		lang_label.text = lang
		lang_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.62))
		lang_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		header.add_child(lang_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	header.add_child(_make_code_copy_button(code_text))
	vbox.add_child(header)
	var l := RichTextLabel.new()
	l.bbcode_enabled = false # literal code: no escaping needed
	l.text = code_text
	l.fit_content = true
	l.scroll_active = false
	l.selection_enabled = true
	l.focus_mode = Control.FOCUS_CLICK
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_override("normal_font", _mono_font_cached())
	l.add_theme_color_override("default_color", CODE_FG_COLOR)
	vbox.add_child(l)
	margin.add_child(vbox)
	panel.add_child(margin)
	panel.mouse_entered.connect(_queue_hover_refresh)
	panel.mouse_exited.connect(_queue_hover_refresh)
	l.mouse_entered.connect(_queue_hover_refresh)
	l.mouse_exited.connect(_queue_hover_refresh)
	return panel


const CODE_COPY_ICON_PATH := "res://addons/GdAI/GdAiDock/MessageBox/code_copy_icon.png"
const CODE_COPY_HOVER_PATH := "res://addons/GdAI/GdAiDock/MessageBox/code_copy_icon_hover.png"


func _make_code_copy_button(code_text: String) -> BaseButton:
	var btn: BaseButton
	if ResourceLoader.exists(CODE_COPY_ICON_PATH):
		var t := TextureButton.new()
		t.texture_normal = load(CODE_COPY_ICON_PATH) as Texture2D
		if ResourceLoader.exists(CODE_COPY_HOVER_PATH):
			t.texture_hover = load(CODE_COPY_HOVER_PATH) as Texture2D
		t.ignore_texture_size = true
		t.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		t.custom_minimum_size = Vector2(32, 32)
		btn = t
	else:
		var b := Button.new()
		b.text = "Copy"
		btn = b
	btn.tooltip_text = "Copy code"
	btn.pressed.connect(_on_code_copy_pressed.bind(code_text, btn))
	btn.mouse_entered.connect(_on_code_copy_hover.bind(btn, true))
	btn.mouse_exited.connect(_on_code_copy_hover.bind(btn, false))
	btn.button_down.connect(_on_code_copy_press.bind(btn, true))
	btn.button_up.connect(_on_code_copy_press.bind(btn, false))
	return btn


func _on_code_copy_pressed(code_text: String, btn: BaseButton) -> void:
	DisplayServer.clipboard_set(code_text)
	btn.tooltip_text = "Copied!"


func _on_code_copy_hover(btn: BaseButton, hovering: bool) -> void:
	btn.modulate = ACTION_MODULATE_HOVER if hovering else ACTION_MODULATE_NORMAL
	_queue_hover_refresh()


func _on_code_copy_press(btn: BaseButton, pressed: bool) -> void:
	if pressed:
		btn.modulate = ACTION_MODULATE_PRESSED
	else:
		var over := btn.get_global_rect().has_point(btn.get_global_mouse_position())
		btn.modulate = ACTION_MODULATE_HOVER if over else ACTION_MODULATE_NORMAL


func _mono_font_cached() -> Font:
	if _mono_font == null:
		var mono := SystemFont.new()
		mono.font_names = PackedStringArray(["Menlo", "Consolas", "Courier New", "monospace"])
		_mono_font = mono # size comes from the label theme at draw time, matching prose
	return _mono_font


func append_message_text(chunk: String) -> void:
	_pending_text += chunk
	if label != null:
		label.append_text(chunk)


# Flat mode drops the bubble background (AI flow): the panel stylebox plus the
# label's own normal/focus backgrounds. The MarginContainer keeps text
# padding. Non-flat restores the themed bubble (user messages).
func set_flat(flat: bool) -> void:
	_flat = flat
	_apply_flat()


# Reworked scene: the bubble export. Legacy scene: the root itself (the
# static type can't express the legacy root, hence the native-class check).
func _message_panel() -> PanelContainer:
	if bubble != null:
		return bubble
	if get_class() == "PanelContainer":
		return get_node(".") as PanelContainer
	return null


func _apply_flat() -> void:
	var panel := _message_panel()
	if _flat:
		if panel != null:
			panel.add_theme_stylebox_override("panel", _flat_style)
		if label != null:
			label.add_theme_stylebox_override("normal", _flat_style)
			label.add_theme_stylebox_override("focus", _flat_style)
	else:
		if panel != null:
			panel.remove_theme_stylebox_override("panel")
		if label != null:
			label.remove_theme_stylebox_override("normal")
			label.remove_theme_stylebox_override("focus")


func is_flat() -> bool:
	return _flat


# Copy button shows on AI responses only; null-safe until the scene wires it.
func set_copy_visible(v: bool) -> void:
	_copy_visible = v
	_apply_copy_visibility()


func _apply_copy_visibility() -> void:
	if copy_button == null:
		return
	# AI (flat): pinned by copy-ready state. User: revealed on hover only.
	_copy_shown = _copy_visible if _flat else _hover
	# Layout-stable: the button always holds its slot; transparency + mouse
	# filter hide it, so toggling never shifts the chat.
	copy_button.visible = true
	copy_button.mouse_filter = Control.MOUSE_FILTER_STOP if _copy_shown else Control.MOUSE_FILTER_IGNORE
	_refresh_copy_modulate(false)


func is_copy_shown() -> bool:
	return _copy_shown


# Hover truth comes from geometry, not event order: any enter/exit on any
# part recomputes whether the mouse is over the message or its buttons.
# Runs twice: immediately (same-frame probes and the common case) plus
# deferred (mouse position can lag signal dispatch by an event).
func _queue_hover_refresh() -> void:
	_refresh_hover()
	_refresh_hover.call_deferred()


func _refresh_hover() -> void:
	var mouse := get_global_mouse_position()
	_hover = _covers_button(copy_button, _copy_shown, mouse) or _covers_button(delete_button, _delete_shown, mouse) or get_global_rect().grow(HOVER_SLOP_PX).has_point(mouse)
	_apply_copy_visibility()
	_apply_delete_visibility()


static func _covers_button(button: BaseButton, shown: bool, mouse: Vector2) -> bool:
	return button != null and shown and button.get_global_rect().grow(HOVER_SLOP_PX).has_point(mouse)


func is_copy_visible() -> bool:
	return _copy_visible


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(_pending_text)
	if copy_button != null:
		copy_button.tooltip_text = "Copied!"


# Hover/press feedback without extra textures: brighten on hover, dim while
# held. All four signals pass 0 args, matching these handlers.
func _on_copy_mouse_entered() -> void:
	_copy_hover = true
	_refresh_copy_modulate(false)
	_queue_hover_refresh()


func _on_copy_mouse_exited() -> void:
	_copy_hover = false
	_refresh_copy_modulate(false)
	_queue_hover_refresh()


func _on_copy_button_down() -> void:
	_refresh_copy_modulate(true)


func _on_copy_button_up() -> void:
	_refresh_copy_modulate(false)


func _refresh_copy_modulate(pressed: bool) -> void:
	if copy_button == null:
		return
	var c := ACTION_MODULATE_NORMAL
	if pressed:
		c = ACTION_MODULATE_PRESSED
	elif _copy_hover:
		c = ACTION_MODULATE_HOVER
	c.a = 1.0 if _copy_shown else 0.0
	copy_button.modulate = c


# Delete reveals on user-message hover exactly like the user copy button; it
# never shows on AI responses.
func _apply_delete_visibility() -> void:
	if delete_button == null:
		return
	_delete_shown = (not _flat) and _hover
	delete_button.visible = true
	delete_button.mouse_filter = Control.MOUSE_FILTER_STOP if _delete_shown else Control.MOUSE_FILTER_IGNORE
	_refresh_delete_modulate(false)


func is_delete_shown() -> bool:
	return _delete_shown


# Per-turn token usage, shown under AI responses once the turn completes.
# Hidden until set (user messages never set it).
func set_usage(prompt_tokens: int, completion_tokens: int) -> void:
	_usage = {"prompt": prompt_tokens, "completion": completion_tokens}
	_apply_usage()


func get_usage() -> Dictionary:
	return _usage


func _apply_usage() -> void:
	if usage_label == null:
		return
	if _usage.is_empty():
		usage_label.visible = false
		return
	usage_label.text = format_usage(int(_usage.get("prompt", 0)), int(_usage.get("completion", 0)))
	usage_label.visible = true


static func format_usage(prompt_tokens: int, completion_tokens: int) -> String:
	return "%s in · %s out" % [_fmt_k(prompt_tokens), _fmt_k(completion_tokens)]


static func _fmt_k(n: int) -> String:
	if n < 1000:
		return str(n)
	if n % 1000 == 0:
		return "%dk" % (n / 1000)
	return "%.1fk" % (float(n) / 1000.0)


func _on_delete_pressed() -> void:
	delete_requested.emit(self)


func _on_delete_mouse_entered() -> void:
	_delete_hover = true
	_refresh_delete_modulate(false)
	_queue_hover_refresh()


func _on_delete_mouse_exited() -> void:
	_delete_hover = false
	_refresh_delete_modulate(false)
	_queue_hover_refresh()


func _on_delete_button_down() -> void:
	_refresh_delete_modulate(true)


func _on_delete_button_up() -> void:
	_refresh_delete_modulate(false)


func _refresh_delete_modulate(pressed: bool) -> void:
	if delete_button == null:
		return
	var c := ACTION_MODULATE_NORMAL
	if pressed:
		c = ACTION_MODULATE_PRESSED
	elif _delete_hover:
		c = ACTION_MODULATE_HOVER
	c.a = 1.0 if _delete_shown else 0.0
	delete_button.modulate = c
