@tool
extends EditorPlugin

var dock: EditorDock

## Instantiates the dock scene and registers the GD AI editor dock.
func _enter_tree() -> void:
	# Load the dock UI scene.
	var scene := preload("res://addons/GdAI/GdAiDock/GdAiDock.tscn").instantiate()

	# Wrap the scene in a configured dock.
	dock = EditorDock.new()
	dock.add_child(scene)
	dock.title = "GD AI"
	dock.default_slot = EditorDock.DOCK_SLOT_LEFT_UL
	dock.available_layouts = EditorDock.DOCK_LAYOUT_HORIZONTAL | EditorDock.DOCK_LAYOUT_FLOATING
	# Register the dock with the editor.
	add_dock(dock)

## Removes and frees the GD AI editor dock on plugin unload.
func _exit_tree() -> void:
	remove_dock(dock)
	dock.queue_free()
	dock = null
