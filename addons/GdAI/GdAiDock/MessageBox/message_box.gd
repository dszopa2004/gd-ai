@tool
class_name MessageBox
extends Container # BoxContainer root once reworked; PanelContainer root still works

signal delete_requested(message: MessageBox)
signal retry_requested(message: MessageBox)

@export var label: RichTextLabel
@export var copy_button: BaseButton # Button or TextureButton
@export var delete_button : BaseButton
## AI-only regenerate button. Same layout sizing as copy_button; textures are
## user-supplied via the scene, like the other action buttons.
@export var retry_button : BaseButton
@export var bubble: PanelContainer # inner bubble in the reworked scene; null in the legacy scene
@export var segments: VBoxContainer # segment host; null until the scene adds it (legacy label path meanwhile)
@export var usage_label: Label

static var _bubble_warned := false
static var _re_cache := {}

const COPY_TOOLTIP := "Copy response"
const DELETE_TOOLTIP := "Delete message"
const RETRY_TOOLTIP := "Retry response"
const ACTION_MODULATE_NORMAL := Color.WHITE
const ACTION_MODULATE_HOVER := Color(1.25, 1.25, 1.25)
const ACTION_MODULATE_PRESSED := Color(0.75, 0.75, 0.75)
const HOVER_SLOP_PX := 1.0 # forgiveness for landings exactly on a rect edge
const CODE_BG := "#1f1f24"
const CODE_BG_COLOR := Color(0.122, 0.122, 0.141)
const CODE_FG_COLOR := Color(0.87, 0.87, 0.88)
const CODE_RADIUS := 6
const CODE_BORDER := Color(1, 1, 1, 0.09)
# Syntax-highlight palette for code blocks (dark CODE_BG backdrop).
const HL_KEYWORD := "#ff7085"
const HL_STRING := "#ffeda1"
const HL_COMMENT := "#808080"
const HL_NUMBER := "#a1ffe0"
const HL_FUNCTION := "#66c3ff"
const HL_MEMBER := "#bce0ff"

var _pending_text := ""
var _usage: Dictionary = {}
var _copy_visible := false
var _copy_hover := false
var _hover := false
var _copy_shown := false
var _delete_hover := false
var _delete_shown := false
var _retry_last := false # dock-set: this box is the last AI message shown (its retry target)
var _retry_hover := false
var _retry_shown := false
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
	if retry_button != null:
		retry_button.tooltip_text = RETRY_TOOLTIP
		retry_button.pressed.connect(_on_retry_pressed)
		retry_button.mouse_entered.connect(_on_retry_mouse_entered)
		retry_button.mouse_exited.connect(_on_retry_mouse_exited)
		retry_button.button_down.connect(_on_retry_button_down)
		retry_button.button_up.connect(_on_retry_button_up)
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
	_apply_retry_visibility()
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


