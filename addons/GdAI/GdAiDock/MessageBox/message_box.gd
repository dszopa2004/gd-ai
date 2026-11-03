@tool
class_name MessageBox
extends Container # BoxContainer root once reworked; PanelContainer root still works

@export var label: RichTextLabel
@export var copy_button: BaseButton # Button or TextureButton
@export var bubble: PanelContainer # inner bubble in the reworked scene; null in the legacy scene

static var _bubble_warned := false

const COPY_TOOLTIP := "Copy response"
const COPY_MODULATE_NORMAL := Color.WHITE
const COPY_MODULATE_HOVER := Color(1.25, 1.25, 1.25)
const COPY_MODULATE_PRESSED := Color(0.75, 0.75, 0.75)

var _pending_text := ""
var _copy_visible := false
var _copy_hover := false
var _hover := false
var _copy_shown := false
var _flat := false
var _flat_style := StyleBoxEmpty.new()


func _ready() -> void:
	label.text = _pending_text
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
	# Hover funnel: the engine notifies whichever child is under the cursor,
	# so every hoverable part recomputes from geometry (order-independent).
	mouse_entered.connect(_refresh_hover)
	mouse_exited.connect(_refresh_hover)
	if bubble != null:
		bubble.mouse_entered.connect(_refresh_hover)
		bubble.mouse_exited.connect(_refresh_hover)
	if label != null:
		label.mouse_entered.connect(_refresh_hover)
		label.mouse_exited.connect(_refresh_hover)
	_apply_flat() # set_flat may have run before exports resolved
	_apply_copy_visibility()


func set_message_text(text: String) -> void:
	_pending_text = text
	if label != null:
		label.text = text
	if copy_button != null:
		copy_button.tooltip_text = COPY_TOOLTIP


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
# part recomputes whether the mouse is over the message or its button.
func _refresh_hover() -> void:
	var btn_rect := Rect2()
	var btn_vis := false
	if copy_button != null:
		btn_rect = copy_button.get_global_rect()
		btn_vis = _copy_shown
	_hover = _hover_covers(get_global_rect(), btn_rect, btn_vis, get_global_mouse_position())
	_apply_copy_visibility()


static func _hover_covers(msg_rect: Rect2, btn_rect: Rect2, btn_visible: bool, mouse: Vector2) -> bool:
	if msg_rect.has_point(mouse):
		return true
	return btn_visible and btn_rect.has_point(mouse)


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
	_refresh_hover()


func _on_copy_mouse_exited() -> void:
	_copy_hover = false
	_refresh_copy_modulate(false)
	_refresh_hover()


func _on_copy_button_down() -> void:
	_refresh_copy_modulate(true)


func _on_copy_button_up() -> void:
	_refresh_copy_modulate(false)


func _refresh_copy_modulate(pressed: bool) -> void:
	if copy_button == null:
		return
	var c := COPY_MODULATE_NORMAL
	if pressed:
		c = COPY_MODULATE_PRESSED
	elif _copy_hover:
		c = COPY_MODULATE_HOVER
	c.a = 1.0 if _copy_shown else 0.0
	copy_button.modulate = c
