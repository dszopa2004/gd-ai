@tool
extends EditorPlugin

var dock: EditorDock

func _enter_tree() -> void:
	var scene := preload("res://addons/GdAI/GdAiDock/GdAiDock.tscn").instantiate()

	dock = EditorDock.new()
	dock.add_child(scene)
	dock.title = "GD AI"
	dock.default_slot = EditorDock.DOCK_SLOT_LEFT_UL
	dock.available_layouts = EditorDock.DOCK_LAYOUT_HORIZONTAL | EditorDock.DOCK_LAYOUT_FLOATING
	add_dock(dock)

func _exit_tree() -> void:
	remove_dock(dock)
	dock.queue_free()
	dock = null