# Per-language lexer config: keywords, line-comment marker, block-comment
# pair, single-line string quotes, triple-quote openers (checked first).
# Unknown languages return {} and render as plain escaped code — never
# mis-highlighted under a guessed grammar.
static func _lang_spec(lang: String) -> Dictionary:
	match lang:
		"gdscript", "gd":
			return {
				"keywords": ["extends", "class_name", "signal", "enum", "const", "static", "var", "func", "return", "pass", "break", "continue", "if", "elif", "else", "for", "while", "match", "in", "is", "as", "and", "or", "not", "self", "super", "true", "false", "null", "void", "await", "breakpoint", "get", "set", "PI", "TAU", "INF", "NAN"],
				"line": "#",
				"block": [],
				"strings": ["\"", "'"],
				"triple": ["\"\"\""],
			}
		"python", "py":
			return {
				"keywords": ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"],
				"line": "#",
				"block": [],
				"strings": ["\"", "'"],
				"triple": ["\"\"\"", "'''"],
			}
		"json":
			return {
				"keywords": ["true", "false", "null"],
				"line": "",
				"block": [],
				"strings": ["\""],
				"triple": [],
			}
		"csharp", "cs", "c#":
			return {
				"keywords": ["using", "namespace", "class", "struct", "enum", "interface", "record", "const", "static", "readonly", "void", "var", "int", "uint", "long", "ulong", "short", "ushort", "byte", "sbyte", "char", "string", "bool", "object", "dynamic", "float", "double", "decimal", "if", "else", "for", "foreach", "while", "do", "switch", "case", "default", "break", "continue", "goto", "return", "try", "catch", "finally", "throw", "new", "this", "base", "true", "false", "null", "async", "await", "public", "private", "protected", "internal", "sealed", "override", "virtual", "abstract", "partial", "extern", "get", "set", "value", "out", "ref", "in", "params", "is", "as", "typeof", "sizeof", "nameof"],
				"line": "//",
				"block": ["/*", "*/"],
				"strings": ["\"", "'"],
				"triple": [],
			}
		"cpp", "c", "h", "hpp", "c++":
			return {
				"keywords": ["auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "explicit", "extern", "false", "float", "for", "friend", "goto", "if", "inline", "int", "long", "mutable", "namespace", "new", "nullptr", "operator", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "wchar_t", "while"],
				"line": "//",
				"block": ["/*", "*/"],
				"strings": ["\"", "'"],
				"triple": [],
			}
		"glsl", "shader", "gdshader", "vert", "frag":
			return {
				"keywords": ["shader_type", "render_mode", "uniform", "varying", "const", "in", "out", "inout", "highp", "mediump", "lowp", "precision", "invariant", "void", "bool", "int", "uint", "float", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "mat2", "mat3", "mat4", "sampler2D", "sampler3D", "samplerCube", "struct", "if", "else", "for", "while", "do", "break", "continue", "return", "discard", "true", "false", "layout", "binding", "readonly", "writeonly", "centroid", "flat", "smooth", "noperspective"],
				"line": "//",
				"block": ["/*", "*/"],
				"strings": ["\""],
				"triple": [],
			}
		"javascript", "js":
			return {
				"keywords": ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "null", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield", "await", "async", "of", "from", "as", "get", "set"],
				"line": "//",
				"block": ["/*", "*/"],
				"strings": ["\"", "'"],
				"triple": [],
			}
		"bash", "sh", "shell":
			return {
				"keywords": ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "in", "case", "esac", "select", "function", "return", "exit", "echo", "printf", "local", "export", "readonly", "shift", "break", "continue"],
				"line": "#",
				"block": [],
				"strings": ["\"", "'"],
				"triple": [],
			}
	return {}


# Highlight one fence body as BBCode. A single linear pass (it re-runs on
# every stream update); unclosed strings/comments run to end-of-input so
# mid-stream text stays valid, and brackets are always escaped so code can
# never inject tags. Beyond keywords/strings/comments/numbers: word( calls,
# .members, @annotations, and $NodePaths get their own colors.
static func highlight_code(code: String, lang: String) -> String:
	var spec := _lang_spec(lang.strip_edges().to_lower())
	if spec.is_empty():
		return _escape_bbcode(code)
	var keywords: Array = spec["keywords"]
	var line_c := str(spec.get("line", ""))
	var block: Array = spec.get("block", [])
	var quotes: Array = spec.get("strings", [])
	var triples: Array = spec.get("triple", [])
	var out: Array[String] = []
	var i := 0
	var n := code.length()
	while i < n:
		if line_c != "" and code.substr(i, line_c.length()) == line_c:
			var eol := code.find("\n", i)
			if eol < 0:
				eol = n
			out.append("[color=" + HL_COMMENT + "][i]" + _escape_bbcode(code.substr(i, eol - i)) + "[/i][/color]")
			i = eol
			continue
		if not block.is_empty() and code.substr(i, str(block[0]).length()) == str(block[0]):
			var close := str(block[1])
			var bend := code.find(close, i + str(block[0]).length())
			if bend < 0:
				bend = n
			else:
				bend += close.length()
			out.append("[color=" + HL_COMMENT + "][i]" + _escape_bbcode(code.substr(i, bend - i)) + "[/i][/color]")
			i = bend
			continue
		var tri_end := _triple_end(code, i, triples)
		if tri_end >= 0:
			out.append("[color=" + HL_STRING + "]" + _escape_bbcode(code.substr(i, tri_end - i)) + "[/color]")
			i = tri_end
			continue
		if quotes.has(code[i]):
			var lit := _scan_string(code, i)
			out.append("[color=" + HL_STRING + "]" + _escape_bbcode(lit) + "[/color]")
			i += lit.length()
			continue
		if code[i] == "$" and i + 1 < n:
			if code[i + 1] == "\"":
				var qs := _scan_string(code, i + 1)
				out.append("[color=" + HL_STRING + "]$" + _escape_bbcode(qs) + "[/color]")
				i += 1 + qs.length()
				continue
			if _is_ident(code[i + 1]):
				var m := i + 1
				while m < n and (_is_ident(code[m]) or code[m] == "/" or code[m] == "%"):
					m += 1
				out.append("[color=" + HL_MEMBER + "]" + _escape_bbcode(code.substr(i, m - i)) + "[/color]")
				i = m
				continue
		if code[i] == "@" and i + 1 < n and _is_ident_start(code[i + 1]):
			var a := i + 1
			while a < n and _is_ident(code[a]):
				a += 1
			out.append("[color=" + HL_KEYWORD + "]" + _escape_bbcode(code.substr(i, a - i)) + "[/color]")
			i = a
			continue
		if _is_ident_start(code[i]) or _is_digit(code[i]):
			var w := i
			while w < n and _is_ident(code[w]):
				w += 1
			var word := code.substr(i, w - i)
			if _is_digit(word[0]):
				var tail := _re("^(\\.\\d[\\d_]*)?([eE][+-]?\\d[\\d_]*)?").search(code.substr(w)).get_string(0)
				word += tail
				w += tail.length()
				if _re("^(0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(\\.\\d[\\d_]*)?([eE][+-]?\\d[\\d_]*)?)$").search(word) != null:
					out.append("[color=" + HL_NUMBER + "]" + _escape_bbcode(word) + "[/color]")
				else:
					out.append(_escape_bbcode(word))
			elif i > 0 and code[i - 1] == ".":
				out.append("[color=" + HL_MEMBER + "]" + _escape_bbcode(word) + "[/color]")
			elif keywords.has(word):
				out.append("[color=" + HL_KEYWORD + "]" + _escape_bbcode(word) + "[/color]")
			elif _followed_by_paren(code, w):
				out.append("[color=" + HL_FUNCTION + "]" + _escape_bbcode(word) + "[/color]")
			else:
				out.append(_escape_bbcode(word))
			i = w
			continue
		out.append(_escape_bbcode(code[i]))
		i += 1
	return "".join(out)


# End index (exclusive) of the triple-quoted string opening at i, or -1 when
# no triple opener matches there. Unclosed runs to end-of-input.
static func _triple_end(code: String, i: int, triples: Array) -> int:
	for t in triples:
		var opener := str(t)
		if code.substr(i, opener.length()) == opener:
			var n := code.length()
			var j := i + opener.length()
			while j < n:
				if code[j] == "\\":
					j += 2
					continue
				if code.substr(j, opener.length()) == opener:
					return j + opener.length()
				j += 1
			return n
	return -1


# Raw substring of the single-line string whose opening quote is at i:
# backslash escapes honored, closing quote included, unclosed runs to EOL.
static func _scan_string(code: String, i: int) -> String:
	var q := code[i]
	var j := i + 1
	var n := code.length()
	while j < n and code[j] != q and code[j] != "\n":
		if code[j] == "\\":
			j += 1
		j += 1
	if j < n and code[j] == q:
		j += 1
	return code.substr(i, j - i)


static func _followed_by_paren(code: String, w: int) -> bool:
	var p := w
	while p < code.length() and (code[p] == " " or code[p] == "\t"):
		p += 1
	return p < code.length() and code[p] == "("


static func _is_digit(c: String) -> bool:
	return c >= "0" and c <= "9"


static func _is_ident_start(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"


static func _is_ident(c: String) -> bool:
	return _is_ident_start(c) or _is_digit(c)


# Legacy single-label path: fences to BBCode (prose markdown-lite, code escaped).
static func render_markdown(text: String) -> String:
	if not text.contains("```"):
		return markdown_lite(text)
	var out: Array[String] = []
	for part in split_markdown(text):
		var d: Dictionary = part
		if bool(d.get("code", false)):
			out.append("[bgcolor=" + CODE_BG + "][code]" + highlight_code(str(d.get("text", "")), str(d.get("lang", ""))) + "[/code][/bgcolor]")
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
	l.bbcode_enabled = true # highlighted code: highlight_code escapes brackets
	l.text = highlight_code(code_text, lang)
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
	# Flat decides which action buttons can ever show; refresh collapse state
	# so a flat change never leaves a stale slot behind.
	_apply_copy_visibility()
	_apply_delete_visibility()
	_apply_retry_visibility()


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
	_apply_retry_visibility() # copy-ready is also the retry finality gate


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
	_hover = _covers_button(copy_button, _copy_shown, mouse) or _covers_button(delete_button, _delete_shown, mouse) or _covers_button(retry_button, _retry_shown, mouse) or get_global_rect().grow(HOVER_SLOP_PX).has_point(mouse)
	_apply_copy_visibility()
	_apply_delete_visibility()
	_apply_retry_visibility()


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
	# User rows hold the slot (hover reveals must not reflow the chat); AI
	# rows can never show delete, so the slot collapses instead of gaping.
	delete_button.visible = not _flat
	delete_button.mouse_filter = Control.MOUSE_FILTER_STOP if _delete_shown else Control.MOUSE_FILTER_IGNORE
	_refresh_delete_modulate(false)


func is_delete_shown() -> bool:
	return _delete_shown


# Retry shows only on the last AI message and only once its turn is final
# (_copy_visible is the finality flag, so Thinking/awaiting/streaming turns
# never offer retry). User messages never show it. Layout-stable like copy.
func set_retry_last(v: bool) -> void:
	_retry_last = v
	_apply_retry_visibility()


func _apply_retry_visibility() -> void:
	if retry_button == null:
		return
	_retry_shown = _flat and _retry_last and _copy_visible
	# AI rows hold the slot (last-flag moves must not reflow); user rows can
	# never show retry, so the slot collapses instead of gaping.
	retry_button.visible = _flat
	retry_button.mouse_filter = Control.MOUSE_FILTER_STOP if _retry_shown else Control.MOUSE_FILTER_IGNORE
	_refresh_retry_modulate(false)


func is_retry_shown() -> bool:
	return _retry_shown


func _on_retry_pressed() -> void:
	retry_requested.emit(self)


func _on_retry_mouse_entered() -> void:
	_retry_hover = true
	_refresh_retry_modulate(false)
	_queue_hover_refresh()


func _on_retry_mouse_exited() -> void:
	_retry_hover = false
	_refresh_retry_modulate(false)
	_queue_hover_refresh()


func _on_retry_button_down() -> void:
	_refresh_retry_modulate(true)


func _on_retry_button_up() -> void:
	_refresh_retry_modulate(false)


func _refresh_retry_modulate(pressed: bool) -> void:
	if retry_button == null:
		return
	var c := ACTION_MODULATE_NORMAL
	if pressed:
		c = ACTION_MODULATE_PRESSED
	elif _retry_hover:
		c = ACTION_MODULATE_HOVER
	c.a = 1.0 if _retry_shown else 0.0
	retry_button.modulate = c


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
